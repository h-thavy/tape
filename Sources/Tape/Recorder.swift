import AppKit
import TapeCore
import os

/// Records one call at a time: starts the capture and the writer, leaves your microphone out exactly while
/// you're muted in the call app, and on stop closes the file, moves it into the recordings folder and hands
/// it on for its transcript and recap.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    private struct Session {
        let capture: AnyObject
        let writer: TapeWriter
        let timeline: MuteTimeline
        let startedAt: Date
        let call: CallWatcher.Call?
    }

    private var session: Session?
    /// Started for a detected call, so it stops when the call ends.
    private(set) var followsCall = false
    /// Muted in the call app (as last seen).
    private(set) var isMuted = false
    /// The call app's mute button being followed (from when the call was noticed).
    private var muteWatcher: MuteWatcher?
    private var warnedAccessibility = false
    /// Recordings being closed and moved (shown as "Saving…").
    private(set) var saving = 0
    var onChange: (() -> Void)?
    var isRecording: Bool { session != nil }
    var startedAt: Date? { session?.startedAt }
    var callName: String? { session?.call?.name }
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "recorder")

    func start(call: CallWatcher.Call?, followsCall: Bool) {
        guard session == nil else { return }
        guard #available(macOS 14.2, *) else {
            Toast.shared.show(.init(id: "error", symbol: "exclamationmark.triangle", title: "Tape needs macOS 14.2 or later",
                                    message: "Recording other apps' audio arrived in macOS 14.2."))
            return
        }
        Recordings.prepareFolders()
        let stem = Recordings.name(at: Date(), app: call?.name)
        let url = Recordings.inProgress.appendingPathComponent(stem).appendingPathExtension("aac")
        let timeline = MuteTimeline()
        do {
            let writer = try TapeWriter(url: url, mute: timeline)
            let capture = CallCapture()
            capture.onCall = { writer.appendCall($0) }
            capture.onMic = { writer.appendMic($0) }
            try capture.start()
            session = Session(capture: capture, writer: writer, timeline: timeline, startedAt: Date(), call: call)
            self.followsCall = followsCall
            if let call { follow(call) }
            // Already muted when the recording starts: from its very beginning.
            if isMuted { timeline.set(true, from: 0) }
            log.notice("Recording started (\(call?.name ?? "by hand", privacy: .public)); microphone \(Permissions.microphone ? "allowed" : "not allowed", privacy: .public), system audio \(Permissions.systemAudio.map { $0 ? "allowed" : "not allowed" } ?? "unknown", privacy: .public), accessibility \(Permissions.accessibility ? "allowed" : "not allowed", privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: url)
            log.error("Couldn't start recording: \(error.localizedDescription, privacy: .public)")
            Toast.shared.show(.init(id: "error", symbol: "exclamationmark.triangle", title: "Couldn't start recording",
                                    message: error.localizedDescription))
        }
        changed()
    }

    /// Starts following a call's mute button (when the call is noticed, so its state is known by the time
    /// recording starts).
    func follow(_ call: CallWatcher.Call) {
        guard muteWatcher?.pid != call.pid else { return }
        unfollow()
        guard Permissions.accessibility else {
            log.error("Can't follow your mute button in \(call.name, privacy: .public): Accessibility isn't allowed for Tape")
            guard !warnedAccessibility else { return }
            warnedAccessibility = true
            Toast.shared.show(.init(
                id: "accessibility", symbol: "mic.slash", title: "Tape can't see when you're muted",
                message: "Allow Tape in Accessibility, or your voice is recorded even while you're muted.",
                primary: .init(title: "Open Settings") {
                    Permissions.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                },
                timeout: 15))
            return
        }
        log.notice("Following your mute button in \(call.name, privacy: .public)")
        let watcher = MuteWatcher(pid: call.pid)
        watcher.onChange = { [weak self] muted, from in self?.mutedInCallChanged(muted, from: from) }
        watcher.start()
        muteWatcher = watcher
        isMuted = false
    }

    /// The call is over (and not being recorded).
    func unfollow() {
        guard !isRecording else { return }
        muteWatcher?.stop()
        muteWatcher = nil
        isMuted = false
    }

    private func mutedInCallChanged(_ muted: Bool, from: Double) {
        guard muted != isMuted else { return }
        isMuted = muted
        session?.timeline.set(muted, from: from)
        changed()
    }

    private func changed() {
        objectWillChange.send()
        onChange?()
    }

    /// Stops and saves. `end` (host clock) trims the recording to when the call ended.
    func stop(endingAt end: Double? = nil) {
        guard let session else { return }
        self.session = nil
        followsCall = false
        if #available(macOS 14.2, *) { (session.capture as? CallCapture)?.stop() }
        saving += 1
        changed()
        let writer = session.writer
        let name = session.call?.name
        writer.finish(endingAt: end) { seconds in
            Task { @MainActor in
                guard seconds >= 0.5 else {
                    try? FileManager.default.removeItem(at: writer.url)
                    self.saving -= 1
                    self.changed()
                    self.log.error("No audio arrived; nothing saved")
                    Toast.shared.show(.init(id: "saved", symbol: "exclamationmark.triangle", title: "Nothing was recorded",
                                            message: "No audio reached Tape. Check its microphone and system audio permissions."))
                    return
                }
                let saved = await Recordings.publish(writer.url)
                self.saving -= 1
                self.changed()
                self.log.notice("Recording stopped after \(Int(seconds)) s")
                guard let saved else {
                    Toast.shared.show(.init(id: "saved", symbol: "exclamationmark.triangle", title: "Couldn't save the recording",
                                            message: "It's still in \(Recordings.inProgress.path)."))
                    return
                }
                // Into the library, and on to its transcript and recap.
                let item = Library.shared.add(audio: saved, app: name, duration: seconds)
                Processor.shared.process(item.id)
                // Saved: ask whether to give it a name (it's used for its files and in the recap).
                Toast.shared.show(.init(
                    id: "saved", symbol: "checkmark", title: "Recording saved. Name it?",
                    message: ([name, Self.duration(seconds)].compactMap { $0 } + [APIKeys.complete ? "Making the recap…" : "Add API keys for a recap"])
                        .joined(separator: " · "),
                    primary: .init(title: "Name it", symbol: "pencil") {
                        MainWindow.shared.show(recording: Library.shared.item(item.id)?.id ?? item.id, rename: true)
                    },
                    secondary: .init(title: "Not now") {},
                    timeout: 20))
            }
        }
    }

    nonisolated static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}
