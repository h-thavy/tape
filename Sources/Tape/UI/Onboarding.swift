import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

/// The introduction on first launch: what Tape does, each idea with a small animation (the notch asking to
/// record, your mic following the mute button, the transcript turning into a recap), then the permissions and
/// the API keys. It can be shown again from Settings.
@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()

    @Published var step = 0
    private var window: NSWindow?
    static let steps = 7

    static var done: Bool { UserDefaults.standard.bool(forKey: "setUp") }

    func show() {
        step = 0
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Done (or closed): Tape opens, and from now on starts with login.
    func finish() {
        let first = !Self.done
        UserDefaults.standard.set(true, forKey: "setUp")
        window?.orderOut(nil)
        if first {
            try? SMAppService.mainApp.register()
            SettingsModel.shared.openAtLogin = SMAppService.mainApp.status == .enabled
            PermissionPrompt.shared.start()
        }
        MainWindow.shared.show()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Tape"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView())
        window.delegate = WindowCloser.shared
        window.center()
        return window
    }

    /// Closing the window counts as finishing.
    private final class WindowCloser: NSObject, NSWindowDelegate {
        static let shared = WindowCloser()
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { if !Onboarding.done { Onboarding.shared.finish() } }
        }
    }

    /// Debug: every step drawn into a PNG, its animation at a telling moment.
    static func snapshot(to folder: URL) {
        for step in 0..<steps {
            let view = NSHostingView(rootView: OnboardingView(fixedStep: step, fixedPhase: 1))
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 580)
            Snapshot.write(view, to: folder.appendingPathComponent("onboarding-\(step + 1).png"))
        }
        let prompt = NSHostingView(rootView: PermissionPromptView {})
        prompt.frame = NSRect(origin: .zero, size: prompt.fittingSize)
        Snapshot.write(prompt, to: folder.appendingPathComponent("permissions.png"))
    }
}

private struct OnboardingView: View {
    var fixedStep: Int?
    var fixedPhase: Int?
    @ObservedObject private var onboarding = Onboarding.shared
    @ObservedObject private var settings = SettingsModel.shared
    @ObservedObject private var permissions = PermissionStatus.shared

    private var step: Int { fixedStep ?? onboarding.step }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.fill.opacity(0.55)
                scene
            }
            .frame(height: 276)
            .clipped()
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Theme.display(26)).tracking(-0.8).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(text).font(Theme.sans(14.5)).lineSpacing(5).foregroundStyle(Theme.body)
                    .fixedSize(horizontal: false, vertical: true)
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 28)
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 760, height: 580)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .id(step)
        .transition(.opacity)
    }

    @ViewBuilder private var scene: some View {
        switch step {
        case 0: TapeMarkView(size: 120, spinning: fixedPhase == nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        case 1: AskScene(fixedPhase: fixedPhase)
        case 2: MuteScene(fixedPhase: fixedPhase)
        case 3: RecapScene(fixedPhase: fixedPhase.map { _ in 4 })
        case 4: SymbolsScene(symbols: ["mic", "speaker.wave.2", "accessibility"])
        case 5: SymbolsScene(symbols: ["key"])
        default: QuickActionsScene()
        }
    }

    private var title: String {
        ["Tape records your calls", "It asks when a call starts", "Your mic follows your mute button",
         "A recap when you want one", "Three permissions", "Your API keys", "You're set"][step]
    }

    private var text: String {
        [
            "Any call, in any app. The recording is saved the moment the call ends, sounding exactly like the call, and you can turn it into a transcript and a recap. No account: your recordings stay on this Mac.",
            "Zoom, Google Meet, Teams, Slack, WhatsApp… when an app starts a call, Tape asks in the notch. One click records, and it stops by itself when the call ends.",
            "While you're muted in the meeting, your mic is left out of the recording entirely. Unmute to speak and it's recorded again. The others are always recorded.",
            "Import audio or record a call, then press Transcribe + summarize. Gemini writes the Khmer transcript, keeping English terms as spoken, then Claude writes a detailed English recap with topics, decisions and next steps. Both appear in Tape. Only the calls you choose use your credits.",
            "Tape needs your microphone (your voice), system audio recording (the other people), and Accessibility (to see the call's mute button). Nothing leaves your Mac except to make a recap.",
            "Add a Gemini key for transcription and an Anthropic key for recaps. Both stay in your Mac's Keychain. You can also add them later in Settings.",
            "Tape waits in the notch and the menu bar. Hover over the notch any time to record, import a recording or open Tape.",
        ][step]
    }

    @ViewBuilder private var extra: some View {
        if step == 4 {
            PermissionList().padding(.top, 8)
            // Continue waits for all three (snapshots show the step as it first appears).
            if !permissions.all || fixedStep != nil {
                Text(permissions.missing.isEmpty ? "Allow all three to continue."
                     : "Allow \(ListFormatter.localizedString(byJoining: permissions.missing)) to continue.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
            }
        } else if step == 5 {
            VStack(spacing: 8) {
                KeyField(service: .gemini)
                KeyField(service: .anthropic)
            }
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<Onboarding.steps, id: \.self) { k in
                    Capsule().fill(k == step ? Theme.ink : Theme.line).frame(width: k == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(Onboarding.steps)")
            Spacer()
            if step > 0 {
                Button("Back") { go(step - 1) }.buttonStyle(.pillQuiet)
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if step < Onboarding.steps - 1 {
                Button(step == 5 && !settings.hasKeys ? "Later" : "Continue") { go(step + 1) }.buttonStyle(.pill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 4 && !permissions.all)
                    .help(step == 4 && !permissions.all ? "Allow all three permissions first" : "")
            } else {
                Button("Open Tape") { onboarding.finish() }.buttonStyle(.pill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 44).padding(.vertical, 22)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func go(_ step: Int) {
        withAnimation(.easeInOut(duration: 0.2)) { onboarding.step = step }
    }
}

// MARK: - Scenes

/// A scene's animation: counts through `count` phases, `every` seconds each, looping. Fixed in snapshots;
/// slower and without movement between phases under Reduce Motion.
private struct Phases<Content: View>: View {
    let count: Int
    var every: Double = 1.6
    var fixed: Int?
    @ViewBuilder let content: (Int) -> Content
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(fixed ?? phase)
            .task {
                guard fixed == nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(reduceMotion ? every * 1.5 : every))
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.8)) {
                        phase = (phase + 1) % count
                    }
                }
            }
    }
}

/// The top of a screen, with its notch.
private struct ScreenTop<Island: View>: View {
    @ViewBuilder let island: () -> Island

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xC9CCD3))
            HStack {
                Text("Opera GX   File   Edit   View").font(Theme.sans(11, .medium))
                Spacer()
                Text("Thu 10:42").font(Theme.sans(11, .medium))
            }
            .foregroundStyle(Color(hex: 0x1A1A1A))
            .padding(.horizontal, 14).frame(height: 26)
            .background(Color.white.opacity(0.55))
            island()
        }
        .frame(width: 560, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

/// The notch grows into "Meeting detected", Record is pressed, and it shrinks to the live strip.
private struct AskScene: View {
    var fixedPhase: Int?

    var body: some View {
        Phases(count: 4, every: 1.7, fixed: fixedPhase) { phase in
            ScreenTop {
                let open = phase == 1 || phase == 2
                let live = phase == 3
                ZStack(alignment: .top) {
                    if open {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.Island.tile).frame(width: 30, height: 30)
                                .overlay(Image(systemName: "video").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Meeting detected").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.Island.text)
                                Text("Google Meet in Opera GX").font(Theme.sans(11)).foregroundStyle(Theme.Island.text2)
                            }
                            Spacer()
                            Text("Record").font(Theme.sans(11.5, .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Capsule().fill(.white))
                                .scaleEffect(phase == 2 ? 0.9 : 1)
                                .overlay(Circle().fill(.white.opacity(phase == 2 ? 0.35 : 0)).frame(width: 46, height: 46))
                        }
                        .padding(.top, 34).padding(.horizontal, 18).padding(.bottom, 14)
                        .transition(.opacity)
                    } else if live {
                        HStack {
                            HStack(spacing: 5) {
                                Circle().fill(Theme.recording).frame(width: 6, height: 6)
                                Text("0:04").font(Theme.mono(10.5, .medium)).foregroundStyle(.white)
                            }
                            Spacer()
                            Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12).frame(height: 26)
                    }
                }
                .frame(width: open ? 400 : live ? 300 : 160, height: open ? nil : 26, alignment: .top)
                .background(IslandShape(flare: 7, radius: open ? 22 : 10).fill(.black))
            }
        }
    }
}

/// The others are always recorded; your track is recorded only while you're unmuted.
private struct MuteScene: View {
    var fixedPhase: Int?

    var body: some View {
        Phases(count: 2, every: 2.2, fixed: fixedPhase) { phase in
            let muted = phase == 1
            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill").font(.system(size: 13, weight: .semibold))
                    Text(muted ? "Muted in Meet" : "Unmuted in Meet").font(Theme.sans(13, .semibold))
                }
                .foregroundStyle(muted ? Theme.onInk : Theme.ink)
                .padding(.horizontal, 16).frame(height: 36)
                .background(Capsule().fill(muted ? Theme.ink : Theme.raised))
                .overlay(Capsule().strokeBorder(muted ? .clear : Theme.ink, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 10) {
                    track("The others", recorded: true, seed: 1)
                    track("You", recorded: !muted, seed: 2)
                }
                .padding(18)
                .frame(width: 520)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(muted ? "Muted: only the others are recorded" : "Unmuted: you and the others are recorded")
        }
    }

    private func track(_ name: String, recorded: Bool, seed: Double) -> some View {
        HStack(spacing: 12) {
            Text(name).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink2).frame(width: 76, alignment: .leading)
            TimelineView(.animation(minimumInterval: 0.06, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<48, id: \.self) { k in
                        let v = recorded ? 0.25 + 0.75 * abs(sin(t * 3 + Double(k) * 0.55 * seed) * cos(Double(k) * 0.3 + t * seed)) : 0.06
                        Capsule().fill(recorded ? Theme.speaker(Int(seed) - 1) : Theme.line).frame(width: 4, height: 4 + 30 * v)
                    }
                }
                .frame(height: 36)
            }
            Text(recorded ? "Recorded" : "Left out").font(Theme.sans(11.5, .semibold))
                .foregroundStyle(recorded ? Theme.ready : Theme.ink3).frame(width: 64, alignment: .trailing)
        }
    }
}

/// The recording becomes a transcript, line by line, and the transcript a recap.
private struct RecapScene: View {
    var fixedPhase: Int?
    private let lines = [("00:40", "Speaker 1", "យើងនឹងលាក់ contact details របស់ candidate"), ("00:52", "Speaker 2", "OK, so employers see the CV first"),
                         ("01:10", "Speaker 1", "Submit the app now, no new features")]

    var body: some View {
        Phases(count: 5, every: 1.3, fixed: fixedPhase) { phase in
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    label("Transcript", symbol: "text.alignleft")
                    ForEach(0..<3) { k in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(lines[k].0).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.ink2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(lines[k].1).font(Theme.sans(10.5, .semibold)).foregroundStyle(Theme.speaker(k == 1 ? 1 : 0))
                                Text(lines[k].2).font(Theme.sans(12)).foregroundStyle(Theme.body).lineLimit(1)
                            }
                        }
                        .opacity(phase > k ? 1 : 0)
                        .offset(y: phase > k ? 0 : 6)
                    }
                }
                .padding(16).frame(width: 290, height: 190, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink3).padding(.top, 86)
                VStack(alignment: .leading, spacing: 10) {
                    label("Recap", symbol: "doc.text")
                    topic(1, "Candidate app", "Contacts stay hidden until paid.", time: "00:40")
                    topic(2, "App Store", "Submit now; no new features.", time: "01:10")
                }
                .padding(16).frame(width: 220, height: 190, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                .opacity(phase >= 4 ? 1 : 0.25)
            }
            .accessibilityHidden(true)
        }
    }

    private func label(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.ink2)
    }

    private func topic(_ number: Int, _ title: String, _ text: String, time: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.onInk)
                .frame(width: 18, height: 18).background(Circle().fill(Theme.ink))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.sans(12.5, .semibold))
                    Text("▶ \(time)").font(Theme.mono(9.5, .medium)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fill))
                }
                Text(text).font(Theme.sans(11.5)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SymbolsScene: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(Theme.ink)
                    .frame(width: 84, height: 84)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.line))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The notch open on its quick actions.
private struct QuickActionsScene: View {
    var body: some View {
        ScreenTop {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    TapeMarkView(size: 16, ink: .white)
                    Text("Tape").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.Island.text)
                    Text("Listening for calls").font(Theme.sans(11)).foregroundStyle(Theme.Island.text2)
                }
                HStack(spacing: 7) {
                    ForEach([("record.circle", "Record now"), ("square.and.arrow.down", "Import"), ("macwindow", "Open Tape")], id: \.1) { symbol, title in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: symbol).font(.system(size: 14))
                            Text(title).font(Theme.sans(11.5, .semibold))
                        }
                        .foregroundStyle(Theme.Island.text)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.Island.tile))
                    }
                }
            }
            .padding(.top, 34).padding(.horizontal, 18).padding(.bottom, 16)
            .frame(width: 400)
            .background(IslandShape(flare: 7, radius: 22).fill(.black))
        }
    }
}

// MARK: - Permissions and keys

/// Asks for the permissions Tape can't work without: at every launch (after the introduction, which asks
/// the first time) while one is missing, and whenever one is turned off while Tape runs. It closes by itself
/// once everything is allowed.
@MainActor
final class PermissionPrompt {
    static let shared = PermissionPrompt()
    private var window: NSWindow?
    private var timer: Timer?
    /// What was missing when last checked: a new gap (a permission turned off) asks again.
    private var missing: Set<String> = []

    static var current: Set<String> {
        var missing: Set<String> = []
        if !Permissions.microphone { missing.insert("microphone") }
        if Permissions.systemAudio == false { missing.insert("system audio") }
        if !Permissions.accessibility { missing.insert("accessibility") }
        return missing
    }

    func start() {
        guard timer == nil else { return }
        missing = []
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionPrompt.shared.check() }
        }
    }

    private func check() {
        guard Onboarding.done else { return }
        let now = Self.current
        if now.isEmpty {
            window?.orderOut(nil)
        } else if !now.isSubset(of: missing) {
            show()
        }
        missing = now
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Tape needs your permission"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: PermissionPromptView { [weak window] in window?.orderOut(nil) })
        window.center()
        return window
    }
}

private struct PermissionPromptView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.working)
                Text("Tape needs your permission").font(Theme.display(22)).tracking(-0.6).accessibilityAddTraits(.isHeader)
            }
            Text("Without these, Tape can't record the call properly: your microphone (your voice), system audio (the other people), and Accessibility (to leave your mic out while you're muted). Allow each one, then switch Tape on in System Settings.")
                .font(Theme.sans(13.5)).lineSpacing(4).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
            PermissionList().padding(.top, 4)
            HStack {
                Spacer()
                Button("Later", action: close).buttonStyle(.pillQuiet).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 22)
        .frame(width: 760)
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
    }
}

/// The three permissions as they are now, checked every second (they're switched on in System Settings, so
/// there's no notice when they change).
@MainActor
final class PermissionStatus: ObservableObject {
    static let shared = PermissionStatus()
    enum Kind { case microphone, systemAudio, accessibility }

    @Published private(set) var microphone = false
    @Published private(set) var systemAudio = false
    @Published private(set) var accessibility = false
    /// The answer to Tape's own system audio request, for when TCC can't be asked directly.
    private var audioAnswer = false
    private var timer: Timer?

    var all: Bool { microphone && systemAudio && accessibility }
    var missing: [String] {
        [(microphone, "the microphone"), (systemAudio, "system audio"), (accessibility, "Accessibility")].filter { !$0.0 }.map(\.1)
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionStatus.shared.refresh() }
        }
    }

    func refresh() {
        let mic = Permissions.microphone, audio = Permissions.systemAudio ?? audioAnswer, ax = Permissions.accessibility
        if mic != microphone { microphone = mic }
        if audio != systemAudio { systemAudio = audio }
        if ax != accessibility { accessibility = ax }
    }

    /// macOS's own prompt the first time; once it has been answered "Don't Allow", macOS won't ask again, so
    /// the page in System Settings where it's switched on.
    func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Task { _ = await Permissions.requestMicrophone(); refresh() }
            } else {
                Self.openPane("Privacy_Microphone")
            }
        case .systemAudio:
            if Permissions.systemAudio == false {
                Self.openPane("Privacy_AudioCapture")
            } else {
                Task {
                    audioAnswer = await Permissions.requestSystemAudio()
                    refresh()
                    if !systemAudio { Self.openPane("Privacy_AudioCapture") }
                }
            }
        case .accessibility:
            Permissions.requestAccessibility()
            Self.openPane("Privacy_Accessibility")
        }
    }

    private static func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

private struct PermissionList: View {
    @ObservedObject private var status = PermissionStatus.shared

    var body: some View {
        HStack(spacing: 10) {
            item("Microphone", granted: status.microphone) { status.request(.microphone) }
            item("System audio", granted: status.systemAudio) { status.request(.systemAudio) }
            item("Accessibility", granted: status.accessibility) { status.request(.accessibility) }
        }
    }

    private func item(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.sans(13, .medium)).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.ready)
            } else {
                Button("Allow", action: request)
                    .buttonStyle(.pill).controlSize(.small)
                    .accessibilityLabel("Allow \(title)")
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(granted ? Theme.line : Theme.ink3.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

private struct KeyField: View {
    let service: APIKeys.Service
    @ObservedObject private var settings = SettingsModel.shared
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(service.title).font(Theme.sans(13, .medium)).frame(width: 150, alignment: .leading)
            if let saved = APIKeys.get(service) {
                Label("Saved ••••\(saved.suffix(4))", systemImage: "checkmark.circle.fill").font(Theme.sans(12.5, .medium))
                    .foregroundStyle(Theme.ready)
                Spacer()
            } else {
                SecureField("Paste the key", text: $draft).textFieldStyle(.roundedBorder).onSubmit(save)
                    .accessibilityLabel("\(service.title) API key")
                Button("Save", action: save).buttonStyle(.pill).controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .id(settings.hasKeys)
    }

    private func save() {
        settings.save(service, draft)
        draft = ""
    }
}
