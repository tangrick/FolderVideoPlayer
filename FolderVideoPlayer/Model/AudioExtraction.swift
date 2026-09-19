// The audio a speech pass needs, shaped the one way a speech model takes it:
// 16 kHz, mono, floats.
//
// AVFoundation does the work — demuxing, decoding, resampling and downmixing —
// so the app needs nothing installed: no ffmpeg, no Python, no network. Measured
// on this machine, a 44.1 kHz mono AAC track comes back at 16 kHz with the
// sample count within 0.02% of the track's length (AAC priming moves it by a few
// samples per file, which is why nothing here promises an exact count).
//
// Two callers matter. A short clip is read whole. A long film is NOT: at this
// rate a two-hour recording is 460 MB of float, so the job reads windows through
// `from`/`to` and never holds the whole thing.
import AVFoundation
import Foundation

/// What a file can tell us about its sound before any of it is decoded.
struct AudioProbe: Equatable {
    /// False for a video with no audio track at all — an answer, not a failure.
    var hasAudio: Bool
    /// The track's OWN rate, before this type resamples it to 16 kHz.
    var sampleRate: Double
    var channels: Int
    /// The container's duration, which is meaningful even when there is no audio.
    var seconds: Double
}

enum AudioExtractionError: Error, Equatable {
    /// No audio track: nothing to transcribe, and nothing to retry.
    case noAudioTrack
    /// The file could not be opened or decoded, with the reason.
    case unreadable(String)
    case emptyAudio
    /// A window that cannot exist — backwards, half-specified, or past the end.
    case badRange
}

enum AudioExtraction {
    /// The one shape speech models are trained on.
    static let sampleRate: Double = 16_000

    /// What the file is, without decoding its sound.
    static func probe(path: String) async throws -> AudioProbe {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw AudioExtractionError.unreadable("no such file")
        }
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard let track = tracks.first else {
            // A video with no audio is still a video: report its length.
            return AudioProbe(hasAudio: false, sampleRate: 0, channels: 0, seconds: seconds)
        }
        let desc = try await track.load(.formatDescriptions).first
        let sd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        return AudioProbe(hasAudio: true,
                          sampleRate: sd?.mSampleRate ?? 0,
                          channels: Int(sd?.mChannelsPerFrame ?? 0),
                          seconds: seconds)
    }

    /// Decode audio as 16 kHz mono floats. With no range the whole track is read;
    /// with `from` and `to` only that window is, so a long file is worked through
    /// in pieces instead of all at once.
    ///
    /// Half a range is a caller's mistake and is refused rather than guessed at.
    static func samples(path: String, from: Double? = nil, to: Double? = nil) async throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        // A missing file must fail as THIS module's error, not as whatever the
        // framework says first: a caller that handles AudioExtractionError would
        // otherwise be surprised by a raw AVFoundation error escaping here.
        guard FileManager.default.fileExists(atPath: path) else {
            throw AudioExtractionError.unreadable("no such file")
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractionError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        if from != nil || to != nil {
            guard let from, let to, from >= 0, to > from else {
                throw AudioExtractionError.badRange
            }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                           end: CMTime(seconds: to, preferredTimescale: 600))
        }
        // Asking for this format makes AVFoundation resample and downmix for us.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioExtractionError.unreadable("reader refused the audio track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExtractionError.unreadable(reader.error?.localizedDescription ?? "reader did not start")
        }

        var out: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = length / MemoryLayout<Int16>.size
            var chunk = [Int16](repeating: 0, count: frames)
            chunk.withUnsafeMutableBytes { raw -> Void in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress!)
            }
            out.reserveCapacity(out.count + frames)
            for value in chunk { out.append(Float(value) / 32768.0) }
        }
        if reader.status == .failed {
            throw AudioExtractionError.unreadable(reader.error?.localizedDescription ?? "read failed")
        }
        // A window that starts past the end reads nothing at all: refused as
        // empty rather than handed on as a silent clip to hallucinate over.
        guard !out.isEmpty else { throw AudioExtractionError.emptyAudio }
        return out
    }

    /// Write 16-bit PCM at 16 kHz mono. Kept because a slow transcription is
    /// worth being able to look at later without decoding the video again — and
    /// because the OS decoder reading our own header back is a check on it.
    static func writeWAV(_ samples: [Float], to path: String) throws {
        var data = Data()
        let byteCount = samples.count * 2
        func ascii(_ s: String) -> Data { Data(s.utf8) }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append(ascii("RIFF")); data.append(u32(UInt32(36 + byteCount))); data.append(ascii("WAVE"))
        data.append(ascii("fmt ")); data.append(u32(16)); data.append(u16(1)); data.append(u16(1))
        data.append(u32(UInt32(sampleRate))); data.append(u32(UInt32(sampleRate) * 2))
        data.append(u16(2)); data.append(u16(16))
        data.append(ascii("data")); data.append(u32(UInt32(byteCount)))
        for s in samples {
            let clamped = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: clamped.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
