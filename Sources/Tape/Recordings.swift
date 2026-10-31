import AudioToolbox
import Foundation
import os

/// Where recordings go: ~/Documents/Tape, one .m4a per call ("2026-10-30 14.05 Zoom.m4a"). While a call is
/// being recorded its audio is in Application Support (so nothing half-written shows up in the folder);
/// anything left there by a crash is finished on the next launch.
enum Recordings {
    #if DEBUG
    static var testingRoot: URL?
    #endif
    private static let log = Logger(subsystem: "io.github.h-thavy.tape", category: "recordings")

    static var folder: URL {
        #if DEBUG
        if let testingRoot { return testingRoot.appendingPathComponent("Recordings", isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Tape", isDirectory: true)
    }

    static var inProgress: URL {
        #if DEBUG
        if let testingRoot { return testingRoot.appendingPathComponent("Support/Recording", isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tape/Recording", isDirectory: true)
    }

    static func prepareFolders() {
        for url in [folder, inProgress] { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    /// "2026-10-30 14.05 Zoom"
    static func name(at date: Date, app: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let app = app?.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return [formatter.string(from: date), app].compactMap { $0 }.joined(separator: " ")
    }

    /// A file name in the recordings folder that isn't taken.
    static func destination(for stem: String) -> URL {
        var url = folder.appendingPathComponent(stem).appendingPathExtension("m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(n)").appendingPathExtension("m4a")
            n += 1
        }
        return url
    }

    /// Moves a finished .aac into the recordings folder as .m4a, repackaged without re-encoding. If that fails
    /// the .aac itself is moved (it plays in most players). Returns where it ended up.
    static func publish(_ source: URL) async -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }
        prepareFolders()
        let destination = destination(for: source.deletingPathExtension().lastPathComponent)
        let started = Date()
        if await remux(source, to: destination) {
            try? fm.removeItem(at: source)
            log.notice("Saved \(destination.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            return destination
        }
        let fallback = destination.deletingPathExtension().appendingPathExtension("aac")
        do {
            try fm.moveItem(at: source, to: fallback)
            log.error("Saved as .aac (couldn't repackage as .m4a)")
            return fallback
        } catch {
            log.error("Couldn't save the recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Copies the AAC packets from the ADTS stream into an .m4a as they are (no decoding or encoding): about
    /// half a second for an hour.
    private static func remux(_ source: URL, to destination: URL) async -> Bool {
        let status = await Task.detached(priority: .userInitiated) { copyPackets(source, destination) }.value
        if status != noErr {
            log.error("Repackaging failed: \(status)")
            try? FileManager.default.removeItem(at: destination)
        }
        return status == noErr
    }

    private static func copyPackets(_ source: URL, _ destination: URL) -> OSStatus {
        var input: AudioFileID?
        var status = AudioFileOpenURL(source as CFURL, .readPermission, kAudioFileAAC_ADTSType, &input)
        guard status == noErr, let input else { return status }
        defer { AudioFileClose(input) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioFileGetProperty(input, kAudioFilePropertyDataFormat, &size, &format)
        guard status == noErr else { return status }
        var output: AudioFileID?
        status = AudioFileCreateWithURL(destination as CFURL, kAudioFileM4AType, &format, .eraseFile, &output)
        guard status == noErr, let output else { return status }
        defer { AudioFileClose(output) }
        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(input, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileGetProperty(input, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie) == noErr {
                AudioFileSetProperty(output, kAudioFilePropertyMagicCookieData, cookieSize, cookie)
            }
        }
        let chunk: UInt32 = 1024
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(chunk))
        var data = [UInt8](repeating: 0, count: Int(chunk) * 3072)
        var packet: Int64 = 0
        while true {
            var bytes = UInt32(data.count), packets = chunk
            status = AudioFileReadPacketData(input, false, &bytes, &descriptions, packet, &packets, &data)
            guard status == noErr || status == kAudioFileEndOfFileError else { return status }
            guard packets > 0 else { break }
            status = AudioFileWritePackets(output, false, bytes, descriptions, packet, &packets, data)
            guard status == noErr else { return status }
            packet += Int64(packets)
        }
        return packet > 0 ? noErr : kAudioFileInvalidFileError
    }

    /// Recordings a crash or quit left unfinished.
    /// Runs before anything is recorded, so it never takes the file being written.
    static func recoverUnfinished() async -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inProgress, includingPropertiesForKeys: nil)) ?? []
        var saved: [URL] = []
        for file in files where file.pathExtension == "aac" {
            if let url = await publish(file) { saved.append(url) }
        }
        return saved
    }
}
