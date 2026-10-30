import XCTest
@testable import TapeCore

final class MicLineTests: XCTestCase {
    func sine(_ n: Int, rate: Double, frequency: Double = 440, start: Int = 0) -> [Float] {
        (0..<n).map { Float(0.5 * sin(2 * .pi * frequency * Double(start + $0) / rate)) }
    }

    /// Largest sample-to-sample jump (a click shows up as a big one).
    func biggestJump(_ x: [Float]) -> Float {
        zip(x.dropFirst(), x).map { abs($0 - $1) }.max() ?? 0
    }

    func testSameRateIsCopiedAsIs() {
        var line = MicLine(rate: 48_000)
        let x = sine(48_000, rate: 48_000)
        for start in stride(from: 0, to: x.count, by: 512) {
            line.place(Array(x[start..<min(x.count, start + 512)]), rate: 48_000, at: Double(start), source: 0)
        }
        let out = line.read(47_000).samples
        for i in 1_000..<47_000 { XCTAssertEqual(out[i], x[i], accuracy: 1e-4) }
    }

    func testBluetoothRateIsConvertedSmoothly() {
        var line = MicLine(rate: 48_000)
        // A headset in call mode: 24 kHz, in 240-frame buffers.
        let x = sine(24_000, rate: 24_000)
        for start in stride(from: 0, to: x.count, by: 240) {
            line.place(Array(x[start..<start + 240]), rate: 24_000, at: Double(start * 2), source: 0)
        }
        let out = Array(line.read(47_000).samples[100..<46_000])
        // A 440 Hz sine at 48 kHz changes at most 2π·440/48000·0.5 ≈ 0.029 per sample.
        XCTAssertLessThan(biggestJump(out), 0.035)
        XCTAssertEqual(TapeMixer.rms(out), Float(0.5 / 2.0.squareRoot()), accuracy: 0.01)
    }

    func testDriftIsAbsorbedWithoutJumps() {
        var line = MicLine(rate: 48_000)
        // The mic's clock runs 0.05 % fast: its buffers are placed slightly earlier each time.
        let x = sine(48_000 * 10, rate: 48_000)
        for start in stride(from: 0, to: x.count - 512, by: 512) {
            line.place(Array(x[start..<start + 512]), rate: 48_000, at: Double(start) * 0.9995, source: 0)
        }
        let out = line.read(48_000 * 9).samples
        XCTAssertLessThan(biggestJump(Array(out[100...])), 0.035, "drift is stretched out, not jumped over")
    }

    func testSwitchingMicrophonesCrossFadesWithoutAClick() {
        var line = MicLine(rate: 48_000)
        // The Mac's mic (a loud tone) until 0.5 s; AirPods (a quiet, different tone) from 0.49 s, overlapping.
        let mac = sine(24_000, rate: 48_000, frequency: 300)
        for start in stride(from: 0, to: mac.count, by: 512) {
            line.place(Array(mac[start..<min(mac.count, start + 512)]), rate: 48_000, at: Double(start), source: 0)
        }
        let airpods = sine(24_000, rate: 24_000, frequency: 500).map { $0 * 0.3 }
        for start in stride(from: 0, to: airpods.count, by: 240) {
            line.place(Array(airpods[start..<start + 240]), rate: 24_000, at: 23_520 + Double(start * 2), source: 1)
        }
        // The old mic still sends one more buffer: ignored.
        line.place([Float](repeating: 0.9, count: 512), rate: 48_000, at: 24_000, source: 0)
        let (out, switched) = line.read(60_000)
        XCTAssertTrue(switched)
        XCTAssertLessThan(biggestJump(Array(out[100..<59_000])), 0.06)
        XCTAssertFalse(out[24_000..<24_512].contains(0.9))
    }
}
