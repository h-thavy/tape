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
            var header = Data()
            func text(_ value: String) { header.append(contentsOf: value.utf8) }
            func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
            func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
            text("RIFF"); u32(UInt32(size) + 36); text("WAVE")
            text("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
            text("data"); u32(UInt32(size))
            try file.seek(toOffset: 0)
            try file.write(contentsOf: header)
        }.value
    }
}
