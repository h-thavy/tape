import AVFoundation
import TapeCore
import os

/// Mixes the call and writes it to disk as it's recorded, so stopping only has to close the file.
///
/// - Encoded once, as 48 kHz stereo AAC (128 kbps, about 58 MB an hour). Nothing is decoded and encoded again.
/// - Written into an ADTS stream (.aac) while recording: every frame stands on its own, so a crash or power
///   cut loses nothing before it. Finishing repackages it as .m4a without re-encoding, in well under a second.
/// - The call is the timeline. Your microphone is placed on it by timestamp as it arrives (`MicLine`), so a
///   microphone switching mid-call slots in without a gap.
/// - Audio is held back `delay` seconds before it's mixed, so a mute noticed late in the call app still
///   applies from when it may have happened, and the recording can end where the call ended.
final class TapeWriter {
    static let rate = 48_000.0
    static let delay = 5.0

    let url: URL
    private var file: AVAudioFile?
    private let format = AVAudioFormat(standardFormatWithSampleRate: TapeWriter.rate, channels: 2)!
    private let mute: MuteTimeline
    private let queue = DispatchQueue(label: "tape.writer", qos: .userInitiated)
    private let lock = NSLock()

    // Arrival (capture queues, under `lock`).
    private var pending: [(chunk: CallChunk, position: Double)] = []
    /// Where the next call frame goes on the timeline (48 kHz frames), and when the last call buffer ended.
    private var callPosition: Double = 0
    private var callEnd: Double?
    /// The last call buffer's time and position, to place the microphone against.
    private var anchor: (time: Double, position: Double)?
    private var micLine = MicLine(rate: TapeWriter.rate)

    // Writing (writer queue).
    private var mixer = TapeMixer(rate: TapeWriter.rate)
    private var converter: AVAudioConverter?
    private var timer: DispatchSourceTimer?
    private(set) var framesWritten: Int64 = 0
    /// Debug hook: TAPE_DEBUG_TRACKS=1 also writes the call and your microphone (lined up, before mixing)
    /// beside the recording, as call.caf and mic.caf.
    private var rawMic: AVAudioFile?
    private var rawCall: AVAudioFile?
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "writer")

    init(url: URL, mute: MuteTimeline) throws {
        self.url = url
        self.mute = mute
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        if ProcessInfo.processInfo.environment["TAPE_DEBUG_TRACKS"] != nil,
           let mono = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1) {
            let folder = url.deletingLastPathComponent()
            rawMic = try? AVAudioFile(forWriting: folder.appendingPathComponent("mic.caf"), settings: mono.settings)
            rawCall = try? AVAudioFile(forWriting: folder.appendingPathComponent("call.caf"), settings: format.settings)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.drain(before: HostClock.now - Self.delay) }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Arrival (capture queues)

    func appendCall(_ chunk: CallChunk) {
        lock.withLock {
            // A gap in the call's audio (its device restarted): keep the timeline true.
            if let callEnd, chunk.time - callEnd > 0.05 {
                callPosition += min(chunk.time - callEnd, 4 * 3600) * Self.rate
            }
            pending.append((chunk, callPosition))
            anchor = (chunk.time, callPosition)
            callPosition += Double(chunk.frames) * Self.rate / chunk.rate
            callEnd = chunk.time + Double(chunk.frames) / chunk.rate
        }
    }

    func appendMic(_ chunk: MicChunk) {
        lock.withLock {
            guard let anchor else { return }
            let target = anchor.position + (chunk.time - anchor.time) * Self.rate
            micLine.place(chunk.samples, rate: chunk.rate, at: target, source: chunk.source)
        }
    }

    /// Writes what's left (ending at `end`, host clock, if given) and closes the file.
    func finish(endingAt end: Double? = nil, completion: @escaping (_ seconds: Double) -> Void) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            drain(before: .infinity, endingAt: end)
            file = nil   // closes it
            rawMic = nil
            rawCall = nil
            completion(Double(framesWritten) / Self.rate)
        }
    }

    // MARK: - Writing (writer queue)

    private func drain(before limit: Double, endingAt end: Double? = nil) {
        let ready = lock.withLock {
            let count = pending.prefix { $0.chunk.time < limit }.count
            defer { pending.removeFirst(count) }
            return Array(pending.prefix(count))
        }
        for (chunk, position) in ready {
            if let end, chunk.time >= end { break }
            process(chunk, at: position, endingAt: end)
        }
        if let last = ready.last { mute.forget(before: last.chunk.time) }
    }

    private func process(_ chunk: CallChunk, at position: Double, endingAt end: Double?) {
        guard chunk.frames > 0 else { return }
        // Silence for a gap in the call.
        let gap = Int(position.rounded()) - Int(framesWritten)
        if gap > Int(0.05 * Self.rate) {
            log.notice("Filled a \(Double(gap) / Self.rate, format: .fixed(precision: 2)) s gap in the call's audio")
            var left = [Float](repeating: 0, count: gap)
            let mic = lock.withLock { micLine.read(gap).samples }
            let mixed = mixer.mix(mic: mic, left: left, right: left) { _ in false }
            left = mixed.left
            write(left: left, right: mixed.right, mic: mic, callLeft: [Float](repeating: 0, count: gap), callRight: [Float](repeating: 0, count: gap))
        }
        var (left, right) = (chunk.left, chunk.right)
        if chunk.rate != Self.rate {
            if converter?.inputFormat.sampleRate != chunk.rate {
                converter = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: 2).flatMap { AVAudioConverter(from: $0, to: format) }
                log.notice("Call audio at \(chunk.rate) Hz; converting to 48 kHz")
            }
            if let converter { (left, right) = convert(left, right, from: chunk.rate, with: converter) }
        }
        var count = left.count
        if let end { count = min(count, max(0, Int((end - chunk.time) * Self.rate))) }
        guard count > 0 else { return }
        if count < left.count {
            left = Array(left.prefix(count))
            right = Array(right.prefix(count))
        }
        let (mic, switched) = lock.withLock { micLine.read(count) }
        if switched {
            log.notice("Microphone changed")
            mixer.microphoneChanged()
        }
        let start = chunk.time, mute = mute
        let mixed = mixer.mix(mic: mic, left: left, right: right) { mute.isMuted(at: start + Double($0) / Self.rate) }
        write(left: mixed.left, right: mixed.right, mic: mic, callLeft: left, callRight: right)
    }

    private func write(left: [Float], right: [Float], mic: [Float], callLeft: [Float], callRight: [Float]) {
        guard let file, !left.isEmpty, let buffer = Self.buffer(format, [left, right]) else { return }
        do {
            try file.write(from: buffer)
            framesWritten += Int64(left.count)
        } catch {
            log.error("Couldn't write audio: \(error.localizedDescription, privacy: .public)")
        }
        if let rawMic, let rawCall, let m = Self.buffer(rawMic.processingFormat, [mic]), let c = Self.buffer(format, [callLeft, callRight]) {
            try? rawMic.write(from: m)
            try? rawCall.write(from: c)
        }
    }

    private static func buffer(_ format: AVAudioFormat, _ channels: [[Float]]) -> AVAudioPCMBuffer? {
        let n = channels.map(\.count).min() ?? 0
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(n)
        for (index, samples) in channels.enumerated() where index < Int(format.channelCount) {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: n) }
        }
        return buffer
    }

    /// Only when the call's device runs at another rate than 48 kHz.
    private func convert(_ left: [Float], _ right: [Float], from rate: Double, with converter: AVAudioConverter) -> ([Float], [Float]) {
        guard let input = Self.buffer(converter.inputFormat, [left, right]),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(left.count) * Self.rate / rate) + 64)
        else { return ([], []) }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return ([], []) }
        let n = Int(output.frameLength)
        return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: n)),
                Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: n)))
    }
}
