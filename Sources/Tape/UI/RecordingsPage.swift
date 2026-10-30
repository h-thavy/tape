import AVFoundation
import AppKit
import SwiftUI
import TapeCore

/// Every recorded call, newest first, grouped by day; or one recording with its recap.
struct RecordingsPage: View {
    @ObservedObject private var main = MainWindow.shared
    @ObservedObject private var library = Library.shared

    var body: some View {
        if let id = main.selected, let item = library.item(id) {
            RecordingDetail(item: item).id(id)
        } else {
            RecordingList()
        }
    }
}

// MARK: - List

private struct RecordingList: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var settings = SettingsModel.shared
    @State private var search = ""
    @State private var dropping = false

    var body: some View {
        list
            // Drop recordings (or videos) anywhere on the page to import them.
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                Importer.load(providers)
                return true
            }
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.ink.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(0.35)))
                        .overlay(Text("Drop to make recaps").font(Theme.serif(26)).foregroundStyle(Theme.ink))
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
    }

    private var list: some View {
        PageScroll {
            PageHeader(title: "Recordings") {
                Button { Importer.choose() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.pillQuiet)
                    .help("Make recaps of recordings from before Tape, or from elsewhere (audio or video files)")
                if recorder.isRecording {
                    Button { recorder.stop() } label: { Label("Stop and save", systemImage: "stop.fill") }
                        .buttonStyle(.pillRecord)
                } else {
                    Button { recorder.start(call: CallWatcher.shared.current, followsCall: CallWatcher.shared.current != nil) } label: {
                        Label("Start recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.pill)
                }
            }
            if !settings.hasKeys {
                HeroCard(before: "Recaps from ", italic: "your", after: " own keys.",
                         message: "Tape records every call on this Mac. To turn a recording into a transcript and a recap, add a Gemini key (it listens to the call, Khmer and English) and an Anthropic key (Claude writes the recap). No account, no sign-in.") {
                    Button("Add API keys") { MainWindow.shared.page = .settings }.buttonStyle(.pill)
                }
            }
            if library.items.count > 4 {
                SearchField(prompt: "Search recordings", text: $search)
            }
            if library.items.isEmpty {
                EmptyState(title: "No recordings yet",
                           detail: "When a call starts, Tape asks whether to record it. To recap a recording you already have, drop it here or use Import.")
            } else {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: group.title)
                        TableCard {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().overlay(Theme.border) }
                                RecordingRow(item: item)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groups: [(title: String, items: [RecordingItem])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let items = library.items.filter {
            query.isEmpty || $0.displayTitle.lowercased().contains(query) || $0.id.lowercased().contains(query)
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

private struct RecordingRow: View {
    let item: RecordingItem

    var body: some View {
        HoverRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle).font(Theme.sans(15, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(meta(item)).font(Theme.sans(13)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusChip(item: item)
            }
        } actions: {
            IconButton(systemImage: "pencil", help: "Rename") {
                MainWindow.shared.show(recording: item.id, rename: true)
            }
            IconButton(systemImage: "folder", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Library.shared.audioURL(item)])
            }
        }
        .onTapGesture { MainWindow.shared.selected = item.id }
        .pointerCursor()
    }
}

@MainActor
func meta(_ item: RecordingItem) -> String {
    [item.created.formatted(date: .omitted, time: .shortened), Recorder.duration(item.duration), item.app]
        .compactMap { $0 }.joined(separator: " · ")
}

private struct StatusChip: View {
    let item: RecordingItem

    var body: some View {
        switch item.status {
        case .ready:
            EmptyView()
        case .queued, .transcribing, .writing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(item.status == .writing ? "Writing recap" : item.status == .queued ? "Waiting" : "Transcribing")
            }
            .chip(Theme.accent, Theme.onAccent)
        case .waitingForKeys:
            Text("Needs API keys").chip(Theme.buttonFill, Theme.inkSecondary)
        case .notProcessed:
            Text("No recap").chip(Theme.buttonFill, Theme.inkSecondary)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").chip(Theme.recording.opacity(0.12), Theme.recording)
        }
    }
}

private extension View {
    func chip(_ fill: Color, _ ink: Color) -> some View {
        font(Theme.sans(12, .semibold)).foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(fill))
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
            if added.count == 1, let item = added.first { MainWindow.shared.selected = item.id }
        }
    }
}

// MARK: - Detail

private struct RecordingDetail: View {
    let item: RecordingItem
    @State private var tab: Tab = .recap
    @StateObject private var player = AudioPlayer()

    enum Tab { case recap, transcript }

    var body: some View {
        PageScroll {
            Button { MainWindow.shared.selected = nil } label: {
                Label("Recordings", systemImage: "chevron.left").font(Theme.sans(14, .medium)).foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plainPointer)

            VStack(alignment: .leading, spacing: 6) {
                RecordingName(item: item)
                Text([item.created.formatted(date: .complete, time: .shortened), Recorder.duration(item.duration), item.app]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.sans(14)).foregroundStyle(Theme.inkTertiary)
            }

            PlayerBar(player: player)
                .onAppear { player.load(Library.shared.audioURL(item)) }

            StatusBanner(item: item)

            HStack(spacing: 0) {
                UnderlineTab(title: "Recap", selected: tab == .recap) { tab = .recap }
                UnderlineTab(title: "Transcript", selected: tab == .transcript) { tab = .transcript }
                Spacer()
                actions
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            switch tab {
            case .recap:
                if let recap = Library.shared.recap(item) {
                    MarkdownView(markdown: recap, skipTitle: true)
                } else {
                    EmptyState(title: "No recap yet", detail: item.isWorking ? "It appears here when it's ready." : nil)
                }
            case .transcript:
                if let transcript = Library.shared.transcript(item) {
                    Text(transcript).font(Theme.sans(14.5)).lineSpacing(4).foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    EmptyState(title: "No transcript yet", detail: item.isWorking ? "It appears here when it's ready." : nil)
                }
            }
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            if tab == .recap, let recap = Library.shared.recap(item) {
                IconButton(systemImage: "doc.on.doc", help: "Copy the recap (Markdown)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recap, forType: .string)
                }
            }
            if tab == .transcript, let transcript = Library.shared.transcript(item) {
                IconButton(systemImage: "doc.on.doc", help: "Copy the transcript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }
            }
            IconButton(systemImage: "folder", help: "Show in Finder") {
                let library = Library.shared
                let files = [library.recapURL(item), library.transcriptURL(item), library.audioURL(item)]
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
            if item.status == .ready || item.status == .failed {
                IconButton(systemImage: "arrow.clockwise", help: "Write the recap again") {
                    Processor.shared.process(item.id, again: true)
                }
            }
        }
    }
}

/// The recording's name as the page title. Click it (or the pencil) to rename; Return saves, Escape cancels.
private struct RecordingName: View {
    let item: RecordingItem
    @ObservedObject private var main = MainWindow.shared
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var editing: Bool { main.renaming == item.id }

    var body: some View {
        Group {
            if editing {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name this recording", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Theme.serif(32)).tracking(-0.8).foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit(save)
                        .onExitCommand { main.renaming = nil }
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.outline))
                        .padding(.horizontal, -8)
                    HStack(spacing: 8) {
                        Button("Save", action: save).buttonStyle(.pill).controlSize(.small)
                        Button("Cancel") { main.renaming = nil }.buttonStyle(.pillQuiet).controlSize(.small)
                        Text("The recording's files are renamed too.").font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary)
                    }
                }
                .onAppear {
                    draft = item.name ?? item.title ?? ""
                    DispatchQueue.main.async { focused = true }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.displayTitle).font(Theme.serif(32)).tracking(-0.8).foregroundStyle(Theme.ink)
                        .onTapGesture { main.renaming = item.id }
                        .help("Click to rename")
                    IconButton(systemImage: "pencil", help: "Rename") { main.renaming = item.id }
                        .opacity(hovering ? 1 : 0)
                }
                .onHover { hovering = $0 }
            }
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
            banner(symbol: nil, text: item.detail ?? "Waiting…",
                   detail: item.status == .transcribing ? "Gemini is listening to the call. A long meeting takes a few minutes." : nil)
        case .waitingForKeys:
            banner(symbol: "key", text: "Add your API keys to get the recap.", detail: nil) {
                Button("Open Settings") { MainWindow.shared.page = .settings }.buttonStyle(.pillQuiet).controlSize(.small)
            }
        case .notProcessed:
            banner(symbol: "doc.text", text: "This recording has no recap yet.", detail: nil) {
                Button("Make the recap") { Processor.shared.process(item.id) }.buttonStyle(.pill).controlSize(.small)
            }
        case .failed:
            banner(symbol: "exclamationmark.triangle", text: "The recap couldn't be made.", detail: item.detail) {
                Button("Try again") { Processor.shared.process(item.id) }.buttonStyle(.pill).controlSize(.small)
            }
        }
    }

    private func banner(symbol: String?, text: String, detail: String?,
                        @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.inkSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Theme.sans(14, .medium)).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.inkTertiary).textSelection(.enabled) }
            }
            Spacer()
            action()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.mutedCard))
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

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        playing = false
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 13))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.primary))
            }
            .buttonStyle(.plainPointer)
            Text(Self.clock(scrubbing ?? player.time)).font(Theme.sans(12.5)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
            Slider(value: Binding(get: { scrubbing ?? player.time }, set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let value = scrubbing {
                    player.seek(to: value)
                    scrubbing = nil
                }
            }
            .controlSize(.small)
            .tint(Theme.ink)
            Text(Self.clock(player.duration)).font(Theme.sans(12.5)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(Theme.border))
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(0, seconds) : 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Markdown

/// A recap as it reads in the app: serif title, section headings, bullets with bold lead-ins.
struct MarkdownView: View {
    let markdown: String
    /// Leave out the first heading (the page already shows it as its title).
    var skipTitle = false

    private var blocks: [MarkdownBlock] {
        var blocks = MarkdownBlock.parse(markdown)
        if skipTitle, case .heading(1, _)? = blocks.first { blocks.removeFirst() }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level == 1 ? Theme.serif(26) : level == 2 ? Theme.sans(18, .semibold) : Theme.sans(15.5, .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, level == 1 ? 0 : 12)
                case .bullet(let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(depth == 0 ? "•" : "◦").foregroundStyle(Theme.inkTertiary)
                        inline(text)
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).").foregroundStyle(Theme.inkTertiary).monospacedDigit()
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                case .rule:
                    Divider().overlay(Theme.border)
                }
            }
        }
        .font(Theme.sans(15))
        .lineSpacing(3)
        .foregroundStyle(Theme.inkSecondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bold, italics and `code` inside a line.
    private func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
    }
}
