// The Organize window's model — folder management, phase 5.
//
//   1. the folder tree: nested folders, recursive counts, dot-folders and
//      discard folders left out, natural order;
//   2. a folder is empty with only clutter and empty subfolders — not with a
//      subtitle file, or a dotfile somebody put there;
//   3. one folder's listing: its videos and its other files, not recursive;
//   4. a batch move reports each file, and Stop between files leaves the rest
//      untouched and says so;
//   5. which videos a move takes off their share;
//   6. the discard list is stored as named, never resolved on the main thread
//      (a deleted folder froze the app on a sleeping NAS);
//   7. after an operation only the touched folders are read again, and the
//      tree is the one a full walk would give — a moved folder's subtree reused;
//   8. a hidden folder is read only as far as its first file;
//   9. the subtitle index answers exactly as scanning the listing did;
//   10. a folder of three thousand videos lists in one quick pass.
//
// Run: Tests/run_folder_tree.sh

@testable import FVPModel
import Foundation

@main
struct FolderTreeTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-folder-tree-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        func make(_ relative: String) {
            let path = root + "/" + relative
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(relative.utf8))
        }
        func dir(_ relative: String) {
            try? fm.createDirectory(atPath: root + "/" + relative, withIntermediateDirectories: true)
        }
        make("a.mp4"); make("clip10/x.mp4"); make("clip2/y.mp4"); make("clip2/deep/z.mkv")
        make("clip2/notes.txt"); make(".hidden/secret.mp4"); make("Deleted/gone.mp4")
        make("OnlyClutter/.DS_Store"); make("OnlyClutter/@eaDir/SYNO.jpg"); dir("OnlyClutter/empty")
        make("HasSubtitle/a.srt"); make("HasDotfile/.note")

        // 1
        let tree = FolderTree.build(root: root, skipping: [root + "/Deleted"])
        let names = tree.children?.map(\.name) ?? []
        check("1. top-level folders in natural order, dot-folders and discard folders left out",
              names == ["clip2", "clip10", "HasDotfile", "HasSubtitle", "OnlyClutter"], "\(names)")
        let clip2 = tree.children?.first { $0.name == "clip2" }
        check("...counts are recursive", tree.videoCount == 4 && clip2?.videoCount == 2,
              "\(tree.videoCount) / \(clip2?.videoCount ?? -1)")
        check("...and a subfolder is a child", clip2?.children?.map(\.name) == ["deep"])
        check("...flattened lists every folder once, the root first",
              tree.flattened.first?.path == root && Set(tree.flattened.map(\.path)).count == tree.flattened.count)

        // 2
        func node(_ name: String) -> FolderNode? { tree.children?.first { $0.name == name } }
        check("2. only clutter and empty subfolders: empty", node("OnlyClutter")?.isEmpty == true)
        check("...a subtitle file is not empty", node("HasSubtitle")?.isEmpty == false)
        check("...nor a dotfile somebody put there", node("HasDotfile")?.isEmpty == false)
        check("...and the tree agrees with the delete rule",
              node("OnlyClutter")?.isEmpty == FolderDelete.contents(of: root + "/OnlyClutter").isEmpty
                && node("HasDotfile")?.isEmpty == FolderDelete.contents(of: root + "/HasDotfile").isEmpty)

        // 3
        let listing = FolderTree.listing(of: root + "/clip2")
        check("3. a folder's listing: its own videos, not its subfolders'",
              listing.videos.map(\.path) == [root + "/clip2/y.mp4"], "\(listing.videos)")
        check("...and its other files by name", listing.otherFiles == ["notes.txt"])

        // 4
        Paths.support = root + "/support"
        let library = Library()
        let from = root + "/batch", into = root + "/into"
        for i in 1...4 { make("batch/v\(i).mp4") }
        dir("into")
        var heard: [String] = []
        var asked = 0
        let report = await FileOps.move((1...4).map { from + "/v\($0).mp4" }, into: into, library: library,
                                        progress: { _, _, name in heard.append(name) },
                                        shouldStop: { asked += 1; return asked > 2 })
        check("4. each file is reported as it starts", heard == ["v1.mp4", "v2.mp4"], "\(heard)")
        check("...Stop takes effect between files: two moved, two untouched",
              report.done.count == 2 && fm.fileExists(atPath: from + "/v3.mp4")
                && fm.fileExists(atPath: from + "/v4.mp4") && !fm.fileExists(atPath: into + "/v3.mp4"),
              report.summary)
        check("...the report says what moved where, for the playlist to follow",
              report.moves == [PathMap(from: from + "/v1.mp4", to: into + "/v1.mp4"),
                               PathMap(from: from + "/v2.mp4", to: into + "/v2.mp4")], "\(report.moves)")
        let playlist = [from + "/v1.mp4", from + "/v3.mp4", root + "/a.mp4"]
        check("...and a playlist following it finds each video where it is now",
              playlist.map { PathMap.follow($0, through: report.moves) }
                == [into + "/v1.mp4", from + "/v3.mp4", root + "/a.mp4"])
        check("...a folder move carries every path under it",
              PathMap.follow(root + "/Old/x/y.mp4",
                             through: [PathMap(from: root + "/Old", to: root + "/New", isFolder: true)])
                == root + "/New/x/y.mp4")
        check("...and the report says what was left",
              report.skipped.map(\.name) == ["v3.mp4", "v4.mp4"]
                && report.skipped.allSatisfy { $0.why.contains("stopped") })

        // 7. after an operation, only the folders it touched are read again —
        // and the result is the tree a full walk would give.
        let before = FolderTree.build(root: root, skipping: [root + "/Deleted"])
        try? fm.moveItem(atPath: root + "/clip10/x.mp4", toPath: root + "/clip2/x.mp4")
        let afterMove = FolderTree.refreshed(before, touched: [root + "/clip10", root + "/clip2"],
                                             skipping: [root + "/Deleted"])
        check("7. a file moved between folders: the refreshed tree is the full walk's",
              afterMove == FolderTree.build(root: root, skipping: [root + "/Deleted"]))
        try? fm.moveItem(atPath: root + "/clip2", toPath: root + "/Renamed")
        make("Renamed/deep/added-behind.mp4")            // not read: the subtree is reused
        let renamed = FolderTree.refreshed(afterMove, touched: [root],
                                           moved: [PathMap(from: root + "/clip2", to: root + "/Renamed", isFolder: true)],
                                           skipping: [root + "/Deleted"])
        let reused = FolderTree.index(renamed)[root + "/Renamed/deep"]
        check("...a renamed folder keeps its subtree without reading it again",
              reused?.videoCount == 1 && renamed.children?.contains { $0.name == "clip2" } == false,
              "\(reused?.videoCount ?? -1)")
        try? fm.removeItem(atPath: root + "/Renamed/deep/added-behind.mp4")
        try? fm.createDirectory(atPath: root + "/Fresh", withIntermediateDirectories: true)
        try? fm.removeItem(atPath: root + "/HasDotfile/.note")
        try? fm.removeItem(atPath: root + "/HasDotfile")
        let changed = FolderTree.refreshed(renamed, touched: [root], skipping: [root + "/Deleted"])
        check("...a new folder and a deleted one: the full walk's tree again",
              changed == FolderTree.build(root: root, skipping: [root + "/Deleted"]))

        // 8. a hidden folder is read only as far as its first file
        for i in 0..<300 { make("WithThumbs/.FolderVideoPlayer/thumbs/\(i).jpg") }
        let thumbs = FolderTree.build(root: root + "/WithThumbs")
        check("8. a hidden folder with anything in it counts once, found at its first file",
              thumbs.ownOthers == 1 && FolderTree.hasAnyFile(root + "/WithThumbs/.FolderVideoPlayer"))

        // 9. the subtitle index answers exactly as the listing scan did
        let listed = ["clip.mp4", "clip.srt", "clip.en.srt", "Clip.PT-BR.vtt", "clip.en.extra.srt",
                     "clipper.srt", "clip.averyverylongtag.srt", "a.b.mp4", "a.b.srt", "a.b.en.vtt", "a.srt", "x.txt"]
        let index = SubtitleFile.sidecarIndex(listed)
        let same = ["clip.mp4", "a.b.mp4", "a.mp4", "none.mp4", "CLIP.MOV"].allSatisfy {
            SubtitleFile.sidecars(for: $0, in: index) == SubtitleFile.sidecars(for: $0, in: listed)
        }
        check("9. the subtitle index gives the same answer as reading the listing", same,
              "\(SubtitleFile.sidecars(for: "clip.mp4", in: index)) vs \(SubtitleFile.sidecars(for: "clip.mp4", in: listed))")

        // 10. a big folder lists in one pass
        for i in 0..<3000 { make("Big/v\(i).mp4"); make("Big/v\(i).srt") }
        let started = Date()
        let big = FolderTree.listing(of: root + "/Big")
        let took = Date().timeIntervalSince(started)
        check("10. three thousand videos with subtitles list in under a second",
              big.videos.count == 3000 && big.videos.allSatisfy(\.hasSubtitles) && took < 1,
              String(format: "%.2f s", took))

        // 6. the discard list is stored as named: no file system call on the
        // main thread (resolving a folder on a sleeping NAS waits for it).
        let named = root + "/into"              // under /var, a symlink to /private/var
        library.discardFolders = ["test": named]
        check("6. the discard list is kept as named — nothing resolved on the main thread",
              Scanner.discarded == [named], "\(Scanner.discarded)")
        check("...and a walk resolves it for itself",
              Scanner.expanded(Scanner.discarded).count == 2)
        library.discardFolders = [:]

        // 5
        let saved = Paths.volumes
        Paths.volumes = "/Volumes/"
        let leaving = FolderOps.leavingShare(["/Volumes/NAS/a.mp4", "/Volumes/NAS/b/c.mp4", "/Users/me/d.mp4"],
                                             into: "/Users/me/Movies")
        check("5. moving to a Mac's own disk takes the share's videos off it",
              leaving == ["/Volumes/NAS/a.mp4", "/Volumes/NAS/b/c.mp4"], "\(leaving)")
        check("...moving within the share takes nothing off it",
              FolderOps.leavingShare(["/Volumes/NAS/a.mp4"], into: "/Volumes/NAS/Trips").isEmpty)
        check("...and another share is off it too",
              FolderOps.leavingShare(["/Volumes/NAS/a.mp4"], into: "/Volumes/Other/x") == ["/Volumes/NAS/a.mp4"])
        Paths.volumes = saved

        print(failures == 0 ? "\nall folder tree checks pass" : "\n\(failures) folder tree check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
