// Named people and transcripts following a profile to another Mac through the
// shares — two scratch support roots standing in for two Macs, one scratch
// folder standing in for the NAS.
//
//   1. the first Mac publishes its people (with vectors and thumbnails) and
//      its transcripts beside the tags;
//   2. a new Mac with nothing takes all of it: the names, the .f32 and .jpg
//      files byte for byte, and the transcript lines;
//   3. a rename on one Mac arrives on the other as a rename — the old name
//      does not come back through the union;
//   4. a forgotten person stays forgotten on the other Mac;
//   5. two Macs naming different people at once both keep both;
//   6. a transcript made on the second Mac reaches the first;
//   7. a file written by a newer format is left exactly as it is;
//   8. file facts (dates, cameras, places) travel: a new Mac takes them, a
//      correction or a removal on one Mac reaches the other, a Mac's own
//      reading is never overwritten on a first meeting, a video on this Mac's
//      own disk is never published, and a newer facts file is left alone;
//   9. a sync-state file from before facts existed still loads its face base.
//
// Run: Tests/run_shared_extras.sh

@testable import FVPModel
import Foundation

@main
struct SharedExtrasTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   \(what)" : "FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let fm = FileManager.default
    static let scratch = NSTemporaryDirectory() + "shared-extras-\(UUID().uuidString)"
    static let volumes = scratch + "/Volumes/"
    static let profile = "quincy"
    static let folder = volumes + "nas/.FolderVideoPlayer/quincy"
    static let video = volumes + "nas/clips/a.mp4"

    static func mac(_ name: String) -> String { scratch + "/" + name }

    static func sync(_ root: String, device: String,
                     facts: [String: [String]] = [:]) -> SharedExtras.Output {
        let stateFile = SharedExtras.stateFile(profile, root: root)
        let input = SharedExtras.Input(
            root: root, profile: profile, device: device, volumes: volumes,
            folders: ["nas": folder],
            state: JSONStore.load(stateFile, fallback: SharedExtras.State()),
            facts: facts)
        let output = SharedExtras.sync(input, lockBudget: 2)
        _ = JSONStore.save(stateFile, output.state)
        return output
    }

    /// One Mac's facts, as the library holds them, with a sync's updates
    /// applied the way `Library.takeSharedFacts` applies them.
    static var factsOf: [String: [String: [String]]] = [:]
    @discardableResult
    static func syncFacts(_ root: String, device: String) -> [String: [String]] {
        let output = sync(root, device: device, facts: factsOf[root] ?? [:])
        for (key, names) in output.factUpdates {
            factsOf[root, default: [:]][key] = names.isEmpty ? nil : names
        }
        return output.factUpdates
    }

    static func sharedFacts() -> [String: [String]]? {
        fm.contents(atPath: folder + "/facts.json")
            .flatMap { try? JSONDecoder().decode(SharedExtras.Facts.self, from: $0) }?.videos
    }

    static func people(_ root: String) -> [String: [String]] {
        let file = ProfileBundle.file(in: profile, "faces.json", root: root)
        guard let data = fm.contents(atPath: file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String]]) ?? [:]
    }

    static func setPeople(_ root: String, _ people: [String: [String]]) {
        let data = try! JSONSerialization.data(withJSONObject: people)
        FaceRegistry.write(data, to: ProfileBundle.file(in: profile, "faces.json", root: root))
    }

    static func addFace(_ root: String, _ hash: String) {
        let vector = (0..<FaceRegistry.dim).map { Float($0) / 128 + Float(hash.count) }
        FaceRegistry.write(vector.withUnsafeBufferPointer { Data(buffer: $0) },
                           to: FaceRegistry.vectorPath(root: root, hash: hash))
        FaceRegistry.write(Data("jpeg-\(hash)".utf8),
                           to: FaceRegistry.thumbnailPath(root: root, hash: hash))
    }

    static func transcribe(_ root: String, _ path: String, _ text: String) {
        let store = try! EvidenceStore(root: root, profile: profile)
        defer { store.close() }
        _ = try! store.insertTranscript([TranscriptLine(path: path, start: 0, end: 2, text: text,
                                                        language: "en", source: "test")],
                                        path: path, language: "en")
    }

    static func transcript(_ root: String, _ path: String) -> [String] {
        guard fm.fileExists(atPath: Paths.evidenceFile(in: profile, root: root)),
              let store = try? EvidenceStore(root: root, profile: profile) else { return [] }
        defer { store.close() }
        return ((try? store.transcript(for: path)) ?? []).map(\.text)
    }

    static func main() {
        defer { try? fm.removeItem(atPath: scratch) }
        try! fm.createDirectory(atPath: volumes + "nas/clips", withIntermediateDirectories: true)
        let (a, b) = (mac("a"), mac("b"))

        // 1. The first Mac publishes.
        let h1 = "aa11aa11aa11aa11aa11aa11aa11aa11", h2 = "bb22bb22bb22bb22bb22bb22bb22bb22"
        addFace(a, h1); addFace(a, h2)
        setPeople(a, ["Bob": [h1, h2]])
        transcribe(a, video, "hello from a")
        _ = sync(a, device: "mac-a")
        let facesOnShare = fm.contents(atPath: folder + "/faces.json")
            .flatMap { try? JSONDecoder().decode(SharedExtras.Faces.self, from: $0) }
        check(facesOnShare?.people == ["Bob": [h1, h2]], "the share holds the named people")
        check(facesOnShare?.vectors.count == 2 && facesOnShare?.thumbs.count == 2,
              "...with every face's vector and thumbnail")
        check(fm.fileExists(atPath: folder + "/transcripts.json"), "the share holds the transcripts")
        check(!fm.fileExists(atPath: folder + "/tags.lock"), "the lock is released")

        // 2. A new Mac takes all of it.
        let arrived = sync(b, device: "mac-b")
        check(arrived.facesChanged, "the new Mac reports people arrived")
        check(arrived.transcriptsImported == 1, "the new Mac imported one transcript")
        check(people(b) == ["Bob": [h1, h2]], "the new Mac knows Bob")
        check(fm.contents(atPath: FaceRegistry.vectorPath(root: b, hash: h1))
                == fm.contents(atPath: FaceRegistry.vectorPath(root: a, hash: h1)),
              "the face vector arrived byte for byte")
        check(fm.contents(atPath: FaceRegistry.thumbnailPath(root: b, hash: h2))
                == Data("jpeg-\(h2)".utf8), "the thumbnail arrived")
        check(transcript(b, video) == ["hello from a"], "the transcript arrived")
        check(sync(b, device: "mac-b").transcriptsImported == 0, "a second sync imports nothing again")

        // 3. A rename on B arrives on A as a rename.
        setPeople(b, ["Robert": [h1, h2]])
        _ = sync(b, device: "mac-b")
        _ = sync(a, device: "mac-a")
        check(people(a) == ["Robert": [h1, h2]], "a rename arrives without the old name")

        // 4. A forget on A stays forgotten on B.
        setPeople(a, [:])
        _ = sync(a, device: "mac-a")
        _ = sync(b, device: "mac-b")
        check(people(b).isEmpty, "a forgotten person stays forgotten")

        // 5. Both Macs name someone before either syncs.
        let h3 = "cc33cc33cc33cc33cc33cc33cc33cc33", h4 = "dd44dd44dd44dd44dd44dd44dd44dd44"
        addFace(a, h3); addFace(b, h4)
        setPeople(a, ["Alice": [h3]])
        setPeople(b, ["Carol": [h4]])
        _ = sync(a, device: "mac-a")
        _ = sync(b, device: "mac-b")
        _ = sync(a, device: "mac-a")
        check(people(a) == ["Alice": [h3], "Carol": [h4]], "the first Mac keeps both names")
        check(people(b) == ["Alice": [h3], "Carol": [h4]], "the second Mac keeps both names")
        check(fm.fileExists(atPath: FaceRegistry.vectorPath(root: a, hash: h4)),
              "...and the other Mac's face vector")

        // 6. A transcript made on B reaches A.
        let other = volumes + "nas/clips/b.mp4"
        transcribe(b, other, "hello from b")
        _ = sync(b, device: "mac-b")
        check(sync(a, device: "mac-a").transcriptsImported == 1, "the first Mac imported one")
        check(transcript(a, other) == ["hello from b"], "the second Mac's transcript arrived")
        check(transcript(a, video) == ["hello from a"], "the first Mac's own is untouched")

        // 7. A newer format is left alone.
        let newer = Data("{\"format\":99,\"people\":{\"Zed\":[\"x\"]},\"vectors\":{},\"thumbs\":{}}".utf8)
        try! newer.write(to: URL(fileURLWithPath: folder + "/faces.json"))
        setPeople(a, ["Alice": [h3]])
        _ = sync(a, device: "mac-a")
        check(fm.contents(atPath: folder + "/faces.json") == newer, "a newer file is not written over")
        check(people(a) == ["Alice": [h3]], "...nor merged in")

        // The merge on its own: a first meeting unions, a missing base is not a removal.
        check(SharedExtras.mergePeople(local: ["A": ["1"]], base: nil, shared: ["A": ["2"], "B": ["3"]])
                == ["A": ["1", "2"], "B": ["3"]], "a first meeting keeps every face")

        // 8. File facts.
        // The merge on its own first.
        let first = SharedExtras.mergeFacts(local: ["a": ["2016"], "b": ["1080p"]], base: nil,
                                            shared: ["a": ["2017"], "c": ["Singapore"]])
        check(first.local == ["a": ["2016"], "b": ["1080p"], "c": ["Singapore"]],
              "a first meeting fills this Mac's gaps and keeps its own reading")
        check(first.shared == ["a": ["2017"], "b": ["1080p"], "c": ["Singapore"]],
              "...and fills the share's gaps without overwriting it")
        let theirs = SharedExtras.mergeFacts(local: ["a": ["2016"]], base: ["a": ["2016"]],
                                             shared: ["a": ["2016", "Singapore"]])
        check(theirs.local == ["a": ["2016", "Singapore"]], "a change made only elsewhere is taken")
        let ours = SharedExtras.mergeFacts(local: ["a": ["2016", "Iceland"]], base: ["a": ["2016"]],
                                           shared: ["a": ["2016"]])
        check(ours.shared == ["a": ["2016", "Iceland"]], "a change made only here is sent")
        let both = SharedExtras.mergeFacts(local: ["a": ["Mine"]], base: ["a": ["Old"]],
                                           shared: ["a": ["Theirs"]])
        check(both.local == ["a": ["Mine"]] && both.shared == ["a": ["Mine"]],
              "changed on both: this Mac's stands")
        let gone = SharedExtras.mergeFacts(local: [:], base: ["a": ["2016"]], shared: ["a": ["2016"]])
        check(gone.shared.isEmpty && gone.local.isEmpty, "facts removed here are removed from the share")
        let reordered = SharedExtras.mergeFacts(local: ["a": ["2016", "1080P"]], base: ["a": ["1080p", "2016"]],
                                                shared: ["a": ["1080p", "2016"]])
        check(reordered.shared == ["a": ["1080p", "2016"]], "order and case are not a change")

        // Two Macs through the share.
        let (c, d) = (mac("c"), mac("d"))
        factsOf[c] = ["nas/clips/a.mp4": ["2016", "May 2016", "1080p", "Singapore"],
                      "nas/clips/b.mp4": ["2019"],
                      "/Users/someone/Movies/local.mp4": ["2020"]]
        syncFacts(c, device: "mac-c")
        check(sharedFacts() == ["clips/a.mp4": ["2016", "May 2016", "1080p", "Singapore"],
                                "clips/b.mp4": ["2019"]],
              "the share holds the facts, keyed from its root")
        check(sharedFacts()?.keys.contains { $0.contains("local.mp4") } == false,
              "a video on this Mac's own disk is never published")

        let taken = syncFacts(d, device: "mac-d")
        check(taken.count == 2 && factsOf[d]?["nas/clips/a.mp4"] == ["2016", "May 2016", "1080p", "Singapore"],
              "a new Mac takes every fact without opening a video")
        check(syncFacts(d, device: "mac-d").isEmpty, "a second sync changes nothing")

        factsOf[d]?["nas/clips/a.mp4"] = ["2016", "May 2016", "1080p", "Kuala Lumpur"]
        syncFacts(d, device: "mac-d")
        syncFacts(c, device: "mac-c")
        check(factsOf[c]?["nas/clips/a.mp4"]?.contains("Kuala Lumpur") == true
                && factsOf[c]?["nas/clips/a.mp4"]?.contains("Singapore") == false,
              "a place corrected on one Mac arrives on the other")

        factsOf[c]?["nas/clips/b.mp4"] = nil
        syncFacts(c, device: "mac-c")
        syncFacts(d, device: "mac-d")
        check(factsOf[d]?["nas/clips/b.mp4"] == nil, "a video's facts removed on one Mac go on the other")

        let e = mac("e")
        factsOf[e] = ["nas/clips/a.mp4": ["2015"]]
        syncFacts(e, device: "mac-e")
        check(factsOf[e]?["nas/clips/a.mp4"] == ["2015"], "a Mac's own reading survives its first meeting")

        let newerFacts = Data("{\"format\":99,\"videos\":{}}".utf8)
        try! newerFacts.write(to: URL(fileURLWithPath: folder + "/facts.json"))
        factsOf[c]?["nas/clips/z.mp4"] = ["2030"]
        check(syncFacts(c, device: "mac-c").isEmpty
                && fm.contents(atPath: folder + "/facts.json") == newerFacts,
              "a newer facts file is neither merged nor written over")

        // 9. A state file from before facts: its face base must survive.
        let old = Data("{\"faceBase\":{\"nas\":{\"Bob\":[\"h\"]}},\"transcriptMtime\":{},\"transcriptsOnShare\":{}}".utf8)
        let decoded = try? JSONDecoder().decode(SharedExtras.State.self, from: old)
        check(decoded?.faceBase["nas"] == ["Bob": ["h"]] && decoded?.factBase.isEmpty == true,
              "an older sync state still loads, with no fact base")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
