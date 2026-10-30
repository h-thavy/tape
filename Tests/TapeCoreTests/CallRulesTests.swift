import XCTest
@testable import TapeCore

final class CallRulesTests: XCTestCase {
    func testCallApps() {
        XCTAssertEqual(CallRules.callApp(bundleID: "us.zoom.xos")?.platform, .zoom)
        XCTAssertEqual(CallRules.callApp(bundleID: "com.google.Chrome.helper.renderer")?.name, "Chrome")
        XCTAssertEqual(CallRules.callApp(bundleID: "ru.keepcoder.Telegram")?.name, "Telegram")
        XCTAssertNil(CallRules.callApp(bundleID: "com.apple.QuickTimePlayerX"))
    }

    func testWindowTitles() {
        XCTAssertEqual(CallRules.platform(forWindowTitle: "Meet - abc-defg-hij"), .googleMeet)
        XCTAssertEqual(CallRules.platform(forWindowTitle: "Weekly sync | Microsoft Teams"), .teams)
        XCTAssertNil(CallRules.platform(forWindowTitle: "general - Acme - Slack", isSlack: true))
        XCTAssertEqual(CallRules.platform(forWindowTitle: "Huddle: #design", isSlack: true), .slack)
    }

    func testMuteLabels() {
        XCTAssertEqual(CallRules.muteState(labels: ["Turn on microphone (⌘ + d)"]), .muted)
        XCTAssertEqual(CallRules.muteState(labels: ["Turn off microphone (⌘ + d)"]), .unmuted)
        XCTAssertEqual(CallRules.muteState(labels: ["Mute my audio, currently unmuted"]), .unmuted)
        XCTAssertEqual(CallRules.muteState(labels: ["Unmute"]), .muted)
        // Zoom's own wording wins over a participant's "Mute" button.
        XCTAssertEqual(CallRules.muteState(labels: ["Mute", "audio, currently muted"]), .muted)
        XCTAssertEqual(CallRules.muteState(labels: ["Share screen"]), .unknown)
    }
}
