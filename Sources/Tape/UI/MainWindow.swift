import AppKit
import SwiftUI

/// The app window and what it shows. Closing the window leaves Tape running in the menu bar (and the notch),
/// still listening for calls.
@MainActor
final class MainWindow: ObservableObject {
    static let shared = MainWindow()

    enum Page { case recordings, settings }
    enum Tab { case recap, transcript }

    @Published var page: Page = .recordings
    /// The recording open in the reader (nil: the newest).
    @Published var selected: String?
    /// The recording whose name is being typed (its title becomes a field).
    @Published var renaming: String?
    @Published var search = ""
    @Published var tab: Tab = .recap
    /// Recordings picked with ⌘-click or ⇧-click (more than one: the reader shows what can be done to them).
    @Published var marked: Set<String> = []
    /// Where a ⇧-click range starts.
    private var anchor: String?
    private var window: NSWindow?

    /// A click on a recording in the library (`order`: the recordings as listed). ⌘ adds or removes it, ⇧
    /// takes everything from the last one clicked to it, a plain click picks just it.
    func pick(_ id: String, in order: [String]) {
        let flags = NSEvent.modifierFlags
        let shown = selected ?? order.first
        page = .recordings
        if flags.contains(.shift), let from = anchor ?? shown, let a = order.firstIndex(of: from), let b = order.firstIndex(of: id) {
            marked = Set(order[min(a, b)...max(a, b)])
        } else if flags.contains(.command) {
            if marked.isEmpty, let shown { marked = [shown] }
            if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
            anchor = id
        } else {
            marked = []
            anchor = id
        }
        if marked.count <= 1 {
            selected = marked.first ?? id
            marked = []
        }
    }

    /// Puts the recordings' audio files on the clipboard, as files: pasting attaches them (in a chat, an email,
    /// Finder).
    static func copyFiles(_ ids: Set<String>) {
        let urls = Library.shared.items.filter { ids.contains($0.id) }.map { Library.shared.audioURL($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// Asks, then moves the recordings to the Trash.
    func trash(_ ids: Set<String>) {
        let items = Library.shared.items.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        let busy = items.filter { $0.status == .transcribing || $0.status == .writing }
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Move “\(items[0].displayTitle)” to the Trash?" : "Move \(items.count) recordings to the Trash?"
        alert.informativeText = "Their audio, transcripts and recaps go to the Trash; you can put them back from there."
            + (busy.isEmpty ? "" : " \(busy.count == 1 ? "One is" : "\(busy.count) are") being recapped right now and will stay.")
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let moved = Library.shared.trash(ids)
            self.marked.subtract(moved)
            if let selected = self.selected, moved.contains(selected) { self.selected = nil }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    func show(recording: String? = nil, page: Page = .recordings, rename: Bool = false) {
        self.page = page
        if let recording { selected = recording }
        renaming = rename ? recording : nil
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Nothing focused at first (the search field would take the cursor), unless a name is being typed.
        if !rename { DispatchQueue.main.async { window.makeFirstResponder(nil) } }
    }

    #if DEBUG
    /// The E2E runner captures the actual reader without touching normal startup or recording hardware.
    func pipelineSnapshot(to url: URL) {
        if let view = window?.contentView { Snapshot.write(view, to: url) }
    }
    #endif

    /// Debug hook: TAPE_SNAPSHOT=<folder> saves the window's pages there as PNGs (the newest recording's recap
    /// and transcript, settings), the onboarding's steps and the notch island's states, for checking the
    /// layout without screen recording.
    func snapshotIfAsked() {
        guard let folder = ProcessInfo.processInfo.environment["TAPE_SNAPSHOT"].map({ URL(fileURLWithPath: $0) }) else { return }
        let first = Library.shared.items.first(where: { $0.status == .ready })?.id ?? Library.shared.items.first?.id
        let steps: [(String, () -> Void)] = [
            ("recap", { self.page = .recordings; self.selected = first; self.tab = .recap }),
            ("transcript", { self.page = .recordings; self.selected = first; self.tab = .transcript }),
            ("settings", { self.page = .settings; self.tab = .recap }),
            ("selection", { self.page = .recordings; self.marked = Set(Library.shared.items.prefix(3).map(\.id)) }),
        ]
        Task { @MainActor in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window?.appearance = NSAppearance(named: appearance)
                let suffix = appearance == .aqua ? "" : "-dark"
                for (name, step) in steps {
                    marked = []
                    step()
                    try? await Task.sleep(for: .seconds(1.2))
                    if let view = window?.contentView { Snapshot.write(view, to: folder.appendingPathComponent("\(name)\(suffix).png")) }
                }
            }
            window?.appearance = nil
            page = .recordings
            marked = []
            Onboarding.snapshot(to: folder)
            Toast.snapshots(to: folder)
            NotchBar.snapshots(to: folder)
            for (name, image) in [("menubar", TapeMark.menuBarImage()), ("menubar-update", TapeMark.menuBarImage(update: true)),
                                  ("menubar-recording", TapeMark.menuBarImage(recording: true))] {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 78, pixelsHigh: 54, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = NSSize(width: 26, height: 18)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor(white: 0.12, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: 26, height: 18).fill()
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    image.draw(in: NSRect(x: 0, y: 0, width: 26, height: 18))
                }
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Tape"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 580)
        window.contentView = NSHostingView(rootView: RootView())
        window.setFrameAutosaveName("TapeMainWindow")
        if !window.setFrameUsingName("TapeMainWindow") { window.center() }
        return window
    }
}

/// A view drawn into a PNG.
enum Snapshot {
    @MainActor static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The title bar across the top (with the traffic lights), the library on the left, and on the right the
/// reader (or Settings).
private struct RootView: View {
    @ObservedObject private var main = MainWindow.shared

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                LibraryColumn().frame(width: 320)
                Rectangle().fill(Theme.line).frame(width: 1)
                Group {
                    switch main.page {
                    case .recordings: ReaderPane()
                    case .settings: SettingsPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            }
        }
        .ignoresSafeArea()
        .background(Theme.background)
        .font(Theme.sans(14))
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
    }
}

/// The wordmark, search, what Tape is doing, Record, and Settings.
private struct TitleBar: View {
    @ObservedObject private var main = MainWindow.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var calls = CallWatcher.shared
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Room for the traffic lights.
            Color.clear.frame(width: 62, height: 1)
            Wordmark().accessibilityElement(children: .ignore).accessibilityLabel("Tape")
            SearchField(prompt: "Search meetings", text: $main.search, focused: $searching)
                .frame(width: 300).padding(.leading, 18)
                .accessibilityLabel("Search meetings")
            // ⌘K: to the search box.
            Button("") { searching = true }.keyboardShortcut("k").opacity(0).frame(width: 0).accessibilityHidden(true)
            Spacer()
            if let version = updates.availableVersion {
                Button { updates.update() } label: { Label("Update to \(version)", systemImage: "arrow.down.circle") }
                    .buttonStyle(.pillQuiet).controlSize(.small)
            }
            status
            if recorder.isRecording {
                Button { recorder.stop() } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.onInk).frame(width: 8, height: 8)
                        Text("Stop and save")
                    }
                }
                .buttonStyle(.pill)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                Button {
                    recorder.start(call: calls.current, followsCall: calls.current != nil)
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.recording).frame(width: 8, height: 8)
                        Text("Record")
                    }
                }
                .buttonStyle(.pill)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Start recording (⇧⌘R)")
            }
            IconButton(systemImage: main.page == .settings ? "xmark" : "gearshape", help: main.page == .settings ? "Close Settings" : "Settings",
                       box: 32, icon: 15) {
                main.page = main.page == .settings ? .recordings : .settings
            }
            .accessibilityLabel(main.page == .settings ? "Close Settings" : "Settings")
        }
        .padding(.trailing, 16)
        .frame(height: 56)
    }

    /// Listening, on a call, recording (with the time), or what's missing.
    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            if recorder.isRecording, let started = recorder.startedAt {
                Circle().fill(Theme.recording).frame(width: 7, height: 7)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Counter.text(context.date.timeIntervalSince(started))).font(Theme.mono(12.5, .medium)).foregroundStyle(Theme.ink)
                }
                if recorder.blindToMute {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.working)
                    Button { main.show(page: .settings) } label: {
                        Text("Can't see your mute button").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.working)
                    }
                    .buttonStyle(.plainPointer)
                    .help("Allow Accessibility in Settings, or your mic is recorded even while you're muted")
                } else {
                    Text(recorder.isMuted ? "Muted: your mic is left out" : "Recording").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink2)
                }
            } else if !settings.hasKeys {
                Image(systemName: "key").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.working)
                Button { main.page = .settings } label: {
                    Text("Add API keys for recaps").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plainPointer)
            } else if let call = calls.current {
                Circle().fill(Theme.ready).frame(width: 7, height: 7)
                Text("On a call: \(call.name)").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink2).lineLimit(1)
            } else {
                Circle().strokeBorder(Theme.ink2, lineWidth: 1.5).frame(width: 8, height: 8)
                Text("Listening for calls").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .overlay(Capsule().strokeBorder(Theme.line))
        .accessibilityElement(children: .combine)
    }
}
