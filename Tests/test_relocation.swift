// Relocation, phase 1 of folder management: a video that is renamed or moved
// keeps everything the app knows about it.
//
//   1. PathMap — a file maps exactly; a folder maps by prefix, at a path
//      boundary only (`Clips` never touches `Clips 2019`); tag keys too;
//   2. every store follows a rename: tags, resume point, the hidden flag,
//      the fingerprint and a spared copy, provenance, the session, and —
//      through the `pathMoved` hook, wired as the app wires it — the
//      Safe/NSFW mark and the suggestion verdicts;
//   3. subtitle files travel with their video, and a clash among them is a
//      clash for the video;
//   4. a case-only rename works, and a name is keyed as the volume spells it;
//   5. the journal: a move a crash cut short is finished at the next launch,
//      one that never happened is dropped, one on an absent share is kept;
//   6. a refused rename leaves no Undo behind.
//
// Run: Tests/run_relocation.sh

@testable import FVPModel
import Foundation

@main
struct RelocationTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-relocation-\(UUID().uuidString)"
        func dir(_ path: String) -> String {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        func make(_ path: String, _ body: String = "video") {
            fm.createFile(atPath: path, contents: Data(body.utf8))
        }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        func names(_ folder: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        // --- 1. PathMap -------------------------------------------------------------

        let file = PathMap(from: "/v/Clips/a.mp4", to: "/v/Trips/b.mp4")
        check("a file maps exactly", file.map("/v/Clips/a.mp4") == "/v/Trips/b.mp4")
        check("...and touches nothing else", file.map("/v/Clips/a.mp4.srt") == nil
                && file.map("/v/Clips") == nil)
        let folder = PathMap(from: "/v/Clips", to: "/v/Trips/Clips", isFolder: true)
        check("a folder maps what is inside it",
              folder.map("/v/Clips/2024/a.mp4") == "/v/Trips/Clips/2024/a.mp4")
        check("...and itself", folder.map("/v/Clips") == "/v/Trips/Clips")
        check("...but never a sibling that merely starts with its name",
              folder.map("/v/Clips 2019/a.mp4") == nil && folder.map("/v/Clipsy/a.mp4") == nil)
        check("a trailing slash on the folder changes nothing",
              PathMap(from: "/v/Clips/", to: "/v/X/", isFolder: true).map("/v/Clips/a.mp4") == "/v/X/a.mp4")
        let savedVolumes = Paths.volumes
        Paths.volumes = "/Volumes/"
        let onShare = PathMap(from: "/Volumes/NAS/Clips", to: "/Volumes/NAS/Trips", isFolder: true)
        check("a share-relative tag key maps like its path",
              onShare.mapKey("NAS/Clips/a.mp4") == "NAS/Trips/a.mp4")
        check("...and a key elsewhere is left alone", onShare.mapKey("NAS/Other/a.mp4") == nil)
        Paths.volumes = savedVolumes
        let coded = try? JSONDecoder().decode(PathMap.self, from: JSONEncoder().encode(folder))
        check("a relocation survives a round trip to disk", coded == folder)

        // --- 2. every store follows a rename ------------------------------------------

        Paths.support = dir(root + "/support")
        let library = Library()
        let analysis = AnalysisStore(profile: Paths.activeProfile)
        let suggestions = SuggestionStore(file: root + "/support/suggestions-test.json")
        library.pathMoved = { old, new in
            analysis.move(from: old, to: new)
            suggestions.move(from: old, to: new)
        }
        let media = dir(root + "/media")
        let from = media + "/Beach.mp4"
        make(from)
        let fromKey = Paths.tagKey(from)
        library.setTags(["Holiday"], for: from)
        library.setRating(5, for: from)
        library.progress[from] = 42.5
        library.hide([from])
        library.sparedDupes.insert(fromKey)
        library.replacePrints([fromKey: PrintEntry(size: 5, mtime: 1, fp: "abc", full: nil, seen: 1)])
        library.recordMetadataTags(["2016"], for: from)
        library.session = Session(mode: "folder", root: media, path: from)
        analysis.mark(.nsfw, on: [from])
        suggestions.record(from, suggestions: [TagSuggestion(tag: "Sea", confidence: 0.05, frames: 3)],
                           model: "test", framesSeen: 3)
        suggestions.decide(from, tag: "Sea", verdict: .rejected)

        let report = await FileOps.rename(from, to: "Bali", library: library)
        let to = media + "/Bali.mp4"
        let toKey = Paths.tagKey(to)
        check("the rename happened", report.done == [to] && exists(to) && !exists(from),
              report.summary)
        check("tags and stars follow", library.tagsFor(to).contains("Holiday")
                && library.rating(to) == 5 && library.tagsFor(from).isEmpty)
        check("the resume point follows", library.resumePoint(to) == 42.5
                && library.progress[from] == nil)
        check("a HIDDEN video stays hidden after a rename",
              library.isHidden(to) && !library.hidden.contains(fromKey))
        check("the fingerprint follows, so the duplicate finder does not see a stranger",
              library.prints[toKey]?.fp == "abc" && library.prints[fromKey] == nil)
        check("a copy spared from the duplicate list stays spared",
              library.sparedDupes.contains(toKey) && !library.sparedDupes.contains(fromKey))
        check("where its tags came from follows",
              library.provenance.origins[toKey] != nil && library.provenance.origins[fromKey] == nil)
        check("the session that was playing it points at it", library.session?.path == to)
        check("its Safe/NSFW mark follows", analysis.analysis(for: to)?.userLabel == .nsfw
                && analysis.analysis(for: from) == nil)
        check("a rejected suggestion stays rejected",
              suggestions.entry(to)?.verdicts["Sea"] == .rejected && suggestions.entry(from) == nil)
        let reloaded = JSONStore.load(Paths.stateFile, fallback: PersistedState())
        check("...and the hidden flag and resume point are on disk, not just in hand",
              (reloaded.hidden ?? []).contains(toKey) && reloaded.progress[to] == 42.5)

        // Moving it on carries it all again.
        let elsewhere = dir(root + "/elsewhere")
        let moved = await FileOps.move([to], into: elsewhere, library: library)
        let there = elsewhere + "/Bali.mp4"
        check("a move carries the same", moved.done == [there] && library.isHidden(there)
                && library.resumePoint(there) == 42.5 && analysis.analysis(for: there)?.userLabel == .nsfw)
        check("...and leaves no journal behind", !exists(Paths.relocationsFile))

        // --- 3. subtitle files travel with their video --------------------------------

        let subs = dir(root + "/subs")
        make(subs + "/clip.mp4")
        make(subs + "/clip.srt", "1")
        make(subs + "/clip.en.srt", "2")
        make(subs + "/clipper.srt", "3")          // another video's, by name
        let renamedSubs = await FileOps.rename(subs + "/clip.mp4", to: "Beach", library: library)
        check("a rename renames the subtitle files with it",
              renamedSubs.done == [subs + "/Beach.mp4"]
                && names(subs) == ["Beach.en.srt", "Beach.mp4", "Beach.srt", "clipper.srt"],
              "\(names(subs))")

        let dest = dir(root + "/dest")
        make(dest + "/Beach.srt", "somebody else's")
        let movedSubs = await FileOps.move([subs + "/Beach.mp4"], into: dest, library: library)
        check("a subtitle name taken at the destination moves the whole video to “ (2)”",
              movedSubs.done == [dest + "/Beach (2).mp4"]
                && names(dest) == ["Beach (2).en.srt", "Beach (2).mp4", "Beach (2).srt", "Beach.srt"],
              "\(names(dest))")
        check("...and the file that was there is untouched",
              (try? String(contentsOfFile: dest + "/Beach.srt", encoding: .utf8)) == "somebody else's")
        check("...and nothing of the video is left behind", names(subs) == ["clipper.srt"],
              "\(names(subs))")

        make(dest + "/Sea.en.srt", "taken")
        let refused = await FileOps.rename(dest + "/Beach (2).mp4", to: "Sea", library: library)
        check("a rename whose subtitle name is taken is refused whole",
              refused.done.isEmpty && refused.failed.count == 1 && exists(dest + "/Beach (2).mp4")
                && exists(dest + "/Beach (2).en.srt"), refused.detail)

        // --- 4. case-only renames, and names as the volume spells them ------------------

        let casing = dir(root + "/case")
        make(casing + "/clip.mp4")
        make(casing + "/clip.srt")
        library.setTags(["Cased"], for: casing + "/clip.mp4")
        let recased = await FileOps.rename(casing + "/clip.mp4", to: "Clip", library: library)
        check("a rename that only changes the capitals works",
              recased.done == [casing + "/Clip.mp4"] && names(casing) == ["Clip.mp4", "Clip.srt"],
              "\(recased.summary) \(names(casing))")
        check("...and its tags follow", library.tagsFor(casing + "/Clip.mp4") == ["Cased"])

        let accents = dir(root + "/accents")
        let decomposed = "Cafe\u{301}.mp4"
        make(accents + "/" + decomposed)
        let spelt = FileOps.onDisk(accents + "/Caf\u{e9}.mp4")
        check("a name is keyed as the volume spells it, not as it was typed",
              Array((spelt as NSString).lastPathComponent.utf8) == Array(decomposed.utf8))
        check("a plain name is not looked up at all", FileOps.onDisk(accents + "/plain.mp4")
                == accents + "/plain.mp4")

        check("freeName counts the companions as part of the name", {
            let d = dir(root + "/free")
            make(d + "/x.srt")
            return (FileOps.freeName(in: d, for: "x.mp4", companions: [".srt"]) as NSString)
                .lastPathComponent == "x (2).mp4"
                && (FileOps.freeName(in: d, for: "x.mp4") as NSString).lastPathComponent == "x.mp4"
        }())

        // --- 5. the journal -------------------------------------------------------------

        let crash = dir(root + "/crash")
        make(crash + "/before.mp4")
        library.setTags(["Crashed"], for: crash + "/before.mp4")
        library.progress[crash + "/before.mp4"] = 99
        let cut = PathMap(from: crash + "/before.mp4", to: crash + "/after.mp4")
        RelocationJournal.begin(cut)
        try? fm.moveItem(atPath: crash + "/before.mp4", toPath: crash + "/after.mp4")
        // ...and the app dies here. The next launch:
        let finished = library.recoverRelocations()
        check("a move a crash cut short is finished at the next launch",
              finished.count == 1 && library.tagsFor(crash + "/after.mp4") == ["Crashed"]
                && library.resumePoint(crash + "/after.mp4") == 99)
        check("...and struck off", RelocationJournal.pending().isEmpty && !exists(Paths.relocationsFile))

        make(crash + "/stayed.mp4")
        library.setTags(["Stayed"], for: crash + "/stayed.mp4")
        RelocationJournal.begin(PathMap(from: crash + "/stayed.mp4", to: crash + "/never.mp4"))
        let absent = PathMap(from: "/Volumes/fvp-not-mounted-\(UUID().uuidString)/a.mp4",
                             to: "/Volumes/fvp-not-mounted/b.mp4")
        RelocationJournal.begin(absent)
        check("a move that never happened is dropped and changes nothing",
              library.recoverRelocations().isEmpty && library.tagsFor(crash + "/stayed.mp4") == ["Stayed"])
        check("a move on a share that is not mounted is kept for when it is",
              RelocationJournal.pending() == [absent])
        RelocationJournal.end([absent])

        // --- 6. no Undo for a rename that did not happen ------------------------------------

        let fresh = Library()
        make(dest + "/Taken.mp4")
        make(dest + "/Mine.mp4")
        let clash = await FileOps.rename(dest + "/Mine.mp4", to: "Taken", library: fresh)
        check("a rename refused as a clash leaves no Undo behind",
              clash.failed.count == 1 && fresh.undoable == nil)
        let done = await FileOps.rename(dest + "/Mine.mp4", to: "Kept", library: fresh)
        check("...a rename that happens does", done.done.count == 1
                && fresh.undoable?.label == "renaming “Mine.mp4”")

        try? fm.removeItem(atPath: root)
        print(failures == 0 ? "\nall relocation checks pass" : "\n\(failures) relocation check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
