// The image tower at two precisions (float32 "tags", float16 "tags-fp16") as ONE
// embedding space.
//
// What must hold, because the whole point is that switching is free in both
// directions and that nothing weakens the space identity otherwise:
//
//   1. the app loads the chosen build when it is installed, else an installed one;
//   2. the prompt table follows the build, and falls back to the other's copy;
//   3. installing the other precision beside an intact build JOINS the recorded
//      space — the digest (every cache namespace and head binding) does not move;
//   4. the re-check passes for whichever build is chosen;
//   5. a tower whose bytes changed still mints a new space, and a stale marker
//      is never joined;
//   6. removing one precision keeps the marker for the other; removing the last
//      removes it;
//   7. an undescribed install (no pack descriptor) only ever joins: it leaves a
//      marker-less installation without one, so its legacy cache namespace
//      stays where it is, and it never replaces a space.
//
// Run: Tests/run_tower_precision.sh

@testable import FVPModel
import Foundation

@main
struct TowerPrecisionTest {
    static func main() throws {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !ok { failures += 1 }
        }

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-towers-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root + "/tags", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let fp32 = ModelSpace.towers[0], fp16 = ModelSpace.towers[1]
        let preprocess = ModelSpace.declaredPreprocess
        func place(_ tower: ModelSpace.Tower, fill: UInt8) throws {
            let dir = root + "/" + tower.directory
            try? fm.removeItem(atPath: dir)
            try fm.createDirectory(atPath: dir + "/weights", withIntermediateDirectories: true)
            try Data(repeating: fill, count: 4096).write(to: URL(fileURLWithPath: dir + "/weights/weight.bin"))
            for ext in ["json", "f32"] {
                try Data("x".utf8).write(to: URL(fileURLWithPath: "\(root)/tags/\(tower.prompts).\(ext)"))
            }
        }
        func digest(_ tower: ModelSpace.Tower) -> String? {
            ModelSpace.digestOfDirectory(at: URL(fileURLWithPath: root + "/" + tower.directory),
                                         preprocess: preprocess)
        }
        func write(_ tower: ModelSpace.Tower) throws {
            try ModelSpace.write(adapter: "siglip2-base-v1", dim: 768, root: root,
                                 preprocess: preprocess, tower: tower)
        }
        func choose(_ tower: ModelSpace.Tower) throws {
            let bundle = AIBundle(id: tower.bundleID, title: tower.bundleID, what: "fixture", feature: "tags",
                                  assets: [AIBundleAsset(url: "https://example.invalid/t",
                                                         sha256: String(repeating: "a", count: 64),
                                                         bytes: 1, kind: .coreMLPackage,
                                                         install: tower.directory)],
                                  pack: nil)
            try ModelRegistry.choose(bundle, root: root)
        }
        let marker = { ModelSpace.read(root: root) }

        // --- 1 and 2. which build loads, and whose prompt table ---------------
        check("with nothing installed the float32 path is named",
              ModelSpace.activeTower(root: root) == fp32)
        try place(fp16, fill: 16)
        check("the only installed build loads, chosen or not",
              ModelSpace.activeTower(root: root) == fp16)
        check("…and its own prompt table is read",
              PromptTable.jsonURL(root: root).lastPathComponent == "\(fp16.prompts).json")
        try place(fp32, fill: 32)
        check("with both installed and nothing chosen, float32 loads",
              ModelSpace.activeTower(root: root) == fp32)
        try choose(fp16)
        check("choosing float16 loads it", VisionEmbedder.modelURL(root: root).path.hasSuffix(fp16.directory))
        try fm.removeItem(atPath: "\(root)/tags/\(fp16.prompts).json")
        check("a build missing its prompt table reads the other build's copy",
              PromptTable.jsonURL(root: root).lastPathComponent == "\(fp32.prompts).json")
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(root)/tags/\(fp16.prompts).json"))

        // --- 3 and 4. the second precision joins the space --------------------
        try write(fp32)
        let space = marker()
        check("float32 install records its own digest", space?.digest == digest(fp32))
        try write(fp16)
        check("installing float16 beside it keeps the space's digest",
              marker()?.digest == space?.digest, marker()?.digest ?? "no marker")
        check("…and accepts both builds",
              marker()?.accepted == [fp32.directory: digest(fp32)!, fp16.directory: digest(fp16)!])
        check("the chosen float16 build passes the re-check",
              marker()?.matchesInstalledBytes(root: root) == true)
        try choose(fp32)
        check("switching back to float32 passes it too",
              marker()?.matchesInstalledBytes(root: root) == true)
        let joined = marker()
        try write(fp16)
        check("reinstalling identical float16 bytes changes nothing", marker() == joined)
        check("the marker with two builds is accepted for inference",
              (try? ModelSpace.readForInference(root: root)) == joined)

        // --- 5. changed bytes and stale markers --------------------------------
        try place(fp16, fill: 99)
        try choose(fp16)
        check("float16 bytes changed under the marker fail the re-check",
              marker()?.matchesInstalledBytes(root: root) == false)
        try write(fp16)
        check("reinstalling a changed float16 build mints a new space",
              marker()?.digest == digest(fp16) && marker()?.digest != space?.digest)

        try fm.removeItem(atPath: ModelSpace.digestFile(root: root))
        try place(fp32, fill: 32)
        try place(fp16, fill: 16)
        try write(fp32)
        let fresh = marker()
        try place(fp32, fill: 33)          // the float32 build changed; the marker is stale
        try write(fp16)
        check("a stale marker is never joined",
              marker()?.digest == digest(fp16) && marker()?.digest != fresh?.digest)

        // A marker from before `members` existed identified the float32 tower.
        try place(fp32, fill: 32)
        let legacy = ModelSpace(adapter: "siglip2-base-v1", digest: digest(fp32)!, dim: 768,
                                preprocess: preprocess)
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: ModelSpace.digestFile(root: root)))
        try write(fp16)
        check("float16 joins a marker written before two builds existed",
              marker()?.digest == legacy.digest && marker()?.accepted[fp16.directory] == digest(fp16))

        var forged = legacy
        forged.members = ["tags/elsewhere.mlmodelc": digest(fp32)!]
        try JSONEncoder().encode(forged).write(to: URL(fileURLWithPath: ModelSpace.digestFile(root: root)))
        check("a marker naming a tower this build does not know is refused",
              (try? ModelSpace.readForInference(root: root)) == nil
                && FileManager.default.fileExists(atPath: ModelSpace.digestFile(root: root)))

        // --- 6. removal ---------------------------------------------------------
        try JSONEncoder().encode(legacy).write(to: URL(fileURLWithPath: ModelSpace.digestFile(root: root)))
        try write(fp16)
        func bundle(_ tower: ModelSpace.Tower) -> AIBundle {
            AIBundle(id: tower.bundleID, title: tower.bundleID, what: "fixture", feature: "tags",
                     assets: [AIBundleAsset(url: "https://example.invalid/\(tower.bundleID)",
                                            sha256: String(repeating: "a", count: 64),
                                            bytes: 1, kind: .coreMLPackage, install: tower.directory)],
                     pack: nil)
        }
        try ModelInstaller.remove(bundle(fp16), root: root)
        check("removing float16 keeps the space for float32",
              marker()?.digest == legacy.digest && marker()?.accepted == [fp32.directory: legacy.digest])
        try ModelInstaller.remove(bundle(fp32), root: root)
        check("removing the last build removes the marker", marker() == nil)

        // --- 7. no marker stays no marker ---------------------------------------
        try place(fp32, fill: 32)
        let asset = { (tower: ModelSpace.Tower) in
            AIBundleAsset(url: "https://example.invalid/\(tower.bundleID)",
                          sha256: String(repeating: "a", count: 64), bytes: 1,
                          kind: .coreMLPackage, install: tower.directory)
        }
        let staged = root + "/staged-fp16.mlmodelc"
        try fm.createDirectory(atPath: staged, withIntermediateDirectories: true)
        try Data(repeating: 16, count: 4096).write(to: URL(fileURLWithPath: staged + "/weight.bin"))
        try ModelInstaller.activate([(asset(fp16), URL(fileURLWithPath: staged))],
                                    bundle: bundle(fp16), root: root)
        check("an undescribed float16 install on a marker-less machine writes no marker",
              marker() == nil)

        // …and joins an intact space, but never replaces a stale one.
        try write(fp32)
        try fm.removeItem(atPath: root + "/" + fp16.directory)
        try fm.createDirectory(atPath: staged, withIntermediateDirectories: true)
        try Data(repeating: 16, count: 4096).write(to: URL(fileURLWithPath: staged + "/weight.bin"))
        try ModelInstaller.activate([(asset(fp16), URL(fileURLWithPath: staged))],
                                    bundle: bundle(fp16), root: root)
        check("an undescribed float16 install joins an intact space",
              marker()?.digest == digest(fp32) && marker()?.accepted[fp16.directory] == digest(fp16))
        let before = marker()
        try place(fp32, fill: 34)          // a legacy refresh with new compiled bytes
        try ModelSpace.write(adapter: "siglip2-base-v1", dim: 768, root: root, preprocess: preprocess,
                             tower: fp32, joinOnly: true)
        check("an undescribed install never replaces a space", marker() == before)

        print(failures == 0 ? "\nALL PASS tower precision" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
