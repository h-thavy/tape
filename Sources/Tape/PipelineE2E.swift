#if DEBUG
import AppKit
import Foundation

/// Runs the real native import → conversion → Gemini → save → reader flow with a loopback fixture API.
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
            APIKeys.testKeys = scenario == "missing-key" ? [:] : [.gemini: "fixture-key"]
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
            }
            let processor = scenario == "missing-key" ? Processor(notify: false)
                : Processor(gemini: Gemini(key: "fixture-key", endpoint: endpoint), notify: false)
            processor.process(imported.id)
            var item = try await wait(imported.id)
            if scenario == "missing-key" {
                try check(item.status == .waitingForKeys, "Missing key must wait for Settings")
            } else if scenario == "recap-failure-retry" {
                try check(item.status == .failed, "Expected first summary request to fail")
                try check(Library.shared.transcript(item)?.isEmpty == false, "Failed recap lost the transcript")
                try check(Library.shared.recap(item) == nil, "Failed recap was saved")
                processor.process(item.id)
                item = try await wait(item.id)
                try check(item.status == .ready, "Retry failed")
            } else if ["empty-transcript", "empty-summary", "truncated-summary", "invalid-audio", "empty-audio", "refused-key"].contains(scenario) {
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
            if let item = Library.shared.item(id), !item.isWorking { return item }
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
