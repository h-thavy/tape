import AVFoundation
import Foundation
import TapeCore
import os

/// One recorded call. Its files sit side by side in the recordings folder:
/// `<name>.m4a` (the audio), `<name>.transcript.txt` (Gemini) and `<name>.recap.md` (Claude).
struct RecordingItem: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        /// Recorded before recaps existed, or the recap was never asked for.
        case notProcessed
        case waitingForKeys
        case queued
        case transcribing
        case writing
        case ready
        case failed
    }

    /// The file name without its extension: "2026-10-30 14.05 Zoom".
    var id: String
    var audioFile: String
    var created: Date
    var duration: Double
    var app: String?
    var status: Status
    /// What's happening, or what went wrong.
    var detail: String?
    /// The meeting's subject, from the recap's heading.
    var title: String?

    var isWorking: Bool { [.queued, .transcribing, .writing].contains(status) }
    /// The recap's title; before there is one, the call app ("Google Meet in Opera GX" → "Google Meet call").
    var displayTitle: String {
        if let title { return title }
        guard var name = app else { return "Recording" }
        if let range = name.range(of: " in ") { name = String(name[..<range.lowerBound]) }
        return name + " call"
    }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [RecordingItem] = []
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "library")

    private var indexURL: URL {
        Recordings.inProgress.deletingLastPathComponent().appendingPathComponent("library.json")
    }

    func audioURL(_ item: RecordingItem) -> URL { Recordings.folder.appendingPathComponent(item.audioFile) }
    func transcriptURL(_ item: RecordingItem) -> URL { Recordings.folder.appendingPathComponent(item.id + ".transcript.txt") }
    func recapURL(_ item: RecordingItem) -> URL { Recordings.folder.appendingPathComponent(item.id + ".recap.md") }

    func item(_ id: String) -> RecordingItem? { items.first { $0.id == id } }

    func recap(_ item: RecordingItem) -> String? { try? String(contentsOf: recapURL(item), encoding: .utf8) }
    func transcript(_ item: RecordingItem) -> String? { try? String(contentsOf: transcriptURL(item), encoding: .utf8) }

    // MARK: - Loading

    /// Reads the index, then adds any recording in the folder it doesn't know (and drops ones that are gone).
    func load() {
        var known: [RecordingItem] = []
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            known = (try? decoder.decode([RecordingItem].self, from: data)) ?? []
        }
        let fm = FileManager.default
        known = known.filter { fm.fileExists(atPath: Recordings.folder.appendingPathComponent($0.audioFile).path) }
        let files = (try? fm.contentsOfDirectory(at: Recordings.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files where ["m4a", "aac"].contains(file.pathExtension) {
            let id = file.deletingPathExtension().lastPathComponent
            guard !known.contains(where: { $0.id == id }) else { continue }
            known.append(Self.discovered(file))
        }
        for index in known.indices {
            // Work cut off by a quit picks up where it was.
            if known[index].isWorking { known[index].status = .queued }
            known[index].app = known[index].app?.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
        }
        items = known.sorted { $0.created > $1.created }
        save()
    }

    /// A recording found in the folder: its date from the name ("2026-10-30 14.05 Zoom"), else the file's.
    private static func discovered(_ file: URL) -> RecordingItem {
        let id = file.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let created = formatter.date(from: String(id.prefix(16)))
            ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        // "2026-10-30 14.05 Zoom 2": the app, without the number added to a name that was taken.
        let app = id.count > 17 ? String(id.dropFirst(17)).replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression) : nil
        let duration = (try? AVAudioFile(forReading: file)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let folder = file.deletingLastPathComponent()
        let hasRecap = FileManager.default.fileExists(atPath: folder.appendingPathComponent(id + ".recap.md").path)
        var item = RecordingItem(id: id, audioFile: file.lastPathComponent, created: created, duration: duration,
                                 app: app?.isEmpty == false ? app : nil, status: hasRecap ? .ready : .notProcessed)
        if hasRecap, let recap = try? String(contentsOf: folder.appendingPathComponent(id + ".recap.md"), encoding: .utf8) {
            item.title = RecapFormat.title(of: recap)
        }
        return item
    }

    // MARK: - Changes

    func add(audio url: URL, app: String?, duration: Double) -> RecordingItem {
        let id = url.deletingPathExtension().lastPathComponent
        let item = RecordingItem(id: id, audioFile: url.lastPathComponent, created: Date().addingTimeInterval(-duration),
                                 duration: duration, app: app, status: .queued)
        items.removeAll { $0.id == id }
        items.insert(item, at: 0)
        save()
        return item
    }

    func update(_ id: String, _ change: (inout RecordingItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            log.error("Couldn't save the library: \(error.localizedDescription, privacy: .public)")
        }
    }
}
