import Foundation
import os

/// Writes the recap with Claude Opus 5.5 over the Messages API (raw HTTP: there's no Swift SDK). Streamed, as a
/// long transcript and a thorough recap take a while; adaptive thinking at high effort. If Claude's safeguards
/// decline a request, the API retries it on Anthropic's recommended fallback model by itself
/// (`fallbacks: "default"`).
struct Claude {
    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let key: String
    private let endpoint: URL
    private let session: URLSession

    init(key: String, endpoint: URL = Self.endpoint, session: URLSession = .shared) {
        self.key = key
        self.endpoint = endpoint
        self.session = session
    }
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "claude")

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func recap(system: String, request text: String) async throws -> String {
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 64_000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "high"],
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": text]],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No reply from Claude.") }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.failure(status: http.statusCode, body: data)
        }

        // Server-sent events: collect the text blocks. A `fallback` block means a declined attempt was retried
        // on another model; what came before it is the declined partial answer, so it's dropped.
        var text = ""
        var textBlocks = Set<Int>()
        var stopReason: String?
        var finished = false
        var model = Self.model
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "message_start":
                if let name = (event["message"] as? [String: Any])?["model"] as? String { model = name }
            case "content_block_start":
                let block = event["content_block"] as? [String: Any]
                let index = event["index"] as? Int ?? -1
                if block?["type"] as? String == "text" { textBlocks.insert(index) }
                if block?["type"] as? String == "fallback" {
                    text = ""
                    textBlocks.removeAll()
                    stopReason = nil
                    if let to = block?["model"] as? String { model = to }
                }
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if let index = event["index"] as? Int, textBlocks.contains(index),
                   delta?["type"] as? String == "text_delta", let piece = delta?["text"] as? String {
                    text += piece
                }
            case "message_stop":
                finished = true
            case "message_delta":
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
                throw Failure(message: "Claude stopped with an error: \(message)")
            default:
                break
            }
        }
        log.notice("Recap from \(model, privacy: .public), stop reason \(stopReason ?? "-", privacy: .public), \(text.count) characters")
        switch stopReason {
        case "refusal":
            throw Failure(message: "Claude declined to write this recap.")
        case "max_tokens":
            throw Failure(message: "Claude cut the recap short. Your transcript is saved; try again.")
        default:
            guard finished, stopReason == "end_turn" else {
                throw Failure(message: "Claude did not finish the recap. Your transcript is saved; try again.")
            }
            let recap = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recap.isEmpty else { throw Failure(message: "Claude's reply was empty.") }
            return recap
        }
    }

    private static func failure(status: Int, body: Data) -> Failure {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? "unknown"
        switch status {
        case 401, 403: return Failure(message: "Anthropic didn't accept the API key. Check it in Settings.")
        case 429: return Failure(message: "Anthropic's rate limit was reached. Try again in a minute.")
        case 529: return Failure(message: "Claude is overloaded right now. Try again in a few minutes.")
        default: return Failure(message: "Claude error \(status): \(message)")
        }
    }
}
