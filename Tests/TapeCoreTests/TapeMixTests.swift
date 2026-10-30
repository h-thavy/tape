import XCTest
@testable import TapeCore

final class TapeMixTests: XCTestCase {
    let rate = 48_000.0

    /// Speech-like: a tone in bursts, on or off every 100 ms at random (each seed its own pattern).
    func voice(seconds: Double, frequency: Double, level: Float, seed: UInt64 = 1) -> [Float] {
        let n = Int(seconds * rate)
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let slots = (0...Int(seconds * 10)).map { _ -> Bool in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (state >> 33) % 2 == 0
        }
        return (0..<n).map { i in
            let t = Double(i) / rate
            return slots[Int(t * 10)] ? level * Float(sin(2 * .pi * frequency * t)) : 0
        }
    }

    func delayed(_ x: [Float], by seconds: Double, gain: Float) -> [Float] {
        let d = Int(seconds * rate)
        return (0..<x.count).map { $0 >= d ? x[$0 - d] * gain : 0 }
    }

    func testMutedMicIsLeftOutButTheCallStays() {
        var mixer = TapeMixer(rate: rate)
        let mic = voice(seconds: 1, frequency: 300, level: 0.2)
        let call = [Float](repeating: 0.1, count: mic.count)
        let out = mixer.mix(mic: mic, left: call, right: call) { _ in true }
        // After the first block's ramp, only the call is left.
        for i in 480..<out.left.count { XCTAssertEqual(out.left[i], 0.1, accuracy: 1e-6) }
    }

    func testCallsEchoInTheMicIsTurnedDown() {
        var mixer = TapeMixer(rate: rate)
        let call = voice(seconds: 4, frequency: 220, level: 0.3)
        // Speakers: the call comes back into the mic 40 ms later, quieter.
        let mic = delayed(call, by: 0.04, gain: 0.2)
        let out = mixer.mix(mic: mic, left: call, right: call) { _ in false }
        // Compare the last two seconds (after learning): what the mic added should be small.
        let tail = (out.left.count / 2)..<out.left.count
        let added = TapeMixer.rms(tail.map { out.left[$0] - call[$0] })
        let echo = TapeMixer.rms(mic[tail])
        XCTAssertLessThan(added, echo * 0.3, "echo should be cut by more than 10 dB")
    }

    func testYouTalkingOverTheCallIsKept() {
        var mixer = TapeMixer(rate: rate)
        let call = voice(seconds: 3, frequency: 220, level: 0.1)
        let you = voice(seconds: 3, frequency: 500, level: 0.1, seed: 7)
        let out = mixer.mix(mic: you, left: call, right: call) { _ in false }
        let tail = (out.left.count / 2)..<out.left.count
        let added = TapeMixer.rms(tail.map { out.left[$0] - call[$0] })
        XCTAssertGreaterThan(added, TapeMixer.rms(you[tail]) * 0.6)
    }

    func testOnSpeakersYouTalkingOverTheEchoIsKept() {
        var mixer = TapeMixer(rate: rate)
        let call = voice(seconds: 6, frequency: 220, level: 0.2)
        let echo = delayed(call, by: 0.03, gain: 0.25)
        // You join in for the last 3 seconds.
        let you = voice(seconds: 6, frequency: 500, level: 0.08, seed: 3).enumerated().map { $0.offset > Int(3 * rate) ? $0.element : 0 }
        let mic = zip(echo, you).map { $0 + $1 }
        let out = mixer.mix(mic: mic, left: call, right: call) { _ in false }
        // Where you speak: your voice comes through.
        let speaking = (Int(3.5 * rate)..<out.left.count).filter { you[$0] != 0 }
        let added = TapeMixer.rms(speaking.map { out.left[$0] - call[$0] })
        XCTAssertGreaterThan(added, TapeMixer.rms(speaking.map { you[$0] }) * 0.6)
        // Before you join: the echo is turned down.
        let before = Int(1.5 * rate)..<Int(3 * rate)
        XCTAssertLessThan(TapeMixer.rms(before.map { out.left[$0] - call[$0] }), TapeMixer.rms(echo[before]) * 0.3)
    }

    func testYourVoiceComingBackThroughTheCallIsTurnedDown() {
        var mixer = TapeMixer(rate: rate)
        // A phone near you is in the same call: your voice comes back through it 460 ms later.
        let you = voice(seconds: 8, frequency: 300, level: 0.1, seed: 11)
        let back = delayed(you, by: 0.46, gain: 1.5)
        let out = mixer.mix(mic: you, left: back, right: back) { _ in false }
        let tail = Int(4 * rate)..<out.left.count
        // What's left of the call in the mix (the mix minus your mic, which passes at about its own level).
        let callIn = TapeMixer.rms(back[tail])
        let callOut = TapeMixer.rms(tail.map { out.left[$0] - you[$0] * 1.5 })
        XCTAssertLessThan(callOut, callIn * 0.5, "your returning voice should be turned down")
    }

    func testWhileMutedYourVoiceFromAnotherDeviceIsKept() {
        var mixer = TapeMixer(rate: rate)
        // Muted on the Mac, talking into a phone in the same call: the Mac's mic hears you live, the call
        // brings you back from the phone 460 ms later. Only the call's copy belongs in the recording.
        let you = voice(seconds: 8, frequency: 300, level: 0.1, seed: 11)
        let back = delayed(you, by: 0.46, gain: 1.5)
        let out = mixer.mix(mic: you, left: back, right: back) { _ in true }
        let tail = Int(2 * rate)..<out.left.count
        for i in tail { XCTAssertEqual(out.left[i], TapeMixer.limit(back[i]), accuracy: 1e-5) }
    }

    func testOtherPeopleAnsweringYouAreKept() {
        var mixer = TapeMixer(rate: rate)
        // A conversation: you and them taking turns (and sometimes overlapping), on headphones.
        let you = voice(seconds: 10, frequency: 300, level: 0.1, seed: 21)
        let them = voice(seconds: 10, frequency: 200, level: 0.15, seed: 22)
        let out = mixer.mix(mic: you, left: them, right: them) { _ in false }
        let speaking = (Int(3 * rate)..<out.left.count).filter { them[$0] != 0 && you[$0] == 0 }
        let kept = TapeMixer.rms(speaking.map { out.left[$0] })
        XCTAssertGreaterThan(kept, TapeMixer.rms(speaking.map { them[$0] }) * 0.9, "the other side must never be turned down")
    }

    func testRoomNoiseIsNotTakenForYourVoice() {
        var mixer = TapeMixer(rate: rate)
        // A steady room hiss at about -44 dB, nobody talking.
        var seed: UInt64 = 42
        let hiss = (0..<Int(4 * rate)).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.022
        }
        let silence = [Float](repeating: 0, count: hiss.count)
        let out = mixer.mix(mic: hiss, left: silence, right: silence) { _ in false }
        let tail = Int(2 * rate)..<hiss.count
        // Turned down, never up.
        XCTAssertLessThan(TapeMixer.rms(out.left[tail]), TapeMixer.rms(hiss[tail]) * 0.5)
    }

    func testYourVoiceInANoisyRoomIsKept() {
        var mixer = TapeMixer(rate: rate)
        var seed: UInt64 = 9
        let you = voice(seconds: 6, frequency: 300, level: 0.05, seed: 5)
        let mic = you.map { v -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return v + (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.022
        }
        let silence = [Float](repeating: 0, count: mic.count)
        let out = mixer.mix(mic: mic, left: silence, right: silence) { _ in false }
        let speaking = (Int(3 * rate)..<mic.count).filter { you[$0] != 0 }
        XCTAssertGreaterThan(TapeMixer.rms(speaking.map { out.left[$0] }), TapeMixer.rms(speaking.map { you[$0] }) * 0.8)
    }

    func testYourVoiceAloneIsKept() {
        var mixer = TapeMixer(rate: rate)
        let you = voice(seconds: 2, frequency: 400, level: 0.05)
        let silence = [Float](repeating: 0, count: you.count)
        let out = mixer.mix(mic: you, left: silence, right: silence) { _ in false }
        XCTAssertGreaterThan(TapeMixer.rms(out.left), TapeMixer.rms(you))
    }

    func testLimiter() {
        XCTAssertEqual(TapeMixer.limit(0.5), 0.5)
        XCTAssertLessThanOrEqual(TapeMixer.limit(3), 1)
        XCTAssertGreaterThanOrEqual(TapeMixer.limit(-3), -1)
    }

    func testMuteTimelineBackdatesAMute() {
        let timeline = MuteTimeline()
        timeline.set(true, from: 10)
        timeline.set(false, from: 20)
        XCTAssertFalse(timeline.isMuted(at: 9))
        XCTAssertTrue(timeline.isMuted(at: 15))
        XCTAssertFalse(timeline.isMuted(at: 21))
        // A mute noticed late, dated back to 18: replaces the later unmute.
        timeline.set(true, from: 18)
        XCTAssertTrue(timeline.isMuted(at: 25))
        timeline.forget(before: 30)
        XCTAssertTrue(timeline.isMuted(at: 31))
    }
}
