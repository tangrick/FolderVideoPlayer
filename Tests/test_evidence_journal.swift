// The review surface's model half (T11, first half): what a suggestion pass saw
// becomes the spans a review row shows, and the one click that answers a chip
// answers its evidence too.
//
// The things worth proving, in the order this file proves them:
//
//   1. a pass's tags do not clobber each other — one call writes ALL of them,
//      because the store's replacement is scoped to the whole pass;
//   2. the span's confidence is the chip's own margin, not an invented 1.0, and
//      the span is judged by the bar that tag was actually offered against;
//   3. a tag whose source owns no per-frame times (a library prototype, a face)
//      produces NO rows — it is still offered and still judgeable, it simply has
//      no WHEN, and the row must not invent one;
//   4. the reason a reviewer reads counts the frames within the span, and counts
//      only frames the plan actually looked at;
//   5. answering a chip writes the same verdict onto its claim: accept, reject,
//      and ignore are each carried through as themselves;
//   6. a re-run replaces its own unanswered rows and leaves an answered row
//      exactly where the human left it — the app cannot quietly erase an answer;
//   7. staleness is decided against the file as it is NOW: changed bytes and a
//      deleted file both read as stale, because unknown is not unchanged;
//   8. nothing here throws at a caller — an unopenable store or a vanished video
//      lands in `problem` and the pass keeps its suggestions.
//
// No model, no video decode, no network, no Xcode: the readings are hand-made and
// the store is real SQLite in a temporary root.
//
//     sh Tests/run_evidence_journal.sh

@testable import FVPModel
import Foundation

@main
struct EvidenceJournalHarness {

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

    static let root = NSTemporaryDirectory() + "fvp-journal-" + UUID().uuidString
    static let profile = "journal-test"
    static let video = root + "/library/clip.mp4"
    static let other = root + "/library/other.mp4"
    /// Used only by the wiring section: the video whose chips are answered
    /// through the real store, kept apart from `other` so the isolation check
    /// above still means what it says.
    static let wire = root + "/library/wire.mp4"
    static let model = "siglip2-base-v1@r1"
    static let space = "siglip2-base-v1-768"

    static func write(_ path: String, bytes: Int) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes))
    }

    static func append(_ path: String, bytes: Int) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(repeating: 9, count: bytes))
        try? handle.close()
    }

    static func truncate(_ path: String, bytes: Int) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        try? handle.truncate(atOffset: UInt64(bytes))
        try? handle.close()
    }

    static func setModified(_ path: String, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// One pass's sightings: every tag judged against its own bar, over the same
    /// five sampled frames at 0/5/10/15/20 seconds.
    static func pass(_ byTag: [String: (bar: Double, hits: [(Double, Double)])])
        -> EvidenceProposal.TagSightings {
        var sights = EvidenceProposal.TagSightings(sampled: [0, 5, 10, 15, 20])
        for (label, sighting) in byTag {
            sights.byTag[label] = EvidenceProposal.TagSighting(
                bar: sighting.bar, hits: sighting.hits.map { ($0.0, $0.1) })
        }
        return sights
    }

    static func span(_ spans: [EvidenceJournal.Span], _ label: String) -> EvidenceJournal.Span? {
        spans.first { $0.label == label }
    }

    static func main() {
        write(video, bytes: 4_096)
        write(other, bytes: 4_096)

        let journal = EvidenceJournal(root: root)
        journal.reload(profile: profile)

        // --- 1. one pass writes every tag it offered -------------------------
        let first = pass([
            "sunset": (0.02, [(0, 0.03), (5, 0.06)]),
            "cruise": (0.02, [(15, 0.041)]),
            "from-my-library": (0, []),
        ])
        journal.record(path: video, model: model, space: space, first)
        check("a clean pass reports no problem", journal.problem == nil,
              journal.problem ?? "")

        var spans = journal.spans(for: video)
        check("both tags with times were written in one pass", spans.count == 2,
              "\(spans.count) rows: \(spans.map { $0.label })")
        check("the tags keep their own identities",
              Set(spans.map { $0.label }) == ["sunset", "cruise"],
              "\(Set(spans.map { $0.label }))")

        // --- 2. confidence is the chip's own margin, and the bar is its own ---
        if let sunset = span(spans, "sunset") {
            check("the span covers the frames that agreed", sunset.start == 0 && sunset.end == 5,
                  "\(sunset.start)–\(sunset.end)")
            check("confidence is the strongest margin in the span, not an invented 1.0",
                  sunset.confidence == 0.06, "\(sunset.confidence ?? -1)")
            check("a fresh claim is unanswered", sunset.decision == .pending,
                  "\(sunset.decision)")
            check("a claim about the current bytes is not stale", !sunset.isStale)
        } else {
            check("the sunset span exists", false)
        }

        // --- 3. a tag with no per-frame times invents none --------------------
        check("a library-sourced tag produced no timed row",
              span(spans, "from-my-library") == nil)
        check("the store holds exactly the claims that had times", spans.count == 2)

        // --- 4. the reason counts frames inside the span ----------------------
        if let sunset = span(spans, "sunset") {
            check("the reason counts the frames within the span",
                  sunset.reason == "seen in 2 of 2 sampled frames here, highest score 0.06",
                  sunset.reason)
        }

        // --- 5. answering a chip carries its verdict onto its claim -----------
        journal.decide(.accepted, for: video, label: "sunset")
        spans = journal.spans(for: video)
        check("accepting the chip accepted its claim",
              span(spans, "sunset")?.decision == .accepted,
              "\(String(describing: span(spans, "sunset")?.decision))")
        check("another tag's claim was not touched by that",
              span(spans, "cruise")?.decision == .pending)

        journal.decide(.rejected, for: video, label: "cruise")
        check("rejecting the chip rejected its claim",
              span(journal.spans(for: video), "cruise")?.decision == .rejected)

        journal.decide(.ignored, for: video, label: "cruise")
        check("ignore is carried through as ignore, not as a negative",
              span(journal.spans(for: video), "cruise")?.decision == .ignored,
              "\(String(describing: span(journal.spans(for: video), "cruise")?.decision))")

        // --- 6. a re-run replaces its own rows, never an answer ---------------
        // `cruise` was answered above, so its row is not the producer's to
        // withdraw. `beach` was never answered, so it is.
        let beach = pass(["beach": (0.02, [(10, 0.03)])])
        journal.record(path: video, model: model, space: space, beach)
        check("a never-answered tag is written", span(journal.spans(for: video), "beach") != nil)

        let second = pass([
            "cruise": (0.02, [(15, 0.05)]),
            "beach": (0.02, [(10, 0.031)]),
        ])
        journal.record(path: video, model: model, space: space, second)
        spans = journal.spans(for: video)

        check("a re-run that no longer sees a tag leaves the answered row alone",
              span(spans, "sunset")?.decision == .accepted)
        check("an ignored row is an answer too, and also survives",
              spans.contains { $0.label == "cruise" && $0.decision == .ignored },
              "\(spans.filter { $0.label == "cruise" }.map { $0.decision })")
        check("...while the re-run's own claim arrives as the new unanswered one",
              spans.filter { $0.label == "cruise" && $0.decision == .pending }.count == 1,
              "\(spans.filter { $0.label == "cruise" }.map { $0.decision })")
        check("a pending row is replaced, not doubled",
              spans.filter { $0.label == "beach" }.count == 1,
              "\(spans.filter { $0.label == "beach" }.count) beach rows")
        check("the surviving row is the new pass's claim",
              span(spans, "beach")?.reason.hasSuffix("highest score 0.03") ?? false,
              span(spans, "beach")?.reason ?? "")
        check("the review list grew only by the answer it kept",
              spans.count == 4, "\(spans.count) rows")

        // --- 7. staleness is decided against the file as it is NOW ------------
        // A revision is bytes AND a modification time: a rewrite of the same
        // length is a different file, and the app must not call it the same one.
        let whenRead = modified(video)
        append(video, bytes: 10)
        check("changed bytes make every claim about them stale",
              journal.spans(for: video).allSatisfy { $0.isStale })
        truncate(video, bytes: 4_096)
        check("the same length again is still stale — the time changed too",
              journal.spans(for: video).allSatisfy { $0.isStale })
        if let whenRead { setModified(video, whenRead) }
        check("the same bytes at the same time are current again",
              journal.spans(for: video).allSatisfy { !$0.isStale })
        check("...and a stale flag cannot be cached into permanence",
              journal.spans(for: video).first?.isStale == false)

        // --- 8. nothing throws at a caller -----------------------------------
        let gone = root + "/library/gone.mp4"
        write(gone, bytes: 128)
        journal.record(path: gone, model: model, space: space,
                       pass(["sunset": (0.02, [(0, 0.03)])]))
        check("evidence was recorded for the second video",
              journal.spans(for: gone).count == 1, "\(journal.spans(for: gone).count)")
        try? FileManager.default.removeItem(atPath: gone)
        check("a video that is gone makes its claims stale rather than current",
              journal.spans(for: gone).allSatisfy { $0.isStale })
        let before = journal.spans(for: gone).count
        journal.record(path: gone, model: model, space: space,
                       pass(["sunset": (0.02, [(0, 0.03)])]))
        check("a pass over a vanished video reports why and writes nothing",
              journal.problem != nil && journal.spans(for: gone).count == before,
              journal.problem ?? "no problem reported")

        // An unopenable store is reported, not thrown: the pass keeps its chips.
        let blocked = root + "/blocked"
        write(blocked, bytes: 8)
        let broken = EvidenceJournal(root: blocked)
        broken.reload(profile: profile)
        check("a store that cannot be opened reports a problem instead of throwing",
              broken.problem != nil, broken.problem ?? "no problem reported")
        check("...and reads as no evidence rather than as an error",
              broken.spans(for: video).isEmpty)

        // No profile, no evidence, no crash.
        let bare = EvidenceJournal(root: root)
        bare.reload(profile: "")
        check("an empty profile has no evidence and no problem",
              bare.spans(for: video).isEmpty && bare.problem == nil)

        // --- readings: the material itself ------------------------------------
        let readings = EvidenceProposal.readings(
            label: "sunset", sampled: [0, 5, 10], agreed: [(0, 0.03), (20, 0.07)])
        check("readings cover every sampled frame", readings.count == 4,
              "\(readings.count)")
        check("a frame nobody sampled but the tag agreed with is still a reading",
              readings.contains { $0.time == 20 })
        check("an unsampled frame carries the margin it agreed by",
              readings.first { $0.time == 20 }?.scores["sunset"] == 0.07)
        check("a frame the tag did not agree with carries no score for it",
              readings.first { $0.time == 5 }?.scores.isEmpty ?? false)
        let scored = readings.filter { $0.scores["sunset"] != nil }
        check("exactly the agreeing frames are scored", scored.count == 2,
              "\(scored.map { $0.time })")

        let duplicates = EvidenceProposal.readings(
            label: "sunset", sampled: [0], agreed: [(0, 0.03), (0, 0.09)])
        check("the same frame agreeing twice keeps its strongest margin",
              duplicates.first?.scores["sunset"] == 0.09,
              "\(String(describing: duplicates.first?.scores["sunset"]))")

        let nan = EvidenceProposal.readings(
            label: "sunset", sampled: [0], agreed: [(Double.nan, 0.5), (5, Double.infinity)])
        check("a reading that cannot be shown is dropped rather than repaired",
              nan.count == 1, "\(nan.map { $0.time })")

        // --- 9. the app's wiring: answering a chip cannot miss its evidence ----
        // Driven through the REAL SuggestionStore rather than by calling the
        // journal directly, because the claim is not that the journal CAN be told
        // a verdict — it is that no call site can answer a chip without telling
        // it. The hook lives on the store, so that promise is testable here.
        Paths.support = root
        Paths.activeProfile = profile
        write(wire, bytes: 2_048)
        let chips = SuggestionStore(profile: profile)
        chips.onVerdict = { path, tag, verdict in
            journal.decide(verdict, for: path, label: tag)
        }
        func chip(_ tag: String) -> TagSuggestion {
            TagSuggestion(tag: tag, confidence: 0.06, frames: 2, source: "zeroshot")
        }
        chips.record(wire, suggestions: [chip("sunset")], model: "m",
                     framesSeen: 5, paired: false, facesDetected: 0)
        journal.record(path: wire, model: model, space: space,
                       pass(["sunset": (0.02, [(0, 0.03)])]))

        chips.decide(wire, tag: "sunset", verdict: .rejected)
        check("rejecting a chip through the store rejected its evidence",
              journal.spans(for: wire, label: "sunset").allSatisfy { $0.decision == .rejected },
              "\(journal.spans(for: wire, label: "sunset").map { $0.decision })")

        chips.undecide(wire, tag: "sunset")
        check("taking the answer back returns the evidence to unanswered",
              journal.spans(for: wire, label: "sunset").allSatisfy { $0.decision == .pending },
              "\(journal.spans(for: wire, label: "sunset").map { $0.decision })")

        // Dismiss All: one tag was answered, one was never touched, and the
        // evidence has to be able to say which was which afterwards.
        chips.record(wire, suggestions: [chip("sunset"), chip("beach")], model: "m",
                     framesSeen: 5, paired: false, facesDetected: 0)
        journal.record(path: wire, model: model, space: space,
                       pass(["sunset": (0.02, [(0, 0.03)]),
                             "beach": (0.02, [(10, 0.03)])]))
        chips.decide(wire, tag: "sunset", verdict: .accepted)
        chips.dismissRest(wire)
        check("Dismiss All ignored the tag it actually dismissed",
              journal.spans(for: wire, label: "beach").allSatisfy { $0.decision == .ignored },
              "\(journal.spans(for: wire, label: "beach").map { $0.decision })")
        check("...and left the tag the user answered alone",
              journal.spans(for: wire, label: "sunset").allSatisfy { $0.decision == .accepted },
              "\(journal.spans(for: wire, label: "sunset").map { $0.decision })")

        // --- isolation --------------------------------------------------------
        check("another video's evidence is untouched by all of this",
              journal.spans(for: other).isEmpty)

        try? FileManager.default.removeItem(atPath: root)

        if failures == 0 {
            print("ALL PASS evidence journal")
            exit(0)
        } else {
            print("FAILURES: \(failures)")
            exit(1)
        }
    }
}
