import Foundation

/// Your microphone, lined up with the call. The two come from different devices with their own clocks (and
/// your mic changes when you plug in a headset), so each buffer is placed where it belongs on the call's
/// timeline (at `rate`, from its timestamp), converted from the mic's own rate on the way in.
///
/// - Within one microphone the audio stays continuous: small clock drift is corrected by stretching it very
///   slightly (at most 0.2 %, far below hearing), never by jumping.
/// - Moving to another microphone (or a jump of more than 20 ms) cross-fades over 10 ms into the new one,
///   overlapping what the old one already wrote, so there's no click and no gap.
/// - A buffer from an older microphone, still running while the new one starts, is ignored once the new one
///   has been heard.
public struct MicLine {
    public let rate: Double
    private var ring: [Float]
    /// The next frame `read` returns.
    public private(set) var readPosition = 0
    private var source: Int?
    private var writePosition = 0
    /// Where the next buffer starts in the input, relative to its first sample (between -1 and 0: between the
    /// last buffer's final sample and this one's first).
    private var phase: Double = 0
    private var lastSample: Float = 0
    /// Frames left to cross-fade into.
    private var fade = 0
    private var switches: [Int] = []
    static let fadeLength = 0.01

    public init(rate: Double = 48_000, seconds: Double = 30) {
        self.rate = rate
        ring = [Float](repeating: 0, count: Int(rate * seconds))
    }

    /// Places a microphone buffer whose first sample belongs at frame `target` of the timeline.
    public mutating func place(_ samples: [Float], rate inputRate: Double, at target: Double, source: Int) {
        guard !samples.isEmpty, inputRate > 0 else { return }
        if let current = self.source, source < current { return }
        let fadeFrames = Int(rate * Self.fadeLength)
        // Where this buffer's first sample lands if the audio just continues (`phase` is still before it).
        var landing = Double(writePosition) - phase * rate / inputRate
        if source != self.source || abs(target - landing) > 0.02 * rate {
            if self.source != nil, source != self.source { switches.append(Int(target.rounded())) }
            self.source = source
            writePosition = Int(target.rounded())
            phase = 0
            lastSample = samples[0]
            fade = fadeFrames
            landing = Double(writePosition)
        }
        // Drift: ahead of or behind where the buffer should start. Stretch gently to catch up.
        let error = target - landing
        let correction = min(max(error * 2e-5, -0.002), 0.002)
        let step = inputRate / rate * (1 - correction)

        var p = phase
        let last = Double(samples.count - 1)
        while p < last {
            let i = Int(p.rounded(.down))
            let a = i < 0 ? lastSample : samples[i]
            let b = samples[i + 1]
            let value = a + (b - a) * Float(p - Double(i))
            write(value, fadeFrames: fadeFrames)
            p += step
        }
        phase = p - Double(samples.count)
        lastSample = samples[samples.count - 1]
    }

    private mutating func write(_ value: Float, fadeFrames: Int) {
        defer { writePosition += 1 }
        // Too late (already read) or too far ahead (would overwrite what's unread).
        guard writePosition >= max(0, readPosition), writePosition < readPosition + ring.count else { return }
        let index = writePosition % ring.count
        if fade > 0 {
            let w = Float(fadeFrames - fade + 1) / Float(fadeFrames)
            ring[index] = ring[index] * (1 - w) + value * w
            fade -= 1
        } else {
            ring[index] = value
        }
    }

    /// The next `count` frames (silence where nothing was placed), and whether the microphone changed in them.
    public mutating func read(_ count: Int) -> (samples: [Float], switched: Bool) {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let index = (readPosition + i) % ring.count
            out[i] = ring[index]
            ring[index] = 0
        }
        let end = readPosition + count
        let switched = switches.contains { $0 < end }
        switches.removeAll { $0 < end }
        readPosition = end
        return (out, switched)
    }

    /// Skips `count` frames (a gap in the call).
    public mutating func skip(_ count: Int) {
        _ = read(count)
    }
}
