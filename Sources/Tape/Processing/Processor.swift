import AppKit
import TapeCore
import os

/// Turns each finished recording into a transcript (Gemini) and a recap (Claude), one recording at a time.
/// The transcript is kept, so a failed recap is retried without transcribing again.
@MainActor
final class Processor {
    static let shared = Processor()

    private var running = false
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "processor")

    private var library: Library { Library.shared }

    /// Queues a recording (or makes the recap again).
    func process(_ id: String, again: Bool = false) {
        guard let item = library.item(id) else { return }
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
        guard let geminiKey = APIKeys.get(.gemini), let anthropicKey = APIKeys.get(.anthropic) else {
            for item in library.items where item.status == .queued {
                library.update(item.id) {
                    $0.status = .waitingForKeys
                    $0.detail = "Add your Gemini and Anthropic API keys in Settings to get the recap."
                }
            }
            return
        }
        running = true
        Task {
            await run(next, gemini: Gemini(key: geminiKey), claude: Claude(key: anthropicKey))
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
            let date = item.created.formatted(.dateTime.day().month(.wide).year().hour().minute())
            // A name given meanwhile is what the recording is called.
            let request = RecapPrompts.recapRequest(
                recording: library.item(id)?.name ?? item.id, date: date, seconds: item.duration, app: item.app,
                transcriptFile: library.transcriptURL(item).lastPathComponent, transcript: transcript ?? "")
            let recap = try await claude.recap(system: RecapPrompts.recapSystem, request: request)
            try (recap + "\n").write(to: library.recapURL(item), atomically: true, encoding: .utf8)
            library.update(id) {
                $0.status = .ready
                $0.detail = nil
                $0.title = RecapFormat.title(of: recap)
                // Not named after the meeting (or by you): named after what it was about.
                if $0.name == nil, let title = $0.title, !Library.fileSafe(title).isEmpty { $0.name = Library.fileSafe(title) }
            }
            log.notice("Recap for \(id, privacy: .public) ready after \(Int(Date().timeIntervalSince(started))) s")
            let named = library.applyName(id)
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
