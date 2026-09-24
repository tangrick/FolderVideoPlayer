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
//   7. a file written by a newer format is left exactly as it is.
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

    static func sync(_ root: String, device: String) -> SharedExtras.Output {
        let stateFile = SharedExtras.stateFile(profile, root: root)
        let input = SharedExtras.Input(
            root: root, profile: profile, device: device, volumes: volumes,
            folders: ["nas": folder],
            state: JSONStore.load(stateFile, fallback: SharedExtras.State()))
        let output = SharedExtras.sync(input, lockBudget: 2)
        _ = JSONStore.save(stateFile, output.state)
        return output
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

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
