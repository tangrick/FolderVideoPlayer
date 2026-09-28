// What a profile carries to another Mac, end to end through the library: one
// Mac tags a video, names the person in it, reads its facts and pins a folder,
// and a second Mac with nothing opens the profile the way File ▸ Open does.
//
//   1. the first Mac's publish leaves everything on the share — tags, people,
//      file facts, pinned folders — which is also all the Apple TV reads;
//   2. the second Mac gets the tags, the person (name and face vector), the
//      facts and the pinned folders;
//   3. pins changed on the second Mac reach the first when it opens the
//      profile again, and a folder on a Mac's own disk stays on that Mac.
//
// Two scratch support roots stand in for the two Macs, one scratch folder for
// the NAS. `Paths.support` is global, so each Mac's library is closed before
// the other's root is put in force: a close cancels the pending auto-publish,
// which would otherwise land in the wrong Mac's folder.
//
// Run: Tests/run_profile_travels.sh

@testable import FVPModel
import Foundation

@main
struct ProfileTravelsTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-profile-travels-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: scratch) }
        let (macA, macB) = (scratch + "/mac-a", scratch + "/mac-b")
        Paths.volumes = scratch + "/Volumes/"
        let video = Paths.volumes + "media/clips/a.mp4"
        let kids = Paths.volumes + "media/kids"
        let clips = Paths.volumes + "media/clips"
        let homeFolder = scratch + "/Users/someone/Movies"
        for dir in [macA, macB, clips, kids] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: video, contents: Data())
        let folder = Paths.volumes + "media/.FolderVideoPlayer/quincy"
        func onShare<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            fm.contents(atPath: folder + "/" + name).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        let hash = "0123abcd"
        let vector = Data((0..<512).map { UInt8($0 % 251) })

        // MARK: the first Mac

        Paths.support = macA
        Paths.activeProfile = "quincy"
        let a = Library()
        a.profiles = ["Quincy"]
        a.person = "Quincy"
        a.setPublishDeviceName("mac-a")
        a.setTags(["Beach", "Mum"], for: video)
        a.setFacts(["2016", "May 2016", "Singapore"], for: video)
        a.saveFacts()
        a.pinned = [kids, homeFolder]
        // Mum is a person: the face registry names her, with her face vector.
        JSONStore.save(ProfileBundle.file(in: "quincy", "faces.json", root: macA), ["Mum": [hash]])
        FaceRegistry.write(vector, to: FaceRegistry.vectorPath(root: macA, hash: hash))
        await a.publishTags()
        a.closeProfile()

        check("the share holds the tags", onShare(SharedTagFile.self, "tags.json")?.videos["clips/a.mp4"] == ["Beach", "Mum"])
        check("...the people", onShare(SharedExtras.Faces.self, "faces.json")?.people == ["Mum": [hash]])
        check("...the file facts",
              onShare(SharedExtras.Facts.self, "facts.json")?.videos["clips/a.mp4"] == ["2016", "May 2016", "Singapore"])
        check("...and the pinned folders, without one on the Mac's own disk",
              onShare(SharedExtras.Pins.self, "pins.json")?.folders == ["kids"])

        // MARK: a second Mac opens the profile

        Paths.support = macB
        let b = Library()
        b.setPublishDeviceName("mac-b")
        await b.openProfile("Quincy")
        check("the second Mac has the profile open", b.profileOpen && b.person == "Quincy", b.person)
        check("...with its tags", b.tagsFor(video) == ["Beach", "Mum"], "\(b.tagsFor(video))")
        let people: [String: [String]] = JSONStore.load(ProfileBundle.file(in: "quincy", "faces.json", root: macB),
                                                        fallback: [:])
        check("...its people", people == ["Mum": [hash]], "\(people)")
        check("...with the face to recognise them by",
              fm.contents(atPath: FaceRegistry.vectorPath(root: macB, hash: hash)) == vector)
        check("...its file facts", Set(b.factsFor(video)) == ["2016", "May 2016", "Singapore"], "\(b.factsFor(video))")
        check("...and its pinned folders", b.pinned == [kids], "\(b.pinned)")

        b.unpin(folder: kids)
        b.pin(folder: clips)
        await b.publishTags()
        b.closeProfile()
        check("pins changed on the second Mac reach the share",
              onShare(SharedExtras.Pins.self, "pins.json")?.folders == ["clips"])

        // MARK: the first Mac, later

        Paths.support = macA
        await a.openProfile("Quincy")
        check("...and the first Mac takes them, keeping its own disk's folder",
              a.pinned == [clips, homeFolder], "\(a.pinned)")
        a.closeProfile()

        print(failures == 0 ? "\nall profile travel checks pass" : "\n\(failures) profile travel check(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
