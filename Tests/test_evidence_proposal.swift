// The evidence producer (T07, first half): per-frame scores become reviewable
// timed evidence, and a re-run says what happens to the run before it.
//
// The things worth proving, in the order this file proves them:
//
//   1. a run of sightings is ONE row, not one row per sampled frame;
//   2. the threshold is the only reason a frame is claimed, and what is below it
//      neither creates a claim nor extends one;
//   3. the gap rule joins a span across one missed sample and splits it across
//      two — and claims nothing about the frames nobody sampled;
//   4. a label that returns later is a second claim, not one long one;
//   5. every row carries the order, the model, the space and the revision it came
//      from, and arrives unanswered;
//   6. readings that cannot be reviewed (NaN, infinite, negative) are dropped
//      rather than repaired;
//   7. a pass records, a re-run replaces its OWN unanswered rows, and the list
//      never doubles;
//   8. what a human answered survives every re-run, along with another revision's
//      and another model's evidence — a producer cannot delete a verdict;
//   9. a pass cannot launder an answer in as a proposal, and cannot mix two
//      videos' scopes in one replacement.
//
// No model, no video, no network, no Xcode: the grouping rules are a pure
// function of the readings; the store is real SQLite in a temporary root.
//
//     sh Tests/run_evidence_proposal.sh

import Foundation

@main
struct EvidenceProposalHarness {

    static var failures = 0

    static func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("ok   \(what)")
        } else {
            failures += 1
            print("FAIL \(what)" + (detail.isEmpty ? "" : " — \(detail)"))
        }
    }

    // MARK: - fixtures

    static let video = "/library/trip/clip.mp4"
    static let other = "/library/trip/other.mp4"
    static let source = "siglip2-base-v1@r1"
    static let space = "siglip2-base-v1-768"
    static let revision = TimedEvidence.SourceRevision(bytes: 4_096, modifiedAt: 1_700_000_000)
    static let now: Double = 1_700_000_001

    static func reading(_ time: Double, _ scores: [String: Double]) -> FrameReading {
        FrameReading(time: time, scores: scores)
    }

    static func spans(_ readings: [FrameReading],
                      capability: TimedEvidence.Capability = .scenes,
                      path: String = video,
                      limits: EvidenceProposal.Limits = EvidenceProposal.Limits()) -> [TimedEvidence] {
        EvidenceProposal.spans(readings: readings,
                               capability: capability,
                               path: path,
                               source: source,
                               space: space,
                               revision: revision,
                               limits: limits,
                               now: now)
    }

    /// A shot sampled every five seconds — the spacing the gap rule reads.
    static var shot: [FrameReading] {
        [reading(0,  ["sunset": 0.91]),
         reading(5,  ["sunset": 0.88, "beach": 0.72]),
         reading(10, ["sunset": 0.62, "beach": 0.80]),
         reading(15, ["beach": 0.85]),
         reading(20, ["beach": 0.79]),
         reading(25, ["city": 0.55])]
    }

    // MARK: - main

    static func main() {
        let root = NSTemporaryDirectory() + "fvp-evidence-proposal-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // --- 1. a run of sightings is one row, not eighteen ---------------------

        let grouped = spans(shot)
        check("one run of sightings is one row, not one row per frame",
              grouped.count == 3,
              grouped.map { "\($0.label)@\($0.start)-\($0.end)" }.joined(separator: " "))

        if let sunset = grouped.first(where: { $0.label == "sunset" }) {
            check("the span starts at the first frame that showed it", sunset.start == 0, "\(sunset.start)")
            check("the span ends at the last frame that showed it, not at the end of the video",
                  sunset.end == 10, "\(sunset.end)")
            check("the reason says how much of the span was actually seen",
                  sunset.reason.contains("3 of 3"), sunset.reason)
            check("the reason carries a score a reviewer can check",
                  sunset.reason.contains("0.91"), sunset.reason)
        } else {
            check("the sunset span exists", false, "no sunset row at all")
        }
        check("no span claims time nothing was sampled in",
              grouped.allSatisfy { $0.end <= 25 }, grouped.map(\.end).description)

        if let beach = grouped.first(where: { $0.label == "beach" }) {
            check("a label continuing past another run keeps its own span",
                  beach.start == 5 && beach.end == 20, "\(beach.start)-\(beach.end)")
            check("confidence is the highest score in the span, not an average of them",
                  beach.confidence == 0.85, "\(beach.confidence ?? -1)")
        } else {
            check("the beach span exists", false, "no beach row at all")
        }

        // --- 2. the threshold is the only reason a frame is claimed -------------

        let quiet = spans([reading(0, ["sunset": 0.49]),
                           reading(5, ["sunset": 0.50]),
                           reading(10, ["sunset": 0.51])])
        check("a score below the threshold is not a claim", quiet.count == 1, "\(quiet.count)")
        check("a score AT the threshold is a claim, and the span starts there",
              quiet.first?.start == 5, "\(quiet.first?.start ?? -1)")
        check("what is below the threshold does not extend the span",
              quiet.first?.end == 10, "\(quiet.first?.end ?? -1)")
        check("a pass that sees nothing proposes nothing",
              spans([reading(0, ["sunset": 0.1]), reading(5, ["beach": 0.2])]).isEmpty)

        // --- 3. the gap rule, counted in MISSED SAMPLES -------------------------

        let joined = spans([reading(0,  ["sunset": 0.9]),
                            reading(5,  ["sunset": 0.9]),
                            reading(10, [:]),                 // the label is missing here
                            reading(15, ["sunset": 0.9]),
                            reading(20, ["sunset": 0.9])])
        check("one missed sample joins the span", joined.count == 1,
              joined.map { "\($0.start)-\($0.end)" }.joined(separator: " "))
        check("and the span reaches across the sample it did not see",
              joined.first?.start == 0 && joined.first?.end == 20,
              "\(joined.first?.start ?? -1)-\(joined.first?.end ?? -1)")

        let split = spans([reading(0,  ["sunset": 0.9]),
                           reading(5,  ["sunset": 0.9]),
                           reading(10, [:]),
                           reading(15, [:]),
                           reading(20, ["sunset": 0.9]),
                           reading(25, ["sunset": 0.9])])
        check("two missed samples split it", split.count == 2,
              split.map { "\($0.start)-\($0.end)" }.joined(separator: " "))

        var tight = EvidenceProposal.Limits()
        tight.maxMissedSamples = 0
        let tightSpans = spans([reading(0,  ["sunset": 0.9]),
                                reading(5,  ["sunset": 0.9]),
                                reading(10, [:]),
                                reading(15, ["sunset": 0.9])],
                               limits: tight)
        check("asking for no missed samples splits what the default joins",
              tightSpans.count == 2, "\(tightSpans.count)")

        check("the missed-sample count is what the rule compares",
              EvidenceProposal.missedSamples(from: 0, to: 10, spacing: 5) == 1
                && EvidenceProposal.missedSamples(from: 0, to: 15, spacing: 5) == 2,
              "\(EvidenceProposal.missedSamples(from: 0, to: 10, spacing: 5)) "
                + "\(EvidenceProposal.missedSamples(from: 0, to: 15, spacing: 5))")
        check("and a spacing a hair under the plan's interval does not double-count",
              EvidenceProposal.missedSamples(from: 0, to: 10, spacing: 4.9999) == 1,
              "\(EvidenceProposal.missedSamples(from: 0, to: 10, spacing: 4.9999))")
        check("two sightings in the same instant are not a missed sample",
              EvidenceProposal.missedSamples(from: 7, to: 7, spacing: 5) == 0)

        var strict = EvidenceProposal.Limits()
        strict.minimumSamples = 2
        let once = spans([reading(0, ["sunset": 0.9])])
        check("a claim seen once is NOT dropped by default", once.count == 1)
        check("and is dropped when the caller asks for a repeat sighting",
              spans([reading(0, ["sunset": 0.9])], limits: strict).isEmpty)
        check("a single sighting's reason says it is one",
              once.first?.reason.contains("1 of 1") == true, once.first?.reason ?? "")

        // --- 4. a label that comes back is a second claim -----------------------

        let returning = spans([reading(0,  ["city": 0.8]),
                               reading(5,  ["city": 0.8]),
                               reading(30, ["city": 0.8]),
                               reading(35, ["city": 0.8])])
        check("a label that disappears and returns is two spans, not one long claim",
              returning.count == 2, returning.map { "\($0.start)-\($0.end)" }.joined(separator: " "))
        check("and neither span covers the time in between",
              returning.first?.end == 5 && returning.last?.start == 30,
              "\(returning.first?.end ?? -1) then \(returning.last?.start ?? -1)")

        // --- 5. order, provenance, and the shape of a proposal ------------------

        let ordered = spans([reading(20, ["beach": 0.9]),
                             reading(0,  ["sunset": 0.9]),
                             reading(10, ["alpha": 0.9])])
        check("the review list is in the order the video plays",
              ordered.map(\.start) == [0, 10, 20], ordered.map(\.start).description)
        let sameSpan = spans([reading(0, ["b": 0.9, "a": 0.9])])
        check("two labels over the same span have a stable order",
              sameSpan.map(\.label) == ["a", "b"], sameSpan.map(\.label).description)

        if let row = ordered.first {
            check("the proposal names the video it is about", row.path == video, row.path)
            check("and the model that made the claim", row.source == source, row.source)
            check("and the space that score is only comparable within", row.space == space, row.space)
            check("and the revision of the bytes it was read from", row.sourceRevision == revision)
            check("and it arrives unanswered", row.decision == .pending, row.decision.rawValue)
            check("with the time it was proposed", row.proposedAt == now, "\(row.proposedAt)")
            check("and the capability it was proposed for", row.capability == .scenes, row.capability.rawValue)
        }
        check("the capability is the caller's, not guessed from the label",
              spans([reading(0, ["sunset": 0.9])], capability: .tags).first?.capability == .tags)

        // --- 6. readings that cannot be reviewed are dropped --------------------

        let broken = spans([reading(.nan,      ["sunset": 0.9]),
                            reading(.infinity, ["sunset": 0.9]),
                            reading(-5,        ["sunset": 0.9]),
                            reading(10,        ["sunset": .nan]),
                            reading(15,        ["sunset": 0.9])])
        check("an unplayable time is dropped rather than claimed", broken.count == 1, "\(broken.count)")
        check("and the surviving claim is the real one",
              broken.first?.start == 15 && broken.first?.end == 15,
              "\(broken.first?.start ?? -1)-\(broken.first?.end ?? -1)")
        check("a score that is not a number is not a claim",
              spans([reading(0, ["sunset": .nan]), reading(5, ["sunset": .infinity])]).isEmpty)
        check("no readings, no proposals", spans([]).isEmpty)
        check("a proposal about no video is not made",
              spans([reading(0, ["sunset": 0.9])], path: "").isEmpty)
        check("readings arriving out of order are put in order",
              spans([reading(10, ["sunset": 0.9]), reading(0, ["sunset": 0.9])]).first?.start == 0)
        let spacing = EvidenceProposal.sampleSpacing([reading(0, [:]), reading(4, [:]), reading(8, [:])])
        check("the gap rule reads the spacing the plan actually achieved", spacing == 4, "\(spacing)")

        // --- 7. a pass records, and a re-run replaces its own claims -----------

        guard let store = try? EvidenceStore(root: root, profile: "producer") else {
            check("the producer's store opens", false, "could not open a store in \(root)")
            exit(1)
        }

        guard let first = try? EvidenceProposal.record(grouped, in: store, for: video,
                                                       capability: .scenes, source: source,
                                                       space: space, revision: revision) else {
            check("a pass records its proposals", false, "record threw")
            exit(1)
        }
        check("a pass writes its proposals", first.written.count == 3, "\(first.written.count)")
        check("and withdraws nothing on its first run", first.withdrawn == 0, "\(first.withdrawn)")

        let stored = (try? store.count(capability: .scenes)) ?? -1
        check("the store holds them", stored == 3, "\(stored)")
        let labels = ((try? store.evidence(for: video, capability: .scenes)) ?? []).map(\.label)
        check("they come back in the order a reviewer walks the video",
              labels == ["sunset", "beach", "city"], labels.description)

        let again = try? EvidenceProposal.record(grouped, in: store, for: video,
                                                 capability: .scenes, source: source,
                                                 space: space, revision: revision)
        check("a re-run withdraws what the previous run proposed",
              again?.withdrawn == 3, "\(again?.withdrawn ?? -1)")
        let afterRerun = (try? store.count(capability: .scenes)) ?? -1
        check("so the review list does not double", afterRerun == 3, "\(afterRerun)")

        // --- 8. what a human answered is not a producer's to withdraw ----------

        let rows = (try? store.evidence(for: video, capability: .scenes)) ?? []
        let beachID = rows.first { $0.label == "beach" }?.id
        if let beachID {
            let accepted = try? store.setDecision(.accepted, id: beachID)
            check("a proposal can be accepted where it lies", accepted?.decision == .accepted)

            let third = try? EvidenceProposal.record(grouped, in: store, for: video,
                                                     capability: .scenes, source: source,
                                                     space: space, revision: revision)
            check("a re-run withdraws only what is still unanswered",
                  third?.withdrawn == 2, "\(third?.withdrawn ?? -1)")

            let after = (try? store.evidence(for: video, capability: .scenes)) ?? []
            check("and what a human answered is still there, with its answer",
                  after.contains { $0.id == beachID && $0.decision == .accepted },
                  after.map { "\($0.label):\($0.decision.rawValue)" }.joined(separator: " "))
            check("even though the pass proposed that label again",
                  after.filter { $0.label == "beach" }.count == 2,
                  "\(after.filter { $0.label == "beach" }.count) rows")
            let decided = try? store.evidence(for: video, capability: .scenes)
            check("a decided row keeps its decision on every later read",
                  decided?.first { $0.id == beachID }?.decision == .accepted)

            let withdrawnPass = try? EvidenceProposal.record([], in: store, for: video,
                                                             capability: .scenes, source: source,
                                                             space: space, revision: revision)
            check("a pass that sees nothing withdraws its own unanswered claims",
                  withdrawnPass?.withdrawn == 3, "\(withdrawnPass?.withdrawn ?? -1)")
            check("and writes nothing", withdrawnPass?.written.isEmpty == true)
            let survived = (try? store.evidence(for: video, capability: .scenes)) ?? []
            check("but the answered row is not in that producer's reach",
                  survived.contains { $0.id == beachID })
            let training = (try? store.trainingEvidence(limit: 10)) ?? []
            check("a human's answer is training data",
                  training.contains { $0.id == beachID })
            check("a proposal nobody answered is not",
                  training.allSatisfy { $0.decision.forTraining },
                  training.map(\.decision.rawValue).joined(separator: " "))
        } else {
            check("a proposal can be accepted where it lies", false, "no beach row to answer")
        }

        // --- 9. another revision, another model: not this producer's to withdraw

        let stale = TimedEvidence.SourceRevision(bytes: 9_999, modifiedAt: 1_600_000_000)
        let staleRows = spans(shot).map { row -> TimedEvidence in
            var copy = row
            copy.sourceRevision = stale
            return copy
        }
        _ = try? store.replacePending(staleRows)
        let withStale = (try? store.count(capability: .scenes)) ?? -1
        // Four: the one row a human answered (which the empty pass could not take
        // back) plus this revision's three proposals.
        check("a stale revision's evidence is stored too", withStale == 4, "\(withStale)")

        _ = try? EvidenceProposal.record(grouped, in: store, for: video, capability: .scenes,
                                         source: source, space: space, revision: revision)
        let afterCurrent = (try? store.count(capability: .scenes)) ?? -1
        check("re-running the current revision leaves the stale one's rows alone",
              afterCurrent == withStale + 3, "\(afterCurrent)")

        let otherSpaceRows = spans(shot).map { row -> TimedEvidence in
            var copy = row
            copy.space = "other-space-512"
            return copy
        }
        _ = try? EvidenceProposal.record(otherSpaceRows, in: store, for: video,
                                         capability: .scenes, source: source,
                                         space: "other-space-512", revision: revision)
        let afterOtherSpace = (try? store.count(capability: .scenes)) ?? -1
        check("a different embedding space's evidence is somebody else's claim",
              afterOtherSpace == afterCurrent + 3, "\(afterOtherSpace)")

        _ = try? EvidenceProposal.record(spans(shot, capability: .tags), in: store, for: video,
                                         capability: .tags, source: source, space: space,
                                         revision: revision)
        let scenesNow = (try? store.count(capability: .scenes)) ?? -1
        check("the same pass for another capability does not disturb the scene rows",
              scenesNow == afterOtherSpace, "\(scenesNow)")

        // --- 10. a pass cannot launder an answer in, or mix two videos ---------

        var mixed = spans(shot)
        if var copy = mixed.first {
            copy.path = other
            mixed.append(copy)
        }
        let beforeMixed = (try? store.count()) ?? -1
        do {
            _ = try store.replacePending(mixed)
            check("a batch spanning two videos is refused", false, "it was accepted")
        } catch EvidenceError.mixedProposalScope {
            let after = (try? store.count()) ?? -2
            check("a batch spanning two videos is refused, writing nothing", after == beforeMixed,
                  "\(beforeMixed) then \(after)")
        } catch {
            check("a batch spanning two videos is refused", false, "\(error)")
        }

        var decidedRow = spans(shot)
        if var copy = decidedRow.first {
            copy.decision = .accepted
            decidedRow = [copy]
        }
        do {
            _ = try store.replacePending(decidedRow)
            check("an already-answered row cannot be handed in as a proposal", false, "it was accepted")
        } catch EvidenceError.proposalMustBePending(let decision) {
            check("an already-answered row cannot be handed in as a proposal",
                  decision == .accepted, decision.rawValue)
        } catch {
            check("an already-answered row cannot be handed in as a proposal", false, "\(error)")
        }

        let scopeCount = (try? store.count()) ?? -1
        let nothingToReplace = try? store.replacePending([])
        check("replacing with an empty batch writes and withdraws nothing",
              nothingToReplace?.withdrawn == 0 && nothingToReplace?.written.isEmpty == true,
              "\(nothingToReplace?.withdrawn ?? -1) withdrawn")
        check("and the store is exactly as it was", (try? store.count()) == scopeCount,
              "\(scopeCount) then \((try? store.count()) ?? -2)")

        if var stray = spans(shot).first {
            stray.capability = .tags          // built as a scene, recorded as a tag
            do {
                _ = try EvidenceProposal.record([stray], in: store, for: video, capability: .scenes,
                                                source: source, space: space, revision: revision)
                check("a pass whose rows name another capability is refused", false, "it was accepted")
            } catch EvidenceError.mixedProposalScope {
                check("a pass whose rows name another capability is refused", true)
            } catch {
                check("a pass whose rows name another capability is refused", false, "\(error)")
            }
        }

        let allTraining = (try? store.trainingEvidence(limit: 100)) ?? []
        check("nothing a pass writes is a human label by itself",
              allTraining.allSatisfy { $0.decision.forTraining },
              allTraining.map(\.decision.rawValue).joined(separator: " "))

        store.close()

        print("")
        if failures == 0 {
            print("ALL PASS evidence proposal")
        } else {
            print("\(failures) FAILURE(S) evidence proposal")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
