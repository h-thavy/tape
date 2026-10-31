import AVFoundation
import Foundation
import TapeCore
import os

/// Transcribes a recording with Gemini (`gemini-3.8-flash`, which handles Khmer mixed with English best):
/// the audio goes up through the Files API, an interaction runs in the background while Tape checks on it,
/// and the uploaded file is deleted afterwards.
struct Gemini {
    static let model = "gemini-3.8-flash"
    static let summaryModel = "gemini-3.8-flash"
    private static let base = URL(string: "https://generativelanguage.googleapis.com")!

    let key: String
    private let endpoint: URL
    private let session: URLSession
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "gemini")

    init(key: String, endpoint: URL = Self.base, session: URLSession = .shared) {
        self.key = key
        self.endpoint = endpoint
        self.session = session
    }

    struct Failure: LocalizedError {
        let message: String
        /// A failure on Gemini's side that may not happen again.
        var retryable = false
        var errorDescription: String? { message }
    }

    /// Recordings longer than this go in parts: Gemini fails on long audio in one go ("There was a problem
    /// processing your request", every time, on a 32-minute call).
    static let partLength: Double = 10 * 60

    func transcribe(_ audio: URL, prompt: String, progress: @escaping (String) -> Void) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tape-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Some formats (notably OGG) report a different asset timeline from their decoded audio. Cutting
        // that timeline can repeat speech at boundaries. Normalize first, then split the decoded timeline.
        progress("Preparing 16 kHz mono audio…")
        let prepared = folder.appendingPathComponent("recording.wav")
        try await AudioPreparation.wav(from: audio, to: prepared)
        let duration = try await AVURLAsset(url: prepared).load(.duration).seconds
        guard duration > Self.partLength * 1.2 else {
            return try await withRetry { try await transcribePrepared(prepared, prompt: prompt, progress: progress) }
        }
        let count = Int((duration / Self.partLength).rounded(.up))
        var transcript: [String] = []
        for index in 0..<count {
            let start = Double(index) * Self.partLength
            let part = folder.appendingPathComponent("part \(index + 1).m4a")
            try await Self.cut(prepared, from: start, length: min(Self.partLength, duration - start), to: part)
            // The end of the part before, so the same voices keep the same labels.
            let previous = transcript.last.map { $0.components(separatedBy: "\n").suffix(12).joined(separator: "\n") }
            let text = try await withRetry {
                try await transcribeFile(part, prompt: RecapPrompts.transcription(part: index + 1, of: count, previous: previous)) { message in
                    progress("Part \(index + 1) of \(count): \(message.lowercased())")
                }
            }
            transcript.append(Transcript.shifted(Transcript.cleanedPart(text), by: start))
            log.notice("Transcribed part \(index + 1) of \(count)")
        }
        return transcript.joined(separator: "\n\n")
    }

    private func transcribeFile(_ audio: URL, prompt: String, progress: @escaping (String) -> Void) async throws -> String {
        progress("Preparing 16 kHz mono audio…")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tape-wav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("audio.wav")
        try await AudioPreparation.wav(from: audio, to: wav)
        return try await transcribePrepared(wav, prompt: prompt, progress: progress)
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

    /// A second, text-only Gemini request writes the detailed English meeting recap.
    func recap(system: String, request recapRequest: String) async throws -> String {
        guard !recapRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "The recap request is empty. Transcribe a recording first.")
        }
        return try await withRetry {
            var call = request("v1beta/models/\(Self.summaryModel):generateContent", method: "POST", timeout: 180)
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["parts": [["text": recapRequest]]]],
                "generationConfig": ["temperature": 0, "maxOutputTokens": 16384, "thinkingConfig": ["thinkingLevel": "high"]],
            ])
            let (data, _) = try await send(call)
            let json = try parse(data)
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
                  candidate["finishReason"] as? String == "STOP",
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw Failure(message: "Gemini didn't finish the recap. Your transcript is saved; try again.")
            }
            let text = parts.filter { $0["thought"] as? Bool != true }
                .compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw Failure(message: "Gemini returned an empty recap. Your transcript is saved; try again.")
            }
            return text
        }
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

    /// `length` seconds of `audio` from `start`, as an .m4a (copied as it is when it's AAC, else re-encoded).
    private static func cut(_ audio: URL, from start: Double, length: Double, to output: URL) async throws {
        let asset = AVURLAsset(url: audio)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: output)
            export.outputURL = output
            export.outputFileType = .m4a
            export.timeRange = range
            await export.export()
            if export.status == .completed { return }
        }
        throw Failure(message: "Couldn't split the recording into parts for Gemini.")
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
        case "incomplete":
            throw Failure(message: "Gemini cut the transcript short. Try again or import a shorter recording.")
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
