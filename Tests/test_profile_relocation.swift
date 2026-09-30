// Every tag profile follows a move — folder management, phase 2.
//
// Two people tag the same video on one NAS. One of them renames it. Neither
// person's tags may go missing, on any device:
//
//   1. the other profiles on the renaming Mac follow — tags, readings, watch
//      state, moments, suggestion verdicts, Safe/NSFW marks, transcripts —
//      and the move is queued for each one's own sync;
//   2. every other person's folder on the share follows — their tags.json
//      takes the `.move` their own devices would send (tag names untouched,
//      nothing else in the file touched, the renaming Mac not added to their
//      devices), and their facts.json and transcripts.json are re-keyed. A
//      folder of old per-device files only is left alone;
//   3. the renaming person's own file follows at their own sync;
//   4. the other person's own Mac, at its next sync, has their tags at the new
//      path AND replays the move for what lives only on that Mac: resume
//      point, watch state, the hidden flag;
//   5. a person's folder whose lock is held is owed its moves, and gets them
//      on the next try;
//   6. who is warned about when a video leaves its share, and that their tags
//      are left exactly where they were;
//   7. a move a crash cut short reaches the other people too once recovered;
//   8. `unseenMoves`: chains followed, removals and seen records skipped.
//
// Two scratch support roots stand in for the two Macs and one scratch folder
// for the NAS, as in test_profile_travels. `Paths.support` is global, so each
// Mac's library is closed before the other's root is put in force.
//
// Run: Tests/run_profile_relocation.sh

@testable import FVPModel
import Foundation

@main
struct ProfileRelocationTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-profile-relocation-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: scratch) }
        let (macA, macB) = (scratch + "/mac-a", scratch + "/mac-b")
        Paths.volumes = scratch + "/Volumes/"
        let clips = Paths.volumes + "media/clips"
        let home = scratch + "/Users/alex/Movies"
        for dir in [macA, macB, clips, home] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let a = clips + "/a.mp4", b = clips + "/b.mp4"
        fm.createFile(atPath: a, contents: Data("a".utf8))
        let nas = Paths.volumes + "media/" + Paths.shareDir
        let samFolder = nas + "/sam"
        let caseyFolder = nas + "/casey"
        for dir in [samFolder, caseyFolder] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        func read<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
            fm.contents(atPath: path).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        func samTags() -> SharedTagFile? { read(SharedTagFile.self, samFolder + "/tags.json") }
        ProfileRelocation.lockBudget = 0.5

        // MARK: the NAS, before anybody moves anything

        var samFile = SharedTagFile(videos: ["clips/a.mp4": ["Sunset", "Mum"], "clips/other.mp4": ["Keep"]])
        samFile.devices["sam-mac"] = SharedTagFile.Device(format: 1, seen: 1)
        _ = SharedTagDisk.write(samFile, folder: samFolder, device: "sam-mac")
        _ = SharedExtras.write(SharedExtras.Facts(videos: ["clips/a.mp4": ["2019"]]),
                               samFolder + "/facts.json", device: "sam-mac")
        let line = SharedExtras.Transcripts.Line(start: 0, end: 1, text: "hello", language: "en", source: "test")
        _ = SharedExtras.write(SharedExtras.Transcripts(videos: ["clips/a.mp4": [line]]),
                               samFolder + "/transcripts.json", device: "sam-mac")
        // Casey's devices have not moved to the shared file yet.
        JSONStore.save(caseyFolder + "/tags-casey-tv.json", ["clips/a.mp4": ["Old"]])

        // MARK: Sam's own Mac takes her profile in, and watches the video

        Paths.support = macB
        let samMac = Library()
        samMac.setPublishDeviceName("sam-mac")
        await samMac.openProfile("Sam")
        check("Sam's Mac has her tags at the old path",
              Set(samMac.tagsFor(a)) == ["Sunset", "Mum"], "\(samMac.tagsFor(a))")
        samMac.markWatched([a], true)
        samMac.progress[a] = 77
        samMac.hide([a])
        samMac.save()
        samMac.closeProfile()

        // MARK: Alex's Mac, which also holds a profile for Sam

        Paths.support = macA
        ProfileBundle.ensure(profile: "sam", name: "Sam", root: macA)
        func bundle(_ name: String) -> String { ProfileBundle.file(in: "sam", name, root: macA) }
        let key = "media/clips/a.mp4", newKey = "media/clips/b.mp4"
        JSONStore.save(bundle("tags.json"), [key: ["Sunset", "Mum"]])
        MetadataFacts([key: ["2019"]]).save(to: bundle("readings.json"))
        var watched = WatchLog()
        watched.mark([key], watched: true)
        watched.save(to: bundle("watch.json"))
        var book = MomentBook()
        try? book.upsert(Moment(key: key, start: 5, end: nil, title: "the wave", createdAt: 1, modifiedAt: 1))
        _ = book.save(to: bundle("moments.json"))
        var verdicts = VideoSuggestions()
        verdicts.verdicts["Sea"] = .rejected
        JSONStore.save(bundle("suggestions.json"), [key: verdicts])
        JSONStore.save(bundle("marks.json"), [key: VideoMark(label: .safe)])
        if let store = try? EvidenceStore(root: macA, profile: "sam") {
            _ = try? store.insertTranscript([TranscriptLine(path: a, start: 0, end: 1, text: "hello")],
                                            path: a, language: "en")
            store.close()
        }

        let alex = Library()
        alex.profiles = ["Alex"]
        alex.person = "Alex"
        alex.setPublishDeviceName("mac-a")
        alex.setTags(["Beach"], for: a)
        await alex.publishTags()

        check("before the move: Sam is the one who would be warned about",
              ProfileRelocation.peopleTagging([a], skip: "alex") == ["sam": 1],
              "\(ProfileRelocation.peopleTagging([a], skip: "alex"))")

        let renamed = await FileOps.rename(a, to: "b", library: alex)
        check("Alex renames the video", renamed.done == [b] && fm.fileExists(atPath: b), renamed.summary)
        check("...his own tags follow", alex.tagsFor(b) == ["Beach"] && alex.tagsFor(a).isEmpty)

        // 1. the other profile on Alex's Mac, never opened
        let samTagsHere: [String: [String]] = JSONStore.load(bundle("tags.json"), fallback: [:])
        check("Sam's profile on Alex's Mac: her tags follow, word for word",
              samTagsHere == [newKey: ["Sunset", "Mum"]], "\(samTagsHere)")
        check("...her readings", MetadataFacts.load(at: bundle("readings.json")).names(for: newKey) == ["2019"]
                && MetadataFacts.load(at: bundle("readings.json")).names(for: key).isEmpty)
        check("...her watch state", WatchLog.load(at: bundle("watch.json")).entry(newKey) != nil
                && WatchLog.load(at: bundle("watch.json")).entry(key) == nil)
        check("...her moments", MomentBook.load(at: bundle("moments.json")).moments(for: newKey).map(\.title)
                == ["the wave"])
        let verdictsHere: [String: VideoSuggestions] = JSONStore.load(bundle("suggestions.json"), fallback: [:])
        check("...her rejected suggestion", verdictsHere[newKey]?.verdicts["Sea"] == .rejected
                && verdictsHere[key] == nil)
        let marksHere: [String: VideoMark] = JSONStore.load(bundle("marks.json"), fallback: [:])
        check("...her Safe/NSFW mark", marksHere[newKey]?.label == .safe && marksHere[key] == nil)
        let transcriptHere = (try? EvidenceStore(root: macA, profile: "sam")).map { store -> Bool in
            defer { store.close() }
            return ((try? store.transcript(for: b)) ?? []).map(\.text) == ["hello"]
                && ((try? store.transcript(for: a)) ?? []).isEmpty
        } ?? false
        check("...her transcript", transcriptHere)
        let samSync = JSONStore.load(bundle("shared-sync.json"), fallback: SharedSyncState())
        check("...and the move is queued for her own sync",
              samSync.pending["media"] == [.move("clips/a.mp4", "clips/b.mp4")], "\(samSync.pending)")

        // 2. every other person's folder on the share
        let theirs = samTags()
        check("Sam's tags.json on the NAS: her tags at the new path, word for word",
              theirs?.videos["clips/b.mp4"] == ["Sunset", "Mum"] && theirs?.videos["clips/a.mp4"] == nil,
              "\(theirs?.videos ?? [:])")
        check("...with the move recorded for late edits to follow",
              theirs?.destination(of: "clips/a.mp4") == "clips/b.mp4")
        check("...and nothing else in her file touched",
              theirs?.videos["clips/other.mp4"] == ["Keep"] && theirs?.devices.keys.sorted() == ["sam-mac"],
              "\(theirs?.devices.keys.sorted() ?? [])")
        check("...her file facts follow",
              read(SharedExtras.Facts.self, samFolder + "/facts.json")?.videos == ["clips/b.mp4": ["2019"]])
        check("...and her transcript",
              read(SharedExtras.Transcripts.self, samFolder + "/transcripts.json")?.videos.keys.sorted()
                == ["clips/b.mp4"])
        check("a person with only old per-device files is left alone",
              read([String: [String]].self, caseyFolder + "/tags-casey-tv.json") == ["clips/a.mp4": ["Old"]])
        check("nothing is owed", ProfileRelocation.owed().isEmpty)

        // 3. Alex's own file, at his own sync
        await alex.publishTags()
        let his = read(SharedTagFile.self, nas + "/alex/tags.json")
        check("Alex's own tags.json follows at his sync",
              his?.videos == ["clips/b.mp4": ["Beach"]] && his?.destination(of: "clips/a.mp4") == "clips/b.mp4",
              "\(his?.videos ?? [:])")
        alex.closeProfile()

        // 4. Sam's own Mac, at its next sync
        Paths.support = macB
        let samAgain = Library()
        await samAgain.openProfile("Sam")
        check("Sam opens her profile on her own Mac: nothing missing",
              Set(samAgain.tagsFor(b)) == ["Sunset", "Mum"] && samAgain.tagsFor(a).isEmpty,
              "\(samAgain.tagsFor(b)) / \(samAgain.tagsFor(a))")
        check("...her resume point replayed to the new path",
              samAgain.resumePoint(b) == 77 && samAgain.progress[a] == nil)
        check("...her watch state", samAgain.watch.entry(Paths.tagKey(b)) != nil
                && samAgain.watch.entry(Paths.tagKey(a)) == nil)
        check("...and the video is still hidden on her Mac", samAgain.isHidden(b) && !samAgain.isHidden(a))
        let seen = JSONStore.load(Paths.sharedSyncFile("Sam"), fallback: SharedSyncState()).goneSeen?["media"]
        check("...and the move is remembered as replayed", seen?["clips/a.mp4"] != nil, "\(seen ?? [:])")
        await samAgain.publishTags()
        check("her own next save keeps the new path",
              samTags()?.videos["clips/b.mp4"] == ["Sunset", "Mum"] && samTags()?.videos["clips/a.mp4"] == nil)
        samAgain.closeProfile()

        // 5. a person's folder whose lock is held
        Paths.support = macA
        let c = clips + "/c.mp4", d = clips + "/d.mp4"
        fm.createFile(atPath: c, contents: Data("c".utf8))
        var withC = samTags() ?? SharedTagFile()
        withC.videos["clips/c.mp4"] = ["Held"]
        _ = SharedTagDisk.write(withC, folder: samFolder, device: "sam-mac")
        let lock = samFolder + "/" + SharedTagFile.lockName
        fm.createFile(atPath: lock, contents: Data("{\"by\":\"appletv\",\"token\":\"x\"}".utf8))
        let alexAgain = Library()
        await alexAgain.openProfile("Alex")
        _ = await FileOps.rename(c, to: "d", library: alexAgain)
        check("a held lock leaves Sam's file as it was",
              samTags()?.videos["clips/c.mp4"] == ["Held"] && samTags()?.videos["clips/d.mp4"] == nil)
        check("...and owes her folder the move",
              ProfileRelocation.owed() == [ProfileRelocation.Owed(folder: samFolder,
                                                                    moves: [["clips/c.mp4", "clips/d.mp4"]])],
              "\(ProfileRelocation.owed())")
        try? fm.removeItem(atPath: lock)
        ProfileRelocation.retryOwed(device: "mac-a")
        check("once the lock is free, the next try delivers it",
              samTags()?.videos["clips/d.mp4"] == ["Held"] && samTags()?.videos["clips/c.mp4"] == nil)
        check("...and nothing is owed any more",
              ProfileRelocation.owed().isEmpty && !fm.fileExists(atPath: Paths.relocationsOwedFile))

        // 6. a video leaving its share
        check("moving off the share: Sam is who the warning names",
              ProfileRelocation.peopleTagging([d], skip: "alex") == ["sam": 1])
        alexAgain.setTags(["Mine"], for: d)
        let away = await FileOps.move([d], into: home, library: alexAgain)
        check("the video leaves the share, with Alex's own tags",
              away.done == [home + "/d.mp4"] && alexAgain.tagsFor(home + "/d.mp4") == ["Mine"])
        check("...and Sam's tags stay on the share exactly as they were",
              samTags()?.videos["clips/d.mp4"] == ["Held"])

        // 7. a crash cut a move short, and the next launch finishes it
        let e = clips + "/e.mp4", f = clips + "/f.mp4"
        fm.createFile(atPath: e, contents: Data("e".utf8))
        var withE = samTags() ?? SharedTagFile()
        withE.videos["clips/e.mp4"] = ["Crash"]
        _ = SharedTagDisk.write(withE, folder: samFolder, device: "sam-mac")
        RelocationJournal.begin(PathMap(from: e, to: f))
        try? fm.moveItem(atPath: e, toPath: f)
        let finished = alexAgain.recoverRelocations()
        await ProfileRelocation.spread(finished, library: alexAgain)
        check("a move a crash cut short reaches Sam's file once recovered",
              finished.count == 1 && samTags()?.videos["clips/f.mp4"] == ["Crash"])
        alexAgain.closeProfile()

        // 8. which moves a Mac still has to replay
        var gone = SharedTagFile()
        gone.gone = ["x": .init(to: "y", at: 1), "y": .init(to: "z", at: 2),
                     "binned": .init(to: nil, at: 3), "old": .init(to: "new", at: 4)]
        let unseen = gone.unseenMoves(seen: ["old": 4])
        check("a chain is followed to where the video is now; a removal and a seen move are not replayed",
              unseen.moves == [["x", "z"], ["y", "z"]], "\(unseen.moves)")
        check("...and everything the file still records is now seen",
              unseen.seen == ["x": 1, "y": 2, "binned": 3, "old": 4])
        check("a record seen at another time is a new move",
              gone.unseenMoves(seen: ["old": 3]).moves.contains(["old", "new"]))

        print(failures == 0 ? "\nall profile relocation checks pass"
                            : "\n\(failures) profile relocation check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
