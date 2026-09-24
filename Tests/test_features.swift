// The Sep '26 feature batch: bulk tag-a-folder, star ratings, and renaming a
// person in the face registry.
//
// What is worth proving rather than assuming:
//
//   1. addTag ADDS — the bulk-tag action must never remove a tag from a video
//      that already carries it (toggle over a folder where some rows already
//      have the tag would silently do exactly that), it is case-insensitively
//      idempotent, and it leaves every other tag alone.
//   2. star ratings are TAGS ("Favorite" = 5 stars, "4 Stars" … "1 Star"):
//      they read and clear through the rating shim, re-rating replaces rather
//      than doubles, clearing leaves no star tag behind, clamping holds, they
//      move with a repaired file, survive a relaunch AS TAGS, stay out of the
//      assignable tag lists, and a v1.1.1 ratings map migrates into them.
//   3. renaming a person moves the face bindings AND the tag, refuses to
//      collide with an existing person, is case-insensitive about who is
//      being renamed, and a rename that was refused changes nothing.
//
// Scratch root only: `Paths.support` is redirected before any store is built,
// so nothing here can reach a real library.
//
// `@main` rather than top-level code, because this file compiles alongside the
// app's model layer and only main.swift may carry top-level statements.

@testable import FVPModel
import Foundation

@main
struct FeaturesTest {
    /// Wrapped rather than `throws`, so a thrown error prints the checks that
    /// already ran instead of losing them to the runtime's top-level abort.
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            print("\nFAIL the harness threw: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-features-\(UUID().uuidString)"
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        // Never the real library. Set before any store is built.
        Paths.support = scratch

        // A small folder tree: two clips at the top, one in a subfolder.
        let media = scratch + "/media"
        let sub = media + "/day two"
        try fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for (path, bytes) in [(media + "/a.mp4", 3_000), (media + "/b.mp4", 4_000),
                              (sub + "/c.mp4", 5_000)] {
            try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        }
        let all = Scanner.scan(media)
        check("the fixture scans to three videos", all.count == 3, "\(all)")
        // Every later assertion uses the SCANNED paths, not constructed ones:
        // macOS symlinks /var into /private/var, so a path built by hand and
        // a path returned by a walk are different strings for the same file —
        // and a tag keyed on one does not meet a query for the other.
        // Natural order puts a.mp4 and b.mp4 at the top, the subfolder last.
        let pathA = all[0]
        let pathB = all[1]
        let pathC = all[2]
        check("the walk really descended into the subfolder",
              pathC.hasSuffix("/c.mp4") && pathC.contains("/day two/"), pathC)

        // --- 1. bulk tag-a-folder --------------------------------------------

        let library = Library()
        var tagged = library.addTag("Holiday", to: all)
        check("tagging a folder tags every video under it", tagged == 3, "\(tagged)")
        check("the subfolder's video is tagged too",
              library.hasTag(pathC, "Holiday"))
        check("the folder reports its tag count", library.count(of: "Holiday") == 3)

        tagged = library.addTag("holiday", to: all)
        check("adding the tag again is idempotent", tagged == 0, "\(tagged)")
        check("...and the count did not double", library.count(of: "Holiday") == 3)

        // A video that already carries the tag keeps its OTHER tags too.
        library.addTag("Beach", to: [pathA])
        tagged = library.addTag("Holiday", to: all)
        check("re-tagging one already-tagged video touches nothing", tagged == 0)
        check("...and its other tag is still there",
              library.hasTag(pathA, "Beach"))
        check("an empty tag name tags nothing", library.addTag("   ", to: all) == 0)
        check("an empty path list tags nothing", library.addTag("X", to: []) == 0)

        // --- 2. stars (which are tags) ---------------------------------------

        check("an unrated video reads as zero", library.rating(pathA) == 0)
        library.setRating(4, for: pathA)
        library.setRating(5, for: [pathC])
        check("a single video can be rated", library.rating(pathA) == 4)
        check("a selection can be rated", library.rating(pathC) == 5)
        check("rating a video does not rate its neighbours",
              library.rating(pathB) == 0)
        // 5 stars IS the Favorite tag — the fact the Apple TV sees.
        check("five stars is the Favorite tag",
              library.hasTag(pathC, favoriteTag))
        check("four stars is its own tag",
              library.hasTag(pathA, "4 Stars"))
        check("ratings are clamped from above", {
            library.setRating(9, for: pathB)
            return library.rating(pathB) == 5
        }())
        check("ratings are clamped from below", {
            library.setRating(-3, for: pathB)
            return library.rating(pathB) == 0
        }())
        check("clearing leaves no star tag behind", {
            library.setRating(0, for: pathB)
            return !library.tagsFor(pathB).contains { isStarTag($0) }
        }())
        // A re-rate REPLACES the old mark; nothing else on the video moves.
        check("re-rating replaces the old star tag", {
            library.setRating(2, for: pathA)
            let names = library.tagsFor(pathA)
            return library.rating(pathA) == 2
                && !library.hasTag(pathA, "4 Stars")
                && names.filter { isStarTag($0) }.count == 1
        }())
        check("other tags survive a re-rate", library.hasTag(pathA, "Beach"))
        library.setRating(4, for: pathA)

        // A repair (the moved-file scan) carries the rating like any tag.
        let moved = ((pathA as NSString).deletingLastPathComponent
            as NSString).appendingPathComponent("renamed.mp4")
        try fm.moveItem(atPath: pathA, toPath: moved)
        _ = library.moveTags(from: pathA, to: moved)
        check("a repair carries the stars to the new path",
              library.rating(moved) == 4, "\(library.rating(moved))")
        check("...and leaves none behind on the old one",
              library.rating(pathA) == 0)
        // Put the file back for the next block.
        try fm.moveItem(atPath: moved, toPath: pathA)
        _ = library.moveTags(from: moved, to: pathA)

        // Relaunch: stars are the user's judgement and must survive — as
        // tags, which is the whole point (the tags file is what shares).
        let relaunch = Library()
        check("a rating survives the relaunch", relaunch.rating(pathA) == 4)
        check("...and the other one does too", relaunch.rating(pathC) == 5)
        check("...and the four stars survive AS A TAG",
              relaunch.hasTag(pathA, "4 Stars"))

        // --- 2b. the Stars section ------------------------------------------

        // The section's rows are the ratings that exist, counted directly.
        check("countRated counts one video at 4 stars", relaunch.countRated(4) == 1)
        check("countRated counts one video at 5 stars", relaunch.countRated(5) == 1)
        check("countRated is zero where nothing is rated", relaunch.countRated(3) == 0)
        check("rated lists the 5-star video", relaunch.rated(5) == [pathC])
        check("rated lists the 4-star video", relaunch.rated(4) == [pathA])
        // Re-rating moves a video between rows; clearing removes it.
        relaunch.setRating(5, for: pathA)
        check("re-rating moves the video between star rows",
              relaunch.rated(4).isEmpty && relaunch.rated(5).sorted() == [pathA, pathC].sorted())
        relaunch.setRating(0, for: pathA)
        check("clearing empties that star row", relaunch.rated(5) == [pathC])
        relaunch.setRating(5, for: pathA)

        // The star tags stay out of the generic tag vocabulary — the Stars
        // section and the rating controls are the only places they appear.
        let assignable = relaunch.assignableTags()
        check("no star tag is offered as an ordinary chip",
              !assignable.contains { isStarTag($0) })
        check("ordinary tags still are",
              assignable.contains("Beach") && assignable.contains("Holiday"))

        // --- 2c. a v1.1.1 ratings map migrates into star tags, once ---------

        // A library as v1.1.1 left it: a ratings map in state.json, the tag
        // file carrying only ordinary tags, one video carrying a Favorite
        // tag from an even older build. The map converts at load; the
        // Favorite tag needs no conversion — it already IS 5 stars.
        let legacy = scratch + "/legacy"
        try fm.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        let old1 = legacy + "/old1.mp4"
        let old2 = legacy + "/old2.mp4"
        try Data(count: 2_000).write(to: URL(fileURLWithPath: old1))
        try Data(count: 2_500).write(to: URL(fileURLWithPath: old2))
        Paths.support = scratch + "/legacy-support"
        try fm.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
        // Build the fixture the way v1.1.1 actually left a machine: a
        // COMPLETE state file (synthesized decoding refuses a file that is
        // missing so much as one key) with a ratings map in it, and a tag
        // file carrying only ordinary tags plus one older Favorite.
        Library().save()
        var raw = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: Paths.stateFile))))
            as? [String: Any] ?? [:]
        raw["ratings"] = [Paths.tagKey(old1): 4, Paths.tagKey(old2): 5]
        let patched = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try patched.write(to: URL(fileURLWithPath: Paths.stateFile))
        JSONStore.save(Paths.tagsFile, [Paths.tagKey(old2): ["Beach", favoriteTag]])

        let oldLibrary = Library()      // the migration runs in init
        check("a mapped rating became its star tag", oldLibrary.rating(old1) == 4)
        check("...the other one too", oldLibrary.rating(old2) == 5)
        check("...and the Favorite tag is still exactly that",
              oldLibrary.hasTag(old2, favoriteTag))
        check("...and an ordinary tag survived the migration",
              oldLibrary.hasTag(old2, "Beach"))
        check("the migrated rows are countable",
              oldLibrary.countRated(4) == 1 && oldLibrary.countRated(5) == 1)
        check("the map is gone from state.json after the migration", {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: Paths.stateFile))) ?? Data()
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return parsed["ratings"] == nil
        }())

        // A relaunch does not fold again — the map is gone, so the second
        // Library reads stars that are already tags.
        let oldRelaunch = Library()
        check("the migration does not fire twice",
              oldRelaunch.rating(old1) == 4 && oldRelaunch.hasTag(old1, "4 Stars"))

        // A library with no ratings map and no star tags at all is untouched.
        Paths.support = scratch + "/fresh-support"
        try fm.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
        let fresh = Library()
        fresh.setRating(3, for: old1)
        check("an unrated-but-never-mapped library is untouched",
              fresh.rating(old1) == 3 && fresh.count(of: "4 Stars") == 0)

        // --- 2d. the switch that turns the automatic pass on and off ---------

        // One property, one stored key. The key is the OLD name on purpose:
        // it was written before the switch had a control, so renaming the
        // property must not strand every existing settings file.
        Paths.support = scratch + "/autowork-support"
        try fm.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
        let switched = Library()
        check("the automatic pass is on by default", switched.autoWorkWhilePlaying)
        switched.autoWorkWhilePlaying = false
        check("turning it off writes the old key, not the new name", {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: Paths.stateFile))) ?? Data()
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return parsed["classifyWhilePlaying"] as? Bool == false
                && parsed["autoWorkWhilePlaying"] == nil
        }())
        check("a relaunch reads the choice back",
              Library().autoWorkWhilePlaying == false)

        // A settings file an older build left behind: absent must mean ON, and
        // an explicit false must stay false (the rename must not un-switch it).
        for (written, expected) in [(nil as Bool?, true), (false, false), (true, true)] {
            Paths.support = scratch + "/autowork-legacy-\(expected)"
            try fm.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
            Library().save()
            var raw = (try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: Paths.stateFile)))) as? [String: Any] ?? [:]
            if let written { raw["classifyWhilePlaying"] = written } else { raw.removeValue(forKey: "classifyWhilePlaying") }
            try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: Paths.stateFile))
            check("a settings file with classifyWhilePlaying=\(written.map(String.init) ?? "absent") loads as \(expected)",
                  Library().autoWorkWhilePlaying == expected)
        }

        // --- 3. renaming a person ----------------------------------------------

        // A registry of three people, keyed like faces.json.
        let profile = Paths.activeProfile
        try fm.createDirectory(atPath: Paths.profileDir(profile),
                               withIntermediateDirectories: true)
        let registryFile = Paths.facesFile(in: profile)
        let registry: [String: [String]] = [
            "Quincy": ["hash1", "hash2"],
            "Sofia": ["hash3"],
        ]
        try JSONSerialization.data(withJSONObject: registry)
            .write(to: URL(fileURLWithPath: registryFile))
        // The name is on two videos, as face recognition would have left it —
        // spelled "Q. Hale" because that is the registry spelling this
        // section renames from.
        library.addTag("Q. Hale", to: [pathA, pathC])

        let faceRegistry = FaceRegistry(root: scratch, profile: profile)
        let renamedKey = try await faceRegistry.rename(from: "quincy", to: "Q. Hale")
        check("rename reports the name it filed", renamedKey == "Q. Hale")
        let stored = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: registryFile)))
            as? [String: [String]]) ?? [:]
        check("the bindings moved to the new name",
              stored["Q. Hale"] == ["hash1", "hash2"], "\(stored)")
        check("...and the old name is gone", stored["Quincy"] == nil)
        check("other people are untouched", stored["Sofia"] == ["hash3"])

        do {
            _ = try await faceRegistry.rename(from: "Q. Hale", to: "sofia")
            check("renaming onto an existing person is refused", false, "no throw")
        } catch {
            check("renaming onto an existing person is refused", true)
        }
        check("the refusal changed nothing",
              ((try? JSONSerialization.jsonObject(
                  with: Data(contentsOf: URL(fileURLWithPath: registryFile)))
                  as? [String: [String]]) ?? [:])["Q. Hale"]?.count == 2)
        do {
            _ = try await faceRegistry.rename(from: "Nobody", to: "Someone")
            check("renaming a person who does not exist is refused", false, "no throw")
        } catch {
            check("renaming a person who does not exist is refused", true)
        }
        do {
            _ = try await faceRegistry.rename(from: "Q. Hale", to: "q. hale")
            check("renaming to a case-variant of the same name is refused", false, "no throw")
        } catch {
            check("renaming to a case-variant of the same name is refused", true)
        }

        // The tag half: the store moves the person's tag with the name.
        let store = FaceStore(profile: profile)
        store.attach(engine: nil, library: library)
        Paths.activeProfile = profile
        let result = await store.renamePerson("Q. Hale", to: "Quin")
        check("the store renames a person", result == .renamed, "\(result)")
        check("the tag followed the person",
              library.tagsFor(pathC).contains("Quin"))
        check("...and the old tag is gone",
              !library.tagsFor(pathC).contains("Q. Hale"))
        check("a video that never carried the name still does not",
              !library.tagsFor(pathB).contains("Quin")
                  && !library.tagsFor(pathB).contains("Q. Hale"),
              "\(library.tagsFor(pathB))")
        let refused = await store.renamePerson("Quin", to: "Sofia")
        check("the store refuses a rename onto an existing person",
              refused != .renamed, "\(refused)")
        check("...and the tag did not move",
              library.tagsFor(pathC).contains("Quin"))

        // --- 4. re-asking a video the app cannot read -------------------------
        //
        // The look-alike search no longer tells the user to go and run Classify
        // when it cannot read a video: it re-analyses the video itself.
        // `requeue` is what makes that possible at all — such a record says
        // Done, and `enqueue` deliberately leaves a Done row alone, so without
        // it the search would find the same unreadable videos every time it
        // ran, for as long as the tag existed. What must NOT move is a human's
        // word, and a row the engine is holding.
        Paths.support = scratch + "/requeue-support"
        try fm.createDirectory(atPath: Paths.support, withIntermediateDirectories: true)
        let requeueStore = AnalysisStore()
        let answered = pathA, judged = pathB, held = pathC
        let neverSeen = media + "/never-scanned.mp4"
        let verdict = NsfwPrediction(score: 0.61, maxFrame: 0.9, meanFrame: 0.2,
                                     frames: 9, framesAbove: 1, threshold: 0.5,
                                     aggregation: "weighted_max_frac",
                                     modelID: "siglip2-base",
                                     classifier: "falconsai-nsfw-v1", classifiedAt: 0)
        requeueStore.enqueue([answered, judged, held])
        requeueStore.begin(answered)
        requeueStore.finish(answered, prediction: verdict, frames: [])
        requeueStore.begin(judged)
        requeueStore.mark(.safe, on: [judged])
        requeueStore.begin(held)        // the engine is mid-video on this one
        check("the fixture is one answered, one judged, one in flight",
              requeueStore.analysis(for: answered)?.phase == .done
                  && requeueStore.analysis(for: judged)?.phase == .done
                  && requeueStore.analysis(for: held)?.phase == .analyzing,
              "\(String(describing: requeueStore.analysis(for: answered)?.phase)) / "
              + "\(String(describing: requeueStore.analysis(for: judged)?.phase)) / "
              + "\(String(describing: requeueStore.analysis(for: held)?.phase))")

        let reQueued = requeueStore.requeue([answered, judged, held, neverSeen])
        check("an answered video the engine cannot read is re-asked",
              requeueStore.analysis(for: answered)?.phase == .queued,
              "\(String(describing: requeueStore.analysis(for: answered)?.phase))")
        check("...and it is the only one re-asked", reQueued == 1, "\(reQueued)")

        // --- 4b. a verdict about changed bytes is stale -----------------------
        //
        // `finish` records the file's identity beside the verdict. A re-encode
        // or a moved-over video makes the verdict a claim about bytes that no
        // longer exist: `isStale` says so, and a re-analysis records a fresh
        // revision, which clears the staleness. A legacy record (no revision)
        // is never called stale by this check — the space check governs it.
        let stalePath = media + "/stale-check.mp4"
        try Data("original bytes".utf8).write(to: URL(fileURLWithPath: stalePath))
        requeueStore.enqueue([stalePath])
        requeueStore.begin(stalePath)
        requeueStore.finish(stalePath, prediction: verdict, frames: [])
        let staleRecord = requeueStore.analysis(for: stalePath)
        check("a fresh verdict records the file's revision",
              staleRecord?.sourceRevision != nil
                && staleRecord?.isStale(forPath: stalePath) == false)
        Thread.sleep(forTimeInterval: 0.02)
        try Data("re-encoded bytes".utf8).write(to: URL(fileURLWithPath: stalePath))
        check("a changed file makes its verdict stale",
              requeueStore.analysis(for: stalePath)?.isStale(forPath: stalePath) == true)
        check("a stale verdict survives the round trip through the store",
              requeueStore.analysis(for: stalePath)?.sourceRevision != nil)
        requeueStore.requeue([stalePath])
        requeueStore.begin(stalePath)
        requeueStore.finish(stalePath, prediction: verdict, frames: [])
        check("re-analysing the new bytes clears the staleness",
              requeueStore.analysis(for: stalePath)?.isStale(forPath: stalePath) == false)
        var legacyRecord = VideoAnalysis()
        legacyRecord.phase = .done
        legacyRecord.prediction = verdict
        check("a legacy record with no revision is not called stale",
              legacyRecord.isStale(forPath: stalePath) == false)
        check("a missing file is stale, whatever the record says",
              requeueStore.analysis(for: stalePath)?.isStale(forPath: media + "/absent.mp4") == true)
        check("...and the verdict it had is kept until the re-run replaces it",
              requeueStore.analysis(for: answered)?.prediction?.score == 0.61)
        check("a human's word is never re-asked",
              requeueStore.analysis(for: judged)?.phase == .done)
        check("...and the label itself is untouched",
              requeueStore.analysis(for: judged)?.userLabel == .safe)
        check("a row the engine is holding is left to the engine",
              requeueStore.analysis(for: held)?.phase == .analyzing,
              "\(String(describing: requeueStore.analysis(for: held)?.phase))")
        check("a path with no record is not invented",
              requeueStore.analysis(for: neverSeen) == nil)
        check("re-asking a row that is already waiting changes nothing more",
              requeueStore.requeue([answered]) == 0)
        // The run's own work list is `phase == .queued`, so what this queues
        // has to be exactly that or nothing would ever pick it up.
        check("the re-asked row is what the engine's queue filter looks for",
              requeueStore.analysis(for: answered)?.phase == .queued)
        // A source replaced WHILE the engine runs must not be certified with
        // the new file's revision merely because finish() read it afterward.
        let inFlightRevision = SourceRevision.of(stalePath)!
        let oldPrediction = requeueStore.analysis(for: stalePath)?.prediction
        try? Data("replacement arriving during inference".utf8).write(to: URL(fileURLWithPath: stalePath))
        let acceptedLate = requeueStore.finish(stalePath, prediction: verdict, frames: [],
                                              expectedRevision: inFlightRevision)
        check("late verdict for replaced source is refused", !acceptedLate)
        check("late verdict does not stamp the replacement as analysed",
              requeueStore.analysis(for: stalePath)?.sourceRevision == inFlightRevision
                && requeueStore.analysis(for: stalePath)?.prediction == oldPrediction)

        // And a stale in-flight row is the run's to rescue, which is how the
        // widening hands over a row the last run left behind.
        requeueStore.rescueStaleAnalyses()
        check("a stale in-flight row joins the queue the same way",
              requeueStore.analysis(for: held)?.phase == .queued)

        // The disk half of the look-alike search's widening: which of the paths
        // it is about to analyse are still there. Off the main actor by design —
        // a `stat` against a share costs ~2 ms, and asking about EVERY candidate
        // was 5.6 s of blocked main thread (the spinning ball this fixes), so
        // only the batch is asked about, and only from here.
        let present = await LookAlikes.existing([answered, judged, media + "/gone.mp4"])
        check("existing keeps the paths that are still there, in order",
              present.live == [answered, judged], "\(present.live)")
        check("...and counts the one that is not", present.gone == 1, "\(present.gone)")
        check("...and a path that names nothing is not a special case",
              await LookAlikes.existing([]).gone == 0)

        print("")
        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("feature batch — all checks passed")
    }
}
