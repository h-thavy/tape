import AppKit
import Combine
import SwiftUI

/// The camera notch as Tape's quick controls, like a Dynamic Island. Hover over the notch and it opens: start
/// a recording, import, open Tape, and the latest recording with its recap; while recording, the time, whether
/// your mic is in, and Stop and save. While recording, a live strip hugs the notch all the time (a red dot and
/// the timer on one side, your mic's level, or a crossed-out mic while you're muted, on the other), over
/// full-screen calls too. Only on a screen with a notch; elsewhere the menu bar icon has the same actions.
@MainActor
final class NotchBar: ObservableObject {
    static let shared = NotchBar()

    @Published private(set) var open = false
    @Published private(set) var notch: CGSize = .zero
    private var panel: NSPanel?
    private var screen: NSScreen?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var leftAt: Date?

    /// How far the live strip reaches out on each side of the notch while recording.
    static let wing: CGFloat = 68
    static let openWidth: CGFloat = 460

    func start() {
        place()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.place() } }
            .store(in: &cancellables)
        // The mouse is followed rather than tracked: the panel is mostly see-through, and see-through parts of a
        // window don't get mouse events.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { NotchBar.shared.followMouse() }
        }
    }

    /// On the screen with the notch (the built-in display), or nowhere.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { Toast.notch(on: $0) != nil }), let notch = Toast.notch(on: screen) else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        self.screen = screen
        self.notch = notch
        let size = NSSize(width: Self.openWidth + 40, height: notch.height + 260)
        let panel = self.panel ?? Self.makePanel()
        panel.setFrame(NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = FirstClickHostingView(rootView: NotchView())
        return panel
    }

    /// Opens while the pointer is over the notch (or the open island), closes a moment after it leaves.
    private func followMouse() {
        guard let screen, panel != nil else { return }
        let mouse = NSEvent.mouseLocation
        let width = open ? Self.openWidth : notch.width + (Recorder.shared.isRecording ? 2 * Self.wing : 0)
        let height = open ? notch.height + (Recorder.shared.isRecording ? 170 : 236) : notch.height
        let area = NSRect(x: screen.frame.midX - width / 2 - 4, y: screen.frame.maxY - height - 4, width: width + 8, height: height + 4)
        let inside = area.contains(mouse)
        if inside, !open, !Toast.shared.isShowing {
            leftAt = nil
            withAnimation(Toast.spring(0.4, 0.8)) { open = true }
        } else if !inside, open {
            if leftAt == nil { leftAt = Date() }
            if let leftAt, Date().timeIntervalSince(leftAt) > 0.35 { close() }
        } else if inside {
            leftAt = nil
        }
    }

    /// Debug: the notch's states drawn into PNGs (a 14" MacBook Pro's notch), whatever is happening now.
    static func snapshots(to folder: URL) {
        let notch = CGSize(width: 185, height: 32)
        let states: [(String, NotchView.Preview)] = [
            ("notch-actions", .init(open: true, recording: false, muted: false)),
            ("notch-recording-open", .init(open: true, recording: true, muted: true)),
            ("notch-recording", .init(open: false, recording: true, muted: false)),
            ("notch-recording-muted", .init(open: false, recording: true, muted: true)),
        ]
        for (name, preview) in states {
            let view = NSHostingView(rootView: NotchView(preview: preview, previewNotch: notch).background(Color(hex: 0xC9C9C9)))
            view.frame = NSRect(x: 0, y: 0, width: openWidth + 40, height: preview.open ? notch.height + 250 : notch.height + 30)
            Snapshot.write(view, to: folder.appendingPathComponent("\(name).png"))
        }
    }

    func close() {
        leftAt = nil
        withAnimation(Toast.spring(0.32, 0.9)) { open = false }
    }
}

private struct NotchView: View {
    /// Debug snapshots: a state to draw instead of the real one.
    struct Preview {
        let open: Bool
        let recording: Bool
        let muted: Bool
    }
    var preview: Preview?
    var previewNotch: CGSize?

    @ObservedObject private var bar = NotchBar.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var calls = CallWatcher.shared

    private var open: Bool { preview?.open ?? bar.open }
    private var recording: Bool { preview?.recording ?? recorder.isRecording }
    private var muted: Bool { preview?.muted ?? recorder.isMuted }
    private var notch: CGSize { previewNotch ?? bar.notch }
    private var started: Date { preview != nil ? Date().addingTimeInterval(-768) : recorder.startedAt ?? Date() }

    var body: some View {
        let width = open ? NotchBar.openWidth : notch.width + (recording ? 2 * NotchBar.wing : 0)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if open {
                    Group { if recording { recordingPanel } else { quickActions } }
                        .padding(.top, notch.height + 10)
                        .padding(.horizontal, 22).padding(.bottom, 18)
                        .transition(.opacity)
                } else if recording {
                    live.frame(height: notch.height)
                }
            }
            .frame(width: width, height: open ? nil : notch.height, alignment: .top)
            .background(IslandShape(flare: 8, radius: open ? 26 : 12).fill(Color.black))
            .clipShape(IslandShape(flare: 8, radius: open ? 26 : 12))
            .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 18, y: 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(Toast.spring(0.4, 0.82), value: recording)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tape")
    }

    // MARK: Live strip

    /// While recording: the red dot and the time left of the notch, your mic right of it.
    private var live: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Theme.recording).frame(width: 7, height: 7)
                clock.font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.Island.text)
            }
            .frame(width: NotchBar.wing - 16, alignment: .leading)
            Spacer(minLength: notch.width)
            Group {
                if muted {
                    Image(systemName: "mic.slash.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Island.text2)
                } else {
                    LevelBars()
                }
            }
            .frame(width: NotchBar.wing - 16, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Recording, muted in the call: your mic is left out" : "Recording")
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Counter.text(context.date.timeIntervalSince(started))).monospacedDigit()
        }
    }

    // MARK: Open, not recording

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TapeMarkView(size: 18, ink: .white)
                Text("Tape").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.Island.text)
                Text(calls.current.map { "On a call: \($0.name)" } ?? "Listening for calls")
                    .font(Theme.sans(12)).foregroundStyle(Theme.Island.text2).lineLimit(1)
                Spacer()
                Button { bar.close(); MainWindow.shared.show(page: .settings) } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Island.text2)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
                .accessibilityLabel("Settings")
            }
            HStack(spacing: 8) {
                tile("Record now", symbol: "record.circle") {
                    recorder.start(call: calls.current, followsCall: calls.current != nil)
                    bar.close()
                }
                tile("Import", symbol: "square.and.arrow.down") { bar.close(); Importer.choose() }
                tile("Open Tape", symbol: "macwindow") { bar.close(); MainWindow.shared.show() }
            }
            if let latest = library.items.first {
                Button {
                    bar.close()
                    MainWindow.shared.show(recording: latest.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(latest.displayTitle).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.Island.text).lineLimit(1)
                            MiniMap(turns: Parsed.shared.transcript(latest)?.turns ?? [], duration: latest.duration, height: 4,
                                    colors: Theme.Island.speaker, empty: Color.white.opacity(0.15))
                            Text([RecapStatus.text(latest), Counter.text(latest.duration),
                                  latest.created.formatted(.relative(presentation: .named))].joined(separator: " · "))
                                .font(Theme.sans(11.5)).foregroundStyle(Theme.Island.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Island.text)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
                .accessibilityLabel("Open \(latest.displayTitle), \(RecapStatus.text(latest))")
            }
        }
        .frame(width: NotchBar.openWidth - 44, alignment: .leading)
    }

    private func tile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                Text(title).font(Theme.sans(12.5, .semibold))
            }
            .foregroundStyle(Theme.Island.text)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.Island.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
    }

    // MARK: Open, recording

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(Theme.recording).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording").font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.Island.text)
                    Text(preview != nil ? "Google Meet in Opera GX" : recorder.callName ?? "Recording by hand")
                        .font(Theme.sans(12)).foregroundStyle(Theme.Island.text2).lineLimit(1)
                }
                Spacer()
                clock.font(Theme.mono(26, .medium)).foregroundStyle(Theme.Island.text)
            }
            HStack(spacing: 8) {
                Image(systemName: muted ? "mic.slash" : "mic").font(.system(size: 13, weight: .medium))
                Text(muted ? "You're muted in the call, so your mic is left out." : "Your mic is in. Mute in the call to leave it out.")
                    .font(Theme.sans(12.5))
            }
            .foregroundStyle(Color(hex: 0xC4C4C4))
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Spacer()
                IslandButton(title: "Open Tape") { bar.close(); MainWindow.shared.show() }
                IslandButton(title: "Stop and save", symbol: "stop.fill", prominent: true) { recorder.stop(); bar.close() }
            }
        }
        .frame(width: NotchBar.openWidth - 44, alignment: .leading)
    }
}

/// Your mic's level as five bars, moving with your voice.
private struct LevelBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 0.5 : 0.08)) { context in
            let level = CGFloat(Recorder.meter.level)
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5) { k in
                    let wobble = 0.55 + 0.45 * abs(sin(t * 7 + Double(k) * 1.3))
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.white)
                        .frame(width: 3, height: 3 + 13 * level * CGFloat(reduceMotion ? 1 : wobble) * [0.5, 0.8, 1, 0.7, 0.45][k])
                }
            }
            .frame(height: 18)
        }
    }
}
