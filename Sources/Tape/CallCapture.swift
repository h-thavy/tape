import AVFoundation
import CoreAudio
import os

/// A stretch of what the Mac played (the other people in the call).
struct CallChunk {
    /// Host-clock seconds of the first frame.
    let time: Double
    let rate: Double
    let left: [Float]
    let right: [Float]
    var frames: Int { left.count }
}

/// A stretch of your microphone. `source` goes up whenever Tape moves to another microphone.
struct MicChunk {
    let time: Double
    let rate: Double
    let samples: [Float]
    let source: Int
}

enum HostClock {
    static var now: Double { seconds(AudioGetCurrentHostTime()) }
    static func seconds(_ hostTime: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9 }
}

/// Records the call as two streams, so that changing microphones or headphones never interrupts the other
/// people:
///
/// - **The call:** everything the Mac plays, in stereo, from a Core Audio process tap, before the volume
///   control, exactly as the call app played it. It's read through a private aggregate device clocked by the
///   Mac's built-in output, which is always there: switching from speakers to AirPods (or back) changes where
///   the sound goes, not this device, so it never restarts. No bot joins the call and no driver is installed.
/// - **Your microphone:** read directly from its device. When the microphone changes, the new one is started
///   before the old one is stopped (the writer cross-fades between them), and a Bluetooth headset switching
///   into call mode (a new sample rate) is followed at once.
///
/// A Bluetooth headset's mic is used only once the call already uses it: opening it switches the headset into
/// call mode (mono, 16–24 kHz) for everything you hear. Until then your voice comes from the Mac's microphone.
@available(macOS 14.2, *)
final class CallCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): "Couldn't record the call's audio (\(step): \(status))."
            case .noOutput: "No audio output device is available."
            }
        }
    }

    /// Called on the capture queues.
    var onCall: ((CallChunk) -> Void)?
    var onMic: ((MicChunk) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var clockUID: String?
    private var rate: Double = 48_000
    private let callQueue = DispatchQueue(label: "tape.capture.call", qos: .userInteractive)
    private let control = DispatchQueue(label: "tape.capture.control")
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pollTimer: DispatchSourceTimer?
    private var pendingCheck: DispatchWorkItem?

    private var mic: MicInput?
    /// The previous microphone, kept running until the new one delivers sound.
    private var leaving: MicInput?
    private var nextSource = 0
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "capture")

    func start() throws {
        let own = CoreAudioLookup.processObject(for: getpid()).map { [$0] } ?? []
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        tap.uuid = tapUUID
        tap.name = "Tape"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check("create tap", AudioHardwareCreateProcessTap(tap, &tapID))
        do {
            try control.sync {
                try buildCallDevice()
                checkMicrophone()
            }
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw error
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        deviceListener = listener
        for selector in Self.deviceSelectors {
            var address = CoreAudioLookup.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, listener)
        }
        // A headset switching into call mode changes its rate, not the default device: look twice a second.
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkMicrophone() }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        if let deviceListener {
            for selector in Self.deviceSelectors {
                var address = CoreAudioLookup.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, deviceListener)
            }
        }
        deviceListener = nil
        control.sync {
            pollTimer?.cancel()
            pollTimer = nil
            pendingCheck?.cancel()
            pendingCheck = nil
            mic?.stop()
            leaving?.stop()
            mic = nil
            leaving = nil
            tearDownCallDevice()
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static let deviceSelectors = [
        kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
    ]

    // MARK: - The call (control queue)

    /// The Mac's built-in output, which is always there; otherwise the current output.
    private static func clockDevice() -> AudioObjectID? {
        CoreAudioLookup.builtInOutput() ?? CoreAudioLookup.defaultDevice(input: false)
    }

    private func buildCallDevice() throws {
        guard let clock = Self.clockDevice(), let clockUID = CoreAudioLookup.uid(clock) else { throw CaptureError.noOutput }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tape",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Auto-start holds the whole device until something plays, losing the start of the call.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check("create device", AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
        self.clockUID = clockUID
        // The tap's buffers come after the clock device's own inputs (a built-in output has none).
        let skip = CoreAudioLookup.inputStreamCount(clock)
        rate = CoreAudioLookup.nominalRate(aggregateID) ?? 48_000

        var rateAddress = CoreAudioLookup.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let rate = CoreAudioLookup.nominalRate(self.aggregateID) else { return }
            self.callQueue.async { self.rate = rate }
            self.log.notice("Call audio rate changed to \(rate) Hz")
        }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddress, control, listener)

        var logged = false
        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, callQueue) { [weak self] _, input, inputTime, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if !logged {
                logged = true
                self.log.notice("Call device buffers: \(buffers.map { "\($0.mNumberChannels)ch" }.joined(separator: " + "), privacy: .public)")
            }
            guard let (left, right) = Self.stereo(buffers, from: skip) else { return }
            let time = Self.time(inputTime, frames: left.count, rate: self.rate)
            self.onCall?(CallChunk(time: time, rate: self.rate, left: left, right: right))
        })
        try check("start device", AudioDeviceStart(aggregateID, ioProcID))
        log.notice("Recording the Mac's audio at \(self.rate) Hz (clocked by \(CoreAudioLookup.name(clock) ?? clockUID, privacy: .public))")
    }

    private func tearDownCallDevice() {
        guard aggregateID != kAudioObjectUnknown else { return }
        if let rateListener {
            var rateAddress = CoreAudioLookup.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &rateAddress, control, rateListener)
        }
        rateListener = nil
        AudioDeviceStop(aggregateID, ioProcID)
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - The microphone (control queue)

    /// The microphone to record now: the default one, unless it's a Bluetooth headset the call isn't using
    /// (still in music mode), whose mic would switch it into call mode.
    private static func wantedMicrophone() -> AudioObjectID? {
        guard Permissions.microphone, let wanted = CoreAudioLookup.defaultDevice(input: true) else { return nil }
        if CoreAudioLookup.isBluetooth(wanted), (CoreAudioLookup.nominalRate(wanted) ?? 0) >= 44_100,
           let builtIn = CoreAudioLookup.builtInInput() {
            return builtIn
        }
        return wanted
    }

    private func devicesChanged() {
        // macOS announces a change several times while it settles.
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.tapID != kAudioObjectUnknown else { return }
            // The clock device only goes away on Macs without a built-in output.
            if let clockUID = self.clockUID, CoreAudioLookup.device(uid: clockUID) == nil {
                self.log.notice("The call's clock device is gone; rebuilding")
                self.tearDownCallDevice()
                do { try self.buildCallDevice() } catch {
                    self.log.error("Couldn't rebuild the call device: \(error.localizedDescription, privacy: .public)")
                }
            }
            self.checkMicrophone()
        }
        pendingCheck = work
        control.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Moves to another microphone when the wanted one changed (or the current one stopped delivering).
    private func checkMicrophone() {
        guard tapID != kAudioObjectUnknown else { return }
        let wanted = Self.wantedMicrophone()
        if let mic, mic.device == wanted, mic.isAlive { return }
        guard let wanted else {
            if mic != nil { log.notice("No microphone; recording only the call") }
            mic?.stop()
            mic = nil
            return
        }
        let source = nextSource
        nextSource += 1
        let name = CoreAudioLookup.name(wanted) ?? "microphone"
        do {
            let next = try MicInput(device: wanted, source: source) { [weak self] chunk in self?.onMic?(chunk) }
            // Keep the old one until the new one is heard, so there's no gap.
            leaving?.stop()
            leaving = mic
            next.onFirstSound = { [weak self] in
                self?.control.async {
                    self?.leaving?.stop()
                    self?.leaving = nil
                }
            }
            mic = next
            log.notice("Recording your voice from \(name, privacy: .public) at \(next.rate) Hz")
        } catch {
            log.error("Couldn't start \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// The first two channels after `skip` buffers (interleaved or not); a mono source is copied to both.
    private static func stereo(_ buffers: UnsafeMutableAudioBufferListPointer, from skip: Int) -> ([Float], [Float])? {
        var channels: [(UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = []
        for index in min(skip, buffers.count)..<buffers.count {
            let buffer = buffers[index]
            let count = Int(buffer.mNumberChannels)
            guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (4 * count)
            for channel in 0..<count { channels.append((data + channel, count, frames)) }
        }
        guard let first = channels.first, first.frames > 0 else { return nil }
        let second = channels.count > 1 ? channels[1] : first
        let frames = min(first.frames, second.frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            left[i] = first.0[i * first.stride]
            right[i] = second.0[i * second.stride]
        }
        return (left, right)
    }

    static func time(_ stamp: UnsafePointer<AudioTimeStamp>, frames: Int, rate: Double) -> Double {
        stamp.pointee.mFlags.contains(.hostTimeValid) ? HostClock.seconds(stamp.pointee.mHostTime) : HostClock.now - Double(frames) / rate
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            log.error("\(step, privacy: .public) failed: \(status)")
            throw CaptureError.coreAudio(step, status)
        }
    }
}

/// One microphone, read directly from its device. Follows the device's sample rate as it changes (a Bluetooth
/// headset going into call mode). Nothing is delivered until it sends real sound: a Bluetooth headset switching
/// into call mode first sends a stretch of pure zeros, and the previous microphone keeps recording meanwhile.
@available(macOS 14.2, *)
private final class MicInput {
    let device: AudioObjectID
    /// Called once, when the first buffer with real sound arrives.
    var onFirstSound: (() -> Void)?
    private var ioProcID: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var _rate: Double
    private var lastBuffer = HostClock.now
    private var heard = false

    var rate: Double { lock.withLock { _rate } }
    /// False once the device has stopped sending sound (unplugged, or taken over).
    var isAlive: Bool { HostClock.now - lock.withLock { lastBuffer } < 1.5 }

    init(device: AudioObjectID, source: Int, onChunk: @escaping (MicChunk) -> Void) throws {
        self.device = device
        _rate = CoreAudioLookup.nominalRate(device) ?? 48_000
        queue = DispatchQueue(label: "tape.capture.mic.\(source)", qos: .userInteractive)
        var address = CoreAudioLookup.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let rate = CoreAudioLookup.nominalRate(device) else { return }
            self.lock.withLock { self._rate = rate }
        }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, queue) { [weak self] _, input, inputTime, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels > 0,
                  let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = Int(first.mNumberChannels)
            let frames = Int(first.mDataByteSize) / (4 * stride)
            guard frames > 0 else { return }
            let samples = (0..<frames).map { data[$0 * stride] }
            let rate = self.rate
            // A working microphone always has some noise; pure zeros mean it isn't really there yet.
            let sound = samples.contains { abs($0) > 1e-7 }
            let firstTime = self.lock.withLock { () -> Bool? in
                if sound { self.lastBuffer = HostClock.now }
                if self.heard { return false }
                guard sound else { return nil }
                self.heard = true
                return true
            }
            guard let firstTime else { return }
            onChunk(MicChunk(time: CallCapture.time(inputTime, frames: frames, rate: rate), rate: rate, samples: samples, source: source))
            if firstTime { self.onFirstSound?() }
        }
        guard status == noErr, let ioProcID else {
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
            throw CallCapture.CaptureError.coreAudio("open microphone", status)
        }
        let started = AudioDeviceStart(device, ioProcID)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, ioProcID)
            self.ioProcID = nil
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
            throw CallCapture.CaptureError.coreAudio("start microphone", started)
        }
    }

    func stop() {
        if let rateListener {
            var address = CoreAudioLookup.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, rateListener)
        }
        rateListener = nil
        guard let ioProcID else { return }
        AudioDeviceStop(device, ioProcID)
        AudioDeviceDestroyIOProcID(device, ioProcID)
        self.ioProcID = nil
    }

    deinit { stop() }
}

/// Core Audio property lookups.
enum CoreAudioLookup {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        var address = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func uid(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let transport = uint32(device, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func allDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    /// The Mac's own microphone.
    static func builtInInput() -> AudioObjectID? {
        allDevices().first { uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && inputStreamCount($0) > 0 }
    }

    /// The Mac's own speakers (or headphone jack).
    static func builtInOutput() -> AudioObjectID? {
        allDevices().first { uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && outputStreamCount($0) > 0 }
    }

    static func inputStreamCount(_ device: AudioObjectID) -> Int { streamCount(device, kAudioObjectPropertyScopeInput) }
    static func outputStreamCount(_ device: AudioObjectID) -> Int { streamCount(device, kAudioObjectPropertyScopeOutput) }

    private static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
