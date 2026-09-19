// The fitted heads on disk: merge, atomicity, and what a bad file does.
//
// engine.py kept these in an `.npz`; the Swift path keeps them in JSON. The
// format changed, so the properties it must still have are checked here rather
// than assumed:
//  - a save MERGES: two training scopes (a playlist's Train button, Tag
//    Profiles' whole-library pass) must not erase each other's heads;
//  - a tag called "nsfw" cannot collide with the Safe/NSFW correction head,
//    because they are stored in different places;
//  - a head round-trips through the file bit-for-bit — it is scored in float32,
//    and a file that quietly rounds is a wrong suggestion with no error;
//  - an unreadable, truncated, newer or wrong-width file yields NO heads plus a
//    stated reason. An unfitted head mistaken for a fitted one is the failure
//    mode this app has already been burned by once.
//
// Run: Tests/run_trained_heads.sh

import Foundation

@main
struct TrainedHeadsTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-heads-\(UUID().uuidString)"
        try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let slug = "test_slug"
        let dim = 4
        func head(_ values: [Float], _ b: Float, _ n: Float) -> LogisticHead {
            LogisticHead(w: values, b: b, n: n)
        }
        // Values chosen to be unkind to any decimal round-trip: a repeating
        // third, a denormal, a tiny and a huge magnitude, and exact zeros.
        let awkward: [Float] = [0.1, -1.0 / 3.0, 1e-30, 1.5e30]
        let alpha = head(awkward, -0.371212, 23)
        let beta = head([1, -2, 3.5, -4.25], 0.490852, 20)
        let gamma = head([0, 0, 0, 0.5], -1, 7)

        // --- 1. nothing there yet ------------------------------------------
        let empty = TrainedHeads.load(root: root, slug: slug)
        check("a root with no file yields no heads", empty.isEmpty)
        check("...and no complaint about it", empty.problem == nil)
        check("...and the file it would use is under the profile's own folder",
              TrainedHeads.file(root: root, slug: slug)
                  .hasSuffix("/\(ProfileBundle.relativeDir(Paths.activeProfile))"
                             + "/\(ProfileBundle.headsRelative(slug, "_trained_heads.json"))"))

        // --- 2. write, read back -------------------------------------------
        let store = TrainedHeads(slug: slug, dim: dim, tags: ["alpha": alpha, "beta": beta], nsfw: nil)
        try! store.save(root: root, merging: false)
        let path = TrainedHeads.file(root: root, slug: slug)
        check("the file is written where the app looks for it", fm.fileExists(atPath: path))
        check("no .tmp file is left behind",
              !fm.fileExists(atPath: path + ".tmp"))

        let read1 = TrainedHeads.load(root: root, slug: slug)
        checkEqual("both heads come back", read1.tags.keys.sorted(), ["alpha", "beta"])
        check("no nsfw head yet", read1.nsfw == nil)
        checkEqual("the width is recorded", read1.dim, dim)
        checkEqual("no complaint", read1.problem, nil)
        for (tag, want) in [("alpha", alpha), ("beta", beta)] {
            guard let got = read1.tags[tag] else { check("\(tag) survived", false); continue }
            check("\(tag): every weight is bit-identical after the round trip",
                  got.w.count == want.w.count
                  && (0..<got.w.count).allSatisfy { got.w[$0].bitPattern == want.w[$0].bitPattern })
            check("\(tag): bias is bit-identical", got.b.bitPattern == want.b.bitPattern)
            checkEqual("\(tag): n is kept", got.n, want.n)
        }
        check("a loaded head actually scores, not just stores",
              read1.tags["alpha"]!.score([1, 0, 0, 0]).isFinite)

        // --- 3. merge, never replace ---------------------------------------
        let scopeA = TrainedHeads(slug: slug, dim: dim, tags: ["gamma": gamma], nsfw: nil)
        try! scopeA.save(root: root)                       // merging by default
        let read2 = TrainedHeads.load(root: root, slug: slug)
        checkEqual("a second training scope adds its head without erasing the first two",
                   read2.tags.keys.sorted(), ["alpha", "beta", "gamma"])
        check("the untouched head is still bit-identical",
              read2.tags["beta"]!.w.map { $0.bitPattern } == beta.w.map { $0.bitPattern })

        let nsfwHead = head([0.25, -0.25, 0.5, -0.5], -0.180558, 20)
        try! TrainedHeads(slug: slug, dim: dim, tags: [:], nsfw: nsfwHead).save(root: root)
        let read3 = TrainedHeads.load(root: root, slug: slug)
        checkEqual("the nsfw head lands beside the tag heads",
                   read3.nsfw?.w.map { $0.bitPattern } ?? [], nsfwHead.w.map { $0.bitPattern })
        checkEqual("...and the tag heads are untouched", read3.tags.keys.sorted(),
                   ["alpha", "beta", "gamma"])

        // A user tag may be called "nsfw". It must not overwrite the correction
        // head, and the correction head must not hide the tag.
        let collisions = head([9, 9, 9, 9], 9, 9)
        try! TrainedHeads(slug: slug, dim: dim, tags: ["nsfw": collisions], nsfw: nil).save(root: root)
        let read4 = TrainedHeads.load(root: root, slug: slug)
        checkEqual("a tag named nsfw keeps its own head", read4.tags["nsfw"]?.w.first ?? 0, Float(9))
        checkEqual("...and the Safe/NSFW correction head is still the correction head",
                   read4.nsfw?.w.first ?? 0, Float(0.25))

        // --- 4. refusing rather than guessing -------------------------------
        func write(_ json: String) {
            try! json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
        let b64_4 = Data(repeating: 0, count: 4).base64EncodedString()
        let b64_8 = Data(repeating: 0, count: 8).base64EncodedString()

        write(#"{"version":99,"dim":4,"tags":{"alpha":{"w":"\#(b64_4)","b":0,"n":1}}}"#)
        let readNewer = TrainedHeads.load(root: root, slug: slug)
        check("a newer file yields no heads", readNewer.isEmpty)
        check("...and says the version is why",
              readNewer.problem?.contains("newer version") == true)

        write("not json at all")
        let readGarbage = TrainedHeads.load(root: root, slug: slug)
        check("a corrupt file yields no heads and does not throw", readGarbage.isEmpty)
        check("...and says so", readGarbage.problem?.contains("could not be read") == true)

        // A truncated vector: 8 bytes where the width says 16. This is the one
        // that reads back as a *valid shorter head* if it is not checked.
        write(#"{"version":1,"dim":4,"tags":{"alpha":{"w":"\#(b64_8)","b":0,"n":1}}}"#)
        let readShort = TrainedHeads.load(root: root, slug: slug)
        check("a truncated head is refused, not shortened", readShort.tags["alpha"] == nil)
        check("...with the byte counts stated", readShort.problem?.contains("expected 16") == true)

        write(#"{"version":1,"tags":{}}"#)
        let readNoDim = TrainedHeads.load(root: root, slug: slug)
        check("a file with no width yields no heads",
              readNoDim.isEmpty && readNoDim.problem?.contains("no width") == true)

        // --- 5. a write that would corrupt the file fails instead -----------
        try! TrainedHeads(slug: slug, dim: dim, tags: ["ok": alpha], nsfw: nil)
            .save(root: root, merging: false)
        var wrongWidth = TrainedHeads(slug: slug, dim: 8,
                                      tags: ["wide": head(Array(repeating: 0.5, count: 8), 0, 1)], nsfw: nil)
        var threw = false
        do { try wrongWidth.save(root: root) } catch { threw = true }
        check("merging a different width into the file is refused", threw)
        let afterRefusal = TrainedHeads.load(root: root, slug: slug)
        checkEqual("...and the file it refused to write is unchanged", afterRefusal.tags.keys.sorted(), ["ok"])

        threw = false
        wrongWidth = TrainedHeads(slug: slug, dim: dim, tags: ["bad": head([1, 2], 0, 1)], nsfw: nil)
        do { try wrongWidth.save(root: root) } catch { threw = true }
        check("a head of the wrong width is refused", threw)

        threw = false
        do { try TrainedHeads(slug: slug, dim: 0, tags: [:], nsfw: nil)
                .save(root: root, merging: false) } catch { threw = true }
        check("a fresh save with no width at all is refused", threw)

        // ...but a MERGE takes the width from the file, so a caller adding one
        // head does not have to restate something the file already knows.
        let added = LogisticHead(w: [0.1, 0.2, 0.3, 0.4], b: 0, n: 1)
        let inherited = TrainedHeads(slug: slug, dim: 0, tags: ["later": added], nsfw: nil)
        var inheritedThrew = false
        do { try inherited.save(root: root) } catch { inheritedThrew = true }
        let afterInherit = TrainedHeads.load(root: root, slug: slug)
        check("a merge with no width inherits the file's", !inheritedThrew)
        checkEqual("...and the head it added is there", afterInherit.tags["later"]?.w.first ?? 0, Float(0.1))
        checkEqual("...at the file's width", afterInherit.dim, dim)

        // --- 6. one file per encoder ---------------------------------------
        let otherSlug = "other_encoder"
        try! TrainedHeads(slug: otherSlug, dim: 2,
                          tags: ["solo": head([1, 1], 0, 1)], nsfw: nil).save(root: root, merging: false)
        let otherRead = TrainedHeads.load(root: root, slug: otherSlug)
        checkEqual("a second slug has its own file", otherRead.tags.keys.sorted(), ["solo"])
        checkEqual("...and the first slug is untouched",
                   TrainedHeads.load(root: root, slug: slug).tags.keys.sorted(), ["later", "ok"])
        // Default slug is the encoder the app actually uses; the Core ML runner
        // compiles VisionEmbedder too and asserts the two agree.
        checkEqual("the default slug is the SigLIP 2 one",
                   TrainedHeads.defaultSlug, "siglip2_base")

        // --- 7. heads belong to a profile ----------------------------------
        // The point of the per-profile file: training one person must not
        // change what another is offered, and a profile that has never trained
        // must have nothing at all.
        try! TrainedHeads(slug: slug, dim: dim, tags: ["mine": gamma], nsfw: nil)
            .save(root: root, merging: false, profile: "alice")
        checkEqual("a profile's head is filed under that profile",
                   TrainedHeads.load(root: root, slug: slug, profile: "alice").tags.keys.sorted(),
                   ["mine"])
        check("another profile has no head",
              TrainedHeads.load(root: root, slug: slug, profile: "bob").tags.isEmpty)
        check("...and no complaint, since nothing was ever written for it",
              TrainedHeads.load(root: root, slug: slug, profile: "bob").problem == nil)
        check("two profiles never share a file",
              TrainedHeads.file(root: root, slug: slug, profile: "alice")
                  != TrainedHeads.file(root: root, slug: slug, profile: "bob"))
        check("nothing was left in the shared models dir",
              !fm.fileExists(atPath: (root as NSString)
                  .appendingPathComponent("models/\(slug)_trained_heads.json")))

        // --- 9. heads bind to the installed embedding space --------------------
        // Equal widths never imply equal spaces: a 4-wide head fitted in one
        // space and a 4-wide vector from another are both "4-wide" and
        // incomparable. The file carries the digest of the space it was fitted
        // against; a load against a different installed artifact refuses
        // wholesale, with the reason stated.
        let spaceRoot = NSTemporaryDirectory() + "fvp-heads-space-\(UUID().uuidString)"
        try! fm.createDirectory(atPath: spaceRoot + "/tags/siglip2_base.mlmodelc",
                                withIntermediateDirectories: true)
        try! Data("tower-v1".utf8).write(
            to: URL(fileURLWithPath: spaceRoot + "/tags/siglip2_base.mlmodelc/model.bin"))
        defer { try? fm.removeItem(atPath: spaceRoot) }
        try! ModelSpace.write(adapter: "siglip2-base-v1", dim: 4, root: spaceRoot)
        let spaceMarker = ModelSpace.read(root: spaceRoot)
        check("the marker records the installed artifact digest", spaceMarker != nil)

        func wireDict(_ root: String) -> [String: Any] {
            (try! JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: TrainedHeads.file(root: root, slug: slug)))))
                as! [String: Any]
        }
        try! TrainedHeads(slug: slug, dim: dim, tags: ["bound": alpha], nsfw: nil)
            .save(root: spaceRoot, merging: false)
        check("saving records the space the heads were fitted in",
              wireDict(spaceRoot)["space_digest"] as? String == spaceMarker?.digest)
        let bound = TrainedHeads.load(root: spaceRoot, slug: slug)
        check("heads bound to the installed space load", bound.problem == nil && bound.tags["bound"] != nil)

        // Same filenames, same width, different bytes: a different space, and
        // the old heads must refuse rather than score against it.
        try! Data("tower-v2".utf8).write(
            to: URL(fileURLWithPath: spaceRoot + "/tags/siglip2_base.mlmodelc/model.bin"))
        try! ModelSpace.write(adapter: "siglip2-base-v1", dim: 4, root: spaceRoot)
        let otherSpace = ModelSpace.read(root: spaceRoot)
        check("a changed tower is a different space though nothing else moved",
              otherSpace != nil && otherSpace != spaceMarker)
        let foreign = TrainedHeads.load(root: spaceRoot, slug: slug)
        check("heads fitted in another space are refused wholesale",
              foreign.isEmpty && foreign.dim == 0
                && foreign.problem?.contains("another embedding space") == true)

        // A file written before spaces existed (no space_digest) still loads
        // against a marked root — and the next save adopts the space it is
        // actually used against, so every file converges to being bound.
        try! TrainedHeads(slug: slug, dim: dim, tags: ["legacy": beta], nsfw: nil)
            .save(root: spaceRoot, merging: false)
        var legacy = wireDict(spaceRoot)
        legacy.removeValue(forKey: "space_digest")
        try! JSONSerialization.data(withJSONObject: legacy).write(
            to: URL(fileURLWithPath: TrainedHeads.file(root: spaceRoot, slug: slug)))
        check("a pre-binding file loads against a marked root (legacy rule)",
              TrainedHeads.load(root: spaceRoot, slug: slug).problem == nil)
        try! TrainedHeads(slug: slug, dim: dim, tags: ["adopted": gamma], nsfw: nil)
            .save(root: spaceRoot)                       // merging by default
        check("the next save binds the legacy heads to the space in use",
              wireDict(spaceRoot)["space_digest"] as? String == otherSpace?.digest)

        // No marker at all — no tower installed — loads anywhere.
        try! fm.removeItem(atPath: ModelSpace.digestFile(root: spaceRoot))
        check("no marker: heads load anywhere",
              TrainedHeads.load(root: spaceRoot, slug: slug).problem == nil)

        print(failures == 0 ? "ALL PASS trained heads" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
