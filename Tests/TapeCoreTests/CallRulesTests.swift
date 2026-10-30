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

final class MeetingTitleTests: XCTestCase {
    func testTitlesFromWindows() {
        XCTAssertEqual(CallRules.meetingTitle(fromWindowTitle: "Meet – Weekly sync with Ploy HR - Google Chrome - Work"), "Weekly sync with Ploy HR")
        XCTAssertEqual(CallRules.meetingTitle(fromWindowTitle: "Meet - AI-Powered CV Automation - Opera"), "AI-Powered CV Automation")
        XCTAssertEqual(CallRules.meetingTitle(fromWindowTitle: "Meet - Pricing review - Camera or microphone recording - Google Chrome"), "Pricing review")
        XCTAssertEqual(CallRules.meetingTitle(fromWindowTitle: "Payroll module review | Microsoft Teams"), "Payroll module review")
        XCTAssertEqual(CallRules.meetingTitle(fromWindowTitle: "Bank NOC follow-up (Meeting) | Microsoft Teams"), "Bank NOC follow-up")
    }

    func testNoTitle() {
        XCTAssertNil(CallRules.meetingTitle(fromWindowTitle: "Meet - abc-defg-hij - Opera"))
        XCTAssertNil(CallRules.meetingTitle(fromWindowTitle: "Meet – abc-defg-hij"))
        XCTAssertNil(CallRules.meetingTitle(fromWindowTitle: "Zoom Meeting"))
        XCTAssertNil(CallRules.meetingTitle(fromWindowTitle: "Calendar | Microsoft Teams"))
        XCTAssertNil(CallRules.meetingTitle(fromWindowTitle: "YouTube - Google Chrome"))
        XCTAssertNil(CallRules.meetingTitle(fromWindowTitle: "Meet - Google Chrome"))
    }
}
