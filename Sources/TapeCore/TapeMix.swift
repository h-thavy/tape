import Foundation

/// When you were muted in the call, on the host clock (seconds). Tape leaves your microphone out of those
/// moments. Audio is written a few seconds late, so a mute that's noticed late can still be dated back to when
/// it may have happened.
public final class MuteTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [(at: Double, muted: Bool)] = []

    public init() {}

    /// You're `muted` (or not) from `time` on. Anything recorded later than `time` is replaced.
    public func set(_ muted: Bool, from time: Double) {
        lock.withLock {
            changes.removeAll { $0.at >= time }
            if (changes.last?.muted ?? false) != muted { changes.append((time, muted)) }
        }
    }

    public func isMuted(at time: Double) -> Bool {
        lock.withLock { changes.last(where: { $0.at <= time })?.muted ?? false }
    }

    /// Drops changes that no longer matter (all audio before `time` is written), keeping the state at `time`.
    public func forget(before time: Double) {
        lock.withLock {
            guard let keep = changes.lastIndex(where: { $0.at <= time }), keep > 0 else { return }
            changes.removeFirst(keep)
        }
    }
}

/// Mixes your microphone into the call's audio, the way the call sounded:
/// - the call (everything the Mac played) is kept as it is, in stereo;
/// - your mic goes in the middle, gently levelled (call apps do the same before sending your voice);
/// - between your words your mic is turned down, so the room's steady hum and hiss don't sit under everyone
///   (what counts as your voice is learned against the room's own noise floor);
/// - on speakers, the other side's voice also reaches your mic from the room a moment later. That echo is
///   recognised by its loudness following the call's (at some delay up to 300 ms, with its reverb), and your mic is turned
///   down while it's only echo, so their voices aren't recorded twice. Your own voice doesn't follow the
///   call, so talking over them keeps your mic open;
/// - when another device near you is in the same call, your voice comes back through the call a moment
///   later (0.1–1.5 s). That's recognised the same way (the call's loudness following your mic's), and the
///   call is turned down while it's only your voice coming back, so you're not recorded twice;
/// - while you're muted in the call, your mic is left out;
/// - a soft limiter catches both sides peaking together.
/// Works in 10 ms blocks with gain ramps inside each block, so nothing clicks.
public struct TapeMixer {
    public let rate: Double
    private let block: Int

    /// Echo delays looked at (blocks): up to 300 ms, plus 100 ms of the room's reverb after it.
    static let lags = 40
    static let maxDelay = 30
    static let tail = 10
    /// The call's loudness per block, newest last, for looking up what it was `lag` blocks ago.
    private var callLevels: [Float]
    private var levelIndex = 0
    /// Running (about 2 s) means, variances and covariances at each lag, of block loudness.
    private var callMean: Float = 0
    private var micMean: Float = 0
    private var callVariance: Float = 0
    private var micVariance: Float = 0
    private var covariance: [Float]
    private var echoGain: Float = 1

    /// Your voice coming back through the call: delays looked at (blocks), from 100 ms to 1.5 s.
    static let backDelays = 10...150
    /// Your mic's loudness per block, newest last, to look back up to 1.5 s.
    private var micLevels: [Float]
    private var micIndex = 0
    private var backCovariance: [Float]
    /// How loud your returning voice is in the call, against your mic (log), at the delay found.
    private var logBackRatio: Float = 0
    private var callGain: Float = 1
    private var lastCallGain: Float = 1
    private var backHangover = 0
    private var started = false
    /// Blocks left to keep your mic open after you stop talking, so word endings aren't cut.
    private var hangover = 0
    /// Blocks in a row that sounded like you (two are needed to open the mic while the call plays).
    private var talkStreak = 0
    /// How loud the echo is against the call (log), learned at the echo's delay: the 30th percentile, so the
    /// moments you talk over them don't count.
    private var logEchoRatio: Float = log(0.1)
    private var levelGain: Float = 1.5
    /// The room's noise in your mic: follows the quietest blocks down quickly and rises only slowly.
    private var noiseFloor: Float = 0.003
    private var lastGain: Float = 1.5

    static let speech: Float = 0.006
    static let suppressed: Float = 0.12
    /// Your mic between words when nobody in the call is talking.
    static let between: Float = 0.3
    static let levelTarget: Float = 0.07
    static let memory: Float = 0.995

    public init(rate: Double) {
        self.rate = rate
        block = max(1, Int(rate / 100))
        callLevels = [Float](repeating: 0, count: Self.lags)
        covariance = [Float](repeating: 0, count: Self.lags)
        micLevels = [Float](repeating: 0, count: Self.backDelays.upperBound + 8)
        backCovariance = [Float](repeating: 0, count: Self.backDelays.upperBound + 1)
    }

    /// Another microphone: its room, noise and echo are different, so those are learned again. Your voice's
    /// level is kept (it's the same voice).
    public mutating func microphoneChanged() {
        noiseFloor = 0.05   // falls to the new mic's floor within a fraction of a second
        logEchoRatio = log(0.1)
        for i in covariance.indices { covariance[i] = 0 }
        for i in backCovariance.indices { backCovariance[i] = 0 }
        micVariance = 0
        hangover = 0
        talkStreak = 0
    }

    /// Mixes one stretch of audio. `mic`, `left` and `right` have the same length; `muted(i)` says whether you
    /// were muted at frame `i`. Returns the stereo mix.
    public mutating func mix(mic: [Float], left: [Float], right: [Float], muted: (Int) -> Bool) -> (left: [Float], right: [Float]) {
        let n = min(mic.count, left.count, right.count)
        var outLeft = [Float](repeating: 0, count: n)
        var outRight = [Float](repeating: 0, count: n)
        var start = 0
        while start < n {
            let end = min(n, start + block)
            let gain = nextGain(mic: mic[start..<end], left: left[start..<end], right: right[start..<end], muted: muted(start))
            let count = end - start
            for i in 0..<count {
                // Ramp from the previous block's gains to this one's.
                let step = Float(i + 1) / Float(count)
                let g = lastGain + (gain - lastGain) * step
                let c = lastCallGain + (callGain - lastCallGain) * step
                let voice = mic[start + i] * g
                outLeft[start + i] = Self.limit(left[start + i] * c + voice)
                outRight[start + i] = Self.limit(right[start + i] * c + voice)
            }
            lastGain = gain
            lastCallGain = callGain
            start = end
        }
        return (outLeft, outRight)
    }

    /// The call's loudness `lag` blocks ago (0 = this block).
    private func callLevel(_ lag: Int) -> Float {
        callLevels[(levelIndex - 1 - lag + 2 * Self.lags) % Self.lags]
    }

    /// Your mic's loudness `lag` blocks ago (0 = this block).
    private func micLevel(_ lag: Int) -> Float {
        micLevels[(micIndex - 1 - lag + 2 * micLevels.count) % micLevels.count]
    }

    /// Turns the call down while it's only your own voice coming back (another device near you in the call).
    private mutating func followReturningVoice(call: Float, spread: Float) {
        let a = Self.memory
        var best = Self.backDelays.lowerBound
        for lag in Self.backDelays {
            backCovariance[lag] = a * backCovariance[lag] + (1 - a) * (micLevel(lag) - micMean) * (call - callMean)
            if backCovariance[lag] > backCovariance[best] { best = lag }
        }
        // A call that hardly changes (silence, a steady tone) can't be following anything.
        let correlation = callVariance > 1e-6 && micVariance > 1e-7 ? backCovariance[best] / spread : 0
        var returning = false
        if correlation > 0.6 {
            let you = (max(0, best - 3)...min(micLevels.count - 1, best + 5)).map(micLevel).max() ?? 0
            let then = micLevel(best)
            if then > max(Self.speech, 3.5 * noiseFloor), call > Self.speech / 3 {
                logBackRatio += log(call / then) > logBackRatio ? 0.015 : -0.015
                logBackRatio = min(max(logBackRatio, log(0.05)), log(20))
            }
            // The call is no louder than your voice from back then would make it: it's only you.
            returning = you > max(Self.speech, 3.5 * noiseFloor) && call < 2 * exp(logBackRatio) * you
        }
        if returning { backHangover = 15 } else if backHangover > 0 { backHangover -= 1 }
        let target: Float = backHangover > 0 && returning ? Self.suppressed : backHangover > 0 ? callGain : 1
        // Opens at once (the other side starts talking), closes over ~30 ms.
        callGain = target > callGain ? target : callGain * 0.7 + target * 0.3
    }

    private mutating func nextGain(mic: ArraySlice<Float>, left: ArraySlice<Float>, right: ArraySlice<Float>, muted: Bool) -> Float {
        let micLevel = Self.rms(mic)
        var sum: Float = 0
        for (l, r) in zip(left, right) { sum += (l + r) * (l + r) / 4 }
        callLevels[levelIndex] = sqrt(sum / Float(max(1, left.count)))
        levelIndex = (levelIndex + 1) % Self.lags

        // How the mic's loudness follows the call's, at each delay.
        let a = Self.memory
        let call = callLevel(0)
        // Start the averages where the audio is, so their first seconds don't look like a correlation.
        if !started {
            started = true
            callMean = call
            micMean = micLevel
        }
        callMean = a * callMean + (1 - a) * call
        micMean = a * micMean + (1 - a) * micLevel
        callVariance = a * callVariance + (1 - a) * (call - callMean) * (call - callMean)
        micVariance = a * micVariance + (1 - a) * (micLevel - micMean) * (micLevel - micMean)
        var best = 0
        for lag in 0..<Self.lags {
            covariance[lag] = a * covariance[lag] + (1 - a) * (callLevel(lag) - callMean) * (micLevel - micMean)
            if lag <= Self.maxDelay, covariance[lag] > covariance[best] { best = lag }
        }
        let spread = sqrt(callVariance * micVariance)
        let correlation = spread > 0 ? covariance[best] / spread : 0
        // What you sent into the call: nothing while muted (then the call can't have your voice coming back).
        micLevels[micIndex] = muted ? 0 : micLevel
        micIndex = (micIndex + 1) % micLevels.count
        followReturningVoice(call: call, spread: spread)
        // Clearly following the call: the echo expected now, from the call around `best` blocks ago (the
        // loudest of that moment and the reverb after it).
        var echo: Float = 0
        if correlation > 0.5 {
            let window = (max(0, best - 2)...min(Self.lags - 1, best + Self.tail)).map(callLevel).max() ?? 0
            let atDelay = callLevel(best)
            if atDelay > Self.speech / 3, micLevel > noiseFloor * 1.5 {
                logEchoRatio += log(micLevel / atDelay) > logEchoRatio ? 0.03 * 0.3 : -0.03 * 0.7
                logEchoRatio = min(max(logEchoRatio, log(0.001)), log(2))
            }
            echo = exp(logEchoRatio) * window
        }

        noiseFloor = micLevel < noiseFloor ? noiseFloor * 0.8 + micLevel * 0.2 : noiseFloor * 1.002
        noiseFloor = min(max(noiseFloor, 0.0001), 0.05)
        let calling = (0...Self.maxDelay).contains { callLevel($0) > Self.speech / 3 }
        let loud = micLevel > max(Self.speech, 3.5 * noiseFloor) && micLevel > 1.8 * echo
        talkStreak = loud ? talkStreak + 1 : 0
        let talking = loud && (talkStreak >= 2 || !calling)
        if talking { hangover = 12 } else if hangover > 0 { hangover -= 1 }
        let echoTarget: Float = hangover > 0 ? 1 : calling ? Self.suppressed : Self.between
        // Open at once, close over ~30 ms.
        echoGain = echoTarget > echoGain ? echoTarget : echoGain * 0.7 + echoTarget * 0.3

        // Level your voice slowly, only from blocks where it's you speaking.
        if talking, micLevel > max(Self.speech * 2, 6 * noiseFloor) {
            let wanted = min(max(Self.levelTarget / micLevel, 0.7), 3)
            levelGain += (wanted - levelGain) * 0.01
        }
        return echoGain * levelGain * (muted ? 0 : 1)
    }

    /// Leaves quiet audio untouched and rounds off peaks above 0.9.
    public static func limit(_ x: Float) -> Float {
        let size = abs(x)
        guard size > 0.9 else { return x }
        return (x < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((size - 0.9) / 0.1))
    }

    public static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
