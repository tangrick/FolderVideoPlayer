import Foundation
import CryptoKit

/// The frozen evaluation corpus: a manifest of consented media, a labelling
/// rubric, deterministic splits, and the metrics that grade a run against
/// human labels.
///
/// T01's contract (design §8/§9): reproducible splits, an annotation rubric,
/// and baseline cold/warm latency/quality numbers — reusable by every later
/// task. Quality truth is HUMAN labels, never agreement with the previous
/// engine (design §9). Thresholds are NOT frozen here: the design reserves
/// their acceptance for the maintainer, so until then every quality
/// acceptance is UNVERIFIED and this file only supplies the honest numbers.
///
/// Everything here is pure arithmetic on plain data — no video is opened, no
/// model is loaded, no library is touched — except `Benchmark`, which drives
/// the REAL engine over whatever videos the caller hands it and measures what
/// actually happened.
enum EvalCorpus {

    // MARK: - the annotation rubric

    /// How a human decides a label. Frozen as data so two annotators (or one
    /// annotator and their future self) answer the same question. The first
    /// pass grades the Safe/NSFW decision — the only label the app currently
    /// elicits — under the same two-way choice the review UI offers.
    enum Rubric {

        /// The question the annotator answers, in order, and what each answer
        /// means. Deliberately written as sentences: a rubric that fits in a
        /// table cell is a rubric nobody follows at the margins.
        static let questions: [(rule: String, means: String)] = [
            ("Does any frame show content that is plainly not safe for work?",
             "NSFW — regardless of runtime, context or artistic intent"),
            ("Otherwise, does the video contain suggestive content a viewer could reasonably not want opened in public?",
             "NSFW — the label protects the viewer's context, not the creator's intent"),
            ("Otherwise",
             "Safe — including documentary, medical, artistic and news footage"),
        ]

        /// What the annotator records per video: the label and the seconds
        /// into the video that decided it, so a disagreement can be resolved
        /// against evidence rather than memory.
        struct Annotation: Codable, Equatable {
            var key: String              // share-relative tag key of the video
            var label: NsfwLabel
            /// Seconds into the video of the frames the decision turned on.
            var evidence: [Double] = []
            /// Optional free text: why, or what was ambiguous.
            var note: String = ""
            /// When the annotation was made (epoch seconds).
            var at: Double = 0
        }
    }

    // MARK: - the corpus manifest

    /// One video in the corpus. Manifests are written by hand (consented
    /// media only) and read by everything; `key` is the same share-relative
    /// key the tags and the analysis store use, so an annotated video's
    /// records line up with its library row.
    struct Entry: Codable, Equatable {
        var key: String
        /// Cohort tags: "short", "long", "rotated", "vfr", "no-audio",
        /// "corrupt", "nas", "identity:<name>" — anything the corpus wants
        /// counted. The named cohorts are what the design's completion
        /// evidence requires the corpus to include.
        var cohorts: [String] = []
        /// Group this video belongs to for splitting. Two encodes of the same
        /// recording are one group; the design's rule is that a split is
        /// never broken by near-duplicates.
        var group: String
        /// The human label, once annotated. Absent = unannotated = not graded.
        var annotation: Rubric.Annotation? = nil
    }

    /// The manifest itself: every consented video, with its cohort, group and
    /// annotation. Codable, so a corpus is a file under version control.
    struct Manifest: Codable, Equatable {
        var version: Int = 1
        /// When this manifest was frozen — not when it was last edited. A
        /// threshold may only be tuned against a frozen test split, so the
        /// date is part of the record.
        var frozenAt: Double = 0
        var entries: [Entry] = []

        func entry(_ key: String) -> Entry? {
            entries.first { $0.key == key }
        }

        /// Videos in a named cohort.
        func cohort(_ name: String) -> [Entry] {
            entries.filter { $0.cohorts.contains(name) }
        }

        /// Distinct groups, sorted — the unit splits are made over.
        var groups: [String] {
            Array(Set(entries.map { $0.group })).sorted()
        }
    }

    // MARK: - deterministic splits

    /// Training / tuning / test splits. Disjoint BY GROUP, not by video: two
    /// near-duplicate encodes of one recording land in the same split, so a
    /// model can never be graded on something its training data already
    /// showed it (design §9).
    ///
    /// Deterministic twice over: groups are sorted before assignment, and the
    /// round-robin starts from a fixed offset derived from SHA-256 of the
    /// corpus itself — adding, removing or reordering entries changes the
    /// assignment only by changing the corpus, never by the order a caller
    /// happens to enumerate in.
    struct Splits: Equatable {
        var training: [String] = []   // video keys
        var tuning: [String] = []
        var test: [String] = []

        static func == (a: Splits, b: Splits) -> Bool {
            a.training == b.training && a.tuning == b.tuning && a.test == b.test
        }
    }

    /// Split a manifest into the three disjoint splits, by group. The ratio
    /// walks the sorted groups so each split receives whole groups; with
    /// fewer than three groups nothing can be held out while training on the
    /// rest, so everything lands in training — "nothing frozen to grade
    /// against" is stated rather than faked.
    static func split(_ manifest: Manifest,
                      training: Double = 0.6, tuning: Double = 0.2, test: Double = 0.2) -> Splits {
        var out = Splits()
        let groups = manifest.groups
        guard groups.count >= 3 else {
            out.training = manifest.entries.map { $0.key }.sorted()
            return out
        }

        // Fixed rotation from the corpus's own digest: same corpus, same
        // rotation, whichever way the entries were listed.
        var hasher = SHA256()
        for group in groups { hasher.update(data: Data(group.utf8)) }
        hasher.update(data: Data("\(manifest.entries.count)".utf8))
        let digest = hasher.finalize()
        let first = digest.withUnsafeBytes { $0.load(as: UInt8.self) }
        let rotation = Int(first) % groups.count

        // Budgets in whole groups; the test split is allocated first because
        // it is the one that must never be squeezed out by rounding.
        let wantTest = max(test > 0 ? 1 : 0, Int((Double(groups.count) * test).rounded(.down)))
        let wantTuning = max(tuning > 0 ? 1 : 0, Int((Double(groups.count) * tuning).rounded(.down)))

        for (offset, group) in groups.enumerated() {
            let keys = manifest.entries.filter { $0.group == group }.map { $0.key }.sorted()
            let position = (offset + rotation) % groups.count
            if position < wantTest {
                out.test += keys
            } else if position < wantTest + wantTuning {
                out.tuning += keys
            } else {
                out.training += keys
            }
        }
        return out
    }

    // MARK: - video-level metrics

    /// Confusion counts over VIDEO units — never frames (design §9: frames
    /// are not independent samples, and counting them inflates every N).
    struct Confusion: Equatable {
        var truePositive = 0        // human NSFW, machine NSFW
        var falsePositive = 0       // human Safe, machine NSFW
        var trueNegative = 0        // human Safe, machine Safe
        var falseNegative = 0       // human NSFW, machine Safe
        var abstentions = 0         // the engine declined to speak

        var graded: Int { truePositive + falsePositive + trueNegative + falseNegative }

        /// Precision among displayed (non-abstaining) NSFW suggestions.
        var precision: Double? {
            let displayed = truePositive + falsePositive
            guard displayed > 0 else { return nil }
            return Double(truePositive) / Double(displayed)
        }

        /// Recall over graded videos the machine spoke on.
        var recall: Double? {
            let positives = truePositive + falseNegative
            guard positives > 0 else { return nil }
            return Double(truePositive) / Double(positives)
        }

        /// Fraction of graded videos the machine declined to label.
        var abstentionRate: Double? {
            let total = graded + abstentions
            guard total > 0 else { return nil }
            return Double(abstentions) / Double(total)
        }

        /// Of the NSFW videos the machine DID label, how many the top-3
        /// evidence ranking surfaced — where the runner supplies it. Nil until
        /// a runner that measured it fills it in.
        var top3Hit: Double? = nil
    }

    /// Grade machine predictions against human labels over the test split.
    ///
    /// `prediction(key:)` returns the machine's verdict, or nil to record an
    /// abstention (the design counts "hiding all suggestions" as a failure,
    /// so abstaining is measured, never forgiven by omission). The machine's
    /// label comes from ITS OWN threshold; this function never re-tunes it.
    static func grade(_ manifest: Manifest,
                      keys: [String],
                      threshold: Double = 0.5,
                      prediction: (String) -> Double?) -> Confusion {
        var out = Confusion()
        for key in keys {
            guard let entry = manifest.entry(key), let human = entry.annotation else { continue }
            guard let score = prediction(key) else {
                out.abstentions += 1
                continue
            }
            let humanNSFW = human.label == .nsfw
            let machineNSFW = score >= threshold
            switch (humanNSFW, machineNSFW) {
            case (true, true): out.truePositive += 1
            case (false, true): out.falsePositive += 1
            case (false, false): out.trueNegative += 1
            case (true, false): out.falseNegative += 1
            }
        }
        return out
    }

    // MARK: - the benchmark runner

    /// One measured run of the real engine over real videos.
    struct Measurement: Codable, Equatable {
        var key: String
        var coldSeconds: Double          // first pass (cold model, cold cache)
        var warmSeconds: Double?         // second pass over the same video
        var framesEmbedded: Int = 0
        var cacheHits: Int = 0
        var verdict: Double? = nil       // the machine's video score, if any
        var failed: Bool = false
    }

    /// A whole benchmark's results: what ran, on what, and what it cost.
    struct Benchmark: Codable, Equatable {
        var measuredAt: Double = 0
        /// Which binary/artifact the vectors came from — the installed space
        /// digest when one is stamped, the legacy slug otherwise.
        var spaceKey: String = ""
        var measurements: [Measurement] = []

        /// Nearest-rank wall-time percentiles over the runs that completed,
        /// cold and warm — no interpolation, so a percentile is always a
        /// measurement that actually happened.
        func percentile(_ p: Double, warm: Bool = false) -> Double? {
            var values: [Double] = []
            for m in measurements {
                if m.failed { continue }
                if warm {
                    if let w = m.warmSeconds { values.append(w) }
                } else {
                    values.append(m.coldSeconds)
                }
            }
            values.sort()
            guard !values.isEmpty else { return nil }
            let scaled = (p / 100.0) * Double(values.count - 1)
            let idx = min(values.count - 1, max(0, Int(scaled.rounded())))
            return values[idx]
        }
    }

    /// Drive the REAL engine over the given videos and measure what actually
    /// happened: cold and warm wall time, frames embedded, cache hits, and
    /// the machine's verdict per video.
    ///
    /// This is the runner every later task reuses. It reads the machine's
    /// answer from the SAME store the app writes — no parallel pipeline, no
    /// synthetic scores. A video the engine could not read is `failed`, not
    /// dropped: the design's integrity gates are about what actually happens,
    /// and a benchmark that silently drops failures lies by omission.
    @MainActor
    static func measure(keys: [String], paths: [String]) async -> Benchmark {
        var out = Benchmark()
        out.measuredAt = Date().timeIntervalSince1970
        out.spaceKey = EmbeddingCache.cacheKey(root: Paths.support)

        let fm = FileManager.default
        let store = AnalysisStore()
        let engine = AnalysisEngine()

        for (key, path) in zip(keys, paths) {
            var m = Measurement(key: key, coldSeconds: 0)
            guard fm.fileExists(atPath: path) else {
                m.failed = true
                out.measurements.append(m)
                continue
            }
            let beforeVectors = Self.cachedVectorCount(root: Paths.support)

            var clock = Self.Clock()
            store.enqueue([path])
            await engine.run(store: store, paths: [path])
            m.coldSeconds = clock.read()

            // The record now says what actually happened.
            if let record = store.analysis(for: path), record.phase == .done,
               let verdict = record.prediction {
                m.verdict = verdict.score
                m.framesEmbedded = verdict.frames
            } else {
                m.failed = true
            }

            // Warm pass: same video again. Whatever the cache can serve is
            // work the second pass does not pay for — the difference between
            // coldSeconds and warmSeconds IS the cache's measured value.
            clock = Self.Clock()
            await engine.run(store: store, paths: [path])
            if let record = store.analysis(for: path), record.phase == .done {
                m.warmSeconds = clock.read()
                m.cacheHits = max(0, beforeVectors + m.framesEmbedded - Self.cachedVectorCount(root: Paths.support))
            }
            out.measurements.append(m)
        }
        return out
    }

    /// How many vector files exist under the current cache namespace — the
    /// denominator cache-hit arithmetic needs.
    private static func cachedVectorCount(root: String) -> Int {
        let frames = (root as NSString).appendingPathComponent("frames")
        let namespace = (frames as NSString).appendingPathComponent(
            EmbeddingCache.cacheKey(root: root))
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: namespace) else { return 0 }
        var count = 0
        for item in walker {
            if (item as? String)?.hasSuffix(".f32") == true { count += 1 }
        }
        return count
    }

    /// A wall clock that can be re-armed: one struct per measurement.
    struct Clock {
        let start = DispatchTime.now()
        func read() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        }
    }
}
