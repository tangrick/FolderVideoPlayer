// Watch state and smart collections.
//
// Watch state (P5's foundation, which smart collections' playback rule reads):
//   1. the opening and completion thresholds, for long films and short clips;
//   2. a replay leaves a watched video watched; a routine sample is not news;
//   3. Mark Watched / Unwatched by hand, and unwatched forgets the resume point;
//   4. a preview is not watching; playing to the end is;
//   5. history follows a moved file, survives a relaunch, and stays in its
//      profile.
//
// Smart collections:
//   6. All and Any, exclusion, ratings, dates by day, transcripts, playback,
//      analysis, verdicts and file states;
//   7. a missing value makes a comparison false, not true;
//   8. hidden videos are never in the universe;
//   9. a rule naming a deleted tag is described, and an unknown rule kind from
//      a newer build survives a round trip and matches nothing.
//
// Run: Tests/run_smart_collections.sh

@testable import FVPModel
import Foundation

@main
struct SmartCollectionsTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        // --- 1. thresholds --------------------------------------------------------

        check("a long film's opening is thirty seconds", WatchLog.opening(total: 3600) == 30)
        check("a short clip's opening is a quarter of it", WatchLog.opening(total: 20) == 5)
        check("a long film is finished in its last thirty seconds",
              WatchLog.isCompletion(position: 3571, total: 3600) && !WatchLog.isCompletion(position: 3500, total: 3600))
        check("a short clip is not finished the moment it starts",
              !WatchLog.isCompletion(position: 1, total: 20) && WatchLog.isCompletion(position: 18.5, total: 20))
        check("an unknown length is never finished", !WatchLog.isCompletion(position: 100, total: 0))

        // --- 2. samples -------------------------------------------------------------

        var log = WatchLog()
        check("a sample in the opening is nothing", log.notePlayback("a", position: 10, total: 600, now: 1000) == .none)
        check("unwatched before any play", log.state("a", resume: nil) == .unwatched)
        check("the first real sample is news", log.notePlayback("a", position: 40, total: 600, now: 1000) == .stateChanged)
        check("a sample seconds later is not even a refresh",
              log.notePlayback("a", position: 45, total: 600, now: 1005) == .none)
        check("a sample a minute later refreshes quietly",
              log.notePlayback("a", position: 100, total: 600, now: 1070) == .refreshed)
        check("with a resume point it is in progress", log.state("a", resume: 100) == .inProgress)
        check("finishing is news", log.notePlayback("a", position: 590, total: 600, now: 1200) == .stateChanged)
        check("finished is watched", log.state("a", resume: nil) == .watched)
        _ = log.notePlayback("a", position: 50, total: 600, now: 5000)
        check("a replay leaves it watched", log.state("a", resume: 50) == .watched)
        check("a replay keeps the first completion", log.entry("a")?.completedAt == 1200)
        check("a replay updates the last play", log.entry("a")?.lastPlayedAt == 5000)

        // --- 3. by hand ---------------------------------------------------------------

        log.mark(["b", "c"], watched: true, now: 7)
        check("marked watched is watched", log.state("b", resume: nil) == .watched && log.entry("c")?.completedAt == 7)
        log.mark(["a", "b"], watched: false)
        check("marked unwatched is unwatched, history and all",
              log.state("a", resume: nil) == .unwatched && log.entry("a") == nil)

        // --- moving and saving ----------------------------------------------------------

        log.move(from: "c", to: "c2")
        check("history follows a moved file", log.entry("c") == nil && log.state("c2", resume: nil) == .watched)
        var merged = WatchLog()
        _ = merged.notePlayback("x", position: 40, total: 600, now: 10)
        merged.mark(["y"], watched: true, now: 20)
        merged.move(from: "x", to: "y")
        check("a move onto watched history keeps it watched",
              merged.state("y", resume: nil) == .watched && merged.entry("y")?.lastPlayedAt == 10)

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-smart-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch + "/media", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        let file = scratch + "/watch.json"
        log.save(to: file)
        check("a log survives a round trip", WatchLog.load(at: file) == log)
        try? "{\"version\": 9, \"entries\": {\"k\": {\"completedAt\": 3, \"future\": 1}}, \"other\": true}"
            .write(toFile: file, atomically: true, encoding: .utf8)
        check("a newer build's log is read for what this one understands",
              WatchLog.load(at: file).state("k", resume: nil) == .watched)
        check("an absent log is empty", WatchLog.load(at: scratch + "/none.json") == WatchLog())

        // --- 4 & 5. through the library -------------------------------------------------

        Paths.support = scratch
        for name in ["a", "b", "c", "d", "e.mkv"] {
            let file = name.contains(".") ? name : name + ".mp4"
            try? Data(count: 10).write(to: URL(fileURLWithPath: "\(scratch)/media/\(file)"))
        }
        let all = Scanner.scan(scratch + "/media")
        guard all.count == 5 else {
            print("FAIL the fixture did not scan to five videos — \(all)")
            exit(1)
        }
        let (pa, pb, pc, pd, pe) = (all[0], all[1], all[2], all[3], all[4])
        let library = Library()
        library.note(position: 200, total: 600, for: pa, watching: false)
        check("a preview is not watching", library.watchState(pa) != .watched && library.lastPlayed(pa) == nil)
        library.note(position: 200, total: 600, for: pa)
        check("playing past the opening is in progress", library.watchState(pa) == .inProgress)
        library.note(position: 600, total: 600, for: pa)
        check("playing to the end is watched", library.watchState(pa) == .watched)
        library.markWatched([pa], false)
        check("Mark Unwatched makes it new and forgets the resume point",
              library.watchState(pa) == .unwatched && library.progress[pa] == nil)
        library.markWatched([pb, pc], true)
        check("Mark Watched on a selection", library.watchState(pb) == .watched && library.watchState(pc) == .watched)

        let moved = scratch + "/media/moved-b.mp4"
        library.moveTags(from: pb, to: moved)
        check("a moved file keeps its watched state", library.watchState(moved) == .watched
                && library.watchState(pb) == .unwatched)

        let reread = WatchLog.load(at: Paths.watchFile(library.person))
        check("watch state is on disk for a relaunch", reread.state(Paths.tagKey(pc), resume: nil) == .watched)

        let first = library.person
        library.switchProfile(to: "Somebody Else", startingEmpty: true)
        check("another profile has watched nothing", library.watchState(pc) == .unwatched)
        library.markWatched([pd], true)
        library.switchProfile(to: first)
        check("switching back restores this profile's history",
              library.watchState(pc) == .watched && library.watchState(pd) == .unwatched)

        // --- facts arriving from a share (1.1.22) -------------------------------------------

        let sentFacts = library.facts.byKey
        let arrivedKey = Paths.tagKey(pd)
        library.takeSharedFacts([arrivedKey: ["2021", "Oslo"]], sent: sentFacts)
        check("facts from a share are taken in", library.factsFor(pd) == ["2021", "Oslo"])
        let snapshot = library.facts.byKey
        library.setFacts(["2022"], for: pe)          // changed here while a sync ran
        library.takeSharedFacts([Paths.tagKey(pe): ["1999"], arrivedKey: []], sent: snapshot)
        check("a video changed here during the sync keeps this Mac's facts", library.factsFor(pe) == ["2022"])
        check("an empty list from the share removes a video's facts", library.factsFor(pd).isEmpty)
        library.setFacts([], for: pe)

        // --- 6. smart collections -------------------------------------------------------

        library.addTag("Beach", to: [pa, pc])
        library.addTag("Anna", to: [pc, pd])
        library.setRating(4, for: [pa])
        library.setRating(2, for: [pc])
        library.setFacts(["May 2016", "2016"], for: pa)
        library.setFacts(["2019"], for: pd)
        var context = library.smartContext(adding: [Paths.tagKey(pe)])
        let ka = Paths.tagKey(pa), kc = Paths.tagKey(pc), kd = Paths.tagKey(pd), ke = Paths.tagKey(pe)
        let buckets: [String: AnalysisBucket] = [ka: .safe, kc: .needsReview, kd: .failed]
        context.analysis = { buckets[$0] ?? .unseen }
        context.transcriptHits = ["hello there": [kc]]
        context.addedOn = [ka: date(2020, 1, 10), kc: date(2024, 6, 1)]
        context.fileExists = [ka: true, kc: false, ke: true]

        func run(_ match: SmartCollection.Match, _ rules: [SmartRule]) -> [String] {
            SmartEvaluator.members(SmartCollection(name: "t", match: match, rules: rules), in: context)
        }
        let beach = SmartRule(kind: .tag, op: .includes, text: "beach")
        let anna = SmartRule(kind: .person, op: .includes, text: "Anna")
        check("the universe holds what the library knows, and what is added",
              Set(context.universe).isSuperset(of: [ka, kc, kd, ke]))
        check("All needs every rule", run(.all, [beach, anna]) == [kc])
        check("Any needs one", Set(run(.any, [beach, anna])) == [ka, kc, kd])
        check("no rules pick nothing", run(.all, []).isEmpty)
        check("excluding a tag",
              !run(.all, [SmartRule(kind: .tag, op: .excludes, text: "Beach")]).contains(ka))
        check("rating at least", run(.all, [SmartRule(kind: .rating, op: .atLeast, stars: 3)]) == [ka])
        check("rating at most includes unrated",
              run(.all, [SmartRule(kind: .rating, op: .atMost, stars: 2)]).contains(ke))
        check("rating exactly", run(.all, [SmartRule(kind: .rating, op: .equals, stars: 2)]) == [kc])
        check("recorded before a date reads the month",
              run(.all, [SmartRule(kind: .recorded, op: .before, from: date(2016, 6, 1))]) == [ka])
        check("recorded between two dates, inclusive",
              run(.all, [SmartRule(kind: .recorded, op: .between, from: date(2019, 1, 1), to: date(2019, 1, 1))]) == [kd])
        check("added after a day means from the next day",
              run(.all, [SmartRule(kind: .added, op: .after, from: date(2020, 1, 10))]) == [kc])
        check("transcript words", run(.all, [SmartRule(kind: .transcript, op: .contains, text: " Hello There ")]) == [kc])
        check("playback state",
              Set(run(.all, [SmartRule(kind: .playback, op: .isValue, text: "watched")])) == [kc, Paths.tagKey(moved)])
        check("analysis complete", Set(run(.all, [SmartRule(kind: .analysis, op: .isValue, text: "complete")])) == [ka, kc])
        check("analysis failed", run(.all, [SmartRule(kind: .analysis, op: .isValue, text: "failed")]) == [kd])
        check("verdict needs review", run(.all, [SmartRule(kind: .verdict, op: .isValue, text: "needsReview")]) == [kc])
        check("file missing", run(.all, [SmartRule(kind: .file, op: .isValue, text: "missing")]) == [kc])
        check("file needs conversion", run(.all, [SmartRule(kind: .file, op: .isValue, text: "needsConversion")]) == [ke])
        check("a file fact rule matches readings off the file",
              run(.all, [SmartRule(kind: .fact, op: .includes, text: "may 2016")]) == [ka])
        check("a file fact rule excludes by reading",
              !run(.all, [SmartRule(kind: .fact, op: .excludes, text: "2019")]).contains(kd))
        check("a tag rule does not match a reading of the same name",
              run(.all, [SmartRule(kind: .tag, op: .includes, text: "2016")]).isEmpty)
        check("a file fact rule does not match a tag",
              run(.all, [SmartRule(kind: .fact, op: .includes, text: "Beach")]).isEmpty)
        check("two kinds of rule combine",
              run(.all, [anna, SmartRule(kind: .analysis, op: .isValue, text: "failed")]) == [kd])

        // --- 7. missing values ---------------------------------------------------------------

        check("no recording date is never before or after",
              !run(.any, [SmartRule(kind: .recorded, op: .before, from: date(2100, 1, 1)),
                          SmartRule(kind: .recorded, op: .after, from: date(1900, 1, 1))]).contains(kc))
        check("never stat-ed is neither missing nor playable",
              !run(.any, [SmartRule(kind: .file, op: .isValue, text: "missing"),
                          SmartRule(kind: .file, op: .isValue, text: "playable")]).contains(kd))

        // --- 8. hidden -------------------------------------------------------------------------

        _ = library.hide([pc])
        let hiddenContext = library.smartContext()
        check("a hidden video is never in the universe", !hiddenContext.universe.contains(kc))
        _ = library.unhide([pc])

        // --- 9. problems and storage -------------------------------------------------------------

        let known: (String) -> Bool = { !library.pathsCarrying($0).isEmpty }
        check("a live tag rule has no problem", SmartEvaluator.problem(with: beach, knownNames: known) == nil)
        library.deleteTag("Beach")
        let gone = SmartEvaluator.problem(with: beach, knownNames: known) ?? ""
        check("a deleted tag is described", gone.contains("beach") && gone.contains("renamed or deleted"), gone)
        check("an empty transcript rule asks for words",
              SmartEvaluator.problem(with: SmartRule(kind: .transcript, op: .contains), knownNames: known) != nil)

        var saved = SmartCollectionFile()
        saved.collections = [SmartCollection(name: "Unwatched Anna", match: .any,
                                             rules: [anna, SmartRule(kind: .playback, op: .isValue, text: "unwatched")])]
        let path = Paths.smartCollectionsFile(library.person)
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        check("collections save", saved.save(to: path))
        check("collections round-trip", SmartCollectionFile.load(at: path) == saved)
        check("collections are filed per profile",
              Paths.smartCollectionsFile("one") != Paths.smartCollectionsFile("two"))

        let future = """
        {"version": 3, "collections": [{"id": "\(UUID().uuidString)", "name": "F", "match": "all",
          "rules": [{"id": "\(UUID().uuidString)", "type": "mood", "op": "is", "text": "happy",
                     "stars": 0, "from": 0, "to": 0}]}]}
        """
        try? future.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = SmartCollectionFile.load(at: path)
        check("a newer build's rule kind still loads", loaded.collections.first?.rules.first?.type == "mood")
        if let rule = loaded.collections.first?.rules.first {
            check("...is described as not understood",
                  SmartEvaluator.problem(with: rule, knownNames: known)?.contains("newer version") == true)
            check("...and matches nothing", run(.any, [rule]).isEmpty)
        }
        _ = loaded.save(to: path)
        check("...and survives being saved again",
              SmartCollectionFile.load(at: path).collections.first?.rules.first?.type == "mood")

        print(failures == 0 ? "\nall smart collection checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Double {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970
    }
}
