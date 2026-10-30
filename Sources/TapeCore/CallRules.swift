import Foundation

/// Which call platform a call is on, when it can be told.
public enum CallPlatform: String, Sendable {
    case zoom, googleMeet, teams, slack, facetime, webex, discord

    public var title: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .slack: "Slack huddle"
        case .facetime: "FaceTime"
        case .webex: "Webex"
        case .discord: "Discord"
        }
    }
}

/// An app whose use of the microphone means a call.
public struct CallApp: Equatable, Sendable {
    public enum Kind: Sendable { case meetingApp, browser, chat }
    public let name: String
    public let kind: Kind
    /// For meeting apps, the platform it is; browsers and chat apps get theirs from the window title.
    public let platform: CallPlatform?
}

/// Whether you're muted in the call app, read from its controls' accessibility labels.
public enum CallMuteState: Sendable { case muted, unmuted, unknown }

public enum CallRules {
    /// Bundle ID (lower-case) → app. Any of these taking the microphone is a call.
    static let callApps: [String: CallApp] = {
        func app(_ name: String, _ kind: CallApp.Kind, _ platform: CallPlatform? = nil, _ ids: [String]) -> [(String, CallApp)] {
            ids.map { ($0, CallApp(name: name, kind: kind, platform: platform)) }
        }
        let rows: [[(String, CallApp)]] = [
            app("FaceTime", .meetingApp, .facetime, ["com.apple.facetime", "com.apple.avconferenced"]),
            app("Webex", .meetingApp, .webex, ["com.cisco.webexmeetingsapp", "cisco-systems.spark"]),
            app("Dialpad Meetings", .meetingApp, nil, ["com.electron.uberconference"]),
            app("Gather", .meetingApp, nil, ["com.gather.gather"]),
            app("Lark", .meetingApp, nil, ["com.larksuite.larkapp"]),
            app("Microsoft Teams", .meetingApp, .teams, ["com.microsoft.teams", "com.microsoft.teams2", "com.microsoft.teams2.modulehost"]),
            app("VooV Meeting", .meetingApp, nil, ["com.tencent.tencentmeeting"]),
            app("Zoom", .meetingApp, .zoom, ["us.zoom.xos"]),
            app("Arc", .browser, nil, ["company.thebrowser.browser"]),
            app("Dia", .browser, nil, ["company.thebrowser.dia"]),
            app("ChatGPT Atlas", .browser, nil, ["com.openai.atlas"]),
            app("Brave", .browser, nil, ["com.brave.browser"]),
            app("Chrome", .browser, nil, ["com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary",
                                           "com.google.chrome.dev", "org.chromium.chromium"]),
            app("Comet", .browser, nil, ["ai.perplexity.comet"]),
            app("Microsoft Edge", .browser, nil, ["com.microsoft.edgemac"]),
            app("Firefox", .browser, nil, ["org.mozilla.firefox"]),
            app("Opera", .browser, nil, ["com.operasoftware.opera"]),
            app("Opera GX", .browser, nil, ["com.operasoftware.operagx"]),
            app("Safari", .browser, nil, ["com.apple.safari", "com.apple.webkit.gpu"]),
            app("Vivaldi", .browser, nil, ["com.vivaldi.vivaldi"]),
            app("Zen Browser", .browser, nil, ["app.zen-browser.zen"]),
            app("Slack", .chat, nil, ["com.tinyspeck.slackmacgap"]),
            app("Discord", .chat, .discord, ["com.hnc.discord"]),
            app("WhatsApp", .chat, nil, ["net.whatsapp.whatsapp"]),
            app("Telegram", .chat, nil, ["ru.keepcoder.telegram", "org.telegram.desktop"]),
            app("Signal", .chat, nil, ["org.whispersystems.signal-desktop"]),
            app("Skype", .chat, nil, ["com.skype.skype"]),
            app("Aircall", .chat, nil, ["io.aircall.phone", "io.aircall.workspace"]),
            app("Dialpad", .chat, nil, ["com.electron.dialpad"]),
            app("ClickUp", .chat, nil, ["com.clickup.desktop-app"]),
            app("Tuple", .chat, nil, ["app.tuple.app"]),
        ]
        return Dictionary(rows.flatMap { $0 }, uniquingKeysWith: { first, _ in first })
    }()

    /// The call app for a mic holder's bundle ID; helper processes ("….helper", "….helper.renderer") count as
    /// their app.
    public static func callApp(bundleID: String) -> CallApp? {
        var id = bundleID.trimmingCharacters(in: .whitespaces).lowercased()
        if let app = callApps[id] { return app }
        for suffix in [".helper.renderer", ".helper.plugin", ".helper.gpu", ".web.helper", ".helper"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
            return callApps[id]
        }
        return nil
    }

    /// The platform a window title belongs to ("Meet - abc-defg-hij" → Google Meet).
    public static func platform(forWindowTitle title: String, isSlack: Bool = false) -> CallPlatform? {
        let t = title.lowercased()
        if isSlack { return t.contains("huddle") ? .slack : nil }
        if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("meet.google.com") { return .googleMeet }
        if t.contains("microsoft teams") || t.contains("teams.microsoft.com") || t.contains("teams.live.com") { return .teams }
        if t.contains("zoom meeting") || t.contains("app.zoom.us") || t.contains("zoom.us/wc") { return .zoom }
        if t.contains("huddle") && t.contains("slack") { return .slack }
        return nil
    }

    /// The mute state from a call app's labels. Zoom's and Google Meet's own wording comes first; a button that
    /// starts with "Unmute" / "Mute" (Teams) is the fallback, as "Mute" buttons next to other people (Zoom's
    /// participant list) would otherwise mislead.
    public static func muteState(labels: [String]) -> CallMuteState {
        let texts = labels.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        for text in texts {
            if text.contains("currently unmuted") || text == "computer audio unmuted" || text.contains("your microphone is on")
                || text.hasPrefix("turn off microphone") { return .unmuted }
            if text.contains("currently muted") || text == "computer audio muted" || text.contains("your microphone is off")
                || text.hasPrefix("turn on microphone") { return .muted }
        }
        for text in texts {
            if text.hasPrefix("unmute") { return .muted }
            if text == "mute" || text.hasPrefix("mute (") || text.hasPrefix("mute mic") || text.hasPrefix("mute microphone")
                || text.hasPrefix("mute my") { return .unmuted }
        }
        return .unknown
    }
}
