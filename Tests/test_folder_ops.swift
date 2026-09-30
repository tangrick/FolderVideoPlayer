// Folder operations — folder management, phase 4.
//
//   1.  names: every rule, for folders and for videos;
//   2.  a new folder is "untitled folder", then "untitled folder 2";
//   3.  renaming a folder carries every video in it, subfolders included —
//       and never `Clips 2019`, which only starts with the same letters;
//   4.  a video known under the old folder whose file is already gone moves too;
//   5.  the lists that name folders follow: pinned and recent (this profile and
//       another), scans, discard folders, the session, background upkeep;
//   6.  another profile on this Mac and another person on the share follow —
//       their tags AND their pinned folders — their devices untouched;
//   7.  a folder moves into another; not into itself; not across drives;
//   8.  a case-only folder rename;
//   9.  two thousand videos carried in one batch, fast, the hook told once;
//   10. a folder move a crash cut short is finished at the next launch;
//   11. the delete code holds no recursive delete;
//   12. a folder with a video, a subtitle file or a dotfile is not deleted;
//   13. one with only the Mac's and the NAS's clutter, and empty subfolders, is;
//   14. a file dropped in mid-delete stops it, and nothing is lost;
//   15. a deleted folder leaves every list that named it.
//
// Run: Tests/run_folder_ops.sh

@testable import FVPModel
import Foundation

@main
struct FolderOpsTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-folder-ops-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: scratch) }
        let macA = scratch + "/mac-a"
        Paths.volumes = scratch + "/Volumes/"
        let media = Paths.volumes + "media"
        let clips = media + "/Clips", sub = clips + "/sub", clips2019 = media + "/Clips 2019"
        let samFolder = media + "/" + Paths.shareDir + "/sam"
        for dir in [macA, sub, clips2019, samFolder] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        func make(_ path: String) { fm.createFile(atPath: path, contents: Data(path.utf8)) }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        func read<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
            fm.contents(atPath: path).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        let a = clips + "/a.mp4", b = sub + "/b.mp4", c = clips2019 + "/c.mp4"
        [a, b, c].forEach(make)
        ProfileRelocation.lockBudget = 0.5

        // 1. names
        for (name, bad) in [("", true), (".", true), ("a/b", true), ("a:b", true), (".hidden", true),
                            (Paths.shareDir, true), (String(repeating: "a", count: 256), true),
                            ("  Trips  ", false), ("Holiday 2019", false)] {
            check("folder name “\(name.prefix(20))” \(bad ? "refused" : "accepted")",
                  (FolderOps.validateName(name, isFolder: true) != nil) == bad)
        }
        check("a video may not become a .txt", FolderOps.validateName("clip.txt", isFolder: false) != nil)
        check("...but may be renamed .mkv, or with no extension",
              FolderOps.validateName("clip.mkv", isFolder: false) == nil
                && FolderOps.validateName("clip", isFolder: false) == nil)

        // 2. new folders
        let made1 = await FolderOps.makeFolder(in: media)
        let made2 = await FolderOps.makeFolder(in: media)
        let taken = await FolderOps.makeFolder(in: media, named: "Clips")
        check("2. a new folder is “untitled folder”, then “untitled folder 2”",
              made1.done == [media + "/untitled folder"] && made2.done == [media + "/untitled folder 2"])
        check("...and a name already there is refused", taken.done.isEmpty && taken.failed.count == 1)

        // MARK: the library, another profile and another person

        Paths.support = macA
        var state = PersistedState()
        state.pinnedByProfile = ["sam": [clips, media + "/Other"]]
        JSONStore.save(Paths.stateFile, state)
        ProfileBundle.ensure(profile: "sam", name: "Sam", root: macA)
        func bundle(_ name: String) -> String { ProfileBundle.file(in: "sam", name, root: macA) }
        let aKey = Paths.tagKey(a), bKey = Paths.tagKey(b)
        JSONStore.save(bundle("tags.json"), [aKey: ["Sunset"]])
        var upkeep = MaintenanceFile()
        upkeep.settings.folders = [clips, clips2019]
        _ = upkeep.save(to: bundle("maintenance.json"))
        _ = SharedTagDisk.write(SharedTagFile(videos: ["Clips/a.mp4": ["Sunset"], "Clips/sub/b.mp4": ["Wave"]]),
                                folder: samFolder, device: "sam-mac")
        _ = SharedExtras.write(SharedExtras.Pins(folders: ["Clips", "Clips/sub", "Other"]),
                               samFolder + "/pins.json", device: "sam-mac")

        let alex = Library()
        alex.profiles = ["Alex"]
        alex.person = "Alex"
        alex.setPublishDeviceName("mac-a")
        alex.setTags(["Beach"], for: a)
        alex.setTags(["Deep"], for: b)
        alex.setTags(["Keep"], for: c)
        let orphan = clips + "/gone.mp4"
        alex.setTags(["Orphan"], for: orphan)
        alex.progress[a] = 12
        alex.hide([b])
        alex.markWatched([b], true)
        alex.pin(folder: clips)
        alex.remember(folder: sub)
        alex.scans.append(DupeScan(id: "t", name: "t", folders: [clips]))
        alex.discardFolders["media"] = sub + "/Deleted"
        alex.session = Session(mode: "folder", root: clips, path: a)
        alex.saveTags()

        // 3–6. rename Clips → Trips
        let trips = media + "/Trips"
        let renamed = await FolderOps.renameFolder(clips, to: "Trips", library: alex)
        check("...and its report says what moved, for the playlist to follow",
              renamed.moves == [PathMap(from: clips, to: trips, isFolder: true)])
        check("3. the folder is renamed", renamed.done == [trips] && exists(trips + "/sub/b.mp4") && !exists(clips),
              renamed.summary)
        check("...its videos' tags follow, subfolders included",
              alex.tagsFor(trips + "/a.mp4") == ["Beach"] && alex.tagsFor(trips + "/sub/b.mp4") == ["Deep"]
                && alex.tagsFor(a).isEmpty)
        check("...and resume point, hidden flag and watch state",
              alex.resumePoint(trips + "/a.mp4") == 12 && alex.isHidden(trips + "/sub/b.mp4")
                && alex.watch.entry(Paths.tagKey(trips + "/sub/b.mp4")) != nil)
        check("...but “Clips 2019”, which only starts the same, is untouched",
              alex.tagsFor(c) == ["Keep"] && exists(c))
        check("4. a video known under the old folder whose file is gone moves too",
              alex.tagsFor(trips + "/gone.mp4") == ["Orphan"] && alex.tagsFor(orphan).isEmpty)
        let saved = JSONStore.load(Paths.stateFile, fallback: PersistedState())
        check("5. pinned and recent follow", alex.pinned == [trips] && alex.recent.contains(trips + "/sub"),
              "\(alex.pinned) \(alex.recent)")
        check("...another profile's pinned folders too",
              saved.pinnedByProfile?["sam"] == [trips, media + "/Other"], "\(saved.pinnedByProfile ?? [:])")
        check("...scans, discard folders and the session",
              alex.scans.last?.folders == [trips] && alex.discardFolders["media"] == trips + "/sub/Deleted"
                && alex.session?.root == trips)
        let samUpkeep = MaintenanceFile.load(at: bundle("maintenance.json"))
        check("...and another profile's background upkeep", samUpkeep.settings.folders == [trips, clips2019],
              "\(samUpkeep.settings.folders)")
        var mine = MaintenanceFile()
        mine.settings.folders = [clips]
        mine.known[media] = ["Clips/a.mp4": 5]
        mine.relocate(PathMap(from: clips, to: trips, isFolder: true))
        check("...and upkeep in hand, a snapshot above the folder re-rooted",
              mine.settings.folders == [trips] && mine.known[media] == ["Trips/a.mp4": 5])
        let samTags: [String: [String]] = JSONStore.load(bundle("tags.json"), fallback: [:])
        check("6. another profile on this Mac follows", samTags == [Paths.tagKey(trips + "/a.mp4"): ["Sunset"]],
              "\(samTags)")
        let theirs = read(SharedTagFile.self, samFolder + "/tags.json")
        check("...another person on the share: their tags",
              theirs?.videos == ["Trips/a.mp4": ["Sunset"], "Trips/sub/b.mp4": ["Wave"]]
                && theirs?.devices.isEmpty == true, "\(theirs?.videos ?? [:])")
        check("...and their pinned folders",
              read(SharedExtras.Pins.self, samFolder + "/pins.json")?.folders == ["Trips", "Trips/sub", "Other"])
        _ = aKey; _ = bKey

        // 7. moving folders
        let box = media + "/Box"
        try? fm.createDirectory(atPath: box, withIntermediateDirectories: true)
        let moved = await FolderOps.moveFolder(trips, into: box, library: alex)
        check("7. a folder moves into another", moved.done == [box + "/Trips"]
                && alex.tagsFor(box + "/Trips/a.mp4") == ["Beach"], moved.summary)
        let inside = await FolderOps.moveFolder(box, into: box + "/Trips", library: alex)
        check("...never into itself", inside.done.isEmpty && inside.failed.count == 1 && exists(box))
        let realSameVolume = FolderOps.sameVolume
        FolderOps.sameVolume = { _, _ in false }
        let across = await FolderOps.moveFolder(box + "/Trips", into: media, library: alex)
        FolderOps.sameVolume = realSameVolume
        check("...never across drives, and nothing moves",
              across.done.isEmpty && exists(box + "/Trips/a.mp4"), across.detail)

        // 8. case only
        let recased = await FolderOps.renameFolder(box, to: "box", library: alex)
        check("8. a case-only folder rename works",
              recased.done.count == 1 && (try? fm.contentsOfDirectory(atPath: media))?.contains("box") == true
                && alex.tagsFor(media + "/box/Trips/a.mp4") == ["Beach"], recased.detail)

        // 9. batching
        let big = media + "/Big"
        try? fm.createDirectory(atPath: big, withIntermediateDirectories: true)
        var many: [String: [String]] = [:]
        for i in 0..<2000 { many[Paths.tagKey(big + "/v\(i).mp4")] = ["Many"] }
        alex.applyTags(["Many"], to: many.keys.map(Paths.tagPath))
        var told = 0, pairs = 0
        alex.pathsMoved = { told += 1; pairs += $0.count }
        let started = Date()
        _ = await FolderOps.renameFolder(big, to: "Bigger", library: alex)
        let took = Date().timeIntervalSince(started)
        alex.pathsMoved = nil
        check("9. two thousand videos carried in one batch in under 2 s",
              took < 2 && alex.taggedWith("Many").count == 2000
                && alex.taggedWith("Many").allSatisfy { $0.hasPrefix(media + "/Bigger/") },
              String(format: "%.2f s", took))
        check("...the stores told once, with every move", told == 1 && pairs == 2000, "\(told) / \(pairs)")

        // 10. a crash mid folder move
        let before = media + "/Before", after = media + "/After"
        try? fm.createDirectory(atPath: before, withIntermediateDirectories: true)
        make(before + "/d.mp4")
        alex.setTags(["Crash"], for: before + "/d.mp4")
        RelocationJournal.begin(PathMap(from: before, to: after, isFolder: true))
        try? fm.moveItem(atPath: before, toPath: after)
        await FolderOps.recover(library: alex)
        check("10. a folder move a crash cut short is finished at the next launch",
              alex.tagsFor(after + "/d.mp4") == ["Crash"] && RelocationJournal.pending().isEmpty)

        // 11. the code guard
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../FolderVideoPlayer/Model/FolderDelete.swift").path
        let code = (try? String(contentsOfFile: source, encoding: .utf8)) ?? ""
        check("11. the delete code holds no recursive delete — rmdir and unlink only",
              !code.isEmpty && !code.contains("removeItem(") && !code.contains("trashItem(")
                && code.contains("rmdir(") && code.contains("unlink("))

        // 12–14. deleting
        func folderWith(_ name: String, _ files: [String], dirs: [String] = []) -> String {
            let dir = media + "/" + name
            for d in dirs { try? fm.createDirectory(atPath: dir + "/" + d, withIntermediateDirectories: true) }
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for f in files { make(dir + "/" + f) }
            return dir
        }
        for (name, file) in [("HasVideo", "x.mp4"), ("HasSubtitle", "x.srt"), ("HasDotfile", ".note")] {
            let dir = folderWith(name, [file])
            let refused = await FolderOps.deleteFolder(dir, library: alex)
            check("12. a folder holding \(file) is not deleted, and nothing in it is touched",
                  refused.done.isEmpty && exists(dir + "/" + file), refused.detail)
        }
        let clutter = folderWith("Clutter", [".DS_Store", "._x.mp4", "Icon\r", "@eaDir/SYNO_x.jpg"],
                                 dirs: ["@eaDir", "empty/deeper"])
        let cleared = await FolderOps.deleteFolder(clutter, library: alex)
        check("13. only clutter and empty subfolders: deleted, all of it",
              cleared.done == [clutter] && !exists(clutter), cleared.detail)
        let racing = folderWith("Racing", [".DS_Store"], dirs: ["inner"])
        FolderDelete.beforeRemoving = { make(racing + "/inner/arrived.mp4") }
        let raced = await FolderOps.deleteFolder(racing, library: alex)
        FolderDelete.beforeRemoving = nil
        check("14. a file dropped in mid-delete stops it, and it is still there",
              raced.done.isEmpty && exists(racing + "/inner/arrived.mp4")
                && raced.detail.contains("1 video"), raced.detail)

        // 15. a deleted folder leaves every list
        let pinnedGone = media + "/PinnedGone"
        try? fm.createDirectory(atPath: pinnedGone, withIntermediateDirectories: true)
        alex.pin(folder: pinnedGone)
        _ = SharedExtras.write(SharedExtras.Pins(folders: ["PinnedGone", "Other"]),
                               samFolder + "/pins.json", device: "sam-mac")
        var samUp = MaintenanceFile.load(at: bundle("maintenance.json"))
        samUp.settings.folders.append(pinnedGone)
        _ = samUp.save(to: bundle("maintenance.json"))
        let deleted = await FolderOps.deleteFolder(pinnedGone, library: alex)
        check("15. a deleted folder leaves this profile's pins",
              deleted.done == [pinnedGone] && !alex.pinned.contains(pinnedGone))
        check("...another profile's background upkeep",
              !MaintenanceFile.load(at: bundle("maintenance.json")).settings.folders.contains(pinnedGone))
        check("...and another person's pinned folders on the share",
              read(SharedExtras.Pins.self, samFolder + "/pins.json")?.folders == ["Other"])
        alex.closeProfile()

        print(failures == 0 ? "\nall folder ops checks pass" : "\n\(failures) folder ops check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
