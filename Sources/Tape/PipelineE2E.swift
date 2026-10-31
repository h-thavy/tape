#if DEBUG
import AppKit
import Foundation

/// Runs the real native import → conversion → Gemini → Claude → save → reader flow with a loopback fixture API.
/// Called before normal startup, so it never starts call detection or touches personal recordings or keys.
@MainActor
enum PipelineE2E {
    static func run() async {
        let args = CommandLine.arguments
        guard args.count == 6, let endpoint = URL(string: args[3]), endpoint.host == "127.0.0.1" else { exit(2) }
        let folder = URL(fileURLWithPath: args[2], isDirectory: true)
        let scenario = args[4]
        var receipt: [String: Any] = ["passed": false, "scenario": scenario, "mode": "fixture"]
        do {
            Recordings.testingRoot = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let missingKey = ["missing-key", "missing-gemini-key", "missing-claude-key"].contains(scenario)
            APIKeys.testKeys = [.gemini: "fixture-key", .anthropic: "fixture-claude-key"]
            if scenario == "missing-key" { APIKeys.testKeys = [:] }
            if scenario == "missing-gemini-key" { APIKeys.testKeys?.removeValue(forKey: .gemini) }
            if scenario == "missing-claude-key" { APIKeys.testKeys?.removeValue(forKey: .anthropic) }
            try check(APIKeys.complete == !missingKey, "Setup must require both API keys")
            Recordings.prepareFolders()
            Library.shared.load()
            Fonts.register()
            let sources = await Library.shared.importFiles([URL(fileURLWithPath: args[5])])
            guard let imported = sources.first else { throw Check.failed("Import failed") }
            try check(imported.status == .notProcessed, "Import should wait for an explicit processing request")
            if scenario == "success" {
                MainWindow.shared.show(recording: imported.id)
                try await Task.sleep(for: .milliseconds(500))
                MainWindow.shared.pipelineSnapshot(to: folder.appendingPathComponent("before-processing.png"))
                MainWindow.shared.show(page: .settings)
                try await Task.sleep(for: .milliseconds(500))
                MainWindow.shared.pipelineSnapshot(to: folder.appendingPathComponent("settings.png"))
                Onboarding.snapshot(to: folder)
                MainWindow.shared.show(recording: imported.id)
            }
            func gemini() -> Gemini {
                Gemini(key: "fixture-key", endpoint: endpoint, preparedAudio: { url in
                    try Data(contentsOf: url).write(to: folder.appendingPathComponent("reference.wav"), options: .atomic)
                })
            }
            let processor = missingKey ? Processor(notify: false)
                : Processor(gemini: gemini(),
                            claude: Claude(key: "fixture-claude-key", endpoint: endpoint.appendingPathComponent("v1/messages")),
                            notify: false)
            processor.process(imported.id)
            var item = try await wait(imported.id)
            if missingKey {
                try check(item.status == .waitingForKeys, "Missing key must wait for Settings")
            } else if ["recap-failure-retry", "resume-transcription", "changed-audio-retry", "corrupt-cache-retry"].contains(scenario) {
                try check(item.status == .failed, "Expected the initial processing request to fail")
                if scenario == "recap-failure-retry" {
                    try check(Library.shared.transcript(item)?.isEmpty == false, "Failed recap lost the transcript")
                } else {
                    try check(Library.shared.transcript(item) == nil, "Partial transcript was marked complete")
                }
                if scenario == "changed-audio-retry" {
                    let url = Library.shared.audioURL(item)
                    var data = try Data(contentsOf: url)
                    data[44] ^= 64
                    try data.write(to: url)
                }
                if scenario == "corrupt-cache-retry" {
                    let url = Recordings.inProgress.deletingLastPathComponent()
                        .appendingPathComponent("Transcription").appendingPathComponent(item.id + ".wav")
                    var data = try Data(contentsOf: url)
                    data[44] ^= 64
                    try data.write(to: url)
                }
                try check(Library.shared.recap(item) == nil, "Failed recap was saved")
                Library.shared.load()
                let retryProcessor = Processor(gemini: gemini(),
                                               claude: Claude(key: "fixture-claude-key", endpoint: endpoint.appendingPathComponent("v1/messages")), notify: false)
                retryProcessor.process(item.id)
                item = try await wait(item.id)
                try check(item.status == .ready, "Retry failed")
            } else if ["empty-transcript", "empty-summary", "truncated-summary", "invalid-audio", "empty-audio", "refused-key", "refused-claude-key", "interrupted-summary", "refused-summary", "bounded-incomplete"].contains(scenario) {
                try check(item.status == .failed, "Expected failure, got \(item.status.rawValue)")
                try check(Library.shared.recap(item) == nil, "Failure left a finished recap")
            } else {
                try check(item.status == .ready, "Pipeline failed: \(item.detail ?? item.status.rawValue)")
            }
            receipt["status"] = item.status.rawValue
            receipt["detail"] = item.detail
            receipt["transcript"] = Library.shared.transcript(item) ?? ""
            receipt["recap"] = Library.shared.recap(item) ?? ""
            if item.status == .ready {
                receipt["duration"] = item.duration
                let player = AudioPlayer()
                player.load(Library.shared.audioURL(item), duration: item.duration)
                try await Task.sleep(for: .milliseconds(500))
                try check(abs(player.duration - item.duration) < 0.001, "Player replaced decoded duration with container metadata")
                player.seek(to: item.duration + 60)
                try check(player.time <= item.duration, "Player sought past decoded audio")
                receipt["player_duration"] = player.duration
                player.stop()
                try check(item.topicTimes?["1"] == 0, "Detailed recap lost its topic playback time")
                MainWindow.shared.show(recording: item.id)
                MainWindow.shared.tab = .recap
                try await Task.sleep(for: .milliseconds(500))
                MainWindow.shared.pipelineSnapshot(to: folder.appendingPathComponent("recap.png"))
                MainWindow.shared.tab = .transcript
                try await Task.sleep(for: .milliseconds(500))
                MainWindow.shared.pipelineSnapshot(to: folder.appendingPathComponent("transcript.png"))
            }
            receipt["passed"] = true
        } catch {
            receipt["error"] = error.localizedDescription
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("receipt.json"), options: .atomic)
        } catch { exit(3) }
        exit(receipt["passed"] as? Bool == true ? 0 : 1)
    }

    private static func wait(_ id: String) async throws -> RecordingItem {
        for _ in 0..<1200 {
            // The isolated library contains one item; its recap title can rename it after processing.
            if let item = Library.shared.item(id) ?? Library.shared.items.first, !item.isWorking { return item }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Check.failed("Pipeline timed out")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Check.failed(message) }
    }

    private enum Check: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
    }
}
#endif
