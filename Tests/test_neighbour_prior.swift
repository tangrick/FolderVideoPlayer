// The neighbour prior — what the videos shot AROUND one video say about a tag.
//
// This is a ranking term, not a candidate source, and every way of getting it
// subtly wrong still produces a plausible-looking list: a raw count that lets a
// four-hundred-file folder's blanket tag win everywhere, a single neighbour
// treated as a trend because share==1.0, a stat that failed read as a cluster
// of videos all shot at the epoch, an arbitrary forty of a batch-copied folder
// so the same video ranks differently on the next run, a hidden video quietly
// teaching the suggester.
//
// So each of those is pinned here, with the arithmetic written out rather than
// recomputed from the same constants the code uses — a test that calls
// `weight * share * saturate` back proves only that Swift multiplies.
//
// Pure: no FileManager, no cache tree, no model, no engine.py. Milliseconds.
//
// Run: Tests/run_neighbour_prior.sh

@testable import FVPModel
import Foundation

@main
struct NeighbourPriorTest {
    static func main() {
        var failures = 0

        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        func close(_ name: String, _ got: Double, _ want: Double,
                   _ tol: Double = 1e-9) {
            let ok = abs(got - want) <= tol
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }

        // A fixed clock so "same day" is not a function of when the suite runs.
        // 2026-03-10 12:00:00 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_772_107_200).timeIntervalSince1970
        let hour: Double = 3600

        /// Build a pool of `(key, when)` plus the tag table behind it.
        func pool(_ entries: [(String, Double, [String])])
            -> (dated: [(key: String, when: Double)], tags: (String) -> [String]) {
            var table: [String: [String]] = [:]
            var dated: [(key: String, when: Double)] = []
            for (key, when, tags) in entries {
                table[key] = tags
                dated.append((key, when))
            }
            return (dated, { table[$0] ?? [] })
        }

        print("— the no-opinion cases —")

        // 1. No neighbours at all: the regression gate for every existing user.
        //    An empty prior means `bonus(tag:)` is zero for everything, so
        //    TagSuggester's key is byte-for-byte today's ranking.
        do {
            let p = pool([("me", noon, [])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            check("no neighbours → empty prior", prior.isEmpty)
            close("no neighbours → zero bonus", prior.bonus(tag: "Iceland"), 0)
            checkEqual("no neighbours → count 0", prior.neighbours, 0)
        }

        // 2. A failed stat is 0, and a run of them must not read as a cluster
        //    of videos all shot at the epoch.
        do {
            let p = pool([("a", 0, ["Iceland"]), ("b", 0, ["Iceland"]),
                          ("c", 0, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: 0, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            check("date == 0 → empty prior", prior.isEmpty)
        }

        // 3. Neighbours whose own stat failed are skipped, not matched at zero.
        do {
            let p = pool([("a", 0, ["Iceland"]), ("b", 0, ["Iceland"]),
                          ("c", noon + hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            check("undated neighbours skipped", prior.isEmpty,
                  "one real neighbour is below minNeighbours")
        }

        // 4. One neighbour is a coincidence, not a neighbourhood.
        do {
            let p = pool([("a", noon + hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            check("a single neighbour → empty prior", prior.isEmpty)
        }

        // 5. A video never supports itself.
        do {
            let p = pool([("me", noon, ["Iceland"]),
                          ("a", noon + hour, ["Iceland"]),
                          ("b", noon + 2 * hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("self excluded from the pool", prior.neighbours, 2)
            checkEqual("self excluded from support", prior.support["Iceland"], 2)
        }

        print("\n— the arithmetic —")

        // 6. Full bonus: three of three neighbours agree.
        //    share = 3/3 = 1, saturate = min(1, 3/3) = 1 → weight.
        do {
            let p = pool([("a", noon + hour, ["Iceland"]),
                          ("b", noon + 2 * hour, ["Iceland"]),
                          ("c", noon - hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("three neighbours counted", prior.neighbours, 3)
            close("3 of 3 → the full weight", prior.bonus(tag: "Iceland"), 0.0033)
        }

        // 7. Two supporters of two: share 1, saturate 2/3 → 0.0033 * 2/3.
        //    (0.0033 is `NeighbourPrior.weight` — a third of the SigLIP 2
        //    `vocabularyMargin`, where the old tower's third was 0.02.)
        do {
            let p = pool([("a", noon + hour, ["Iceland"]),
                          ("b", noon + 2 * hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            close("2 of 2 → two thirds of the weight",
                  prior.bonus(tag: "Iceland"), 0.0033 * 2.0 / 3.0)
        }

        // 8. One supporter among three: share 1/3, saturate 1/3 → 0.0033/9.
        //    The case that matters — a lone tag in a busy neighbourhood is
        //    nearly nothing, which is what stops a stray tag propagating.
        do {
            let p = pool([("a", noon + hour, ["Iceland"]),
                          ("b", noon + 2 * hour, ["Dinner"]),
                          ("c", noon - hour, ["Dinner"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            close("1 of 3 → a ninth of the weight",
                  prior.bonus(tag: "Iceland"), 0.0033 / 9.0)
            close("2 of 3 → four ninths of the weight",
                  prior.bonus(tag: "Dinner"), 0.0033 * (2.0 / 3.0) * (2.0 / 3.0))
            check("the busier tag wins",
                  prior.bonus(tag: "Dinner") > prior.bonus(tag: "Iceland"))
        }

        // 9. Share, not raw count: 4 of 40 must lose to 3 of 3.
        //    This is the whole defence against a blanket-tagged folder — the
        //    version of this feature that counts supporters gets it backwards.
        do {
            var entries: [(String, Double, [String])] = []
            for i in 0..<40 {
                entries.append(("big\(i)", noon + Double(i) * 60,
                                i < 4 ? ["Blanket", "Rare"] : ["Blanket"]))
            }
            let p = pool(entries)
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("forty neighbours counted", prior.neighbours, 40)
            close("40 of 40 → the full weight", prior.bonus(tag: "Blanket"), 0.0033)
            // share 4/40 = 0.1, saturate min(1, 4/3) = 1 → 0.00033
            close("4 of 40 → a tenth of the weight", prior.bonus(tag: "Rare"), 0.00033)

            // and the comparison the design rests on
            let small = pool([("a", noon + hour, ["Tight"]),
                              ("b", noon + 2 * hour, ["Tight"]),
                              ("c", noon - hour, ["Tight"])])
            let tight = NeighbourPrior.measure(for: noon, dated: small.dated,
                                               tagsFor: small.tags, excluding: "me",
                                               calendar: utc)
            check("3 of 3 beats 4 of 40",
                  tight.bonus(tag: "Tight") > prior.bonus(tag: "Rare"))
        }

        // 10. A tag applied twice to one video counts once.
        do {
            let p = pool([("a", noon + hour, ["Iceland", "Iceland"]),
                          ("b", noon + 2 * hour, ["Dinner"]),
                          ("c", noon - hour, ["Dinner"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("a duplicated tag supports once", prior.support["Iceland"], 1)
        }

        print("\n— the window —")

        // 11. Outside ±6h and on another day: not a neighbour.
        do {
            let p = pool([("a", noon + 2 * hour, ["Iceland"]),
                          ("b", noon + 2 * hour + 60, ["Iceland"]),
                          ("far", noon + 72 * hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("a clip three days out is not a neighbour",
                       prior.neighbours, 2)
        }

        // 12. Same calendar day, further than the window: still a neighbour.
        //     A morning and an evening clip from one shoot are 10h apart.
        do {
            let p = pool([("morning", noon - 10 * hour, ["Iceland"]),
                          ("evening", noon + 11 * hour, ["Iceland"])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("same calendar day counts beyond the window",
                       prior.neighbours, 2)
        }

        // 13. The window is symmetric — before counts like after.
        do {
            let before = pool([("a", noon - hour, ["X"]), ("b", noon - 2 * hour, ["X"])])
            let after  = pool([("a", noon + hour, ["X"]), ("b", noon + 2 * hour, ["X"])])
            let p1 = NeighbourPrior.measure(for: noon, dated: before.dated,
                                            tagsFor: before.tags, excluding: "me",
                                            calendar: utc)
            let p2 = NeighbourPrior.measure(for: noon, dated: after.dated,
                                            tagsFor: after.tags, excluding: "me",
                                            calendar: utc)
            close("before and after weigh the same",
                  p1.bonus(tag: "X"), p2.bonus(tag: "X"))
        }

        print("\n— determinism and the cap —")

        // 14. The cap takes the NEAREST in time, and ties break by key, so the
        //     same video ranks the same way on the next run. A batch-copied
        //     folder is the case that produces identical gaps in bulk.
        do {
            var entries: [(String, Double, [String])] = []
            // 60 files all "created" in the same second — a restored backup.
            for i in 0..<60 {
                entries.append((String(format: "copy%03d", i), noon + 1,
                                i < 30 ? ["First"] : ["Second"]))
            }
            let p = pool(entries)
            let a = NeighbourPrior.measure(for: noon, dated: p.dated,
                                           tagsFor: p.tags, excluding: "me",
                                           calendar: utc)
            let shuffled = (dated: p.dated.shuffled(), tags: p.tags)
            let b = NeighbourPrior.measure(for: noon, dated: shuffled.dated,
                                           tagsFor: shuffled.tags, excluding: "me",
                                           calendar: utc)
            checkEqual("the pool is capped", a.neighbours, 40)
            check("pool order does not change the answer", a == b)
            // keys copy000…copy039 sort first: 30 First, 10 Second.
            checkEqual("the cap is the nearest, ties by key", a.support["First"], 30)
            checkEqual("…and the rest", a.support["Second"], 10)
        }

        // 15. A flattened neighbourhood is self-cancelling: when every
        //     neighbour carries the same tags, every tag gets the same bonus,
        //     so the ORDER — the only thing this affects — does not move.
        do {
            var entries: [(String, Double, [String])] = []
            for i in 0..<20 {
                entries.append(("f\(i)", noon + Double(i), ["A", "B", "C"]))
            }
            let p = pool(entries)
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            let values = ["A", "B", "C"].map { prior.bonus(tag: $0) }
            check("a blanket-tagged batch moves nothing relative",
                  values.allSatisfy { abs($0 - values[0]) < 1e-12 })
        }

        print("\n— the contract with the caller —")

        // 16. Hidden videos are excluded by the CALLER (Library.datedPool), so
        //     what this proves is that a pool without them genuinely has no
        //     trace of them: no phantom neighbour count, no support.
        do {
            let visible = pool([("a", noon + hour, ["Iceland"]),
                                ("b", noon + 2 * hour, ["Iceland"])])
            let withHidden = pool([("a", noon + hour, ["Iceland"]),
                                   ("b", noon + 2 * hour, ["Iceland"]),
                                   ("hidden", noon + 3 * hour, ["Secret"])])
            let clean = NeighbourPrior.measure(for: noon, dated: visible.dated,
                                               tagsFor: visible.tags, excluding: "me",
                                               calendar: utc)
            let dirty = NeighbourPrior.measure(for: noon, dated: withHidden.dated,
                                               tagsFor: withHidden.tags, excluding: "me",
                                               calendar: utc)
            check("a filtered pool carries no trace of the filtered video",
                  clean.bonus(tag: "Secret") == 0 && clean.neighbours == 2)
            check("…and an unfiltered one would have (the caller must filter)",
                  dirty.bonus(tag: "Secret") > 0,
                  "this is the reason Library.datedPool drops hidden keys")
        }

        // 17. Neighbours with no tags at all still count as neighbours — they
        //     are evidence AGAINST a tag being characteristic of the burst.
        do {
            let p = pool([("a", noon + hour, ["Iceland"]),
                          ("b", noon + 2 * hour, []),
                          ("c", noon - hour, []),
                          ("d", noon - 2 * hour, [])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            checkEqual("untagged neighbours are still neighbours", prior.neighbours, 4)
            close("1 of 4 → share a quarter, saturate a third",
                  prior.bonus(tag: "Iceland"), 0.0033 * 0.25 * (1.0 / 3.0))
        }

        // 18. A neighbourhood where NOBODY is tagged has an opinion about
        //     nothing — but still reports its size for the Why panel.
        do {
            let p = pool([("a", noon + hour, []), ("b", noon + 2 * hour, [])])
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            check("no tags anywhere → no bonuses", prior.bonus.isEmpty)
            checkEqual("…but the count survives for the Why panel",
                       prior.neighbours, 2)
        }

        // 19. The bonus can never reach the vocabulary floor, so it can never
        //     manufacture the appearance of a chip that cleared its bar. The
        //     ceiling is `weight`, a third of TagSuggester.vocabularyMargin.
        do {
            var entries: [(String, Double, [String])] = []
            for i in 0..<40 { entries.append(("m\(i)", noon + Double(i), ["Max"])) }
            let p = pool(entries)
            let prior = NeighbourPrior.measure(for: noon, dated: p.dated,
                                               tagsFor: p.tags, excluding: "me",
                                               calendar: utc)
            let ceiling = prior.bonus(tag: "Max")
            close("the bonus tops out at the weight", ceiling, 0.0033)
            check("…and the ceiling stays under the vocabulary margin",
                  ceiling < 0.01)
        }

        print("\n— the switch —")

        // 20. Off by default; environment beats the file; the file works.
        do {
            checkEqual("off with nothing set",
                       NeighbourPrior.enabled(environment: nil, override: [:]), false)
            checkEqual("on from the override file",
                       NeighbourPrior.enabled(environment: nil,
                                              override: ["neighbours": "on"]), true)
            checkEqual("the environment wins when it disagrees",
                       NeighbourPrior.enabled(environment: "off",
                                              override: ["neighbours": "on"]), false)
            checkEqual("the environment turns it on",
                       NeighbourPrior.enabled(environment: "on", override: [:]), true)
            checkEqual("an unrelated value is not 'on'",
                       NeighbourPrior.enabled(environment: nil,
                                              override: ["neighbours": "maybe"]), false)
        }

        print("")
        if failures == 0 {
            
// ---------------------------------------------------------------------------
// The wiring. TagSuggester gained a parameter; these pin what that parameter
// must NOT do, because the whole design rests on it being a tiebreak.

// An empty prior is what every existing parity fixture is ranked with, so it
// has to be exactly a no-op rather than approximately one.
do {
    let empty = NeighbourPrior()
    check("an empty prior is worth nothing", empty.bonus(tag: "Beach") == 0)
    check("...and knows it is empty", empty.isEmpty)
}

print("all neighbour prior checks pass")
        } else {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
