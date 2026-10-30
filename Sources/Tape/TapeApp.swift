import AVFoundation
import AppKit
import ServiceManagement
import os

/// Tape records your calls and turns each one into a recap. When an app starts a call it asks whether to
/// record it; the recording stops when the call ends, is in ~/Documents/Tape a moment later, and Gemini
/// (the transcript) and Claude (the recap) take it from there. No account, no sign-in: your own API keys.
@main
enum TapeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

enum Settings {
    /// Ask "Record this call?" when a call starts.
    static var askOnCalls: Bool {
        get { UserDefaults.standard.object(forKey: "askOnCalls") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "askOnCalls") }
    }
    /// Start recording without asking.
    static var autoRecord: Bool {
        get { UserDefaults.standard.bool(forKey: "autoRecord") }
        set { UserDefaults.standard.set(newValue, forKey: "autoRecord") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let watcher = CallWatcher.shared
    private let recorder = Recorder.shared
    private var clock: Timer?
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = Appearance.current.nsAppearance
        NSApp.mainMenu = Self.mainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        recorder.onChange = { [weak self] in self?.refresh() }
        refresh()

        watcher.onStart = { [weak self] call in self?.callStarted(call) }
        watcher.onEnd = { [weak self] call, lastSeen in self?.callEnded(call, lastSeen: lastSeen) }

        Recordings.prepareFolders()
        Library.shared.load()
        Task {
            // Recordings a crash left behind are saved before anything new is recorded into that folder.
            for url in await Recordings.recoverUnfinished() {
                log.notice("Recovered \(url.lastPathComponent, privacy: .public)")
                _ = Library.shared.add(audio: url, app: nil, duration: 0)
            }
            Library.shared.load()

            // Test hook: TAPE_TEST_IMPORT=<file>[,<file>…] imports those files (without making recaps) and quits.
            if let paths = ProcessInfo.processInfo.environment["TAPE_TEST_IMPORT"] {
                let added = await Library.shared.importFiles(paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
                log.notice("Test import: \(added.map { "\($0.audioFile) (\(Int($0.duration)) s)" }.joined(separator: ", "), privacy: .public)")
                NSApp.terminate(nil)
                return
            }

            // Test hook: TAPE_TEST_RECORD=<seconds> records for that long (the call going on, if there is one,
            // with its mute button followed), saves, and quits.
            if let seconds = ProcessInfo.processInfo.environment["TAPE_TEST_RECORD"].flatMap(Double.init) {
                watcher.start()
                try? await Task.sleep(for: .seconds(1.5))
                recorder.start(call: watcher.current, followsCall: false)
                try? await Task.sleep(for: .seconds(seconds))
                recorder.stop()
                while recorder.saving > 0 { try? await Task.sleep(for: .milliseconds(50)) }
                NSApp.terminate(nil)
                return
            }

            MainWindow.shared.show()
            MainWindow.shared.snapshotIfAsked()
            await firstLaunch()
            watcher.start()
            Processor.shared.resume()
            UpdateChecker.shared.start()
        }
    }

    /// The app's menu bar. The Edit menu is what makes ⌘V, ⌘C, ⌘X and ⌘A work in text fields (pasting an API
    /// key): macOS sends those shortcuts through it.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let settings = item("Settings…", #selector(AppDelegate.openSettings), ",")
        submenu("Tape", [
            item("About Tape", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(), settings, .separator(),
            item("Hide Tape", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Tape", #selector(AppDelegate.quit), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    @objc func openSettings() { MainWindow.shared.show(page: .settings) }

    /// Clicking the Dock icon with the window closed opens it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.shared.show() }
        return true
    }

    /// Closing the window keeps Tape listening for calls.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // The .aac is complete up to here; it becomes an .m4a on the next launch.
        if recorder.isRecording { log.notice("Quit while recording") }
    }

    /// Asks for what Tape needs up front, so no prompt appears in the middle of a call: on the first launch,
    /// and again whenever a permission hasn't been decided yet (after an update signed differently, macOS
    /// treats Tape as new).
    private func firstLaunch() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await Permissions.requestMicrophone() }
        if Permissions.systemAudio == nil { _ = await Permissions.requestSystemAudio() }
        guard !UserDefaults.standard.bool(forKey: "setUp") else { return }
        UserDefaults.standard.set(true, forKey: "setUp")
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        try? SMAppService.mainApp.register()
        SettingsModel.shared.openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Calls

    private func callStarted(_ call: CallWatcher.Call) {
        recorder.follow(call)
        if recorder.isRecording { return }
        guard Settings.askOnCalls else { return }
        if Settings.autoRecord {
            recorder.start(call: call, followsCall: true)
            return
        }
        // As in Onword: "Meeting detected", what it is, and one button.
        Toast.shared.show(.init(
            id: "call", symbol: "video", title: "Meeting detected", message: "\(call.name) · Now",
            primary: .init(title: "Record", symbol: "waveform") { [weak self] in
                guard let self, !self.recorder.isRecording else { return }
                self.recorder.start(call: self.watcher.current ?? call, followsCall: true)
            },
            timeout: 30))
    }

    private func callEnded(_ call: CallWatcher.Call, lastSeen: Double) {
        Toast.shared.dismiss("call")
        guard recorder.isRecording, recorder.followsCall else {
            recorder.unfollow()
            return
        }
        // End the recording where the call left the mic (plus a second for the goodbyes still playing).
        recorder.stop(endingAt: lastSeen + 1)
        recorder.unfollow()
    }

    // MARK: - Menu bar

    private func refresh() {
        guard let button = item.button else { return }
        if recorder.isRecording {
            button.image = TapeMark.menuBarImage(recording: true, muted: recorder.isMuted)
            button.imagePosition = .imageLeading
            updateClock()
            if clock == nil {
                clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateClock() }
                }
            }
        } else {
            clock?.invalidate()
            clock = nil
            button.image = TapeMark.menuBarImage()
            button.title = recorder.saving > 0 ? " Saving…" : ""
        }
    }

    private func updateClock() {
        guard let started = recorder.startedAt else { return }
        let s = Int(Date().timeIntervalSince(started))
        let time = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        item.button?.attributedTitle = NSAttributedString(string: " " + time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Tape", action: #selector(openWindow), keyEquivalent: "")
        if let version = UpdateChecker.shared.availableVersion {
            menu.addItem(withTitle: "Update to Tape \(version)…", action: #selector(update), keyEquivalent: "")
        }
        menu.addItem(.separator())
        if recorder.isRecording {
            menu.addItem(withTitle: "Stop and save", action: #selector(toggleRecording), keyEquivalent: "")
            if let name = recorder.callName { menu.addItem(disabled("Recording \(name)")) }
            if recorder.isMuted { menu.addItem(disabled("Muted in the call: your mic isn't recorded")) }
        } else {
            menu.addItem(withTitle: "Start recording", action: #selector(toggleRecording), keyEquivalent: "")
            if recorder.saving > 0 { menu.addItem(disabled("Saving…")) }
        }
        menu.addItem(.separator())
        menu.addItem(toggle("Ask to record when a call starts", Settings.askOnCalls, #selector(toggleAsk)))
        menu.addItem(toggle("Record calls without asking", Settings.autoRecord, #selector(toggleAuto)))
        menu.addItem(toggle("Open at login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(.separator())
        if !Permissions.microphone {
            menu.addItem(withTitle: "Allow microphone access…", action: #selector(openMicrophoneSettings), keyEquivalent: "")
        }
        if Permissions.systemAudio == false {
            menu.addItem(withTitle: "Allow system audio recording…", action: #selector(openSystemAudioSettings), keyEquivalent: "")
        }
        if !Permissions.accessibility {
            menu.addItem(withTitle: "Allow Accessibility (to skip your mic while muted)…", action: #selector(openAccessibility), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Open recordings folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tape", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleRecording() {
        if recorder.isRecording { recorder.stop() } else { recorder.start(call: watcher.current, followsCall: watcher.current != nil) }
    }

    @objc private func openWindow() { MainWindow.shared.show() }
    @objc private func update() { UpdateChecker.shared.update() }
    @objc private func toggleAsk() { SettingsModel.shared.askOnCalls.toggle() }
    @objc private func toggleAuto() { SettingsModel.shared.autoRecord.toggle() }
    @objc private func toggleLogin() { SettingsModel.shared.openAtLogin.toggle() }

    @objc private func openMicrophoneSettings() { openPrivacy("Privacy_Microphone") }
    @objc private func openSystemAudioSettings() { openPrivacy("Privacy_AudioCapture") }
    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        openPrivacy("Privacy_Accessibility")
    }

    private func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    @objc private func openFolder() {
        Recordings.prepareFolders()
        NSWorkspace.shared.open(Recordings.folder)
    }

    @objc fileprivate func quit() {
        if recorder.isRecording {
            recorder.stop()
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.recorder.saving == 0 { NSApp.terminate(nil) } }
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}
