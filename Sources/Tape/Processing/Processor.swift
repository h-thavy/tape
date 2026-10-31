import AppKit
import TapeCore
import os

/// Turns each recording into a Khmer/English transcript and detailed English recap using Gemini and Claude.
/// The transcript is kept, so a failed recap is retried without transcribing again.
@MainActor
final class Processor {
    static let shared = Processor()

    private var running = false
    private let suppliedGemini: Gemini?
    private let suppliedClaude: Claude?
    private let notify: Bool
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "processor")

    private var library: Library { Library.shared }

    init(gemini: Gemini? = nil, claude: Claude? = nil, notify: Bool = true) {
        suppliedGemini = gemini
        suppliedClaude = claude
        self.notify = notify
    }

    /// Queues a recording (or makes the recap again).
    func process(_ id: String, again: Bool = false) {
        guard let item = library.item(id) else { return }
        guard !item.isWorking else { return }
        if again {
            try? FileManager.default.removeItem(at: library.recapURL(item))
        }
        library.update(id) {
            $0.status = .queued
            $0.detail = nil
        }
        runNext()
    }

    /// Runs whatever is waiting: after launch, and when the API keys are saved.
    func resume() {
        for item in library.items where item.status == .waitingForKeys {
            library.update(item.id) { $0.status = .queued }
        }
        runNext()
    }

    private func runNext() {
        guard !running, let next = library.items.reversed().first(where: { $0.status == .queued }) else { return }
        let gemini = suppliedGemini ?? APIKeys.get(.gemini).map { Gemini(key: $0) }
        let claude = suppliedClaude ?? APIKeys.get(.anthropic).map { Claude(key: $0) }
        guard let gemini, let claude else {
            for item in library.items where item.status == .queued {
                library.update(item.id) {
                    $0.status = .waitingForKeys
                    $0.detail = "Add your Gemini and Anthropic API keys in Settings to transcribe and summarize."
                }
            }
            return
        }
        running = true
        Task {
            await run(next, gemini: gemini, claude: claude)
            running = false
            runNext()
        }
    }

    private func run(_ item: RecordingItem, gemini: Gemini, claude: Claude) async {
        let id = item.id
        let started = Date()
        do {
            var transcript = library.transcript(item)
            if transcript?.isEmpty != false {
                library.update(id) { $0.status = .transcribing; $0.detail = "Uploading the recording…" }
                let text = try await gemini.transcribe(library.audioURL(item), prompt: RecapPrompts.transcription) { message in
                    Task { @MainActor in self.library.update(id) { $0.detail = message } }
                }
                try text.write(to: library.transcriptURL(item), atomically: true, encoding: .utf8)
                transcript = text
                log.notice("Transcribed \(id, privacy: .public) in \(Int(Date().timeIntervalSince(started))) s (\(text.count) characters)")
            }
            library.update(id) { $0.status = .writing; $0.detail = "Writing the recap…" }
            let name = library.item(id)?.name
            let request = RecapPrompts.recapRequest(
                recording: name ?? item.id, named: name != nil || item.app == nil,
                date: item.created.formatted(.dateTime.day().month(.wide).year().hour().minute()),
                seconds: item.duration, app: item.app,
                transcriptFile: library.transcriptURL(item).lastPathComponent, transcript: transcript ?? "")
            let (reply, times) = RecapFormat.splitTopicTimes(try await claude.recap(system: RecapPrompts.recapSystem, request: request))
            let recap = RecapFormat.flattened(reply)
            try (recap + "\n").write(to: library.recapURL(item), atomically: true, encoding: .utf8)
            library.update(id) {
                $0.status = .ready
                $0.detail = nil
                $0.topicTimes = times.isEmpty ? nil : times
                $0.title = RecapFormat.title(of: recap)
                // Not named after the meeting (or by you): named after what it was about.
                if $0.name == nil, let title = $0.title, !Library.fileSafe(title).isEmpty { $0.name = Library.fileSafe(title) }
            }
            log.notice("Recap for \(id, privacy: .public) ready after \(Int(Date().timeIntervalSince(started))) s")
            let named = library.applyName(id)
            guard notify else { return }
            let title = library.item(named)?.displayTitle ?? "Your meeting"
            let topics = RecapDocument(recap).sections.filter { $0.number != nil }.count
            Toast.shared.show(.init(
                id: "recap", symbol: "doc.text", title: "Recap ready",
                message: topics > 0 ? "\(title) · \(topics) topic\(topics == 1 ? "" : "s")" : title,
                primary: .init(title: "Open") { MainWindow.shared.show(recording: named) },
                timeout: 10))
        } catch {
            log.error("Processing \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            library.update(id) {
                $0.status = .failed
                $0.detail = error.localizedDescription
            }
            library.applyName(id)
        }
    }
}
