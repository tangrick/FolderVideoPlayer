// Library folders: the list of every folder the library draws videos from, and
// taking one out of the profile's library.
//
//   1. the list: chosen folders first, then the folders videos sit in without
//      anyone having chosen them, most videos first; a folder counts everything
//      under it; `Clips` never claims `Clips 2019`;
//   2. removal: tags (also queued off the share), readings, watch history,
//      resume points, suggestions, moments, Pinned, Recent and the session all
//      leave, for the videos under the folder and no others; a hidden video, a
//      sibling folder with a shared prefix and another profile on this Mac are
//      untouched;
//   3. undo puts back every one of them, in their old places;
//   4. a closed profile owns nothing to remove.
//
// Run: Tests/run_library_folders.sh

@testable import FVPModel
import Foundation

@main
struct LibraryFoldersTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        // --- 1. the list ---------------------------------------------------------------

        let rows = LibraryFolders.build(
            pinned: ["/v/Home"], recent: ["/v/Clips", "/v/Home"], maintained: ["/v/Kept"],
            videoPaths: ["/v/Home/a.mp4", "/v/Home/sub/b.mp4", "/v/Clips/c.mp4", "/v/Clips 2019/d.mp4",
                         "/v/Odd/e.mp4", "/v/Odd/f.mp4", "/v/Other/g.mp4"])
        check("chosen folders come first, once each, in the order chosen",
              rows.map(\.path).prefix(3) == ["/v/Home", "/v/Clips", "/v/Kept"], "\(rows.map(\.path))")
        check("a folder counts every video under it, at any depth",
              rows.first { $0.path == "/v/Home" }?.videos == 2)
        check("Clips does not claim Clips 2019",
              rows.first { $0.path == "/v/Clips" }?.videos == 1
                && rows.contains { $0.path == "/v/Clips 2019" })
        check("a kept-up-to-date folder with nothing in it still shows",
              rows.first { $0.path == "/v/Kept" }?.videos == 0)
        check("then the folders only the videos put there, most videos first",
              rows.map(\.path).suffix(3) == ["/v/Odd", "/v/Clips 2019", "/v/Other"], "\(rows.map(\.path))")
        check("the flags say how each got in",
              rows[0].pinned && rows[0].recent && !rows[0].maintained
                && rows[2].maintained && rows.last!.viaVideosOnly && !rows[0].viaVideosOnly)
        let nested = LibraryFolders.build(pinned: ["/v/Home", "/v/Home/sub"], recent: [], maintained: [],
                                          videoPaths: ["/v/Home/a.mp4", "/v/Home/sub/b.mp4"])
        check("a folder inside another counts its own, and the outer one counts both",
              nested.map(\.videos) == [2, 1])
        check("an empty library lists nothing", LibraryFolders.build(pinned: [], recent: [], maintained: [], videoPaths: []).isEmpty)

        // --- 2. removal -----------------------------------------------------------------

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-library-folders-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: scratch) }
        let macA = scratch + "/mac-a"
        try? fm.createDirectory(atPath: macA, withIntermediateDirectories: true)
        Paths.volumes = scratch + "/Volumes/"
        Paths.support = macA
        let media = Paths.volumes + "media"
        let home = media + "/Home"
        let a = home + "/a.mp4", b = home + "/sub/b.mp4", hiddenOne = home + "/h.mp4"
        let c = media + "/Clips/c.mp4", d = media + "/Clips 2019/d.mp4"

        // Another profile on this Mac, holding a tag on the same video.
        ProfileBundle.ensure(profile: "sam", name: "Sam", root: macA)
        let samTags = ProfileBundle.file(in: "sam", "tags.json", root: macA)
        JSONStore.save(samTags, [Paths.tagKey(a): ["Sunset"]])

        let alex = Library()
        alex.profiles = ["Alex"]
        alex.person = "Alex"
        alex.setPublishDeviceName("mac-a")
        let suggestions = SuggestionStore(file: macA + "/suggestions-test.json")
        let moments = MomentStore(root: macA)
        moments.reload(profile: "alex")
        alex.outsideKeys = { Set(suggestions.byVideo.keys).union(moments.videoKeys) }
        alex.forgetOutside = { folder in
            let taken = suggestions.take(under: folder)
            let marked = moments.take(under: folder)
            return { suggestions.restore(taken); moments.restore(marked) }
        }

        alex.setTags(["Beach", "Kite"], for: a)
        alex.setTags(["Tent"], for: b)
        alex.setTags(["Secret"], for: hiddenOne)
        alex.setTags(["Boat"], for: c)
        alex.setTags(["Sea"], for: d)
        alex.saveTags()
        alex.setFacts(["2019"], for: a)
        alex.saveFacts()
        alex.markWatched([a], true)
        alex.progress[a] = 42
        alex.progressSeen[a] = 1_000
        alex.progress[c] = 30
        alex.progress[hiddenOne] = 10
        alex.hide([hiddenOne])
        alex.pin(folder: home)
        alex.remember(folder: media + "/Clips")
        alex.remember(folder: home + "/sub")          // recent: [Home/sub, Clips]
        alex.session = Session(mode: "folder", root: home, path: a)
        suggestions.record(a, suggestions: [TagSuggestion(tag: "Sea", confidence: 0.05, frames: 3)],
                           model: "test", framesSeen: 3)
        suggestions.decide(a, tag: "Sea", verdict: .rejected)
        suggestions.record(c, suggestions: [TagSuggestion(tag: "Sky", confidence: 0.05, frames: 3)],
                           model: "test", framesSeen: 3)
        _ = moments.add(path: a, at: 3)
        _ = moments.add(path: c, at: 4)

        let plan = alex.folderPlan(home)
        check("the plan counts what is there, hidden videos left out",
              plan.videos == 2 && plan.tagged == 2 && plan.withReadings == 1 && plan.withHistory == 1
                && plan.sidebarEntries == 2, "\(plan)")
        check("...and a folder nothing is held for plans nothing", alex.folderPlan(media + "/Nowhere").videos == 0)

        let revisionBefore = alex.folderRevision
        let removal = alex.removeFolderFromLibrary(home)
        check("removal reports the plan it carried out", removal?.plan == plan && removal?.folder == home)
        check("tags and stars leave the videos under the folder",
              alex.tagsFor(a).isEmpty && alex.tagsFor(b).isEmpty && alex.taggedWith("Kite").isEmpty)
        check("...and no other video's",
              alex.tagsFor(c) == ["Boat"] && alex.tagsFor(d) == ["Sea"])
        check("a hidden video is left exactly as it was",
              alex.tagsFor(hiddenOne) == ["Secret"] && alex.isHidden(hiddenOne)
                && alex.progress[hiddenOne] == 10)
        check("readings leave", alex.factsFor(a).isEmpty)
        check("watch history leaves", alex.watchState(a) == .unwatched && alex.watch.entry(Paths.tagKey(a)) == nil)
        check("resume points leave, and only theirs",
              alex.progress[a] == nil && alex.progressSeen[a] == nil && alex.progress[c] == 30)
        check("Pinned and Recent lose the folder and what is inside it",
              !alex.pinned.contains(home) && !alex.recent.contains(home + "/sub")
                && alex.recent == [media + "/Clips"], "\(alex.pinned) \(alex.recent)")
        check("the session that pointed into it is cleared", alex.session == nil)
        check("suggestions and their verdicts leave, only for its videos",
              suggestions.entry(a) == nil && suggestions.entry(c) != nil)
        check("moments leave, only for its videos",
              moments.moments(for: a).isEmpty && moments.moments(for: c).count == 1)
        check("the folder is no longer one the profile holds videos from",
              alex.knownProfileVideoKeys().allSatisfy { !LibraryFolders.contains(home, Paths.tagPath($0)) }
                && alex.knownProfileVideoKeys().contains(Paths.tagKey(c)))
        let sync = alex.sharedSyncState()
        check("the removal is queued for the share, so the Apple TV stops showing it",
              sync.pending["media"]?.contains(.remove("Home/a.mp4")) == true
                && sync.pending["media"]?.contains(.remove("Home/sub/b.mp4")) == true
                && sync.pending["media"]?.contains(.remove("Clips/c.mp4")) == false,
              "\(sync.pending)")
        check("another profile on this Mac is not touched",
              (JSONStore.load(samTags, fallback: [String: [String]]()))[Paths.tagKey(a)] == ["Sunset"])
        check("nothing was done to a file",
              !fm.fileExists(atPath: a) && alex.lastFolderRemoval != nil)

        check("the revision moves on a removal", alex.folderRevision == revisionBefore + 1)

        // --- 3. undo ----------------------------------------------------------------------

        check("undo reports it put something back", alex.undoFolderRemoval())
        check("tags and readings are back",
              alex.tagsFor(a) == ["Beach", "Kite"] && alex.tagsFor(b) == ["Tent"] && alex.factsFor(a) == ["2019"])
        check("watch history and resume points are back",
              alex.watchState(a) != .unwatched && alex.progress[a] == 42 && alex.progressSeen[a] == 1_000)
        check("Pinned and Recent are back, in their old places",
              alex.pinned == [home] && alex.recent == [home + "/sub", media + "/Clips"],
              "\(alex.pinned) \(alex.recent)")
        check("the session is back", alex.session?.path == a)
        check("suggestions, verdicts and moments are back",
              suggestions.entry(a)?.verdicts["Sea"] == .rejected && moments.moments(for: a).count == 1)
        check("a second undo has nothing to do", !alex.undoFolderRemoval() && alex.lastFolderRemoval == nil)

        // --- 3b. the list watches the revision --------------------------------------------

        // The list of folders rebuilds when this moves. It used to rebuild only
        // when a count happened to change, and missed a second removal.
        let r0 = alex.folderRevision
        alex.removeFolderFromLibrary(home)
        alex.removeFolderFromLibrary(media + "/Clips")      // while the first is still the last removal
        check("every removal moves the revision, a second one made with the first undoable included",
              alex.folderRevision == r0 + 2, "\(r0) \(alex.folderRevision)")
        check("...and the undo is for the latest",
              alex.lastFolderRemoval?.folder == media + "/Clips")
        alex.undoFolderRemoval()
        check("an undo moves it too", alex.folderRevision == r0 + 3)
        let steady = alex.folderRevision
        check("removing a folder with nothing in it changes nothing, and spends no undo",
              alex.removeFolderFromLibrary(media + "/Nowhere") == nil && alex.folderRevision == steady)
        alex.undoFolderRemoval()                              // puts the home folder back for the checks below

        // --- 3c. a removed folder stays out of what the shared stores add -----------------------

        // The AI's readings belong to no profile and the transcripts are not
        // cleared by a removal. The Library Overview and the smart collections
        // add what those hold to the videos the profile knows, so without a
        // memory of the removal they would list the folder's videos again.
        check("undoing the second removal left the first one remembered",
              alex.removedFolders == [home], "\(alex.removedFolders)")
        let analysed = home + "/analysed-only.mp4"            // known to a shared store alone
        let analysedElsewhere = media + "/Clips/analysed-too.mp4"
        let sharedKeys: Set<String> = [Paths.tagKey(analysed), Paths.tagKey(analysedElsewhere)]
        let listed = alex.knownVideoKeys(adding: sharedKeys)
        check("a removed folder's videos known only to a shared store are held back",
              !listed.contains(Paths.tagKey(analysed)))
        check("...and another folder's are not",
              listed.contains(Paths.tagKey(analysedElsewhere)))
        let analysedForeign = Paths.tagKey(media + "/Someone Else/x.mp4")
        check("a shared store's video in a folder this profile holds nothing in is not the profile's",
              !alex.knownVideoKeys(adding: [analysedForeign]).contains(analysedForeign))
        check("...though a store of the profile's own still counts it",
              alex.knownVideoKeys(adding: [analysedForeign], shared: false).contains(analysedForeign))
        check("the removal is written into the profile's bundle, to survive a relaunch",
              JSONStore.load(Paths.removedFoldersFile(alex.person), fallback: [String]()) == [home])
        alex.setTags(["Fresh"], for: analysed)
        check("a video the profile tags afterwards counts again: what it holds itself is never held back",
              alex.knownVideoKeys(adding: sharedKeys).contains(Paths.tagKey(analysed)))
        alex.setTags([], for: analysed)
        let beforeLift = alex.folderRevision
        alex.remember(folder: home)
        check("opening the folder again lifts the removal",
              alex.removedFolders.isEmpty
                && alex.knownVideoKeys(adding: sharedKeys).contains(Paths.tagKey(analysed)))
        check("...writes that down, and tells the lists watching the revision",
              JSONStore.load(Paths.removedFoldersFile(alex.person), fallback: [String]()).isEmpty
                && alex.folderRevision == beforeLift + 1)
        // Each of these needs something to remove, so they hold something first.
        alex.setTags(["Beach"], for: a)
        alex.setTags(["Tent"], for: b)
        alex.removeFolderFromLibrary(home)
        check("a removal is remembered", alex.removedFolders == [home], "\(alex.removedFolders)")
        alex.pin(folder: home)
        check("pinning it lifts it too", alex.removedFolders.isEmpty, "\(alex.removedFolders)")

        alex.setTags(["Beach"], for: a)
        alex.setTags(["Tent"], for: b)
        alex.removeFolderFromLibrary(home + "/sub")
        check("a folder inside it can be removed on its own", alex.removedFolders == [home + "/sub"],
              "\(alex.removedFolders)")
        alex.removeFolderFromLibrary(home)
        check("a removal absorbs earlier removals of folders inside it",
              alex.removedFolders == [home], "\(alex.removedFolders)")
        alex.undoFolderRemoval()
        check("...and undoing it brings the inner one back to the list",
              alex.removedFolders == [home + "/sub"], "\(alex.removedFolders)")
        check("...the undo is a single step: there is no earlier one behind it",
              !alex.undoFolderRemoval() && alex.removedFolders == [home + "/sub"])

        // --- 4. a closed profile ------------------------------------------------------------

        alex.closeProfile()
        check("with no profile open there is nothing to remove, remembered or removable",
              alex.removeFolderFromLibrary(home) == nil && alex.removedFolders.isEmpty)

        print(failures == 0 ? "\nall library folder checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
