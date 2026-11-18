import AVFoundation
import Foundation
import TapeCore
import os

/// Transcribes a recording with Gemini (`gemini-3.8-flash`, which handles Khmer mixed with English best, and
/// `gemini-3.5-flash` for what it won't take): the audio goes up through the Files API as 16 kHz mono, in
/// 10-minute parts when it's long, each transcribed with generateContent, and the uploads are deleted afterwards.
struct Gemini {
    static let model = "gemini-3.8-flash"
    /// For what 3.8 won't transcribe.
    static let fallbackModel = "gemini-3.5-flash"
    private static let base = URL(string: "https://generativelanguage.googleapis.com")!

    let key: String
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "gemini")

    struct Failure: LocalizedError {
        let message: String
        /// A failure on Gemini's side that may not happen again.
        var retryable = false
        var errorDescription: String? { message }
    }

    /// Recordings longer than this go in parts: Gemini fails on long audio in one go ("There was a problem
    /// processing your request", every time, on a 32-minute call).
    static let partLength: Double = 10 * 60

    func transcribe(_ original: URL, prompt: String, progress: @escaping (String) -> Void) async throws -> String {
        // Sent as Gemini hears it: 16 kHz mono (it reduces audio to that itself), about a third of the size.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tape-gemini-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var audio = original
        progress("Preparing the audio…")
        let speech = folder.appendingPathComponent("speech.m4a")
        do {
            try await Self.speechAudio(original, to: speech)
            audio = speech
            let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
            log.notice("Audio for Gemini: \(size(original) / 1024) KB → \(size(speech) / 1024) KB")
        } catch {
            log.error("Couldn't convert the audio (\(error.localizedDescription, privacy: .public)); sending it as it is")
        }
        let duration = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 0
        let count = duration > Self.partLength * 1.2 ? Int((duration / Self.partLength).rounded(.up)) : 1
        var transcript: [String] = []
        for index in 0..<count {
            let start = Double(index) * Self.partLength
            let length = count == 1 ? duration : min(Self.partLength, duration - start)
            // The end of the part before, so the same voices keep the same labels.
            let previous = transcript.last.map(Self.tail)
            let text = try await span(of: audio, from: start, length: length, whole: count == 1,
                                      part: count > 1 ? (index + 1, count) : nil, previous: previous, in: folder) { message in
                progress(count == 1 ? message : "Part \(index + 1) of \(count): \(message.lowercased())")
            }
            transcript.append(text)
            if count > 1 { log.notice("Transcribed part \(index + 1) of \(count)") }
        }
        let text = transcript.joined(separator: "\n\n")
        // Nothing but gaps: that's a failure, not a transcript.
        guard text.components(separatedBy: "\n").contains(where: { !$0.isEmpty && !$0.contains(Self.gapMark) }) else {
            throw Failure(message: "Gemini couldn't transcribe any of the recording; it stops without saying why (\"OTHER\"). Try again later.",
                          retryable: true)
        }
        return text
    }

    /// The smallest stretch a failing part is split into.
    static let smallest: Double = 45
    static let gapMark = "Couldn't be transcribed:"

    /// `length` seconds of the recording from `start`, transcribed, with times on the whole recording's clock.
    /// Gemini sometimes stops on a stretch of audio again and again ("There was a problem processing your
    /// request", or no text with finish reason OTHER); such a stretch is split in two and each half tried on
    /// its own, down to `smallest`, where what still fails is marked as a gap. One bad stretch never costs the
    /// whole recording.
    private func span(of audio: URL, from start: Double, length: Double, whole: Bool, part: (Int, Int)? = nil,
                      previous: String?, in folder: URL, progress: @escaping (String) -> Void) async throws -> String {
        let file: URL
        if whole {
            file = audio
        } else {
            file = folder.appendingPathComponent("span \(Int(start))-\(Int(start + length)).m4a")
            try await Self.cut(audio, from: start, length: length, to: file)
        }
        let prompt = whole ? RecapPrompts.transcription
            : part.map { RecapPrompts.transcription(part: $0.0, of: $0.1, previous: previous) }
                ?? RecapPrompts.transcription(continuing: previous)
        do {
            let text = try await withRetry(tries: length > 2 * Self.smallest ? 2 : 3) {
                let raw = try await transcribeFile(file, prompt: prompt, progress: progress)
                guard !whole else { return raw }
                // An answer without timed lines would otherwise be dropped whole, losing the stretch unnoticed.
                let cleaned = Transcript.cleanedPart(raw)
                guard !cleaned.isEmpty else {
                    log.error("Gemini's answer had no timed lines: \(String(raw.prefix(300)), privacy: .public)")
                    throw Failure(message: "Gemini's answer had no timed lines.", retryable: true)
                }
                return cleaned
            }
            return whole ? text : Transcript.shifted(text, by: start)
        } catch let failure as Failure where failure.retryable {
            let end = start + length
            guard length > 2 * Self.smallest else {
                log.error("Gave up on \(Transcript.stamp(start), privacy: .public)–\(Transcript.stamp(end), privacy: .public)")
                return "[\(Transcript.stamp(start))] [\(Self.gapMark) \(Transcript.stamp(start))–\(Transcript.stamp(end))]"
            }
            log.notice("Splitting \(Transcript.stamp(start), privacy: .public)–\(Transcript.stamp(end), privacy: .public) in two")
            progress("Retrying in smaller pieces…")
            let half = (length / 2).rounded()
            let first = try await span(of: audio, from: start, length: half, whole: false, previous: previous, in: folder, progress: progress)
            let second = try await span(of: audio, from: start + half, length: length - half, whole: false,
                                        previous: Self.tail(first), in: folder, progress: progress)
            return first + "\n\n" + second
        }
    }

    /// The last lines of a transcript, for the next part to carry on from.
    private static func tail(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.contains(gapMark) }.suffix(12).joined(separator: "\n")
    }

    private func transcribeFile(_ audio: URL, prompt: String, progress: @escaping (String) -> Void) async throws -> String {
        progress("Uploading…")
        let file = try await upload(audio)
        defer { Task { try? await delete(file.name) } }
        try await waitUntilActive(file.name)
        progress("Transcribing…")
        // Gemini 3.8 Flash stops on some recordings again and again (no text, finish reason OTHER; from the
        // Interactions API "There was a problem processing your request"); on the same stretches Gemini 3.5 Flash
        // gave a full transcript three times in three. So it gets the same upload when 3.8 fails.
        do {
            return try await generate(prompt: prompt, fileURI: file.uri, mimeType: file.mimeType)
        } catch let failure as Failure where failure.retryable {
            log.notice("\(Self.model, privacy: .public) failed (\(failure.message, privacy: .public)); trying \(Self.fallbackModel, privacy: .public)")
            do {
                let text = try await generate(prompt: prompt, fileURI: file.uri, mimeType: file.mimeType, model: Self.fallbackModel)
                log.notice("\(Self.fallbackModel, privacy: .public) transcribed it")
                return text
            } catch {
                log.error("\(Self.fallbackModel, privacy: .public) failed too: \(error.localizedDescription, privacy: .public)")
                throw failure
            }
        }
    }

    /// Thinking can be set low on the general models; the transcription model takes no thinking setting.
    static func generationConfig(for model: String) -> [String: Any] {
        var config: [String: Any] = ["maxOutputTokens": 65_536, "responseMimeType": "text/plain"]
        if !model.contains("transcribe") { config["thinkingConfig"] = ["thinkingLevel": "low"] }
        return config
    }

    /// The transcript through generateContent: one request that waits for the answer (up to 20 minutes).
    private func generate(prompt: String, fileURI: String, mimeType: String, model: String = Gemini.model) async throws -> String {
        // Transcribing needs little reasoning: low thinking (the least gemini-3.8-flash takes) keeps the model from
        // stalling in it (a cause of finish reason OTHER). The adjustable safety filters are off, so a word in a
        // meeting doesn't cut the transcript.
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt], ["file_data": ["mime_type": mimeType, "file_uri": fileURI]]]]],
            "generationConfig": Self.generationConfig(for: model),
            "safetySettings": ["HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_SEXUALLY_EXPLICIT",
                               "HARM_CATEGORY_DANGEROUS_CONTENT"].map { ["category": $0, "threshold": "OFF"] },
        ]
        var call = request("v1beta/models/\(model):generateContent", method: "POST", timeout: 1200)
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send(call)
        let json = try parse(data)
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let feedback = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
        let reason = candidate?["finishReason"] as? String ?? feedback ?? "no reason given"
        guard !text.isEmpty else {
            let raw = String(data: data, encoding: .utf8).map { String($0.prefix(800)) } ?? ""
            log.error("generateContent gave no text: \(raw, privacy: .public)")
            throw Failure(message: "Gemini returned no transcript (\(reason)).", retryable: true)
        }
        if reason == "MAX_TOKENS" {
            return text + "\n\n[The transcript stops here: the recording was too long to transcribe in one go.]"
        }
        return text
    }

    /// Tries `tries` times in all (waiting 5, then 20 seconds) when Gemini fails on its side or the network
    /// drops; not for a refused key or an exhausted quota.
    private func withRetry(tries: Int = 3, _ work: () async throws -> String) async throws -> String {
        var attempt = 1
        while true {
            do {
                return try await work()
            } catch let failure as Failure where failure.retryable && attempt < tries {
                log.notice("Gemini failed (\(failure.message, privacy: .public)); trying again")
            } catch let error as URLError where attempt < tries {
                log.notice("Network error (\(error.localizedDescription, privacy: .public)); trying again")
            }
            try await Task.sleep(for: .seconds(attempt == 1 ? 5 : 20))
            attempt += 1
        }
    }

    /// The audio as speech for Gemini: 16 kHz mono AAC at 48 kbps (a call's 48 kHz stereo is reduced to this by
    /// Gemini anyway).
    private static func speechAudio(_ source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure(message: "The recording has no audio.") }
        let reader = try AVAssetReader(asset: asset)
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                  AVLinearPCMIsNonInterleaved: false]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(readerOutput)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? Failure(message: "Couldn't convert the audio.")
        }
        writer.startSession(atSourceTime: .zero)
        let queue = DispatchQueue(label: "tape.speech-audio")
        let finished: Bool = await withCheckedContinuation { done in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = readerOutput.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        done.resume(returning: reader.status == .completed)
                        return
                    }
                    if !input.append(buffer) {
                        reader.cancelReading()
                        done.resume(returning: false)
                        return
                    }
                }
            }
        }
        guard finished else {
            writer.cancelWriting()
            throw writer.error ?? reader.error ?? Failure(message: "Couldn't convert the audio.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "Couldn't convert the audio.") }
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

    struct UploadedFile {
        let name: String
        let uri: String
        let mimeType: String
    }

    func upload(_ audio: URL) async throws -> UploadedFile {
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
        let (data, response) = try await URLSession.shared.upload(for: upload, fromFile: audio)
        try check(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["file"] as? [String: Any], let name = file["name"] as? String, let uri = file["uri"] as? String
        else { throw Failure(message: "Gemini's upload reply was unexpected.") }
        log.notice("Uploaded \(size) bytes as \(name, privacy: .public)")
        return UploadedFile(name: name, uri: uri, mimeType: (file["mimeType"] as? String) ?? mimeType)
    }

    /// Audio is processed for a moment after upload before it can be used.
    func waitUntilActive(_ name: String) async throws {
        for _ in 0..<120 {
            let (data, _) = try await send(request("v1beta/\(name)", method: "GET"))
            let state = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["state"] as? String
            if state == nil || state == "ACTIVE" { return }
            if state == "FAILED" { throw Failure(message: "Gemini couldn't read the recording.") }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure(message: "Gemini took too long to take the recording in.")
    }

    func delete(_ name: String) async throws {
        _ = try await send(request("v1beta/\(name)", method: "DELETE"))
    }

    // MARK: - Replies

    private func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Gemini's reply was unexpected.")
        }
        return json
    }

    // MARK: - HTTP

    private func request(_ path: String, method: String, timeout: TimeInterval = 120) -> URLRequest {
        var request = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return (data, response as! HTTPURLResponse)
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No reply from Gemini.") }
        guard !(200..<300).contains(http.statusCode) else { return }
        // The error comes as {"error": {...}}, or sometimes as [{"error": {...}}].
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

extension Gemini {
    /// Test: the same upload sent once to each model, with what came back (TAPE_TEST_MODELS_ON).
    func compare(_ audio: URL, models: [String], prompt: String) async -> String {
        guard let file = try? await upload(audio) else { return "upload failed" }
        defer { Task { try? await delete(file.name) } }
        try? await waitUntilActive(file.name)
        var report: [String] = []
        for model in models {
            let started = Date()
            do {
                let text = try await generate(prompt: prompt, fileURI: file.uri, mimeType: file.mimeType, model: model)
                let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
                report.append("\(model): OK in \(Int(Date().timeIntervalSince(started))) s, \(lines.count) timed lines, last \(lines.last?.prefix(9) ?? "-")")
            } catch {
                report.append("\(model): FAILED in \(Int(Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
            }
        }
        return report.joined(separator: "\n")
    }
}
