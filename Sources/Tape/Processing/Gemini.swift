import CryptoKit
import Foundation
import TapeCore
import os

/// Transcribes a recording with Gemini (`gemini-3.8-flash`, which handles Khmer mixed with English best):
/// the audio goes up through the Files API, an interaction runs in the background while Tape checks on it,
/// and the uploaded file is deleted afterwards.
struct Gemini {
    static let model = "gemini-3.8-flash"
    private static let base = URL(string: "https://generativelanguage.googleapis.com")!

    let key: String
    private let endpoint: URL
    private let session: URLSession
    private let preparedAudio: ((URL) throws -> Void)?
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "gemini")

    init(key: String, endpoint: URL = Self.base, session: URLSession = .shared,
         preparedAudio: ((URL) throws -> Void)? = nil) {
        self.key = key
        self.endpoint = endpoint
        self.session = session
        self.preparedAudio = preparedAudio
    }

    struct Failure: LocalizedError {
        let message: String
        /// A failure on Gemini's side that may not happen again.
        var retryable = false
        /// Discard partial output and retry smaller, non-overlapping audio pieces.
        var splitAudio = false
        var errorDescription: String? { message }
    }

    static let partLength: Double = 5 * 60
    private static let minimumPiece: Int = 60 * AudioPreparation.sampleRate

    private struct Checkpoint: Codable {
        var fingerprint: String
        var preparedDigest: String?
        var pieces: [String: String] = [:]
        var split: Set<String> = []
    }

    func transcribe(_ audio: URL, prompt: String, checkpoint: URL? = nil,
                    preparedDuration: @escaping @MainActor (Double) -> Void = { _ in },
                    progress: @escaping (String) -> Void) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tape-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func digest(_ url: URL, suffix: String = "") throws -> String {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            hash.update(data: Data(suffix.utf8))
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        // Hash original bytes: separate decodes can differ through resampling/dither and end padding.
        let fingerprint = try digest(audio, suffix: Self.model + "|high|300s-pcm-v2|" + prompt +
            RecapPrompts.transcription(part: 1, of: 1, previous: "checkpoint context"))
        var state = Checkpoint(fingerprint: fingerprint)
        var prepared = folder.appendingPathComponent("recording.wav")
        let cachedAudio = checkpoint?.deletingPathExtension().appendingPathExtension("wav")
        if let checkpoint, let data = try? Data(contentsOf: checkpoint),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: data), saved.fingerprint == fingerprint,
           let cachedAudio, let expected = saved.preparedDigest,
           (try? AudioPreparation.frames(in: cachedAudio)) != nil, (try? digest(cachedAudio)) == expected {
            state = saved
            prepared = cachedAudio
        }
        func save() throws {
            guard let checkpoint else { return }
            try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
        }
        if state.preparedDigest == nil {
            progress("Preparing 16 kHz mono audio…")
            try await AudioPreparation.wav(from: audio, to: prepared)
            state.preparedDigest = try digest(prepared)
            if let cachedAudio {
                try FileManager.default.createDirectory(at: cachedAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: cachedAudio.path) {
                    _ = try FileManager.default.replaceItemAt(cachedAudio, withItemAt: prepared)
                } else {
                    try FileManager.default.moveItem(at: prepared, to: cachedAudio)
                }
                prepared = cachedAudio
            }
            try save()
        }
        try preparedAudio?(prepared)
        let total = try AudioPreparation.frames(in: prepared)
        let rate = AudioPreparation.sampleRate
        await preparedDuration(Double(total) / Double(rate))
        let pieceFrames = Int(Self.partLength) * rate
        let count = (total + pieceFrames - 1) / pieceFrames
        func piece(start: Int, frames: Int, label: String, number: Int, previous: String?) async throws -> String {
            try Task.checkCancellation()
            let key = "\(start):\(frames)"
            if let saved = state.pieces[key], !saved.isEmpty {
                progress("\(label): reusing saved transcript…")
                return saved
            }
            if !state.split.contains(key) {
                let wav = folder.appendingPathComponent("\(key).wav")
                try AudioPreparation.slice(prepared, start: start, count: frames, to: wav)
                defer { try? FileManager.default.removeItem(at: wav) }
                let context = RecapPrompts.transcription(part: number, of: count, previous: previous)
                let requestPrompt = prompt + "\n\n" + context.replacingOccurrences(of: RecapPrompts.transcription, with: "")
                do {
                    let raw = try await withRetry {
                        try await transcribePrepared(wav, prompt: requestPrompt) { progress("\(label): \($0.lowercased())") }
                    }
                    let cleaned = Transcript.cleanedPart(raw)
                    guard !cleaned.isEmpty else { throw Failure(message: "Gemini returned no transcript lines.", splitAudio: true) }
                    let text = Transcript.shifted(cleaned, by: Double(start) / Double(rate))
                    state.pieces[key] = text
                    try save()
                    log.notice("Completed audio piece at \(start / rate) s, length \(Double(frames) / Double(rate)) s")
                    return text
                } catch let failure as Failure where failure.splitAudio {
                    guard frames > Self.minimumPiece else {
                        throw Failure(message: "Gemini couldn't finish even a short audio piece. Completed pieces are saved; try again.")
                    }
                    state.split.insert(key)
                    try save()
                    progress("\(label): retrying in smaller pieces…")
                }
            }
            let half = frames / 2
            let first = try await piece(start: start, frames: half, label: label + ".1", number: number, previous: previous)
            let second = try await piece(start: start + half, frames: frames - half, label: label + ".2", number: number,
                                         previous: first.components(separatedBy: "\n").suffix(12).joined(separator: "\n"))
            let text = first + "\n\n" + second
            state.pieces[key] = text
            try save()
            return text
        }
        var transcript: [String] = []
        for index in 0..<count {
            let start = index * pieceFrames
            let previous = transcript.last.map { $0.components(separatedBy: "\n").suffix(12).joined(separator: "\n") }
            transcript.append(try await piece(start: start, frames: min(pieceFrames, total - start),
                                             label: "Part \(index + 1) of \(count)", number: index + 1, previous: previous))
        }
        return transcript.joined(separator: "\n\n")
    }

    private func transcribePrepared(_ wav: URL, prompt: String, progress: @escaping (String) -> Void) async throws -> String {
        progress("Uploading…")
        let file = try await upload(wav)
        do {
            try await waitUntilActive(file.name)
            progress("Transcribing…")
            let transcript = try await interact(prompt: prompt, fileURI: file.uri, mimeType: file.mimeType)
            await removeUpload(file.name)
            return transcript
        } catch {
            await removeUpload(file.name)
            throw error
        }
    }

    private func removeUpload(_ name: String) async {
        do { try await delete(name) }
        catch { log.error("Couldn't delete uploaded audio from Gemini: \(error.localizedDescription, privacy: .public)") }
    }

    /// Tries again (twice, after 5 and 20 seconds) when Gemini fails on its side or the network drops; not
    /// for a refused key or an exhausted quota.
    private func withRetry(_ work: () async throws -> String) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch let failure as Failure where failure.retryable && attempt < 2 {
                log.notice("Gemini failed (\(failure.message, privacy: .public)); trying again")
            } catch let error as URLError where attempt < 2 {
                log.notice("Network error (\(error.localizedDescription, privacy: .public)); trying again")
            }
            attempt += 1
            try await Task.sleep(for: .seconds(attempt == 1 ? 5 : 20))
        }
    }

    // MARK: - Files API

    private struct UploadedFile {
        let name: String
        let uri: String
        let mimeType: String
    }

    private func upload(_ audio: URL) async throws -> UploadedFile {
        let size = (try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? 0
        let mimeType = await Library.audioTypes[audio.pathExtension.lowercased()] ?? "audio/m4a"
        var start = request("upload/v1beta/files", method: "POST")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": audio.lastPathComponent]])
        let (_, startResponse) = try await send(start)
        guard let uploadURL = (startResponse.value(forHTTPHeaderField: "x-goog-upload-url")).flatMap(URL.init(string:)) else {
            throw Failure(message: "Gemini didn't accept the upload.")
        }
        var upload = URLRequest(url: uploadURL, timeoutInterval: 600)
        upload.httpMethod = "POST"
        upload.setValue(String(size), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (data, response) = try await session.upload(for: upload, fromFile: audio)
        try check(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["file"] as? [String: Any], let name = file["name"] as? String, let uri = file["uri"] as? String
        else { throw Failure(message: "Gemini's upload reply was unexpected.") }
        log.notice("Uploaded \(size) bytes as \(name, privacy: .public)")
        return UploadedFile(name: name, uri: uri, mimeType: (file["mimeType"] as? String) ?? mimeType)
    }

    /// Audio is processed for a moment after upload before it can be used.
    private func waitUntilActive(_ name: String) async throws {
        for _ in 0..<120 {
            let (data, _) = try await send(request("v1beta/\(name)", method: "GET"))
            let state = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["state"] as? String
            if state == nil || state == "ACTIVE" { return }
            if state == "FAILED" { throw Failure(message: "Gemini couldn't read the recording.") }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure(message: "Gemini took too long to take the recording in.")
    }

    private func delete(_ name: String) async throws {
        _ = try await send(request("v1beta/\(name)", method: "DELETE"))
    }

    // MARK: - Interactions API

    private func interact(prompt: String, fileURI: String, mimeType: String) async throws -> String {
        var body: [String: Any] = [
            "model": Self.model,
            "input": [
                ["type": "text", "text": prompt],
                ["type": "audio", "uri": fileURI, "mime_type": mimeType],
            ],
            "generation_config": ["thinking_level": "high", "max_output_tokens": 65_536],
            "background": true,
        ]
        var create = request("v1beta/interactions", method: "POST", timeout: 1800)
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: body)
        var data: Data
        do {
            (data, _) = try await send(create)
        } catch let failure as Failure where failure.message.lowercased().contains("background") {
            // Background runs not offered for this key or model: wait for the answer on the same request.
            body["background"] = nil
            create.httpBody = try JSONSerialization.data(withJSONObject: body)
            (data, _) = try await send(create)
        }
        var interaction = try parse(data)
        // A long recording takes a few minutes: check on it every 5 seconds (for up to 90 minutes).
        var waited = 0
        while (interaction["status"] as? String) == "in_progress", let id = interaction["id"] as? String {
            guard waited < 90 * 60 else { throw Failure(message: "Gemini took longer than 90 minutes.") }
            try await Task.sleep(for: .seconds(5))
            waited += 5
            (data, _) = try await send(request("v1beta/interactions/\(id)", method: "GET"))
            interaction = try parse(data)
        }
        let status = interaction["status"] as? String ?? "unknown"
        let text = Self.text(of: interaction)
        switch status {
        case "completed" where !text.isEmpty:
            return text
        case "incomplete", "requires_continuation":
            let usage = interaction["usage"] as? [String: Any]
            let output = usage?["total_output_tokens"] as? Int ?? 0
            let thoughts = usage?["total_thought_tokens"] as? Int ?? 0
            log.notice("Transcription \(status, privacy: .public): output \(output) tokens, thinking \(thoughts) tokens; splitting audio")
            throw Failure(message: "Gemini didn't finish this audio piece.", splitAudio: true)
        case "completed" where text.isEmpty:
            throw Failure(message: "Gemini returned an empty transcript.", splitAudio: true)
        default:
            let errors = (interaction["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String }.joined(separator: " ")
            log.error("Interaction \(status, privacy: .public): \(errors ?? "", privacy: .public)")
            throw Failure(message: "Gemini couldn't transcribe the recording (\(status): \(errors?.isEmpty == false ? errors! : "no reason given")).",
                          retryable: status == "failed")
        }
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Gemini's reply was unexpected.")
        }
        return json
    }

    /// The model's text: `steps[type == model_output].content[type == text].text`.
    private static func text(of interaction: [String: Any]) -> String {
        let steps = interaction["steps"] as? [[String: Any]] ?? []
        return steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP

    private func request(_ path: String, method: String, timeout: TimeInterval = 120) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        try check(data, response)
        return (data, response as! HTTPURLResponse)
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No reply from Gemini.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        // The error comes as {"error": {...}}, or (from the Interactions API) as [{"error": {...}}].
        let json = try? JSONSerialization.jsonObject(with: data)
        let body = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        let message = (body?["error"] as? [String: Any])?["message"] as? String
        switch http.statusCode {
        case 400 where message?.lowercased().contains("api key") == true, 401, 403:
            throw Failure(message: "Gemini didn't accept the API key. Check it in Settings.")
        case 429:
            throw Failure(message: "Gemini's rate limit or quota was reached. Try again in a while.")
        default:
            throw Failure(message: "Gemini error \(http.statusCode): \(message ?? "unknown")", retryable: http.statusCode >= 500)
        }
    }
}
