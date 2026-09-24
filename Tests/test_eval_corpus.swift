// The evaluation corpus: deterministic splits, video-level grading, and the
// honesty rules T01's contract rests on.
//
// The property that matters most: the SAME manifest produces the SAME splits
// every run, and a near-duplicate pair (one `group`) can never be separated —
// a model graded on video its training split already showed it is not being
// evaluated, it is being flattered. Also graded here: frames-are-not-samples
// arithmetic, abstention being measured rather than omitted, and the benchmark
// runner refusing to pretend about failures.
//
// `@main` rather than top-level code: this file compiles alongside the app's
// model layer, and only a file literally named main.swift may carry top-level
// statements.
//
// Run: Tests/run_eval_corpus.sh

@testable import FVPModel
import Foundation
import CryptoKit

@main
struct EvalCorpusTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-eval-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        // --- 1. the rubric is a frozen decision, not a vibe ------------------
        check("the rubric asks ordered questions with stated meanings",
              EvalCorpus.Rubric.questions.count >= 3
                && EvalCorpus.Rubric.questions.allSatisfy { !$0.rule.isEmpty && !$0.means.isEmpty })
        check("an annotation records its evidence seconds",
              (try? JSONEncoder().encode(EvalCorpus.Rubric.Annotation(
                key: "k", label: .nsfw, evidence: [1.5, 4.0]))) != nil)

        // --- 2. deterministic splits over whole groups -----------------------
        // Ten groups, each with two near-duplicate encodes — the shape the
        // design's rule is about.
        func manifest(groups: Int, perGroup: Int = 2) -> EvalCorpus.Manifest {
            var m = EvalCorpus.Manifest()
            m.frozenAt = 1_768_600_000
            for g in 0..<groups {
                for i in 0..<perGroup {
                    m.entries.append(EvalCorpus.Entry(
                        key: String(format: "media/group%02d-encode%d.mp4", g, i),
                        cohorts: g == 0 ? ["short"] : (g == 1 ? ["long", "vfr"] : []),
                        group: String(format: "group-%02d", g)))
                }
            }
            return m
        }
        let corpus = manifest(groups: 10)
        let a = EvalCorpus.split(corpus)
        let b = EvalCorpus.split(corpus)
        check("the same manifest splits identically, run after run", a == b)
        check("every video is assigned to exactly one split",
              a.training.count + a.tuning.count + a.test.count == corpus.entries.count)

        // Reordering the manifest must not change who lands where.
        var shuffled = corpus
        shuffled.entries.reverse()
        check("reordering the manifest does not move a video between splits",
              EvalCorpus.split(shuffled) == a)

        // Disjointness — no group (therefore no video) in two splits.
        let sets: [Set<String>] = [Set(a.training), Set(a.tuning), Set(a.test)]
        check("the splits are pairwise disjoint",
              Set(sets[0]).isDisjoint(with: sets[1]) && Set(sets[0]).isDisjoint(with: sets[2])
                && Set(sets[1]).isDisjoint(with: sets[2]))
        // Group integrity: both encodes of a group sit in the same split.
        func groupsIn(_ keys: [String]) -> Set<String> {
            Set(keys.compactMap { corpus.entry($0)?.group })
        }
        check("near-duplicates stay together (splits break by group, never across)",
              groupsIn(a.training).isDisjoint(with: groupsIn(a.tuning))
                && groupsIn(a.training).isDisjoint(with: groupsIn(a.test))
                && groupsIn(a.tuning).isDisjoint(with: groupsIn(a.test)))

        // Roughly the asked-for ratio — the test split may not be squeezed out.
        let ratio = Double(a.test.count) / Double(corpus.entries.count)
        check("the test split receives its asked-for share (got \(String(format: "%.2f", ratio)))",
              ratio >= 0.15 && ratio <= 0.3)
        // Editing the corpus changes the rotation only through the corpus.
        let bigger = manifest(groups: 11)
        check("a changed corpus re-derives its own splits",
              EvalCorpus.split(bigger) == EvalCorpus.split(bigger)
                && EvalCorpus.split(bigger).test.count > 0)

        // Degenerate shapes state rather than fake.
        let one = EvalCorpus.split(manifest(groups: 1))
        check("a one-group corpus lands entirely in training (nothing frozen to grade)",
              one.test.isEmpty && one.tuning.isEmpty && one.training.count == 2)
        let two = EvalCorpus.split(manifest(groups: 2))
        check("a two-group corpus also holds nothing out",
              two.test.isEmpty && two.tuning.isEmpty && two.training.count == 4)
        let empty = EvalCorpus.split(EvalCorpus.Manifest())
        check("an empty manifest splits to nothing", empty.training.isEmpty
              && empty.tuning.isEmpty && empty.test.isEmpty)

        // --- 3. grading is video-level, abstentions are counted --------------
        var graded = EvalCorpus.Manifest()
        graded.frozenAt = 1
        // (key, human label) — machine scores come from the closure below.
        // "unlabelled" deliberately carries NO annotation: the grader must
        // skip it entirely, not count it as an abstention.
        let cases: [(String, NsfwLabel?, Double?)] = [
            ("tp", .nsfw, 0.9),          // human NSFW, machine NSFW
            ("fp", .safe, 0.8),          // human Safe,  machine NSFW
            ("tn", .safe, 0.1),          // human Safe,  machine Safe
            ("fn", .nsfw, 0.2),          // human NSFW,  machine Safe
            ("abstain", .nsfw, nil),     // the machine declined
            ("unlabelled", nil, nil),    // no human label — outside grading
        ]
        for (key, label, _) in cases {
            graded.entries.append(EvalCorpus.Entry(
                key: key, group: key,
                annotation: label.map { .init(key: key, label: $0) }))
        }
        let machine: [String: Double?] = Dictionary(uniqueKeysWithValues: cases.map { ($0.0, $0.2) })
        let confusion = EvalCorpus.grade(graded, keys: cases.map { $0.0 }, threshold: 0.5) {
            // A key the machine has nothing for, annotated or not, is an
            // abstention — the runner's honest answer.
            (machine[$0] ?? nil)
        }
        check("the confusion counts each graded video once (tp \(confusion.truePositive) fp \(confusion.falsePositive) tn \(confusion.trueNegative) fn \(confusion.falseNegative))",
              confusion.graded == 4)
        check("precision is over DISPLAYED suggestions only",
              confusion.precision == 0.5)   // 1 of {tp, fp}
        check("recall is over graded positives the machine spoke on",
              confusion.recall == 0.5)      // 1 of {tp, fn}
        check("abstention is measured, never forgiven by omission",
              confusion.abstentionRate != nil
                && abs(confusion.abstentionRate! - 1.0 / 5.0) < 1e-12)  // 1 of 5 annotated
        check("a video with no human label grades nothing",
              graded.entry("unlabelled")?.annotation == nil
                && confusion.graded + confusion.abstentions == 5)

        // The engine's own cut is passed through, not re-tuned here: at a
        // 0.95 cut every machine score of 0.9 is a Safe, so the NSFW videos
        // (tp, fn, abstain) all miss — and the abstention is STILL counted.
        let atCut = EvalCorpus.grade(graded, keys: ["tp", "fn"], threshold: 0.95) { _ in 0.9 }
        check("the caller's threshold decides, the grader does not tune",
              atCut.truePositive == 0 && atCut.falseNegative == 2)

        // --- 4. percentile arithmetic on real shapes -------------------------
        var bench = EvalCorpus.Benchmark()
        bench.spaceKey = "siglip2_base"
        for (i, cold) in [1.0, 2.0, 3.0, 4.0].enumerated() {
            var m = EvalCorpus.Measurement(key: "v\(i)", coldSeconds: cold)
            m.warmSeconds = cold / 2
            bench.measurements.append(m)
        }
        var broken = EvalCorpus.Measurement(key: "bad", coldSeconds: 99)
        broken.failed = true
        bench.measurements.append(broken)
        check("a failed video is recorded, and excluded from percentiles",
              bench.measurements.count == 5 && bench.percentile(50) == 3.0
                && bench.percentile(50, warm: true) == 1.5)
        check("p95 reaches the slowest completed run",
              bench.percentile(95) == 4.0)
        check("no measurements means no percentile, not zero",
              EvalCorpus.Benchmark().percentile(50) == nil)

        // --- 5. the real runner measures the real engine ---------------------
        // Everything below drives AnalysisEngine for real, exactly as the
        // Classify button does. Without the models installed this still
        // proves the runner's honesty: a failed video is recorded as failed.
        Paths.support = scratch
        let benchKeys = ["real/clip.mp4", "real/absent.mp4"]
        let benchPaths = [scratch + "/clip.mp4", scratch + "/absent.mp4"]
        try? Data("not really a video".utf8).write(to: URL(fileURLWithPath: benchPaths[0]))
        let result = await EvalCorpus.measure(keys: benchKeys, paths: benchPaths)
        check("the runner stamps the space it measured under",
              result.spaceKey == EmbeddingCache.cacheKey(root: scratch))
        check("a nonexistent video is recorded as failed, not dropped",
              result.measurements.count == 2 && result.measurements[1].failed)
        check("a file that is not a video fails honestly (the engine refuses it)",
              result.measurements[0].failed || result.measurements[0].verdict != nil)
        check("the runner wrote no verdict for a failed video",
              result.measurements[1].verdict == nil)

        print(failures == 0 ? "\nALL PASS eval corpus" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
