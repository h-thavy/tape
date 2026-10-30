import ApplicationServices
import TapeCore
import os

/// Follows whether you're muted in the call app, from its mute button's accessibility label (Zoom's audio
/// button, Google Meet's "Turn on microphone", Teams' Mute/Unmute). It runs from the moment a call is noticed,
/// so the state is known before recording starts. A browser shows only the visible tab to accessibility: while
/// the call's tab is in the background the last state seen stays.
///
/// Cheap enough to run four times a second: the app's controls are searched once to find the button, and from
/// then on only that one element is read. If it goes away (the call's window changed) it's searched for again,
/// at most once a second.
///
/// Privacy comes first: a mute counts from the last moment you were seen unmuted (you may have muted right
/// after it), an unmute only from when it's seen. Since audio is written `TapeWriter.delay` seconds late, the
/// back-dated mute still keeps your voice out.
final class MuteWatcher {
    let pid: pid_t
    private let queue = DispatchQueue(label: "tape.mute", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var button: AXUIElement?
    private var lastSearch = 0.0
    private var lastSeen = HostClock.now
    private var muted = false
    private var found = false
    private var lastMissLog = 0.0
    /// On the main queue: muted or not, from when (host clock).
    var onChange: ((Bool, Double) -> Void)?
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "mute")

    init(pid: pid_t) {
        self.pid = pid
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = HostClock.now
        var state = CallMuteState.unknown
        if let button {
            state = Self.state(of: button)
            if state == .unknown { self.button = nil }
        }
        if state == .unknown, now - lastSearch >= 1 {
            lastSearch = now
            (state, button) = search()
            if button != nil, !found {
                found = true
                log.notice("Found the call's mute button (\(state == .muted ? "muted" : "unmuted", privacy: .public))")
            } else if button == nil, now - lastMissLog > 30 {
                lastMissLog = now
                log.notice("Can't find the call's mute button yet")
            }
        }
        // Unknown (the call's window can't be read right now): the last state stays.
        guard state != .unknown else { return }
        let isMuted = state == .muted
        if isMuted != muted {
            muted = isMuted
            let from = isMuted ? lastSeen : now
            log.notice("\(isMuted ? "Muted: leaving your mic out" : "Unmuted: recording your mic", privacy: .public)")
            DispatchQueue.main.async { self.onChange?(isMuted, from) }
        }
        lastSeen = now
    }

    private static func state(of element: AXUIElement) -> CallMuteState {
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap {
            AXAllWindows.attribute(element, $0)
        }
        return labels.isEmpty ? .unknown : CallRules.muteState(labels: labels)
    }

    /// Searches the call's windows (every Space, the call's own window first) for the mute button. The call
    /// app's own wording wins; a plain "Mute"/"Unmute" button is the fallback.
    private func search() -> (CallMuteState, AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chrome and Electron apps (Teams, Slack, Discord) expose their pages to accessibility only when asked.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let all = AXAllWindows.windows(pid: pid)
        func isCall(_ window: AXUIElement) -> Bool {
            AXAllWindows.attribute(window, kAXTitleAttribute).flatMap { CallRules.platform(forWindowTitle: $0) } != nil
        }
        let windows = all.filter(isCall) + all.filter { !isCall($0) }
        guard !windows.isEmpty else { return (.unknown, nil) }
        // In a browser only the call's page matters, not the tab strip.
        let pages = windows.prefix(3).compactMap { AXAllWindows.webArea(in: $0) }
        var queue = (pages.isEmpty ? windows : pages).map { ($0, 0) }
        var fallback: (CallMuteState, AXUIElement)?
        let deadline = Date().addingTimeInterval(0.75)
        var visited = 0
        while !queue.isEmpty, Date() < deadline, visited < 8000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
                guard let text = AXAllWindows.attribute(element, attribute), !text.isEmpty, text.count < 120 else { continue }
                if ProcessInfo.processInfo.environment["TAPE_DEBUG_AX"] != nil,
                   ["micro", "mute", "mic "].contains(where: text.lowercased().contains) { debugLabels.append(text) }
                let state = CallRules.muteState(labels: [text])
                guard state != .unknown else { continue }
                let lower = text.lowercased()
                if lower.hasPrefix("mute") || lower.hasPrefix("unmute") {
                    if fallback == nil { fallback = (state, element) }
                } else {
                    return (state, element)
                }
            }
            guard depth < 45 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                queue.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        if ProcessInfo.processInfo.environment["TAPE_DEBUG_AX"] != nil {
            let titles = windows.compactMap { AXAllWindows.attribute($0, kAXTitleAttribute) }
            log.notice("Mute search: \(windows.count) windows \(titles.prefix(4).joined(separator: " | "), privacy: .public); \(pages.count) pages; \(visited) elements; mic labels: \(self.debugLabels.prefix(12).joined(separator: " | "), privacy: .public)")
            debugLabels = []
        }
        return fallback.map { ($0.0, $0.1) } ?? (.unknown, nil)
    }

    private var debugLabels: [String] = []
}
