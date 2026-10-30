import AppKit
import ApplicationServices
import CoreAudio
import TapeCore
import os

/// Notices calls starting and ending, from Core Audio's list of which apps use the microphone (checked once a
/// second; no accessibility or screen reading needed for this).
/// - A known call app (Zoom, Teams, FaceTime, Webex, any browser, Slack, Discord, WhatsApp…) on the mic is a
///   call at once.
/// - Any other app is a call once it has used the mic and played audio at the same time for 3 seconds
///   (Telegram, Signal, a softphone…). Dictation only listens, so it doesn't count.
/// A call has ended once its app has been off the mic for `endGrace` seconds.
@MainActor
final class CallWatcher {
    static let shared = CallWatcher()
    struct Call: Equatable {
        /// "Zoom", "Google Meet in Chrome", "Telegram".
        let name: String
        let bundleID: String
        let pid: pid_t
    }

    var onStart: ((Call) -> Void)?
    /// The call that ended, and when it was last on the mic (host clock).
    var onEnd: ((Call, Double) -> Void)?
    private(set) var current: Call?
    private var lastSeen = Date.distantPast
    private var lastSeenHost = 0.0
    private var unknownSince: [String: Date] = [:]
    private var timer: Timer?
    static let endGrace: TimeInterval = 4
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "calls")

    /// Apps that listen without it being a call.
    private static let ignored: Set<String> = [
        "io.github.h-thavy.tape", "io.github.h-thavy.onword", "com.apple.corespeech", "com.apple.corespeechd",
        "com.apple.voicememos", "com.apple.quicktimeplayerx",
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        if let found = scan() {
            lastSeen = Date()
            lastSeenHost = HostClock.now
            guard current?.bundleID != found.bundleID else { return }
            if let ended = current { onEnd?(ended, lastSeenHost) }
            let call = Call(name: Self.displayName(found), bundleID: found.bundleID, pid: found.pid)
            current = call
            log.notice("Call started: \(call.name, privacy: .public) (\(call.bundleID, privacy: .public))")
            onStart?(call)
        } else if let ended = current, Date().timeIntervalSince(lastSeen) > Self.endGrace {
            current = nil
            log.notice("Call ended: \(ended.name, privacy: .public)")
            onEnd?(ended, lastSeenHost)
        }
    }

    private struct Found {
        let bundleID: String
        let pid: pid_t
        let app: CallApp?
    }

    private func scan() -> Found? {
        let apps = AudioProcesses.current()
        // Known call apps on the mic first.
        for app in apps where app.input {
            if let known = CallRules.callApp(bundleID: app.bundleID) { return Found(bundleID: app.bundleID, pid: app.pid, app: known) }
        }
        // The app already being followed keeps counting while it's on the mic.
        if let current, apps.contains(where: { $0.bundleID == current.bundleID && $0.input }) {
            return Found(bundleID: current.bundleID, pid: current.pid, app: nil)
        }
        let now = Date()
        let talking = apps.filter { $0.input && $0.output && !Self.ignored.contains($0.bundleID.lowercased()) }
        unknownSince = unknownSince.filter { id, _ in talking.contains { $0.bundleID == id } }
        for app in talking {
            let since = unknownSince[app.bundleID] ?? now
            unknownSince[app.bundleID] = since
            if now.timeIntervalSince(since) >= 3 { return Found(bundleID: app.bundleID, pid: app.pid, app: nil) }
        }
        return nil
    }

    /// The meeting platform when it can be told (a meeting app, or a browser window titled like a call), else
    /// the app's name.
    private static func displayName(_ found: Found) -> String {
        let appName = found.app?.name
            ?? NSRunningApplication(processIdentifier: found.pid)?.localizedName ?? found.bundleID
        if let platform = found.app?.platform { return platform.title }
        guard AXIsProcessTrusted() else { return appName }
        let titles = AXAllWindows.windows(pid: found.pid).compactMap { AXAllWindows.attribute($0, kAXTitleAttribute) }
        let isSlack = found.bundleID.lowercased() == "com.tinyspeck.slackmacgap"
        if let platform = titles.lazy.compactMap({ CallRules.platform(forWindowTitle: $0, isSlack: isSlack) }).first {
            return found.app?.kind == .browser ? "\(platform.title) in \(appName)" : platform.title
        }
        return appName
    }
}

/// Which apps are using the microphone or playing audio right now, from Core Audio's process list
/// (macOS 14+). Helper processes count as the app they belong to (Chrome's audio service → Chrome).
enum AudioProcesses {
    struct App {
        let pid: pid_t
        let bundleID: String
        var input: Bool
        var output: Bool
    }

    static func current() -> [App] {
        var address = CoreAudioLookup.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        let ownPID = getpid()
        var apps: [String: App] = [:]
        for object in objects {
            let input = CoreAudioLookup.uint32(object, kAudioProcessPropertyIsRunningInput) == 1
            let output = CoreAudioLookup.uint32(object, kAudioProcessPropertyIsRunningOutput) == 1
            guard input || output else { continue }
            let pid = pid_t(bitPattern: CoreAudioLookup.uint32(object, kAudioProcessPropertyPID) ?? 0)
            guard pid > 0, pid != ownPID, let owner = owner(of: pid, object: object) else { continue }
            var app = apps[owner.bundleID] ?? App(pid: owner.pid, bundleID: owner.bundleID, input: false, output: false)
            app.input = app.input || input
            app.output = app.output || output
            apps[owner.bundleID] = app
        }
        return Array(apps.values)
    }

    /// The app a process belongs to: itself, the app whose bundle contains it, or the app macOS holds
    /// responsible for it (Safari for its WebKit processes).
    private static func owner(of pid: pid_t, object: AudioObjectID) -> (pid: pid_t, bundleID: String)? {
        let app = NSRunningApplication(processIdentifier: pid)
        let rawID = app?.bundleIdentifier ?? CoreAudioLookup.string(object, kAudioProcessPropertyBundleID) ?? ""
        if app?.activationPolicy != .regular, let owner = containingApp(for: pid) ?? responsibleApp(for: pid), owner.pid != pid {
            return owner
        }
        guard !rawID.isEmpty else { return nil }
        let bundleID = owningAppBundleID(rawID)
        if bundleID != rawID, let parent = parentPID(of: pid),
           NSRunningApplication(processIdentifier: parent)?.bundleIdentifier == bundleID {
            return (parent, bundleID)
        }
        return (pid, bundleID)
    }

    private static func containingApp(for pid: pid_t) -> (pid: pid_t, bundleID: String)? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        var current = pid
        for _ in 0..<6 {
            guard let parent = parentPID(of: current) else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular,
               let id = app.bundleIdentifier, let bundle = app.bundleURL?.path, path.hasPrefix(bundle + "/") {
                return (parent, id)
            }
            current = parent
        }
        return nil
    }

    private static func responsibleApp(for pid: pid_t) -> (pid: pid_t, bundleID: String)? {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let owner = unsafeBitCast(symbol, to: Responsible.self)(pid)
        guard owner > 0, let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular,
              let id = app.bundleIdentifier else { return nil }
        return (owner, id)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// "com.google.Chrome.helper" → "com.google.Chrome".
    private static func owningAppBundleID(_ id: String) -> String {
        for suffix in [".helper.renderer", ".helper.plugin", ".helper", ".framework.AlertNotificationService"] where id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return id
    }
}
