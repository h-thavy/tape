import AppKit
import ServiceManagement
import SwiftUI

/// The window's colour scheme: light by default (as in Onword), with dark or the system's as options.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .light }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance") }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

/// Settings the window shows, kept in step with the defaults and the Keychain.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published private(set) var hasKeys = APIKeys.complete
    @Published var askOnCalls = Settings.askOnCalls { didSet { Settings.askOnCalls = askOnCalls } }
    @Published var autoRecord = Settings.autoRecord { didSet { Settings.autoRecord = autoRecord } }
    @Published var autoRecap = Settings.autoRecap { didSet { Settings.autoRecap = autoRecap } }
    @Published var chime = Settings.chime { didSet { Settings.chime = chime } }
    @Published var appearance = Appearance.current {
        didSet {
            Appearance.current = appearance
            NSApp.appearance = appearance.nsAppearance
        }
    }
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            if openAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    func save(_ service: APIKeys.Service, _ key: String?) {
        APIKeys.set(service, key)
        hasKeys = APIKeys.complete
        if hasKeys { Processor.shared.resume() }
        objectWillChange.send()
    }
}

struct SettingsPage: View {
    @ObservedObject private var settings = SettingsModel.shared
    /// Permissions are read when the page appears and when Tape comes back to the front.
    @State private var refresh = 0

    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 26) {
            Text("Settings").font(Theme.display(30)).tracking(-1).accessibilityAddTraits(.isHeader)

            section("Recaps") {
                SettingsCard {
                    KeyRow(service: .gemini, detail: "Listens to the call and writes the transcript, Khmer and English as spoken (Gemini 3.8 Flash).")
                    KeyRow(service: .anthropic, detail: "Writes the recap from the transcript (Claude Opus 5.5).")
                    SettingsRow(title: "Make recaps automatically",
                                detail: "Off: a recording waits until you press Make recap, so credits are only used for the calls you want recapped.",
                                last: true) {
                        Toggle("Make recaps automatically", isOn: $settings.autoRecap).toggleStyle(.switch).labelsHidden()
                    }
                }
                Text("Keys stay in your Mac's Keychain. Recordings are sent to Google and Anthropic only to make their transcript and recap.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Calls") {
                SettingsCard {
                    SettingsRow(title: "Ask to record when a call starts",
                                detail: "Zoom, Teams, Meet and other browser calls, FaceTime, Slack, WhatsApp, Telegram…") {
                        Toggle("Ask to record when a call starts", isOn: $settings.askOnCalls).toggleStyle(.switch).labelsHidden()
                    }
                    SettingsRow(title: "Play a sound when a call starts", detail: "A quiet tap as \"Meeting detected\" appears.") {
                        Toggle("Play a sound when a call starts", isOn: $settings.chime).toggleStyle(.switch).labelsHidden()
                            .disabled(!settings.askOnCalls)
                    }
                    SettingsRow(title: "Record calls without asking", detail: "Starts recording as soon as a call starts.") {
                        Toggle("Record calls without asking", isOn: $settings.autoRecord).toggleStyle(.switch).labelsHidden()
                            .disabled(!settings.askOnCalls)
                    }
                    SettingsRow(title: "Open at login", detail: "So Tape is there when the next call starts.", last: true) {
                        Toggle("Open at login", isOn: $settings.openAtLogin).toggleStyle(.switch).labelsHidden()
                    }
                }
            }

            section("Permissions") {
                SettingsCard {
                    PermissionRow(title: "Microphone", detail: "Your voice.", granted: Permissions.microphone,
                                  pane: "Privacy_Microphone") { Task { _ = await Permissions.requestMicrophone(); refresh += 1 } }
                    PermissionRow(title: "System audio recording", detail: "The other people in the call.",
                                  granted: Permissions.systemAudio ?? true, pane: "Privacy_AudioCapture") {
                        Task { _ = await Permissions.requestSystemAudio(); refresh += 1 }
                    }
                    PermissionRow(title: "Accessibility", detail: "Seeing the call's mute button, so your mic is left out while you're muted.",
                                  granted: Permissions.accessibility, pane: "Privacy_Accessibility", last: true) {
                        Permissions.requestAccessibility()
                    }
                }
                .id(refresh)
            }

            section("Updates") {
                SettingsCard { UpdateRow() }
            }

            section("General") {
                SettingsCard {
                    SettingsRow(title: "Appearance") {
                        Picker("", selection: $settings.appearance) {
                            ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        .accessibilityLabel("Appearance")
                    }
                    SettingsRow(title: "Recordings folder", detail: Recordings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        Button("Open") { NSWorkspace.shared.open(Recordings.folder) }.buttonStyle(.pillQuiet).controlSize(.small)
                    }
                    SettingsRow(title: "Introduction", detail: "How Tape works, and the permissions and keys it needs.", last: true) {
                        Button("Show") { Onboarding.shared.show() }.buttonStyle(.pillQuiet).controlSize(.small)
                    }
                }
            }
          }
          .frame(maxWidth: 720, alignment: .leading)
          .padding(.horizontal, 44).padding(.vertical, 32)
          .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
        .onAppear { UpdateChecker.shared.checkIfStale() }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// This version, and the update button when GitHub has a newer one.
private struct UpdateRow: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        SettingsRow(title: "Tape \(UpdateChecker.currentVersion)", detail: detail, last: true) {
            switch updates.state {
            case .available(let version):
                HStack(spacing: 6) {
                    Button("What's new") { updates.openRelease() }.buttonStyle(.pillQuiet).controlSize(.small)
                    Button("Update to \(version)") { updates.update() }.buttonStyle(.pill).controlSize(.small)
                }
            case .checking, .downloading, .installing, .waiting:
                ProgressView().controlSize(.small)
            default:
                Button("Check for updates") { updates.check() }.buttonStyle(.pillQuiet).controlSize(.small)
            }
        }
    }

    private var detail: String {
        switch updates.state {
        case .unknown: "Checks for updates by itself, and updates in one click."
        case .checking: "Checking…"
        case .upToDate: "Up to date."
        case .available(let version): "Tape \(version) is available. Recordings, keys and settings stay."
        case .waiting(let version): "Updates to \(version) when the recording or recap in progress is done."
        case .downloading(let version, let progress): "Downloading \(version)… \(Int(progress * 100)) %"
        case .installing(let version): "Installing \(version); Tape reopens in a moment."
        case .failed(let message): message
        }
    }
}

/// An API key: shown masked once saved, with Change / Remove; a field and Save while it's being entered.
private struct KeyRow: View {
    let service: APIKeys.Service
    let detail: String
    var last = false
    @ObservedObject private var settings = SettingsModel.shared
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let saved = APIKeys.get(service)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.title).font(Theme.sans(14, .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let saved, !editing {
                    Text("••••" + saved.suffix(4)).font(Theme.mono(13)).foregroundStyle(Theme.ink3)
                        .accessibilityLabel("Saved key ending in \(String(saved.suffix(4)))")
                    Button("Change") { editing = true }.buttonStyle(.pillQuiet).controlSize(.small)
                    Button("Remove") { settings.save(service, nil) }.buttonStyle(.pillQuiet).controlSize(.small)
                }
            }
            if editing || saved == nil {
                HStack(spacing: 8) {
                    SecureField("Paste the key", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(service.title) API key")
                        .onSubmit(save)
                    Button("Save", action: save).buttonStyle(.pill).controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved != nil {
                        Button("Cancel") { editing = false; draft = "" }.buttonStyle(.pillQuiet).controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16) }
        }
    }

    private func save() {
        settings.save(service, draft)
        draft = ""
        editing = false
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let pane: String
    var last = false
    let request: () -> Void

    var body: some View {
        SettingsRow(title: title, detail: detail, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ready)
            } else {
                Button("Allow") {
                    request()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .buttonStyle(.pill).controlSize(.small)
            }
        }
    }
}
