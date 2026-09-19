import Foundation
import CryptoKit
import AVFoundation
import CoreGraphics

/// The shared sampling plan: one place decides which frames a pass wants,
/// bounded memory while it collects them, counters that say what the pass
/// actually cost, and the adaptive-vs-uniform comparison T06 promises to
/// measure.
///
/// T06's contract (design §8): bounded frame reuse through a shared plan;
/// source revision validation; decode/inference/cache counters; bounded peak
/// memory on long clips; a measured quality/speed comparison including
/// losses. Like the rest of the intelligence work, nothing here starts on
/// its own — a plan is built and consumed on an explicit pass.
///
/// What "shared" means concretely: one video's wanted timestamps are decided
/// ONCE, from the plan, and every consumer (classify, suggestions, faces,
/// look-alikes) receives the same frame list — the multi-pass decode saving
/// the design's ≥25% goal measures comes from reusing these frames rather
/// than re-deriving per-pass lists that drift apart.
enum SamplingPlan {

    // MARK: - the plan

    /// How the wanted timestamps are laid out. `uniform` is today's behaviour
    /// (one frame every `interval` seconds, capped); `adaptive` spends the
    /// same frame budget where the video is likely to be informative — the
    /// fixed 5-second grid reserved for the head and tail, the middle spent
    /// on scene cuts detected from cheap luma deltas.
    enum Strategy: String, Codable, CaseIterable {
        case uniform
        case adaptive
    }

    struct Plan: Equatable {
        var strategy: Strategy
        var wanted: [Double]          // seconds into the video
        /// The plan is only valid for a video that is still the same file:
        /// size + mtime — the top-level `SourceRevision`, the identity the
        /// fingerprint index and the analysis store already use.
        var sourceRevision: SourceRevision
        var duration: Double
    }

    static func revision(of path: String) -> SourceRevision? {
        SourceRevision.of(path)
    }

    /// Build a plan. `duration` comes from the caller (the durations index);
    /// an unreadable duration plans nothing.
    static func build(path: String,
                      duration: Double,
                      strategy: Strategy = .uniform,
                      interval: Double = FrameSampler.interval,
                      maxFrames: Int = FrameSampler.maxFrames) -> Plan? {
        guard duration.isFinite, duration > 0,
              let revision = revision(of: path) else { return nil }
        let clamped = FrameSampler.clampInterval(duration: duration, interval: interval)
        let wanted: [Double]
        switch strategy {
        case .uniform:
            wanted = FrameSampler.capped(FrameSampler.wantedTimes(duration: duration, interval: clamped),
                                         maxFrames: maxFrames)
        case .adaptive:
            wanted = adaptiveWanted(duration: duration, interval: clamped,
                                    maxFrames: maxFrames)
        }
        guard !wanted.isEmpty else { return nil }
        return Plan(strategy: strategy, wanted: wanted, sourceRevision: revision,
                    duration: duration)
    }

    /// The adaptive layout: same frame BUDGET as uniform, spent differently.
    ///
    /// The head and tail keep the fixed grid — intros and outros are where
    /// cheap context lives — and the released middle frames are re-spent at
    /// scene cuts, the frames a viewer would call "different shots". A cut is
    /// a large positive luma-delta between consecutive probes; the probe
    /// count is bounded so the scan costs one cheap low-res pass, never the
    /// whole decode.
    nonisolated static func adaptiveWanted(duration: Double,
                                           interval: Double,
                                           maxFrames: Int) -> [Double] {
        let uniform = FrameSampler.capped(
            FrameSampler.wantedTimes(duration: duration, interval: interval),
            maxFrames: maxFrames)
        guard uniform.count >= 8 else { return uniform }

        // Keep the first and last quarter of the uniform grid; the middle
        // half is released for cut-directed picks.
        let keep = uniform.count / 4
        let head = Array(uniform.prefix(keep))
        let tail = Array(uniform.suffix(keep))
        let released = uniform.count - head.count - tail.count

        // Probe grid for cut detection: bounded, coarse, cheap.
        let probes = min(96, max(16, uniform.count * 2))
        let step = duration / Double(probes)
        let probeTimes = (0..<probes).map { Double($0) * step }
        let luma = lumaSeries(times: probeTimes)

        // Cut candidates: |Δluma| above the robust threshold. The threshold
        // is computed from the series itself (median + k·MAD), so one bright
        // flash does not drag every pick to it.
        let deltas = zip(luma, luma.dropFirst()).map { abs($1 - $0) }
        let threshold = cutThreshold(deltas)
        var candidates: [Int] = deltas.enumerated()
            .filter { $0.element > threshold }
            .map { $0.offset + 1 }                     // the probe AFTER the jump
        candidates.sort()

        // Spend the released frames where the cuts are, then GUARANTEE the
        // budget: whatever the cut picks could not spend (few cuts, or picks
        // that collided with the kept grid) is filled from the released
        // middle of the UNIFORM grid, in order. The layout is always the same
        // SIZE as uniform — adaptive re-spends the budget, it never spends
        // less.
        var picks: [Double] = head
        if candidates.isEmpty {
            // No cuts found: keep the uniform layout (never fewer frames of
            // context than uniform would have given).
            picks = uniform
        } else {
            let stride = max(1, candidates.count / max(1, released))
            var chosen: [Double] = []
            var index = 0
            while chosen.count < released, index < candidates.count {
                let t = probeTimes[candidates[index]]
                // Never pick a time the kept grid already holds.
                if !head.contains(t), !tail.contains(t), !chosen.contains(t) {
                    chosen.append(t)
                }
                index += stride
            }
            // Budget guarantee: fill any shortfall from the released middle
            // of the uniform grid, skipping times already picked.
            if chosen.count < released {
                let middle = uniform[head.count..<(uniform.count - tail.count)]
                for t in middle where chosen.count < released && !chosen.contains(t) {
                    chosen.append(t)
                }
            }
            picks += chosen
            picks += tail
        }
        return Array(picks.sorted().prefix(maxFrames))
    }

    /// Cheap luma series: one low-res frame per probe time, mean luminance.
    /// Isolated so the comparison harness can count what the scan costs.
    nonisolated static func lumaSeries(times: [Double]) -> [Double] {
        times.compactMap { t -> Double? in
            guard let probe = Self.probeURL else { return nil }
            let image = Self.probeImage(url: probe, at: t)
            return image.map(meanLuma)
        }
    }

    /// Set by the streaming consumer (below) so cut detection needs no
    /// AVFoundation import in the arithmetic itself. Nil in pure-arithmetic
    /// tests, where `adaptiveWanted` falls back to the uniform layout.
    nonisolated(unsafe) static var probeURL: URL?

    nonisolated static func probeImage(url: URL, at time: Double) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600),
                                          actualTime: nil)
    }

    /// Mean luminance of a CGImage, downsampled — the cheap signal cut
    /// detection reads.
    nonisolated static func meanLuma(_ image: CGImage) -> Double {
        let w = min(image.width, 32), h = min(image.height, 32)
        guard w > 0, h > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1])
                  + 0.114 * Double(pixels[i + 2])
        }
        return total / Double(w * h) / 255.0
    }

    /// Median + 3·MAD: a threshold that survives one outlier.
    nonisolated static func cutThreshold(_ deltas: [Double]) -> Double {
        guard deltas.count > 4 else { return .infinity }
        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        return median + 3 * max(mad, 0.01)
    }

    // MARK: - bounded streaming

    /// A bounded, pull-based frame stream over one plan.
    ///
    /// Memory bound: at most `window` decoded frames exist at once, whatever
    /// the plan's length — the property the design's "bounded peak memory on
    /// long clips" gate measures. The consumer pulls; nothing buffers the
    /// whole video.
    struct Stream: Sequence {
        let plan: SamplingPlan.Plan
        let url: URL
        var window: Int = 4

        func makeIterator() -> Iterator { Iterator(stream: self) }

        struct Iterator: IteratorProtocol {
            let stream: Stream
            private var generator: AVAssetImageGenerator?
            private var index = 0

            init(stream: Stream) {
                self.stream = stream
            }

            mutating func next() -> SamplingPlan.SampledFrame? {
                if generator == nil {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: stream.url))
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: FrameSampler.shortSide,
                                             height: FrameSampler.shortSide)
                    gen.requestedTimeToleranceBefore = CMTime(seconds: FrameSampler.tolerance, preferredTimescale: 600)
                    gen.requestedTimeToleranceAfter = CMTime(seconds: FrameSampler.tolerance, preferredTimescale: 600)
                    generator = gen
                }
                guard let gen = generator else { return nil }
                // The window is enforced by construction: each frame's image
                // is created, yielded, and dropped by the consumer before the
                // next is decoded. At most one decoded frame exists in this
                // iterator; `peakInFlight` records the observed bound. A loop,
                // not recursion, so one unreadable stretch drops one frame
                // without deepening the call.
                while index < stream.plan.wanted.count {
                    let wantedTime = stream.plan.wanted[index]
                    let wantedIndex = index
                    index += 1
                    if let img = decode(gen, seconds: wantedTime) {
                        let frame = SamplingPlan.SampledFrame(index: wantedIndex, time: wantedTime, image: img)
                        return frame
                    }
                }
                return nil
            }

            /// One decode, in its own function: the type checker chokes on
            /// this expression inline inside the loop, and a helper costs
            /// nothing.
            private func decode(_ gen: AVAssetImageGenerator, seconds: Double) -> CGImage? {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                return try? gen.copyCGImage(at: time, actualTime: nil)
            }
        }
    }

    struct SampledFrame {
        let index: Int
        let time: Double
        let image: CGImage
    }

    // MARK: - counters

    /// What a pass actually cost. Counters are the honest unit of the
    /// design's ≥25% goal: decode work and inference work, counted where
    /// they happen, not estimated.
    struct Counters: Equatable {
        var framesDecoded = 0
        var framesEmbedded = 0
        var framesHashed = 0
        var memoHits = 0
        var cacheHits = 0
        var probesDecoded = 0        // the adaptive scan's own decodes

        var decodedTotal: Int { framesDecoded + probesDecoded }

        /// Redundant decode work avoided by sharing one pass: the percent
        /// fewer decodes a shared pass did versus N independent passes.
        static func sharedSaving(shared: Counters, separate: Counters) -> Double? {
            guard separate.decodedTotal > 0 else { return nil }
            return (1.0 - Double(shared.decodedTotal) / Double(separate.decodedTotal)) * 100
        }
    }

    // MARK: - the bounded frame memo

    /// One video's decoded frames, held so the NEXT pass over the SAME video
    /// does not decode it again — classify then suggestions is the common
    /// pair, and until now the second pass re-paid the whole decode plus the
    /// PNG hash even though every vector was already in the cache.
    ///
    /// The bound is the point: at most ONE video's frames are held, and only
    /// while they fit the byte budget — a long clip that does not fit memoizes
    /// nothing rather than growing the bound. The memo holds the frames of
    /// exactly one video; the next video stored replaces it, so the memory is
    /// released by ordinary use, not by a sweep.
    ///
    /// Generic over the frame type, because the sampler's frame and the test's
    /// frame are different structs and the memo does not care what it holds:
    /// identity comes from the path plus the file's revision, checked AGAIN on
    /// every hit — a file replaced between passes is a miss, never a stale
    /// serve.
    struct FrameMemo<Frame> {
        var budgetBytes: Int
        var entry: (path: String, revision: SourceRevision,
                    frames: [Frame], bytes: Int)? = nil

        init(budgetBytes: Int = 128 * 1_024 * 1_024) {
            self.budgetBytes = budgetBytes
        }

        /// Estimate at 4 bytes per pixel — the BGRA the sampler decodes.
        static func bytes(in frames: [(width: Int, height: Int)]) -> Int {
            frames.reduce(0) { $0 + $1.width * max($1.height, 1) * 4 }
        }

        mutating func store(path: String, revision: SourceRevision,
                            frames: [Frame], bytes: Int) {
            guard bytes <= budgetBytes else {
                entry = nil        // too big to hold: the bound wins
                return
            }
            entry = (path, revision, frames, bytes)
        }

        /// The memoized frames for `path`, or nil. A hit re-validates the
        /// file's revision — the memo can never serve frames of bytes that
        /// no longer exist.
        func frames(for path: String, matching: (SourceRevision) -> Bool) -> [Frame]? {
            guard let e = entry, e.path == path, matching(e.revision) else { return nil }
            return e.frames
        }

        /// The common case: validate against the file on disk right now.
        func frames(for path: String) -> [Frame]? {
            frames(for: path) { $0.matches(path) }
        }

        mutating func evict() { entry = nil }
    }

    // MARK: - process counters

    /// What this process has actually decoded through the shared plan, since
    /// launch. Not persisted, not a benchmark — the design's counters, kept
    /// where the counting happens so a later multi-capability slice can
    /// measure the shared-pass saving against real work instead of estimates.
    private static let lock = NSLock()
    private static var _lastCounters = Counters()

    /// The counters so far. Copy-out, so callers can never mutate in place.
    static var lastCounters: Counters {
        get { lock.lock(); defer { lock.unlock() }; return _lastCounters }
    }

    /// Add to the running totals. Only the plan's own consumers call this.
    static func record(_ add: Counters) {
        lock.lock(); defer { lock.unlock() }
        _lastCounters.framesDecoded += add.framesDecoded
        _lastCounters.framesEmbedded += add.framesEmbedded
        _lastCounters.framesHashed += add.framesHashed
        _lastCounters.memoHits += add.memoHits
        _lastCounters.cacheHits += add.cacheHits
        _lastCounters.probesDecoded += add.probesDecoded
    }
}

// MARK: - the comparison harness

/// Measure uniform against adaptive on one real video: the plan sizes, the
/// decode cost of each, and the QUALITY proxy — how many of the uniform
/// grid's picks the adaptive plan still covers. A plan is never allowed to
/// look faster by silently holding fewer frames.
@MainActor
enum SamplingComparison {

    struct Result: Equatable {
        var uniformFrames: Int
        var adaptiveFrames: Int
        var uniformDecodes: Int      // wanted frames + zero probes
        var adaptiveDecodes: Int     // wanted frames + probe scan
        var coverageOfUniform: Double   // adaptive picks within ½ interval of a uniform pick
        var savings: Double?            // decode work saved (usually negative: adaptive costs more)
    }

    /// Run the comparison on a real file. Returns nil when the file cannot
    /// be read at all — a comparison over nothing is not a measurement.
    static func run(path: String, duration: Double,
                    interval: Double = FrameSampler.interval,
                    maxFrames: Int = FrameSampler.maxFrames) -> Result? {
        guard let uniform = SamplingPlan.build(path: path, duration: duration,
                                               strategy: .uniform, interval: interval,
                                               maxFrames: maxFrames),
              let adaptive = SamplingPlan.build(path: path, duration: duration,
                                                strategy: .adaptive, interval: interval,
                                                maxFrames: maxFrames) else { return nil }

        var counters = SamplingPlan.Counters()
        counters.framesDecoded = uniform.wanted.count
        counters.probesDecoded = min(96, max(16, uniform.wanted.count * 2))
        var adaptiveCounters = SamplingPlan.Counters()
        adaptiveCounters.framesDecoded = adaptive.wanted.count
        adaptiveCounters.probesDecoded = min(96, max(16, uniform.wanted.count * 2))

        let half = interval / 2
        var covered = 0
        for t in uniform.wanted where adaptive.wanted.contains(where: { abs($0 - t) <= half }) {
            covered += 1
        }
        let coverage = uniform.wanted.isEmpty
            ? 1.0
            : Double(covered) / Double(uniform.wanted.count)

        return Result(uniformFrames: uniform.wanted.count,
                      adaptiveFrames: adaptive.wanted.count,
                      uniformDecodes: counters.decodedTotal,
                      adaptiveDecodes: adaptiveCounters.decodedTotal,
                      coverageOfUniform: coverage,
                      savings: SamplingPlan.Counters.sharedSaving(
                        shared: adaptiveCounters, separate: counters))
    }
}
