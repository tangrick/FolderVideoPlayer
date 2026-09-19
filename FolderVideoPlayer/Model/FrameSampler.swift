import Foundation
import AVFoundation
import CoreGraphics

/// Video → frames, the Swift replacement for the engine's `sample_frames`.
///
/// Same contract as the ffmpeg path: one frame every `SAMPLE_INTERVAL_S`
/// seconds, capped at `maxFrames` by keeping an evenly spaced subset, and the
/// short-clip clamp that keeps a 2-second clip from yielding zero frames (the
/// old silent "analyse failed" bug). Verified frame-for-frame against ffmpeg
/// in Phase 0 (`docs/phase0-results.md`, Task 0.4) on ten real videos
/// including three short clips.
enum FrameSampler {

    struct SampledFrame {
        let index: Int        // position in the full wanted list, pre-cap
        let time: Double      // seconds
        let image: CGImage
    }

    /// One frame every N seconds — matches engine.py SAMPLE_INTERVAL_S.
    static let interval = 5.0
    /// Hard cap per video — matches engine.py MAX_FRAMES.
    static let maxFrames = 250
    /// Decode bound on the short side, like the engine's scale filter. The
    /// model resizes internally anyway; this bounds memory and prepare cost.
    static let shortSide: CGFloat = 384
    /// Seek slack. ffmpeg seeks exactly; AVFoundation asks for tolerance.
    /// Phase 0 measured worst-case drift of 1.0 s — irrelevant for a uniform
    /// sample, but pinned here so it cannot silently grow.
    static let tolerance: Double = 0.5

    /// The fps-interval clamp, ported line-for-line from `_sample_interval`.
    /// `targetShort` is SAMPLE_TARGET_SHORT (4): a clip shorter than the
    /// interval still yields roughly this many frames.
    nonisolated static func clampInterval(duration: Double?,
                                          interval: Double = FrameSampler.interval,
                                          targetShort: Double = 4,
                                          floor: Double = 0.2) -> Double {
        guard let duration, duration > 0 else { return interval }
        return min(interval, max(duration / targetShort, floor))
    }

    /// The wanted timestamps for a video of `duration` seconds, pre-cap.
    nonisolated static func wantedTimes(duration: Double,
                                        interval: Double) -> [Double] {
        guard duration > 0 else { return [0] }
        return stride(from: 0.0, to: duration, by: interval).map { $0 }
    }

    /// Evenly spaced subset when the wanted list exceeds the cap — the same
    /// arithmetic as the engine's `indices[::step][:MAX_FRAMES]`.
    nonisolated static func capped(_ times: [Double],
                                   maxFrames: Int = FrameSampler.maxFrames) -> [Double] {
        guard times.count > maxFrames else { return times }
        let step = Int(ceil(Double(times.count) / Double(maxFrames)))
        return times.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
            .prefix(maxFrames).map { $0 }
    }

    /// Sample a video. Throws when nothing could be read at all (corrupt or
    /// unsupported file) — callers surface that, they do not swallow it.
    static func sample(url: URL,
                       duration: Double? = nil,
                       maxFrames: Int = FrameSampler.maxFrames) async throws -> [SampledFrame] {
        let asset = AVURLAsset(url: url)
        var resolved = duration
        if resolved == nil || resolved! <= 0 {
            resolved = try await asset.load(.duration).seconds
        }
        guard let duration = resolved, duration.isFinite, duration > 0 else {
            throw SamplerError.unreadable(url)
        }

        let interval = clampInterval(duration: duration)
        let times = capped(wantedTimes(duration: duration, interval: interval),
                           maxFrames: maxFrames)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: shortSide, height: shortSide)
        generator.requestedTimeToleranceBefore =
            CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter =
            CMTime(seconds: tolerance, preferredTimescale: 600)

        // Batched generation: AVAssetImageGenerator yields in order, but a
        // failed time comes back as a result whose `image` access throws,
        // so one unreadable stretch drops one frame, not the video.
        var images: [CGImage?] = Array(repeating: nil, count: times.count)
        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        for await result in generator.images(for: cmTimes) {
            let idx = cmTimes.firstIndex(of: result.requestedTime) ?? -1
            guard idx >= 0 else { continue }
            images[idx] = try? result.image
        }

        var out: [SampledFrame] = []
        out.reserveCapacity(times.count)
        for (i, img) in images.enumerated() {
            try Task.checkCancellation()
            guard let img else { continue }
            out.append(SampledFrame(index: i, time: times[i], image: img))
        }
        guard !out.isEmpty else { throw SamplerError.noFrames(url) }
        return out
    }

    enum SamplerError: Error, LocalizedError, CustomStringConvertible {
        case unreadable(URL)
        case noFrames(URL)

        var description: String {
            switch self {
            case .unreadable(let u): return "could not read video: \(u.lastPathComponent)"
            case .noFrames(let u):   return "no frames could be decoded: \(u.lastPathComponent)"
            }
        }

        /// So a refusal reaches the Analysis window as a sentence.
        var errorDescription: String? { description }
    }
}
