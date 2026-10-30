import AppKit
import TapeCore
import os

/// The icon of the platform a call is on, for "Meeting detected": the call app's own icon (Zoom, Teams,
/// Slack, FaceTime, WhatsApp…); for a call in a browser, the platform's desktop app's icon when it's
/// installed, else the platform's web icon (fetched once and kept). Nil when the platform can't be told.
@MainActor
enum PlatformIcons {
    /// Each platform's desktop app, and the site its web icon comes from.
    private static let platforms: [CallPlatform: (apps: [String], site: String)] = [
        .teams: (["com.microsoft.teams2", "com.microsoft.teams"], "teams.microsoft.com"),
        .zoom: (["us.zoom.xos"], "zoom.us"),
        .googleMeet: ([], "meet.google.com"),
        .slack: (["com.tinyspeck.slackmacgap"], "app.slack.com"),
        .webex: (["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"], "webex.com"),
        .discord: (["com.hnc.Discord"], "discord.com"),
        .facetime: (["com.apple.FaceTime"], "apple.com"),
    ]
    nonisolated private static let log = Logger(subsystem: "io.github.h-thavy.tape", category: "icons")
    private static var folder: URL { Recordings.inProgress.deletingLastPathComponent().appendingPathComponent("Icons") }

    static func icon(for call: CallWatcher.Call) -> NSImage? {
        if !call.inBrowser, let app = NSRunningApplication(processIdentifier: call.pid), let icon = app.icon { return icon }
        guard let platform = call.platform, let entry = platforms[platform] else { return nil }
        for id in entry.apps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        }
        return NSImage(contentsOf: folder.appendingPathComponent(platform.rawValue + ".png"))
    }

    /// Fetches the web icons not kept yet (in the background at launch), so they're there when a call
    /// starts. Only the platforms' domains are sent.
    static func prefetch() {
        let missing = platforms.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.key.rawValue + ".png").path) }
        guard !missing.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder
        Task.detached(priority: .background) {
            for (platform, entry) in missing {
                guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(entry.site)&sz=128"),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: data) != nil else { continue }
                try? data.write(to: folder.appendingPathComponent(platform.rawValue + ".png"))
            }
            log.notice("Fetched platform icons")
        }
    }
}
