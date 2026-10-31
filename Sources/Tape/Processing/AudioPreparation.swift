import AVFoundation
import Foundation

/// A temporary 16 kHz, mono, signed 16-bit PCM WAV for speech recognition. The original stays untouched.
/// Uses macOS's audio decoder instead of requiring an FFmpeg installation.
enum AudioPreparation {
    static func wav(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw Gemini.Failure(message: "This file has no readable audio. Import an audio or video recording.")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else {
                throw Gemini.Failure(message: "Couldn't prepare this recording for transcription.")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw Gemini.Failure(message: "Couldn't decode this recording. Try importing an M4A, MP3 or WAV file.")
            }
            defer { reader.cancelReading() }
            // Stream PCM to disk, reserving the standard 44-byte WAV header until the size is known.
            try Data(repeating: 0, count: 44).write(to: destination)
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            try file.seekToEnd()
            var size = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw Gemini.Failure(message: "Couldn't read the recording's audio samples.")
                }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0 else { continue }
                guard size + length <= Int(UInt32.max) - 36 else {
                    throw Gemini.Failure(message: "The recording is too large to prepare as WAV.")
                }
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else {
                    throw Gemini.Failure(message: "Couldn't read the recording's audio samples.")
                }
                try file.write(contentsOf: data)
                size += length
            }
            guard reader.status == .completed, size > 0 else {
                throw Gemini.Failure(message: "This recording is empty or couldn't be decoded. Try another audio file.")
            }
            try file.seek(toOffset: 0)
            try file.write(contentsOf: header(bytes: size))
        }.value
    }

    static let sampleRate = 16_000

    /// Only accepts the canonical PCM WAV produced above, never assumes an imported WAV has a 44-byte header.
    static func frames(in wav: URL) throws -> Int {
        let size = try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int ?? 0
        guard size > 44, size - 44 <= Int(UInt32.max) - 36, (size - 44) % 2 == 0 else {
            throw Gemini.Failure(message: "The prepared audio is empty or invalid.")
        }
        let file = try FileHandle(forReadingFrom: wav)
        defer { try? file.close() }
        guard try file.read(upToCount: 44) == header(bytes: size - 44) else {
            throw Gemini.Failure(message: "The prepared audio format is invalid.")
        }
        return (size - 44) / 2
    }

    /// Split decoded PCM on exact sample boundaries, without a second lossy encode or timeline rounding.
    static func slice(_ wav: URL, start: Int, count: Int, to output: URL) throws {
        let total = try frames(in: wav)
        guard start >= 0, count > 0, start <= total, count <= total - start else {
            throw Gemini.Failure(message: "The audio piece is outside the recording.")
        }
        try header(bytes: count * 2).write(to: output)
        let input = try FileHandle(forReadingFrom: wav)
        defer { try? input.close() }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        try input.seek(toOffset: UInt64(44 + start * 2))
        try file.seekToEnd()
        var remaining = count * 2
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: min(remaining, 1_048_576)), !data.isEmpty else {
                throw Gemini.Failure(message: "Couldn't read the complete audio piece.")
            }
            try file.write(contentsOf: data)
            remaining -= data.count
        }
    }

    private static func header(bytes: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(bytes) + 36); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(UInt32(bytes))
        return data
    }
}
