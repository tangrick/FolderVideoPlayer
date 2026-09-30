// The Trash keeps tags, out of sight, and Put Back returns them — folder
// management, phase 3.
//
// A video two people tagged goes to the Trash. Its tags must leave every list —
// the profile in force, another profile on the same Mac, another person on the
// share — without being lost, and come back for all of them when the file is
// put back:
//
//   1–3. the tags leave the profile in force, another bundle (with the removal
//        queued for its sync) and another person's share file (a `gone` record
//        with no destination), their other videos untouched;
//   4.   readings, watch state, resume point and the hidden flag stay put;
//   5.   everything is kept word for word, with where the file went;
//   6.   its subtitle file went with it;
//   7.   Put Back returns every holder's tags, and the kept entry goes;
//   8.   a person who retagged it meanwhile keeps their own tags;
//   9.   a video gone from the Trash too can be forgotten;
//   10.  a discard folder inside the library is not scanned or counted;
//   11.  a held lock owes the removal, and the retry keeps their tags first;
//   12.  when the tags cannot be kept, nothing is removed from anybody.
//
// The tests never touch the user's own Trash: `FileOps.sendsToTrash` is off,
// so every volume takes the discard-folder route. Two scratch roots and one
// scratch NAS, as in test_profile_relocation.
//
// Run: Tests/run_trash_park.sh

@testable import FVPModel
import Foundation

@main
struct TrashParkTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-trash-park-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: scratch) }
        let macA = scratch + "/mac-a"
        Paths.volumes = scratch + "/Volumes/"
        let media = Paths.volumes + "media"
        let clips = media + "/clips"
        let deleted = media + "/Deleted"                  // the discard folder, INSIDE the library
        let samFolder = media + "/" + Paths.shareDir + "/sam"
        for dir in [macA, clips, deleted, samFolder] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        func make(_ path: String) { fm.createFile(atPath: path, contents: Data(path.utf8)) }
        func samTags() -> SharedTagFile? {
            fm.contents(atPath: samFolder + "/tags.json").flatMap { try? JSONDecoder().decode(SharedTagFile.self, from: $0) }
        }
        func setSam(_ videos: [String: [String]]) {
            var file = samTags() ?? SharedTagFile()
            for (rest, names) in videos { file.videos[rest] = names.isEmpty ? nil : names }
            _ = SharedTagDisk.write(file, folder: samFolder, device: "sam-mac")
        }
        FileOps.sendsToTrash = false
        ProfileRelocation.lockBudget = 0.5
        let ask: (String, String) -> String? = { _, _ in deleted }

        let a = clips + "/a.mp4"
        let key = Paths.tagKey(a)                          // "media/clips/a.mp4"
        make(a)
        make(clips + "/a.srt")
        setSam(["clips/a.mp4": ["Sunset"], "clips/other.mp4": ["Keep"]])

        Paths.support = macA
        func bundle(_ name: String) -> String { ProfileBundle.file(in: "sam", name, root: macA) }
        ProfileBundle.ensure(profile: "sam", name: "Sam", root: macA)
        JSONStore.save(bundle("tags.json"), [key: ["Sunset"]])

        let alex = Library()
        alex.profiles = ["Alex"]
        alex.person = "Alex"
        alex.setPublishDeviceName("mac-a")
        alex.setTags(["Beach"], for: a)
        alex.setFacts(["2019"], for: a)
        alex.saveFacts()
        alex.markWatched([a], true)
        alex.progress[a] = 42
        alex.hide([a])
        await alex.publishTags()

        // MARK: into the Trash

        let report = await FileOps.trash([a], library: alex, askFolder: ask)
        let binnedAt = deleted + "/a.mp4"
        check("the video goes to the discard folder", report.done == [binnedAt]
                && fm.fileExists(atPath: binnedAt) && !fm.fileExists(atPath: a), report.summary)

        check("1. its tags leave the profile in force",
              alex.tagsFor(a).isEmpty && alex.taggedWith("Beach").isEmpty && alex.count(of: "Beach") == 0)
        let samHere: [String: [String]] = JSONStore.load(bundle("tags.json"), fallback: [:])
        let samSync = JSONStore.load(bundle("shared-sync.json"), fallback: SharedSyncState())
        check("2. ...another profile on this Mac, with the removal queued for its sync",
              samHere[key] == nil && samSync.pending["media"] == [.remove("clips/a.mp4")],
              "\(samHere) \(samSync.pending)")
        let theirs = samTags()
        check("3. ...and another person's share file, recorded as gone, their other videos untouched",
              theirs?.videos["clips/a.mp4"] == nil && theirs?.gone["clips/a.mp4"] != nil
                && theirs?.gone["clips/a.mp4"]?.to == nil && theirs?.videos["clips/other.mp4"] == ["Keep"])
        check("4. readings, watch state, resume point and the hidden flag stay where they were",
              alex.factsFor(a) == ["2019"] && alex.watch.entry(key) != nil
                && alex.resumePoint(a) == 42 && alex.isHidden(a))
        let kept = ParkedTags.load().videos[key]
        check("5. every holder's tags are kept word for word, with where the file went",
              kept?.profiles == ["alex": ["Beach"], "sam": ["Sunset"]]
                && kept?.people == [samFolder: ["Sunset"]] && kept?.location == binnedAt,
              "\(String(describing: kept))")
        check("6. its subtitle file went with it",
              fm.fileExists(atPath: deleted + "/a.srt") && !fm.fileExists(atPath: clips + "/a.srt"))
        check("10. a discard folder inside the library is not scanned or counted",
              Scanner.scan(media) == [] && Scanner.count(media) == 0
                && Scanner.scan(media, skipping: []).map { ($0 as NSString).lastPathComponent } == ["a.mp4"],
              "\(Scanner.scan(media)) \(Scanner.discarded)")

        // MARK: Put Back

        try? fm.moveItem(atPath: binnedAt, toPath: a)
        try? fm.moveItem(atPath: deleted + "/a.srt", toPath: clips + "/a.srt")
        let back = await ParkedTags.restore(present: [a], library: alex)
        let samBack: [String: [String]] = JSONStore.load(bundle("tags.json"), fallback: [:])
        check("7. Put Back returns the tags to the profile in force",
              back == 1 && alex.tagsFor(a) == ["Beach"])
        check("...to the other profile on this Mac", samBack[key] == ["Sunset"])
        check("...and to the other person, bringing the path back",
              samTags()?.videos["clips/a.mp4"] == ["Sunset"] && samTags()?.gone["clips/a.mp4"] == nil)
        check("...and nothing is kept any more", ParkedTags.load().videos[key] == nil)

        // MARK: retagged while in the Trash

        _ = await FileOps.trash([a], library: alex, askFolder: ask)
        setSam(["clips/a.mp4": ["Mine"]])
        try? fm.moveItem(atPath: binnedAt, toPath: a)
        await ParkedTags.restore(present: [a], library: alex)
        check("8. a person who retagged it meanwhile keeps their own tags",
              samTags()?.videos["clips/a.mp4"] == ["Mine"] && alex.tagsFor(a) == ["Beach"])

        // MARK: gone from the Trash too

        let b = clips + "/b.mp4"
        make(b)
        alex.setTags(["Gone"], for: b)
        _ = await FileOps.trash([b], library: alex, askFolder: ask)
        try? fm.removeItem(atPath: deleted + "/b.mp4")         // the Trash is emptied
        let bKey = Paths.tagKey(b)
        check("9. a video gone from the Trash too is offered to be forgotten",
              ParkedTags.load().forgettable() == [bKey], "\(ParkedTags.load().forgettable())")
        ParkedTags.forget([bKey])
        check("...and forgetting it drops what was kept", ParkedTags.load().videos[bKey] == nil)

        // MARK: a held lock

        let c = clips + "/c.mp4"
        make(c)
        setSam(["clips/c.mp4": ["Held"]])
        let lock = samFolder + "/" + SharedTagFile.lockName
        fm.createFile(atPath: lock, contents: Data("{\"by\":\"appletv\",\"token\":\"x\"}".utf8))
        _ = await FileOps.trash([c], library: alex, askFolder: ask)
        check("11. a held lock leaves the other person's tags where they were",
              samTags()?.videos["clips/c.mp4"] == ["Held"]
                && ProfileRelocation.owed().first?.edits == [.remove("clips/c.mp4")])
        try? fm.removeItem(atPath: lock)
        ProfileRelocation.retryOwed(device: "mac-a")
        check("...and the retry keeps them before it removes them",
              samTags()?.videos["clips/c.mp4"] == nil
                && ParkedTags.load().videos[Paths.tagKey(c)]?.people == [samFolder: ["Held"]]
                && ProfileRelocation.owed().isEmpty)

        // MARK: when nothing can be kept, nothing is removed

        let d = clips + "/d.mp4"
        make(d)
        alex.setTags(["Safe"], for: d)
        JSONStore.save(bundle("tags.json"), [Paths.tagKey(d): ["Also"]])
        setSam(["clips/d.mp4": ["Theirs"]])
        // A kept-tags file from a later version of the app: this one must not
        // write it, so it cannot keep anything — and so may remove nothing.
        try? Data("{\"format\": 99, \"videos\": {}}".utf8).write(to: URL(fileURLWithPath: Paths.parkedTagsFile))
        let unkept = await FileOps.trash([d], library: alex, askFolder: ask)
        let samD: [String: [String]] = JSONStore.load(bundle("tags.json"), fallback: [:])
        check("12. tags that cannot be kept are not removed — from anybody",
              alex.tagsFor(d) == ["Safe"] && samD[Paths.tagKey(d)] == ["Also"]
                && samTags()?.videos["clips/d.mp4"] == ["Theirs"],
              "\(alex.tagsFor(d)) \(samD) \(samTags()?.videos["clips/d.mp4"] ?? [])")
        check("...and the report says so", unkept.failed.contains { $0.name == "d.mp4" })
        try? fm.removeItem(atPath: Paths.parkedTagsFile)
        try? fm.removeItem(atPath: Paths.relocationsOwedFile)
        alex.closeProfile()

        print(failures == 0 ? "\nall trash park checks pass" : "\n\(failures) trash park check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
