import AppKit
import SwiftUI

/// The app window and which page it shows. Closing the window leaves Tape running in the menu bar, still
/// listening for calls.
@MainActor
final class MainWindow: ObservableObject {
    static let shared = MainWindow()

    enum Page { case recordings, settings }

    @Published var page: Page = .recordings
    /// The recording open on the Recordings page (nil: the list).
    @Published var selected: String?
    /// The recording whose name is being typed (its title becomes a field).
    @Published var renaming: String?
    private var window: NSWindow?

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

    /// Debug hook: TAPE_SNAPSHOT=<folder> saves the window's pages there as PNGs (list, first recording,
    /// settings), for checking the layout without screen-recording permission.
    func snapshotIfAsked() {
        guard let folder = ProcessInfo.processInfo.environment["TAPE_SNAPSHOT"] else { return }
        let first = Library.shared.items.first(where: { $0.status == .ready })?.id ?? Library.shared.items.first?.id
        let steps: [(String, () -> Void)] = [
            ("recordings", { self.page = .recordings; self.selected = nil }),
            ("recording", { self.page = .recordings; self.selected = first }),
            ("settings", { self.page = .settings }),
        ]
        Task { @MainActor in
            for (name, step) in steps {
                step()
                try? await Task.sleep(for: .seconds(1.2))
                guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
            }
            self.page = .recordings
            self.selected = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Tape"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.contentView = NSHostingView(rootView: RootView())
        window.setFrameAutosaveName("TapeMainWindow")
        if !window.setFrameUsingName("TapeMainWindow") { window.center() }
        return window
    }
}

/// A 52 pt title strip shared with the traffic lights, then the sidebar on the warm frame and the page on a
/// rounded panel (24 pt corners on top, 16 at the bottom).
private struct RootView: View {
    @ObservedObject private var main = MainWindow.shared

    private let panel = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 16,
                                               bottomTrailingRadius: 16, topTrailingRadius: 24)

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 52)
            HStack(spacing: 0) {
                Sidebar().frame(width: 216)
                Group {
                    switch main.page {
                    case .recordings: RecordingsPage()
                    case .settings: SettingsPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(panel.fill(Theme.page))
                .clipShape(panel)
                .overlay(panel.strokeBorder(Theme.border))
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .ignoresSafeArea()
        .background(Theme.frame)
        .font(Theme.sans(15))
        .foregroundStyle(Theme.ink)
    }
}

private struct Sidebar: View {
    @ObservedObject private var main = MainWindow.shared
    @ObservedObject private var recorder = Recorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TapeMarkView(size: 30)
                Text("Tape").font(Theme.serif(26))
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .padding(.bottom, 16)

            NavItem(title: "Recordings", icon: "waveform", selected: main.page == .recordings,
                    badge: recorder.isRecording ? "REC" : nil) {
                main.page = .recordings
                main.selected = nil
            }

            Spacer(minLength: 0)

            UpdateCard()
            StatusCard()
                .padding(.bottom, 8)
            Divider().overlay(Theme.border)
                .padding(.bottom, 8)
            NavItem(title: "Settings", icon: "gearshape", selected: main.page == .settings) {
                main.page = .settings
            }
        }
        .padding(12)
    }
}

private struct NavItem: View {
    let title: String
    let icon: String
    let selected: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20, height: 20)
                Text(title).font(Theme.sans(15, .medium))
                Spacer()
                if let badge {
                    Text(badge).font(Theme.sans(10, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.recording))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected || hovering ? Theme.buttonFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A newer Tape is on GitHub: one click to update.
private struct UpdateCard: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        switch updates.state {
        case .available(let version), .waiting(let version), .downloading(let version, _), .installing(let version):
            VStack(alignment: .leading, spacing: 8) {
                Label("Tape \(version) is ready", systemImage: "arrow.down.circle").font(Theme.sans(12.5, .semibold))
                if case .available = updates.state {
                    Button("Update") { updates.update() }.buttonStyle(.pill).controlSize(.small)
                } else {
                    Text(updates.state == .waiting(version) ? "After this recording" : "Updating…")
                        .font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
            .padding(.bottom, 4)
        default:
            EmptyView()
        }
    }
}

/// Bottom of the sidebar: what Tape is doing (recording, or listening for calls), or what needs setting up.
private struct StatusCard: View {
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var settings = SettingsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.isRecording, let started = recorder.startedAt {
                HStack(spacing: 8) {
                    Circle().fill(Theme.recording).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Recording · \(Self.clock(context.date.timeIntervalSince(started)))")
                            .font(Theme.sans(12.5, .semibold)).monospacedDigit()
                    }
                }
                if recorder.isMuted {
                    Text("Muted in the call: your mic is left out").font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
                }
                Button("Stop and save") { recorder.stop() }.buttonStyle(.pillQuiet).controlSize(.small)
            } else if !settings.hasKeys {
                Label("Recaps need API keys", systemImage: "key").font(Theme.sans(12.5, .semibold))
                Button("Add in Settings") { MainWindow.shared.page = .settings }.buttonStyle(.pill).controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Theme.success).frame(width: 7, height: 7)
                    Text("Listening for calls").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                }
                Text("Tape asks when a call starts.").font(Theme.sans(11.5)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mutedCard))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
