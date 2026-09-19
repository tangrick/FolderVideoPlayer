import Foundation

/// One sampled frame's reading: what the CURRENT prompt table said about that
/// frame, in the current embedding space (design §6, step 6).
///
/// Scores are keyed by label and are comparable only within one embedding space
/// and one prompt table — which is why every row the producer writes carries
/// both. A score without its model is a number nobody can check.
struct FrameReading: Equatable {
    var time: Double
    var scores: [String: Double]

    init(time: Double, scores: [String: Double]) {
        self.time = time
        self.scores = scores
    }
}

/// Turns per-frame scores into timed evidence — the producer half of T07.
///
/// Two decisions live here because they are the same decision seen twice: what
/// is a claim worth a human's time (`spans`), and what a re-run does to the
/// claims the run before it made (`record`).
enum EvidenceProposal {

    /// The shape of the review list. Each number is a way to make the list
    /// useless: too low a threshold fills it with noise, one row per sample
    /// buries the real findings, and a gap rule that is too generous invents a
    /// span that nothing was sampled in.
    struct Limits {
        /// A label must score at least this on a frame to be claimed there.
        var threshold: Double = 0.5

        /// How many SAMPLED FRAMES may be missing between two sightings of one
        /// label before they are two spans rather than one. Counting missed
        /// samples rather than seconds is what makes the rule mean the same thing
        /// for a long video (samples seconds apart) as for a short one, and what
        /// lets it survive the plan's spacing drifting slightly.
        ///
        /// Nothing here claims the label was absent from the frames nobody
        /// sampled: a span is only ever as long as the frames that showed it.
        var maxMissedSamples: Int = 1

        /// A label seen once is still a label (a scene can be one shot), so this
        /// is deliberately 1 rather than a number invented for precision that
        /// has not been measured (T01's corpus is what would justify raising it).
        var minimumSamples: Int = 1
    }

    /// The spans a pass should propose.
    ///
    /// A run of sightings becomes ONE row, because a reviewer looking at a
    /// 90-second shot does not want eighteen rows saying the same thing, and a
    /// list of near-duplicates is how a review step gets abandoned.
    ///
    /// A span never claims more than was sampled: `start` and `end` are the first
    /// and last frames that actually showed the label, so a gap in the middle
    /// shows up as a longer span rather than as coverage nobody checked, and the
    /// end of the video is never implied.
    ///
    /// Readings whose time is not a real, non-negative number are dropped rather
    /// than repaired: a NaN in this list would sort unpredictably and put a
    /// claim at a time nobody can seek to.
    static func spans(readings: [FrameReading],
                      capability: TimedEvidence.Capability,
                      path: String,
                      source: String,
                      space: String,
                      revision: TimedEvidence.SourceRevision?,
                      limits: Limits = Limits(),
                      now: Double = Date().timeIntervalSince1970) -> [TimedEvidence] {

        let samples = readings
            .filter { $0.time.isFinite && $0.time >= 0 }
            .sorted { $0.time < $1.time }
        guard !samples.isEmpty, !path.isEmpty else { return [] }

        let spacing = sampleSpacing(samples)
        var labels = Set<String>()
        for sample in samples {
            for (label, score) in sample.scores where score.isFinite && score >= limits.threshold {
                labels.insert(label)
            }
        }

        var proposals: [TimedEvidence] = []
        for label in labels {
            let sightings = samples.indices.filter { index in
                guard let score = samples[index].scores[label] else { return false }
                return score.isFinite && score >= limits.threshold
            }

            var run: [Int] = []
            func closeRun() {
                defer { run = [] }
                guard run.count >= limits.minimumSamples,
                      let first = run.first, let last = run.last else { return }
                let start = samples[first].time
                let end = samples[last].time
                let sampled = samples.filter { $0.time >= start && $0.time <= end }
                let highest = run.compactMap { samples[$0].scores[label] }.max() ?? 0
                proposals.append(TimedEvidence(
                    capability: capability,
                    path: path,
                    start: start,
                    end: end,
                    label: label,
                    reason: "seen in \(run.count) of \(sampled.count) sampled frames here, "
                        + "highest score \(String(format: "%.2f", highest))",
                    source: source,
                    space: space,
                    confidence: highest,
                    proposedAt: now,
                    decision: .pending,
                    sourceRevision: revision))
            }

            for index in sightings {
                if let previous = run.last,
                   spacing > 0,
                   missedSamples(from: samples[previous].time,
                                 to: samples[index].time,
                                 spacing: spacing) > limits.maxMissedSamples {
                    closeRun()
                }
                run.append(index)
            }
            closeRun()
        }

        // The order a reviewer walks the video in, with a stable tiebreak so two
        // labels over the same span do not swap places between runs.
        return proposals.sorted { ($0.start, $0.label) < ($1.start, $1.label) }
    }

    /// Record a pass: withdraw this producer's own UNANSWERED rows for the same
    /// scope, then write the new ones — both inside the store's transaction, so
    /// a crash leaves either the old list or the new one.
    ///
    /// Running a pass twice must not double the review list. That is the whole
    /// reason a producer identifies itself (`source`, `space`, `revision`): the
    /// store withdraws exactly the rows this producer left unanswered, and
    /// nothing else — not a row a human answered, not a stale revision's
    /// evidence, not another model's.
    ///
    /// An empty result is still a result: `discardPending` clears what the last
    /// run proposed, because a label this run cannot see is no longer a claim
    /// this producer is making.
    ///
    /// Nothing here writes a tag, and that is deliberate. Accepting a proposal is
    /// a human action on one row (design §6), and the design's rule that a
    /// rejection must never remove a tag a person applied is only enforceable if
    /// this step cannot touch tags at all: it can only write rows.
    @discardableResult
    static func record(_ proposals: [TimedEvidence],
                       in store: EvidenceRepository,
                       for path: String,
                       capability: TimedEvidence.Capability,
                       source: String,
                       space: String,
                       revision: TimedEvidence.SourceRevision?) throws -> (withdrawn: Int, written: [Int64]) {
        guard !proposals.isEmpty else {
            let withdrawn = try store.discardPending(for: path,
                                                     capability: capability,
                                                     source: source,
                                                     space: space,
                                                     revision: revision)
            return (withdrawn, [])
        }
        // Both branches must mean the same scope. The rows carry it when there
        // are rows; the arguments carry it when there are none — so a caller
        // whose rows belong to a different video, capability, model or revision
        // has a bug, and saying so here is better than replacing one scope while
        // naming another.
        guard proposals.allSatisfy({ $0.path == path
                                     && $0.capability == capability
                                     && $0.source == source
                                     && $0.space == space
                                     && $0.sourceRevision == revision }) else {
            throw EvidenceError.mixedProposalScope
        }
        return try store.replacePending(proposals)
    }

    /// What one suggestion pass saw, per tag — the material a timed claim is
    /// built from. Produced by `CoreMLClassifier.sightings(path:tags:)` from the
    /// same rule and the same bar that offered the chip.
    struct TagSightings {
        /// Every frame the plan looked at, in seconds. A frame nobody sampled is
        /// counted as neither seen nor missed, which is what keeps a span's
        /// "N of M sampled frames" honest.
        var sampled: [Double] = []
        var byTag: [String: TagSighting] = [:]
    }

    /// One tag's sightings: the bar it was judged against, and the frames that
    /// cleared it with the margin they cleared it by.
    struct TagSighting {
        var bar: Double
        var hits: [(at: Double, margin: Double)]
    }

    /// The readings a chip's sightings make: one reading per SAMPLED frame, with
    /// the margin recorded on the frames that agreed with the tag.
    ///
    /// `sampled` is what the plan actually looked at, not a guess at coverage, so
    /// a span's "N of M sampled frames here" counts a frame nobody looked at as
    /// neither seen nor missed. A frame the tag agreed with is scored by the
    /// MARGIN it cleared the bar by — the same number the chip was offered on —
    /// so the span's confidence is the chip's own and not an invented 1.0.
    ///
    /// Callers set `Limits.threshold` to the bar that tag was actually judged
    /// against (per source: a vocabulary margin, a head's cut, a prototype's
    /// bar). Judging evidence by a different bar than the one that offered the
    /// chip would make the evidence a claim about something else.
    static func readings(label: String,
                         sampled: [Double],
                         agreed: [(at: Double, margin: Double)]) -> [FrameReading] {
        var margins: [Double: Double] = [:]
        for hit in agreed where hit.at.isFinite && hit.at >= 0 && hit.margin.isFinite {
            margins[hit.at] = max(margins[hit.at] ?? -.infinity, hit.margin)
        }
        var times = Set(sampled.filter { $0.isFinite && $0 >= 0 })
        times.formUnion(margins.keys)
        return times.sorted().map { time in
            guard let margin = margins[time] else { return FrameReading(time: time, scores: [:]) }
            return FrameReading(time: time, scores: [label: margin])
        }
    }

    /// The spacing the plan actually achieved, as the median gap between
    /// consecutive samples. A fixed number would mean something different for a
    /// long video (samples seconds apart) than for a short one (samples closer
    /// than the interval), and the gap rule is only meaningful relative to it.
    ///
    /// Returns 0 when there is nothing to measure — fewer than two samples, or
    /// every gap zero — which DISABLES the gap rule: with no spacing to compare
    /// against, every sighting of a label belongs to one span. That is the
    /// honest reading of a degenerate plan, and it is why `spans` checks
    /// `spacing > 0` rather than dividing by it.
    static func sampleSpacing(_ samples: [FrameReading]) -> Double {
        guard samples.count > 1 else { return 0 }
        let deltas = zip(samples.dropFirst(), samples).map { $0.time - $1.time }.sorted()
        guard !deltas.isEmpty else { return 0 }
        let middle = deltas.count / 2
        return deltas.count % 2 == 1
            ? deltas[middle]
            : (deltas[middle - 1] + deltas[middle]) / 2
    }

    /// How many sampled frames sit between two sightings, counted from the gap
    /// and the spacing. Rounded rather than truncated, so a spacing that came out
    /// a hair under the plan's own interval still counts as one missed sample
    /// instead of two — an off-by-one here silently cuts a shot in half.
    static func missedSamples(from: Double, to: Double, spacing: Double) -> Int {
        guard spacing > 0 else { return 0 }
        return max(0, Int(((to - from) / spacing).rounded()) - 1)
    }
}
