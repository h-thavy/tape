import AVFoundation
import AppKit
import SwiftUI
import TapeCore

// MARK: - Parsed files

/// Transcripts and recaps as the app shows them, read and parsed once per change of their file.
@MainActor
final class Parsed {
    static let shared = Parsed()
    private var transcripts: [String: (Date, Transcript)] = [:]
    private var recaps: [String: (Date, RecapDocument)] = [:]

    func transcript(_ item: RecordingItem) -> Transcript? {
        let url = Library.shared.transcriptURL(item)
        guard let changed = Self.modified(url) else { return nil }
        if let (date, transcript) = transcripts[item.id], date == changed { return transcript }
        guard let text = Library.shared.transcript(item) else { return nil }
        let transcript = Transcript(text, duration: item.duration)
        transcripts[item.id] = (changed, transcript)
        return transcript
    }

    func recap(_ item: RecordingItem) -> RecapDocument? {
        let url = Library.shared.recapURL(item)
        guard let changed = Self.modified(url) else { return nil }
        if let (date, recap) = recaps[item.id], date == changed { return recap }
        guard let text = Library.shared.recap(item) else { return nil }
        let recap = RecapDocument(text)
        recaps[item.id] = (changed, recap)
        return recap
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - Library

/// Every recording, newest first, grouped by day: its name, length, a strip of who spoke when, the call app
/// and time, and how its recap is doing. Drop recordings on it to import them.
struct LibraryColumn: View {
    @ObservedObject private var main = MainWindow.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var recorder = Recorder.shared
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Library").font(Theme.sans(15, .semibold)).tracking(-0.2)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { Importer.choose() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.pillQuiet).controlSize(.small)
                    .help("Import recordings to recap (or drop them here)")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if recorder.isRecording { RecordingNowRow() }
                    if library.items.isEmpty, !recorder.isRecording {
                        Text("No recordings yet. When a call starts, Tape asks to record it. To recap a recording you already have, drop it here.")
                            .font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                    ForEach(groups, id: \.title) { group in
                        SectionLabel(text: group.title)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.items) { item in LibraryRow(item: item, selected: item.id == shownID) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 14)
            }
        }
        .background(Theme.sidebar)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Importer.load(providers)
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Theme.radiusLarge)
                    .strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.background.opacity(0.92)))
                    .overlay(Text("Drop to make recaps").font(Theme.sans(13, .semibold)))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The recording in the reader: the one picked, else the newest.
    private var shownID: String? { main.selected ?? library.items.first?.id }

    private var groups: [(title: String, items: [RecordingItem])] {
        let query = main.search.trimmingCharacters(in: .whitespaces).lowercased()
        let items = library.items.filter {
            query.isEmpty || $0.displayTitle.lowercased().contains(query) || $0.id.lowercased().contains(query)
                || ($0.app?.lowercased().contains(query) ?? false)
                || (Library.shared.recap($0)?.lowercased().contains(query) ?? false)
        }
        let calendar = Calendar.current
        var result: [(String, [RecordingItem])] = []
        for item in items {
            let day = calendar.isDateInToday(item.created) ? "Today"
                : calendar.isDateInYesterday(item.created) ? "Yesterday"
                : item.created.formatted(.dateTime.weekday(.wide).day().month(.wide))
            if result.last?.0 == day { result[result.count - 1].1.append(item) } else { result.append((day, [item])) }
        }
        return result
    }
}

private struct LibraryRow: View {
    let item: RecordingItem
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            MainWindow.shared.page = .recordings
            MainWindow.shared.selected = item.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.displayTitle).font(Theme.sans(13.5, selected ? .semibold : .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Counter.text(item.duration)).font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                }
                MiniMap(turns: Parsed.shared.transcript(item)?.turns ?? [], duration: item.duration)
                HStack(spacing: 6) {
                    Text([item.app.map(Self.shortApp), item.created.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.sans(12)).foregroundStyle(Theme.ink3).lineLimit(1)
                    Spacer(minLength: 6)
                    RecapStatus(item: item)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium)
                    .fill(selected ? Theme.raised : hovering ? Theme.fill.opacity(0.6) : .clear)
                    .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 6, y: 2)
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(selected ? Theme.line : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { MainWindow.shared.show(recording: item.id, rename: true) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Library.shared.audioURL(item)]) }
            if item.status == .ready || item.status == .failed {
                Button("Write the recap again") { Processor.shared.process(item.id, again: true) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.displayTitle), \(Recorder.duration(item.duration)), \(item.created.formatted(date: .abbreviated, time: .shortened)), \(RecapStatus.text(item))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// "Google Meet in Opera GX" → "Google Meet".
    static func shortApp(_ app: String) -> String {
        app.range(of: " in ").map { String(app[..<$0.lowerBound]) } ?? app
    }
}

/// How a recording's recap is doing, as an icon and a word (never by colour alone).
struct RecapStatus: View {
    let item: RecordingItem

    var body: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .ready: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ready)
            case .queued, .transcribing, .writing: Spinner(size: 10, color: Theme.working)
            case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.failed)
            case .waitingForKeys: Image(systemName: "key").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
            case .notProcessed: EmptyView()
            }
            Text(Self.text(item)).font(Theme.sans(11.5, .medium)).foregroundStyle(color).lineLimit(1)
        }
    }

    private var color: Color {
        switch item.status {
        case .ready: Theme.ready
        case .queued, .transcribing, .writing: Theme.working
        case .failed: Theme.failed
        case .waitingForKeys, .notProcessed: Theme.ink3
        }
    }

    static func text(_ item: RecordingItem) -> String {
        switch item.status {
        case .ready: "Recap ready"
        case .queued: "Waiting"
        case .transcribing: "Transcribing"
        case .writing: "Writing recap"
        case .failed: "Recap failed"
        case .waitingForKeys: "Needs API keys"
        case .notProcessed: "No recap"
        }
    }
}

/// Who spoke when, as a thin strip (a plain line before there's a transcript).
struct MiniMap: View {
    let turns: [Transcript.Turn]
    let duration: Double
    var height: CGFloat = 5
    var colors: (Int) -> Color = Theme.speaker
    var empty: Color = Theme.line

    var body: some View {
        Canvas { context, size in
            guard !turns.isEmpty else {
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(empty))
                return
            }
            let total = max(duration, turns.last?.end ?? 1)
            for turn in turns {
                let x0 = turn.start / total * size.width, x1 = turn.end / total * size.width
                let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0 - 1), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(colors(turn.speaker)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The recording in progress, at the top of the library.
private struct RecordingNowRow: View {
    @ObservedObject private var recorder = Recorder.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.recording).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(recorder.callName.map(LibraryRow.shortApp) ?? "Recording").font(Theme.sans(13.5, .semibold)).lineLimit(1)
                Text(recorder.isMuted ? "Recording · muted, your mic is left out" : "Recording")
                    .font(Theme.sans(12)).foregroundStyle(Theme.ink2)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Counter.text(context.date.timeIntervalSince(recorder.startedAt ?? context.date)))
                    .font(Theme.mono(12, .medium))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.recording.opacity(0.5)))
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Import

/// Bringing in recordings made before Tape (or anywhere else), to recap them.
@MainActor
enum Importer {
    static func choose() {
        let panel = NSOpenPanel()
        panel.title = "Import recordings"
        panel.message = "Choose recordings (audio or video) to transcribe and recap."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK else { return }
        start(panel.urls)
    }

    static func load(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                   let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(fileURL)
                }
            }
            start(urls)
        }
    }

    private static func start(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let added = await Library.shared.importFiles(urls)
            for item in added { Processor.shared.process(item.id) }
            if added.count == 1, let item = added.first { MainWindow.shared.show(recording: item.id) }
        }
    }
}

// MARK: - Reader

struct ReaderPane: View {
    @ObservedObject private var main = MainWindow.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = SettingsModel.shared

    var body: some View {
        if let item = library.item(main.selected ?? "") ?? library.items.first {
            Reader(item: item).id(item.id)
        } else {
            VStack(spacing: 14) {
                TapeMarkView(size: 72)
                Text("Your meetings appear here").font(Theme.display(20, .semibold))
                Text("When a call starts, Tape asks whether to record it. When it ends, the recording is saved and turned into a transcript and a recap.")
                    .font(Theme.sans(13.5)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
                if !settings.hasKeys {
                    Button("Add API keys") { main.page = .settings }.buttonStyle(.pill)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Reader: View {
    let item: RecordingItem
    @StateObject private var player = AudioPlayer()
    @ObservedObject private var main = MainWindow.shared

    var body: some View {
        let transcript = Parsed.shared.transcript(item)
        let recap = Parsed.shared.recap(item)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text([item.created.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                          item.created.formatted(date: .omitted, time: .shortened), item.app.map(LibraryRow.shortApp)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                    RecordingName(item: item)
                }

                MeetingMap(player: player, transcript: transcript, topics: recap?.sections ?? [], duration: item.duration)
                    .onAppear { player.load(Library.shared.audioURL(item)) }

                StatusBanner(item: item)

                tabs

                switch main.tab {
                case .recap:
                    if let recap {
                        RecapView(document: recap, markdown: Library.shared.recap(item) ?? "") { player.seek(to: $0, play: true) }
                    } else {
                        EmptyState(title: "No recap yet", detail: item.isWorking ? "It appears here when it's ready." : nil)
                    }
                case .transcript:
                    if let transcript {
                        TranscriptView(transcript: transcript, player: player)
                    } else {
                        EmptyState(title: "No transcript yet", detail: item.isWorking ? "It appears here when it's ready." : nil)
                    }
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 30).padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { player.stop() }
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TabButton(title: "Recap", selected: main.tab == .recap) { main.tab = .recap }
                TabButton(title: "Transcript", selected: main.tab == .transcript) { main.tab = .transcript }
                Spacer()
                actions
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    @ViewBuilder private var actions: some View {
        let recapTab = main.tab == .recap
        let text = recapTab ? Library.shared.recap(item) : Library.shared.transcript(item)
        let file = recapTab ? Library.shared.recapURL(item) : Library.shared.transcriptURL(item)
        if let text {
            CopyButton(text: text)
            TextIconButton(title: recapTab ? "Open .md" : "Open .txt", systemImage: "arrow.up.forward.square") {
                NSWorkspace.shared.open(file)
            }
        }
        Menu {
            Button("Rename…") { main.renaming = item.id }
            Button("Show in Finder") {
                let library = Library.shared
                let files = [library.recapURL(item), library.transcriptURL(item), library.audioURL(item)]
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
            if item.status == .ready || item.status == .failed {
                Button("Write the recap again") { Processor.shared.process(item.id, again: true) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink2)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More")
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.sans(13.5, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.ink3)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? Theme.ink : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "Copy", then "Copied" for a moment.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        TextIconButton(title: copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

/// The recording's name as the reader's title. Click it to rename; Return saves, Escape cancels.
private struct RecordingName: View {
    let item: RecordingItem
    @ObservedObject private var main = MainWindow.shared
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var editing: Bool { main.renaming == item.id }

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name this recording", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.display(30)).tracking(-1)
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { main.renaming = nil }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.ink, lineWidth: 1.5))
                    .padding(.horizontal, -10)
                    .accessibilityLabel("Recording name")
                HStack(spacing: 8) {
                    Button("Save", action: save).buttonStyle(.pill).controlSize(.small)
                    Button("Cancel") { main.renaming = nil }.buttonStyle(.pillQuiet).controlSize(.small)
                    Text("Its files are renamed too.").font(Theme.sans(12)).foregroundStyle(Theme.ink3)
                }
            }
            .onAppear {
                draft = item.name ?? item.title ?? ""
                DispatchQueue.main.async { focused = true }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.displayTitle).font(Theme.display(30)).tracking(-1).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { main.renaming = item.id }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isHeader)
                IconButton(systemImage: "pencil", help: "Rename") { main.renaming = item.id }
                    .opacity(hovering ? 1 : 0)
                    .accessibilityLabel("Rename")
            }
            .onHover { hovering = $0 }
        }
    }

    private func save() {
        main.renaming = nil
        Library.shared.rename(item.id, to: draft)
    }
}

/// What's happening to the recording, or what went wrong.
private struct StatusBanner: View {
    let item: RecordingItem

    var body: some View {
        switch item.status {
        case .ready:
            EmptyView()
        case .queued, .transcribing, .writing:
            banner(icon: AnyView(Spinner(size: 13, color: Theme.working)), text: item.detail ?? "Waiting…",
                   detail: item.status == .transcribing ? "Gemini is listening to the call. A long meeting takes a few minutes." : nil)
        case .waitingForKeys:
            banner(icon: AnyView(Image(systemName: "key").foregroundStyle(Theme.ink2)), text: "Add your API keys to get the recap.", detail: nil) {
                Button("Open Settings") { MainWindow.shared.page = .settings }.buttonStyle(.pillQuiet).controlSize(.small)
            }
        case .notProcessed:
            banner(icon: AnyView(Image(systemName: "doc.text").foregroundStyle(Theme.ink2)), text: "This recording has no recap yet.", detail: nil) {
                Button("Make the recap") { Processor.shared.process(item.id) }.buttonStyle(.pill).controlSize(.small)
            }
        case .failed:
            banner(icon: AnyView(Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.failed)),
                   text: "The recap couldn't be made.", detail: item.detail) {
                Button("Try again") { Processor.shared.process(item.id) }.buttonStyle(.pill).controlSize(.small)
            }
        }
    }

    private func banner(icon: AnyView, text: String, detail: String?,
                        @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon.font(.system(size: 14, weight: .semibold)).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(Theme.sans(13.5, .semibold)).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.ink2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            action()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.fill.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.line))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Player

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published var time: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVPlayer?
    private var observer: Any?

    func load(_ url: URL) {
        let player = AVPlayer(url: url)
        self.player = player
        Task {
            if let length = try? await AVURLAsset(url: url).load(.duration), length.isNumeric { duration = length.seconds }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds
                if let item = player.currentItem, item.duration.isNumeric { self.duration = item.duration.seconds }
                if self.playing, player.rate == 0 { self.playing = false }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            if duration > 0, time >= duration - 0.25 { player.seek(to: .zero) }
            player.play()
        }
        playing.toggle()
    }

    func seek(to seconds: Double, play: Bool = false) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = max(0, seconds)
        if play, !playing { toggle() }
    }

    func skip(_ seconds: Double) { seek(to: min(max(0, time + seconds), duration)) }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        playing = false
    }
}

/// The player as a map of the meeting: play/pause and the time, who spoke (a colour each), the recap's topics
/// as numbered pins where they start, and every turn as a block on the timeline. Click or drag anywhere on it
/// to jump there.
private struct MeetingMap: View {
    @ObservedObject var player: AudioPlayer
    let transcript: Transcript?
    let topics: [RecapDocument.Section]
    let duration: Double
    @State private var scrubbing: Double?

    private var total: Double { max(player.duration, duration, transcript?.turns.last?.end ?? 0, 1) }
    private var now: Double { scrubbing ?? player.time }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.ink))
                }
                .buttonStyle(.plainPointer)
                .accessibilityLabel(player.playing ? "Pause" : "Play")
                IconButton(systemImage: "gobackward.15", help: "Back 15 seconds") { player.skip(-15) }
                    .accessibilityLabel("Back 15 seconds")
                IconButton(systemImage: "goforward.15", help: "Forward 15 seconds") { player.skip(15) }
                    .accessibilityLabel("Forward 15 seconds")
                HStack(spacing: 4) {
                    Text(Counter.text(now)).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.ink)
                    Text("/ \(Counter.text(total))").font(Theme.mono(13)).foregroundStyle(Theme.ink3)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Counter.text(now)) of \(Counter.text(total))")
                Spacer(minLength: 12)
                legend
            }

            VStack(spacing: 6) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                            if let number = topic.number, let time = topic.time {
                                pin(number: number, past: time <= now)
                                    .offset(x: min(max(0, time / total * width - 11), width - 22))
                                    .onTapGesture { player.seek(to: time, play: true) }
                                    .help(topic.title)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Topic \(number): \(topic.title), at \(Counter.text(time))")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { player.seek(to: time, play: true) }
                            }
                        }
                        ribbon(width: width)
                            .offset(y: topicsWithTimes ? 30 : 0)
                    }
                }
                .frame(height: topicsWithTimes ? 64 : 34)
                HStack {
                    ForEach(0..<5) { k in
                        Text(Counter.text(total * Double(k) / 4)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                        if k < 4 { Spacer() }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Theme.line))
    }

    private var topicsWithTimes: Bool { topics.contains { $0.number != nil && $0.time != nil } }

    @ViewBuilder private var legend: some View {
        if let speakers = transcript?.speakers, speakers.count > 1 || speakers.first != "Speaker" {
            HStack(spacing: 14) {
                ForEach(Array(speakers.prefix(Theme.namedSpeakers).enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.speaker(index)).frame(width: 10, height: 10)
                        Text(name).font(Theme.sans(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                if speakers.count > Theme.namedSpeakers {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.speaker(Theme.namedSpeakers)).frame(width: 10, height: 10)
                        Text("\(speakers.count - Theme.namedSpeakers) more").font(Theme.sans(12)).foregroundStyle(Theme.ink2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speakers: " + speakers.joined(separator: ", "))
        }
    }

    private func pin(number: String, past: Bool) -> some View {
        Text(number).font(Theme.mono(11, .semibold))
            .foregroundStyle(past ? Theme.onInk : Theme.ink)
            .frame(width: 22, height: 22)
            .background(Circle().fill(past ? Theme.ink : Theme.raised))
            .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
            .pointerCursor()
    }

    /// The turns, full colour up to the playhead and faded after it, and the playhead.
    private func ribbon(width: CGFloat) -> some View {
        let turns = transcript?.turns ?? []
        let playX = CGFloat(now / total) * width
        return Canvas { context, size in
            func draw(_ context: GraphicsContext, opacity: Double) {
                guard !turns.isEmpty else {
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                                 with: .color(Theme.ink.opacity(opacity * 0.5)))
                    return
                }
                for turn in turns {
                    let x0 = CGFloat(turn.start / total) * size.width, x1 = CGFloat(turn.end / total) * size.width
                    let rect = CGRect(x: x0, y: 0, width: max(1.5, x1 - x0 - 2), height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(4, rect.width / 2)), with: .color(Theme.speaker(turn.speaker).opacity(opacity)))
                }
            }
            draw(context, opacity: 0.28)
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: playX, height: size.height)))
            draw(played, opacity: 1)
        }
        .frame(width: width, height: 30)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.ink).frame(width: 2, height: 38)
                .offset(x: min(max(0, playX - 1), width - 2))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { scrubbing = max(0, min(total, Double($0.location.x / width) * total)) }
                .onEnded { _ in
                    if let scrubbing { player.seek(to: scrubbing) }
                    scrubbing = nil
                }
        )
        .pointerCursor()
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Counter.text(now)) of \(Counter.text(total))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(15)
            case .decrement: player.skip(-15)
            @unknown default: break
            }
        }
    }
}

// MARK: - Recap and transcript

/// A recap as it reads in the app: the opening paragraph, then each topic numbered (with where it starts in
/// the recording, to play from there), then the next steps.
private struct RecapView: View {
    let document: RecapDocument
    let markdown: String
    let play: (Double) -> Void

    var body: some View {
        if document.sections.isEmpty {
            MarkdownBlocks(blocks: MarkdownBlock.parse(markdown).filter { if case .heading(1, _) = $0 { false } else { true } })
        } else {
            VStack(alignment: .leading, spacing: 22) {
                MarkdownBlocks(blocks: document.intro, size: 15)
                ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                    HStack(alignment: .top, spacing: 14) {
                        badge(section.number)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 10) {
                                Text(section.title).font(Theme.sans(18, .semibold)).tracking(-0.4).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                if let time = section.time {
                                    Button { play(time) } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                                            Text(Counter.text(time)).font(Theme.mono(11.5, .medium))
                                        }
                                        .foregroundStyle(Theme.ink)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
                                    }
                                    .buttonStyle(.plainPointer)
                                    .help("Play from here")
                                    .accessibilityLabel("Play from \(Counter.text(time))")
                                }
                            }
                            MarkdownBlocks(blocks: section.blocks)
                        }
                    }
                }
                if let source = document.source {
                    Text("Source: " + source).font(Theme.sans(12)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func badge(_ number: String?) -> some View {
        if let number {
            Text(number).font(Theme.mono(11.5, .semibold)).foregroundStyle(Theme.onInk)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.ink))
                .padding(.top, 1)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 24, height: 24).overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
                .padding(.top, 1)
                .accessibilityHidden(true)
        }
    }
}

/// Paragraphs, bullets with bold lead-ins, numbered lines and sub-headings.
struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    var size: CGFloat = 14.5

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(Theme.sans(level <= 2 ? 17 : 15, .semibold)).foregroundStyle(Theme.ink)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(depth == 0 ? Theme.ink2 : Theme.ink3).frame(width: 4.5, height: 4.5).offset(y: -2.5)
                        inline(text)
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).").font(Theme.mono(13)).foregroundStyle(Theme.ink3)
                        inline(text)
                    }
                case .paragraph(let text):
                    if !text.hasPrefix("<!--") { inline(text) }
                case .rule:
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .font(Theme.sans(size))
        .lineSpacing(size * 0.32)
        .foregroundStyle(Theme.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bold (in ink), italics and `code` inside a line.
    private func inline(_ text: String) -> Text {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            attributed[run.range].foregroundColor = Theme.ink
        }
        return Text(attributed)
    }
}

/// The transcript line by line: its time (click to play from there), who spoke (in their colour), and what was
/// said. The line being played is highlighted.
private struct TranscriptView: View {
    let transcript: Transcript
    @ObservedObject var player: AudioPlayer

    var body: some View {
        let lines = transcript.lines
        let playing = player.playing ? lines.lastIndex { ($0.time ?? .infinity) <= player.time } : nil
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                let newSpeaker = line.speaker != nil && (index == 0 || lines[index - 1].speaker != line.speaker)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    if let time = line.time, let stamp = line.stamp {
                        Button { player.seek(to: time, play: true) } label: {
                            Text(stamp).font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill))
                        }
                        .buttonStyle(.plainPointer)
                        .help("Play from here")
                        .accessibilityLabel("Play from \(stamp)")
                        .frame(width: 64, alignment: .leading)
                    } else {
                        Color.clear.frame(width: 64, height: 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if newSpeaker, let speaker = line.speaker {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(Theme.speaker(transcript.speakers.firstIndex(of: speaker) ?? Theme.namedSpeakers))
                                    .frame(width: 9, height: 9)
                                Text(speaker).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                            }
                        }
                        Text(line.text).font(Theme.sans(14.5)).foregroundStyle(index == playing ? Theme.ink : Theme.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(index == playing ? Theme.fill.opacity(0.7) : .clear))
                .padding(.top, newSpeaker && index > 0 ? 8 : 0)
                .padding(.horizontal, -8)
            }
        }
    }
}
