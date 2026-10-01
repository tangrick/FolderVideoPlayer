// Triage mode, phase 1 — the model layer:
//
//   1. the queue: what belongs in it, how it moves, and that the answer is
//      asked again when the cursor arrives, not once at the start;
//   2. the strip: numbers that never move, quick tags that are chosen once;
//   3. the session against a real Library and SuggestionStore: what each key
//      records (`accepted`, `rejected`, `ignored`, or nothing), the "nothing
//      to tag" mark, and an undo that puts back tags, verdicts and the mark;
//   4. the stored mark: old files still decode, it does not make a video look
//      analysed, it follows a move, and it survives a write.
//
// Run: Tests/run_triage.sh

@testable import FVPModel
import Foundation

/// Plain values behind a `TriageReader`, changeable mid-session.
final class World {
    var tags: [String: [String]] = [:]
    var pending: Set<String> = []
    var reviewed: Set<String> = []
    var hidden: Set<String> = []
    var broken: Set<String> = []
    var reader: TriageReader {
        TriageReader(tags: { self.tags[$0] ?? [] },
                     hasPendingSuggestions: { self.pending.contains($0) },
                     isReviewed: { self.reviewed.contains($0) },
                     isHidden: { self.hidden.contains($0) },
                     isUnavailable: { self.broken.contains($0) })
    }
}

@main
struct TriageTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        func sugg(_ tag: String, _ confidence: Double) -> TagSuggestion {
            TagSuggestion(tag: tag, confidence: confidence, frames: 3)
        }

        // --- 1. the queue -------------------------------------------------------------

        let world = World()
        let four = starTag(4)
        let list = ["/v/a", "/v/b", "/v/c", "/v/d", "/v/e"]
        world.tags = ["/v/b": ["Beach"], "/v/c": [four]]
        world.reviewed = ["/v/d"]
        world.hidden = ["/v/e"]

        check("a video with only a star rating still needs tags",
              world.reader.needsTags("/v/c"))
        check("a video with a real tag does not", !world.reader.needsTags("/v/b"))
        check("a person's name is a tag", {
            world.tags["/v/p"] = ["Anna"]; defer { world.tags["/v/p"] = nil }
            return !world.reader.needsTags("/v/p")
        }())

        var q = TriageQueue(playlist: list, filter: .needsTags, reader: world.reader)
        check("needs-tags shows the untagged and star-only, not the tagged, reviewed or hidden",
              q.current == "/v/a" && q.left(world.reader) == 2, "\(q.current ?? "nil") \(q.left(world.reader))")
        q.done(world.reader)
        check("done moves to the next video that belongs", q.current == "/v/c")
        check("...and remembers it was finished", q.finished == ["/v/a"] && q.total == 5)
        q.done(world.reader)
        check("done on the last one ends the queue", q.current == nil && q.isFinished)

        // The answer is asked when the cursor arrives.
        world.tags = [:]; world.reviewed = []; world.hidden = []
        q = TriageQueue(playlist: list, filter: .needsTags, reader: world.reader)
        world.tags["/v/b"] = ["Kite"]           // tagged on another device meanwhile
        world.hidden.insert("/v/c")             // hidden meanwhile
        world.broken.insert("/v/d")             // would not open
        q.done(world.reader)
        check("a video tagged, hidden or broken meanwhile is passed over",
              q.current == "/v/e", "\(q.current ?? "nil")")
        world.tags = [:]; world.hidden = []; world.broken = []

        // Skip, revisit.
        q = TriageQueue(playlist: ["/v/a", "/v/b", "/v/c"], filter: .needsTags, reader: world.reader)
        q.skip(world.reader)
        check("skip leaves it for later and moves on", q.current == "/v/b" && q.skipped == ["/v/a"])
        q.done(world.reader)
        q.skip(world.reader)
        check("with only skipped videos left the queue says so",
              q.current == nil && q.onlySkippedLeft && !q.isFinished && q.skipped == ["/v/a", "/v/c"])
        world.tags["/v/c"] = ["Tent"]
        q.revisitSkipped(world.reader)
        check("going through the skipped ones again drops any tagged meanwhile",
              q.current == "/v/a" && q.skipped.isEmpty)
        q.done(world.reader)
        check("...and ends when they are done", q.isFinished)
        world.tags = [:]

        // Back.
        q = TriageQueue(playlist: ["/v/a", "/v/b", "/v/c"], filter: .needsTags, reader: world.reader)
        check("back at the start does nothing", !q.back() && q.current == "/v/a" && !q.canGoBack)
        q.done(world.reader)
        q.skip(world.reader)
        check("back returns to a skipped video and un-skips it",
              q.back() && q.current == "/v/b" && q.skipped.isEmpty)
        check("...and the video it left comes back in its turn", {
            var copy = q
            copy.done(world.reader)
            return copy.current == "/v/c"
        }())
        check("back again returns to a finished video and un-finishes it",
              q.back() && q.current == "/v/a" && q.finished.isEmpty)
        q.done(world.reader)
        q.done(world.reader)
        check("forward after backing walks the same order", q.current == "/v/c")

        // Focus (what an undo does).
        q = TriageQueue(playlist: ["/v/a", "/v/b", "/v/c"], filter: .needsTags, reader: world.reader)
        q.done(world.reader)
        q.done(world.reader)
        q.focus("/v/a")
        check("focus puts a finished video back in view", q.current == "/v/a" && !q.finished.contains("/v/a"))
        check("...without losing the one it left", {
            var copy = q
            copy.done(world.reader)
            return copy.current == "/v/c"
        }())

        // The other filters.
        world.tags = ["/v/a": [four], "/v/b": ["Beach"]]
        world.pending = ["/v/b", "/v/c"]
        check("unrated shows what has no stars",
              TriageQueue(playlist: ["/v/a", "/v/b", "/v/c"], filter: .unrated, reader: world.reader).current == "/v/b")
        let review = TriageQueue(playlist: ["/v/a", "/v/b", "/v/c"], filter: .hasSuggestions, reader: world.reader)
        check("has-suggestions shows videos with something to answer, tagged or not",
              review.current == "/v/b" && review.left(world.reader) == 2)
        check("everything shows everything not hidden",
              TriageQueue(playlist: ["/v/a", "/v/b", "/v/c"], filter: .everything, reader: world.reader)
                  .left(world.reader) == 3)
        check("a playlist that repeats a path shows it once",
              TriageQueue(playlist: ["/v/a", "/v/a", "/v/b"], filter: .everything, reader: world.reader).total == 2)
        check("an empty playlist is finished at once",
              TriageQueue(playlist: [], filter: .needsTags, reader: world.reader).isFinished)

        // --- 2. the strip -------------------------------------------------------------

        let quick = ["Beach", "Kite", "Tent", "Boat", "Sand", "Sea"]
        let opened = TriageStrip.open(
            suggestions: [sugg("Sea", 0.03), sugg("Wave", 0.06), sugg("Beach", 0.05), sugg("Surf", 0.04),
                          sugg("Foam", 0.02), sugg("Gull", 0.01), sugg("Pier", 0.01)],
            carried: ["tent"], quick: quick)
        check("suggestions come first, strongest first, at most five",
              opened.entries.prefix(5).map(\.tag) == ["Wave", "Beach", "Surf", "Sea", "Foam"]
                && opened.entries.prefix(5).allSatisfy { $0.kind == .suggestion },
              "\(opened.entries.map(\.tag))")
        check("quick tags fill the rest up to nine, without repeating a suggestion or a carried tag",
              opened.entries.map(\.tag) == ["Wave", "Beach", "Surf", "Sea", "Foam", "Kite", "Boat", "Sand"],
              "\(opened.entries.map(\.tag))")
        check("key 1 is the first entry and key 9 is nothing when there are only eight",
              opened.entry(forKey: 1)?.tag == "Wave" && opened.entry(forKey: 9) == nil
                && opened.entry(forKey: 0) == nil && opened.entry(forKey: 10) == nil)
        check("equal strengths keep the order they arrived in", {
            let s = TriageStrip.open(suggestions: [sugg("B", 0.05), sugg("A", 0.05)], carried: [], quick: [])
            return s.entries.map(\.tag) == ["B", "A"]
        }())

        var late = TriageStrip.open(suggestions: [], carried: [], quick: ["Beach", "Kite"])
        let before = late.entries
        late.appendLate([sugg("Wave", 0.05), sugg("kite", 0.09), sugg("Surf", 0.04)], carried: ["foam"])
        check("late suggestions go on the end and nothing already there moves",
              Array(late.entries.prefix(2)) == before
                && late.entries.map(\.tag) == ["Beach", "Kite", "Wave", "Surf"],
              "\(late.entries.map(\.tag))")
        check("...so the key a chip answered to a moment ago still answers to it",
              late.entry(forKey: 1)?.tag == "Beach" && late.entry(forKey: 3)?.tag == "Wave")
        var crowded = TriageStrip.open(suggestions: [], carried: [], quick: (1...9).map { "Q\($0)" })
        crowded.appendLate([sugg("Late", 0.05)], carried: [])
        check("past the ninth a chip has no key, only the mouse",
              crowded.entries.count == 10 && crowded.key(at: 9) == nil && crowded.key(at: 8) == 9
                && crowded.entry(forKey: 9)?.tag == "Q9")

        let slots = TriageStrip.quickTags(
            scope: [["Beach", four], ["beach", "Kite"], ["Kite"], ["Tent", "Anna"], []],
            popular: ["Sea", "Beach", "Boat"], limit: 6)
        check("quick tags are the scope's most used, ties alphabetical, stars left out",
              Array(slots.prefix(4)) == ["Beach", "Kite", "Anna", "Tent"], "\(slots)")
        check("...then the library's most used to fill the row, without repeating one",
              slots == ["Beach", "Kite", "Anna", "Tent", "Sea", "Boat"], "\(slots)")
        check("an empty scope falls back to the library alone",
              TriageStrip.quickTags(scope: [], popular: ["Sea", "Boat"]) == ["Sea", "Boat"])

        // --- 3. the session, against the real stores --------------------------------------

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-triage-\(UUID().uuidString)"
        func dir(_ path: String) -> String {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        Paths.support = dir(root + "/support")
        let library = Library()
        let store = SuggestionStore(file: root + "/support/suggestions-test.json")
        let media = dir(root + "/media")
        let a = media + "/a.mp4", b = media + "/b.mp4", c = media + "/c.mp4", d = media + "/d.mp4"

        library.setTags(["Beach"], for: c)
        library.setTags(["Beach", "Kite"], for: d)
        library.saveTags()
        store.record(a, suggestions: [sugg("Sea", 0.05), sugg("Sand", 0.04), sugg("Beach", 0.03), sugg("Boat", 0.02)],
                     model: "test", framesSeen: 3)

        library.setFacts(["2016", "iPhone 15"], for: a)
        let session = TriageSession(library: library, suggestions: store, playlist: [a, b, c, d])
        check("readings do not count as tags: a video with only readings is in the queue",
              !library.factsFor(a).isEmpty && session.current == a && session.left == 2,
              "\(session.current ?? "nil") \(session.left)")
        let shared = TriageSession.reader(library, store)
        check("the reader the Overview shares agrees: readings only needs tags, a real tag does not",
              shared.matches(a, .needsTags) && !shared.matches(c, .needsTags))
        check("quick tags come from the tags in the scope",
              session.quick == ["Beach", "Kite"], "\(session.quick)")
        let opening = session.strip.entries
        check("the strip is suggestions then quick tags, a suggestion not repeated",
              opening.map(\.tag) == ["Sea", "Sand", "Beach", "Boat", "Kite"], "\(opening.map(\.tag))")

        func verdicts(_ path: String) -> [String: SuggestionVerdict] { store.entry(path)?.verdicts ?? [:] }

        session.toggle(key: 1)
        check("a suggestion key puts the tag on and records accepted",
              library.hasTag(a, "Sea") && verdicts(a)["Sea"] == .accepted)
        session.toggle(key: 1)
        check("pressing it again takes the tag off and withdraws the answer",
              !library.hasTag(a, "Sea") && verdicts(a)["Sea"] == nil
                && store.pending(a).contains { $0.tag == "Sea" })
        session.toggle(key: 5)
        check("a quick tag goes on with no verdict, because the engine said nothing",
              library.hasTag(a, "Kite") && verdicts(a).isEmpty)
        session.reject(key: 2)
        check("reject records a real no, and the tag is not on",
              verdicts(a)["Sand"] == .rejected && !library.hasTag(a, "Sand"))
        let stepsBefore = session.steps.count
        session.reject(key: 5)
        check("rejecting a quick tag does nothing", session.steps.count == stepsBefore
                && library.hasTag(a, "Kite") && verdicts(a)["Kite"] == nil)
        check("none of that renumbered the strip", session.strip.entries == opening)
        check("the chips say what happened to them",
              session.isApplied(opening[4]) && session.isRejected(opening[1]) && !session.isRejected(opening[0]))

        // Skip and back write nothing.
        let pendingBefore = store.pending(a).map(\.tag)
        let verdictsBefore = verdicts(a)
        session.skip()
        check("skip moves on", session.current == b)
        session.back()
        check("back returns", session.current == a)
        check("skip and back recorded nothing: suggestions still pending, verdicts unchanged",
              store.pending(a).map(\.tag) == pendingBefore && verdicts(a) == verdictsBefore)

        // Accept all.
        session.acceptAll()
        check("accept all takes every suggestion shown, but not the one that was refused",
              library.tagsFor(a).sorted() == ["Beach", "Boat", "Kite", "Sea"].sorted()
                && verdicts(a)["Sea"] == .accepted && verdicts(a)["Boat"] == .accepted
                && verdicts(a)["Beach"] == .accepted && verdicts(a)["Sand"] == .rejected,
              "\(library.tagsFor(a)) \(verdicts(a))")
        check("...and moves on", session.current == b)

        // Undo that.
        check("undo takes accept-all back and returns to the video", session.undo() && session.current == a)
        check("...tags exactly as they were before it",
              library.tagsFor(a) == ["Kite"], "\(library.tagsFor(a))")
        check("...verdicts exactly as they were before it",
              verdicts(a) == ["Sand": .rejected], "\(verdicts(a))")

        // Done.
        session.done()
        check("done leaves the suggestions it did not take as ignored, never as rejected",
              verdicts(a)["Sea"] == .ignored && verdicts(a)["Beach"] == .ignored
                && verdicts(a)["Boat"] == .ignored && verdicts(a)["Sand"] == .rejected)
        check("done on a video with a tag does not mark it as 'nothing to tag'",
              store.triagedAt(a) == nil)
        check("...and moves on", session.current == b)

        // Nothing to tag.
        check("b has no entry at all yet", store.entry(b) == nil)
        session.done()
        check("done on a video with no tag marks it reviewed", store.triagedAt(b) != nil)
        check("...and the queue is finished", session.current == nil && session.queue.isFinished)
        let again = TriageSession(library: library, suggestions: store, playlist: [a, b, c, d])
        check("a new session does not offer a reviewed video again", again.current == nil)
        check("...though the Everything filter still can", TriageSession(
                library: library, suggestions: store, playlist: [a, b], filter: .everything).current == a)
        check("a reviewed video does not look analysed",
              !store.hasSuggestions(b, model: nil) && store.entry(b)?.suggestedAt == nil)

        // Undo of the mark.
        check("undo of that done un-marks the video and returns to it",
              session.undo() && session.current == b && store.triagedAt(b) == nil)
        check("...leaving no empty entry behind", store.entry(b) == nil)
        let recorded = session.steps.count
        var undone = 0
        while session.undo() { undone += 1 }
        check("undo goes back one step at a time, as far as the session began",
              undone == recorded && undone > 0 && !session.canUndo, "\(undone) of \(recorded)")
        check("...and puts the video back as it was at the start",
              library.tagsFor(a).isEmpty && verdicts(a).isEmpty && session.current == a,
              "\(library.tagsFor(a)) \(verdicts(a))")

        // A typed tag that is also a suggestion.
        let e = media + "/e.mp4"
        store.record(e, suggestions: [sugg("Tent", 0.04), sugg("Pier", 0.03)], model: "test", framesSeen: 3)
        let typed = TriageSession(library: library, suggestions: store, playlist: [e])
        typed.addTyped("tent, Holiday")
        check("typed tags go on", library.tagsFor(e) == ["tent", "Holiday"], "\(library.tagsFor(e))")
        typed.done()
        check("a suggestion the user typed by hand counts as accepted when the video is done",
              verdicts(e)["Tent"] == .accepted && verdicts(e)["Pier"] == .ignored,
              "\(verdicts(e))")

        // Late suggestions.
        let g = media + "/g.mp4"
        let lateSession = TriageSession(library: library, suggestions: store, playlist: [g])
        let lateBefore = lateSession.strip.entries
        store.record(g, suggestions: [sugg("Wave", 0.06), sugg("Surf", 0.04)], model: "test", framesSeen: 3)
        lateSession.refreshSuggestions()
        check("suggestions that land after the video opened join the end of the strip",
              Array(lateSession.strip.entries.prefix(lateBefore.count)) == lateBefore
                && lateSession.strip.entries.suffix(2).map(\.tag) == ["Wave", "Surf"],
              "\(lateSession.strip.entries.map(\.tag))")

        // The one-slot library undo is left alone.
        let h = media + "/h.mp4"
        library.setTags(["Before"], for: h)
        library.rememberForUndo("sentinel")
        let snapshot = library.undoable?.tags
        let spare = TriageSession(library: library, suggestions: store, playlist: [h], filter: .everything)
        spare.toggle(key: 1)
        spare.addTyped("More")
        spare.done()
        spare.undo()
        check("triage does not spend the library's own undo",
              library.undoable?.label == "sentinel" && library.undoable?.tags == snapshot,
              library.undoable?.label ?? "nil")

        // Hidden.
        let x = media + "/x.mp4", y = media + "/y.mp4"
        library.hide([x])
        let hiding = TriageSession(library: library, suggestions: store, playlist: [x, y])
        check("a hidden video is never offered", hiding.current == y && hiding.left == 1)
        let z = media + "/z.mp4"
        let late2 = TriageSession(library: library, suggestions: store, playlist: [y, z])
        library.hide([z])
        late2.skip()
        check("...including one hidden while the session runs", late2.current == nil, "\(late2.current ?? "nil")")

        // Has-suggestions ignores a suggestion the video already carries.
        let k = media + "/k.mp4"
        store.record(k, suggestions: [sugg("Tent", 0.04)], model: "test", framesSeen: 3)
        library.setTags(["tent"], for: k)
        check("a suggestion for a tag the video carries is not something left to answer",
              TriageSession(library: library, suggestions: store, playlist: [k], filter: .hasSuggestions)
                .current == nil)

        // --- 4. the stored mark ---------------------------------------------------------------

        let old = Data("""
        {"/m/a.mp4": {"suggestions": [{"tag": "Sea", "confidence": 0.05, "frames": 3}],
                      "verdicts": {"Sea": "accepted"}}}
        """.utf8)
        let decoded = try? JSONDecoder().decode([String: VideoSuggestions].self, from: old)
        check("a suggestions file from before triage still decodes",
              decoded?["/m/a.mp4"]?.triagedAt == nil && decoded?["/m/a.mp4"]?.verdicts["Sea"] == .accepted)

        let marked = SuggestionStore(file: root + "/support/marked.json")
        let m1 = media + "/m1.mp4", m2 = media + "/m2.mp4"
        marked.setTriaged(m1, to: Date(timeIntervalSince1970: 1_700_000_000))
        marked.record(m2, suggestions: [sugg("Sea", 0.05)], model: "test", framesSeen: 3)
        marked.decide(m2, tag: "Sea", verdict: .rejected)
        marked.setTriaged(m2, to: Date(timeIntervalSince1970: 1_700_000_100))
        check("a mark alone does not make a video look analysed",
              !marked.hasSuggestions(m1, model: nil) && marked.entry(m1)?.suggestedAt == nil)
        check("the mark does not change the training data",
              marked.exampleCounts().map { "\($0.tag):\($0.accepted):\($0.rejected)" } == ["Sea:0:1"],
              "\(marked.exampleCounts())")
        marked.flush()
        let reloaded = SuggestionStore(file: root + "/support/marked.json")
        check("the mark survives a write and a reload",
              reloaded.triagedAt(m1) == Date(timeIntervalSince1970: 1_700_000_000)
                && reloaded.triagedAt(m2) == Date(timeIntervalSince1970: 1_700_000_100))
        reloaded.move(from: m1, to: media + "/m1-renamed.mp4")
        check("the mark follows a renamed video",
              reloaded.triagedAt(media + "/m1-renamed.mp4") != nil && reloaded.triagedAt(m1) == nil)
        reloaded.setTriaged(m2, to: nil)
        check("taking a mark back keeps an entry that holds anything else",
              reloaded.triagedAt(m2) == nil && reloaded.entry(m2)?.verdicts["Sea"] == .rejected)
        reloaded.setTriaged(media + "/never-seen.mp4", to: nil)
        check("taking back a mark that was never there creates nothing",
              reloaded.entry(media + "/never-seen.mp4") == nil)

        // --- 5. saving in a hurry --------------------------------------------------------------

        func onDisk(_ path: String) -> [String]? {
            JSONStore.load(Paths.tagsFile, fallback: [String: [String]]())[Paths.tagKey(path)]
        }
        let quickPath = media + "/quick.mp4"
        library.setTags(["Soon"], for: quickPath)
        library.saveTagsSoon(after: 60)
        check("a soft save counts the tag at once", library.tagCounts["Soon"] == 1)
        check("...but holds the file write back", onDisk(quickPath) == nil)
        library.flushTags()
        check("flushing writes it", onDisk(quickPath) == ["Soon"], "\(onDisk(quickPath) ?? [])")
        library.setTags(["Soon", "Later"], for: quickPath)
        library.saveTagsSoon(after: 60)
        library.saveTags()
        check("an ordinary save overtakes a held write", onDisk(quickPath) == ["Soon", "Later"])
        library.flushTags()
        check("...and flushing with nothing held changes nothing", onDisk(quickPath) == ["Soon", "Later"])

        // --- a closed profile owns nothing ---------------------------------------------------------

        let closing = TriageSession(library: library, suggestions: store, playlist: [media + "/n.mp4"],
                                    filter: .everything)
        library.closeProfile()
        let stepsClosed = closing.steps.count
        closing.addTyped("Nope")
        closing.toggle(key: 1)
        closing.done()
        check("with no profile open nothing is tagged and nothing is recorded",
              !library.profileOpen && closing.steps.count == stepsClosed
                && library.tagsFor(media + "/n.mp4").isEmpty)

        try? fm.removeItem(atPath: root)
        print(failures == 0 ? "\nall triage checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
