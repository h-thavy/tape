import AVFoundation
import Foundation
import TapeCore
import os

/// One recorded call. Its files sit side by side in the recordings folder:
/// `<name>.m4a` (the audio), `<name>.transcript.txt` (Gemini) and `<name>.recap.md` (Gemini).
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
    /// The name you gave it (its files are named after it too).
    var name: String?
    /// Where each numbered topic of the recap starts (topic number → seconds).
    var topicTimes: [String: Double]?

    var isWorking: Bool { [.queued, .transcribing, .writing].contains(status) }
    /// The recap's title; before there is one, the call app ("Google Meet in Opera GX" → "Google Meet call").
    var displayTitle: String {
        if let name { return name }
        if let title { return title }
        // An imported recording: its file name.
        guard var name = app else { return id }
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

    /// Audio Gemini takes as it is (anything else is converted to .m4a on import).
    static let audioTypes: [String: String] = [
        "m4a": "audio/m4a", "aac": "audio/aac", "mp3": "audio/mp3", "wav": "audio/wav", "flac": "audio/flac",
        "ogg": "audio/ogg", "opus": "audio/opus", "aiff": "audio/aiff", "aif": "audio/aiff", "webm": "audio/webm",
    ]

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
        for file in files where Self.audioTypes[file.pathExtension.lowercased()] != nil {
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

    // MARK: - Importing

    /// Recordings from before Tape (or from elsewhere: a phone, Zoom's own recording, a video): copied into the
    /// recordings folder (video and other formats converted to .m4a), then transcribed and recapped like any
    /// call. Returns the new recordings.
    func importFiles(_ urls: [URL]) async -> [RecordingItem] {
        var added: [RecordingItem] = []
        Recordings.prepareFolders()
        for source in urls {
            let ext = source.pathExtension.lowercased()
            let keepsFormat = Self.audioTypes[ext] != nil
            let destination = Self.freeURL(stem: source.deletingPathExtension().lastPathComponent, ext: keepsFormat ? ext : "m4a")
            do {
                if keepsFormat {
                    try FileManager.default.copyItem(at: source, to: destination)
                } else {
                    try await Self.exportAudio(from: source, to: destination)
                }
            } catch {
                log.error("Couldn't import \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                Toast.shared.show(.init(id: "import", symbol: "exclamationmark.triangle", title: "Couldn't import \(source.lastPathComponent)",
                                        message: "Tape reads audio (m4a, mp3, wav, aac, flac…) and video files."))
                continue
            }
            let asset = AVURLAsset(url: destination)
            let duration = (try? await asset.load(.duration)).map(\.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
            let created = (try? source.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let item = RecordingItem(id: destination.deletingPathExtension().lastPathComponent, audioFile: destination.lastPathComponent,
                                     created: created, duration: duration, app: nil, status: .notProcessed)
            items.append(item)
            items.sort { $0.created > $1.created }
            save()
            added.append(item)
            log.notice("Imported \(source.lastPathComponent, privacy: .public) (\(Int(duration)) s)")
        }
        return added
    }

    /// A name in the recordings folder no other recording (or its transcript or recap) uses.
    private static func freeURL(stem: String, ext: String) -> URL {
        let fm = FileManager.default
        func taken(_ name: String) -> Bool {
            let files = (try? fm.contentsOfDirectory(atPath: Recordings.folder.path)) ?? []
            return files.contains { ($0 as NSString).deletingPathExtension == name || $0.hasPrefix(name + ".") }
        }
        var name = stem
        var n = 2
        while taken(name) {
            name = "\(stem) \(n)"
            n += 1
        }
        return Recordings.folder.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// The audio of a video (or of a format Gemini doesn't take), as .m4a.
    private static func exportAudio(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else { throw export.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: - Deleting

    /// Moves recordings to the Trash with their transcripts and recaps (Finder's Put Back restores them).
    /// One being transcribed or recapped right now is left alone. Returns the ids moved.
    @discardableResult
    func trash(_ ids: Set<String>) -> Set<String> {
        var moved: Set<String> = []
        for item in items where ids.contains(item.id) && item.status != .transcribing && item.status != .writing {
            for url in [audioURL(item), transcriptURL(item), recapURL(item)] where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    log.error("Couldn't move \(url.lastPathComponent, privacy: .public) to the Trash: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !FileManager.default.fileExists(atPath: audioURL(item).path) { moved.insert(item.id) }
        }
        items.removeAll { moved.contains($0.id) }
        save()
        log.notice("Moved \(moved.count) recording(s) to the Trash")
        return moved
    }

    // MARK: - Renaming

    /// Names a recording. Its files (audio, transcript, recap) take the name too, as "<name>.m4a",
    /// "<name>.transcript.txt" and "<name>.recap.md"; while it's being transcribed or recapped, that waits until
    /// it's done. An empty name goes back to the recap's title. Returns the recording's id (it changes with the files).
    @discardableResult
    func rename(_ id: String, to raw: String) -> String {
        let name = Self.fileSafe(raw)
        update(id) { $0.name = name.isEmpty ? nil : name }
        guard let item = item(id), !item.isWorking, !name.isEmpty else { return id }
        return moveFiles(of: id, to: name)
    }

    /// After processing: gives the files the name chosen meanwhile.
    @discardableResult
    func applyName(_ id: String) -> String {
        guard let item = item(id), let name = item.name, !item.isWorking, item.id != name else { return id }
        return moveFiles(of: id, to: name)
    }

    private func moveFiles(of id: String, to name: String) -> String {
        guard let item = item(id), item.id != name else { return id }
        let fm = FileManager.default
        let ext = (item.audioFile as NSString).pathExtension
        let audio = Self.freeURL(stem: name, ext: ext)
        let stem = audio.deletingPathExtension().lastPathComponent
        do {
            try fm.moveItem(at: audioURL(item), to: audio)
            for (old, suffix) in [(transcriptURL(item), ".transcript.txt"), (recapURL(item), ".recap.md")] where fm.fileExists(atPath: old.path) {
                try fm.moveItem(at: old, to: Recordings.folder.appendingPathComponent(stem + suffix))
            }
        } catch {
            log.error("Couldn't rename \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return id
        }
        update(id) {
            $0.id = stem
            $0.audioFile = audio.lastPathComponent
        }
        // The recap names the recording and its transcript file: those follow the new name.
        let recap = Recordings.folder.appendingPathComponent(stem + ".recap.md")
        if var text = try? String(contentsOf: recap, encoding: .utf8) {
            text = text.replacingOccurrences(of: "`\(id).transcript.txt`", with: "`\(stem).transcript.txt`")
                .replacingOccurrences(of: "recording \"\(id)\"", with: "recording \"\(stem)\"")
                .replacingOccurrences(of: "# \"\(id)\" — Meeting Recap", with: "# \"\(stem)\" — Meeting Recap")
            try? text.write(to: recap, atomically: true, encoding: .utf8)
        }
        if MainWindow.shared.selected == id { MainWindow.shared.selected = stem }
        log.notice("Renamed \(id, privacy: .public) to \(stem, privacy: .public)")
        return stem
    }

    /// A name that works as a file name: no slashes or colons, no leading dot, trimmed.
    static func fileSafe(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(120))
    }

    // MARK: - Changes

    func add(audio url: URL, app: String?, duration: Double) -> RecordingItem {
        let id = url.deletingPathExtension().lastPathComponent
        let item = RecordingItem(id: id, audioFile: url.lastPathComponent, created: Date().addingTimeInterval(-duration),
                                 duration: duration, app: app, status: .notProcessed)
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
