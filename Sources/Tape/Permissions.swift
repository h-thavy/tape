import AVFoundation
import ApplicationServices
import os

/// The three permissions Tape uses: the microphone (your voice), system audio recording (the other people),
/// and Accessibility (reading the call app's mute button, so muted moments leave your mic out).
enum Permissions {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - System audio recording

    /// macOS has no public call for this permission. TCC's own (as used by Apple's sample code and AudioCap)
    /// asks up front, so the prompt doesn't first appear in the middle of a call; without it, macOS asks on the
    /// first recording.
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    /// nil when it can't be told.
    static var systemAudio: Bool? {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    static func requestSystemAudio() async -> Bool {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else { return false }
        return await withCheckedContinuation { done in
            unsafeBitCast(symbol, to: Request.self)(service, nil) { done.resume(returning: $0) }
        }
    }
}
