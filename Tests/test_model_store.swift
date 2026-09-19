// Kept versions of an installed pack, without a network and without Xcode.
//
// An install writes every asset to the fixed path its catalog entry names, so
// installing revision 2 of a pack overwrites revision 1. This store keeps a copy
// of what was installed so an older revision can be switched back to with no
// download at all. The things worth proving:
//
//   1. what is installed is what gets kept — measured on disk, and a plain file
//      re-checked against the checksum its catalog entry declares;
//   2. the same catalog entry kept twice is ONE version, and a changed bundle is
//      a new one (the directory is named by the catalog digest);
//   3. a copy that never finished is invisible: no manifest, not a version;
//   4. a keep that fails leaves nothing behind — not a half version, and not a
//      file in the store that a later switch would install;
//   5. a tampered kept copy is refused before anything is copied, and a version
//      is refused when the files it needs are not there;
//   6. `isLive` is the receipt's answer, not the store's opinion — one answer to
//      "which version is installed", asked of the authority;
//   7. the store is bounded: the oldest version goes when a newer one is kept;
//   8. activation copies (the store keeps its own) and removing a kept version
//      never touches what is installed;
//   9. a catalogue cannot install into the store: a download that could write it
//      could overwrite a kept version, or forge one.
//
// `@main` rather than top-level code: this file compiles alongside the app's
// model layer and only main.swift may carry top-level statements.
//
// Run: Tests/run_model_store.sh

import Foundation

@main
struct ModelStoreTest {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            print("FAIL the harness threw before finishing — \(error)")
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-store-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        // --- fixtures -----------------------------------------------------------
        /// A plain-file asset whose declared checksum is the checksum of the
        /// bytes really written, so a healthy keep is possible.
        func write(_ install: String, _ contents: String) throws -> AIBundleAsset {
            let path = try ModelCatalogPolicy.destination(install, root: root).path
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            let data = Data(contents.utf8)
            try data.write(to: URL(fileURLWithPath: path))
            return AIBundleAsset(url: "https://example.invalid/\(install.replacingOccurrences(of: "/", with: "-"))",
                                 sha256: (try? ModelVerifier.sha256(fileAt: path)) ?? "",
                                 bytes: Int64(data.count), kind: .file, install: install)
        }

        /// A compiled package: a directory, whose identity is its whole tree.
        func writePackage(_ install: String, _ contents: String) throws -> AIBundleAsset {
            let path = try ModelCatalogPolicy.destination(install, root: root).path
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: URL(fileURLWithPath: (path as NSString).appendingPathComponent("coremldata.bin")))
            return AIBundleAsset(url: "https://example.invalid/pack",
                                 sha256: String(repeating: "b", count: 64),
                                 bytes: 1024, kind: .coreMLPackage, install: install)
        }

        func bundle(_ id: String, revision: String, assets: [AIBundleAsset]) -> AIBundle {
            AIBundle(id: id, title: "Pack \(id)", what: "fixture", feature: "tags", assets: assets,
                     pack: ModelPackDescriptor(version: 1, modelID: "siglip2-base", revision: revision,
                                               adapter: "siglip2-base-v1", minimumMacOS: "14.0",
                                               architectures: ["arm64", "x86_64"], license: "apache-2.0",
                                               sourceURL: "https://example.invalid/model"))
        }

        // --- 1. what is installed is what gets kept -----------------------------
        let promptsV1 = try write("tags/keep_prompts.f32", "rows-v1")
        let tableV1 = try write("tags/keep_prompts.json", "{\"v\":1}")
        let v1 = bundle("keep-a", revision: "r1", assets: [promptsV1, tableV1])

        let keptV1 = try ModelStore.keep(root: root, bundle: v1)
        // The digest has to be a digest of the SAME bytes every time: it names
        // the kept directory and it is what a receipt is compared against.
        check("the catalog digest of one bundle is one number",
              ModelStore.digest(of: v1) == ModelStore.digest(of: v1),
              ModelStore.digest(of: v1).prefix(12) + " vs " + ModelStore.digest(of: v1).prefix(12))
        check("a keep returns the version it kept",
              keptV1.version.digest == ModelStore.digest(of: v1),
              "kept=\(keptV1.version.digest.prefix(12)) computed=\(ModelStore.digest(of: v1).prefix(12))")
        check("the version is named by its catalog digest",
              keptV1.version.token == String(ModelStore.digest(of: v1).prefix(12)),
              "token=\(keptV1.version.token)")
        check("what it costs is measured, not declared",
              keptV1.version.bytes > 0 && keptV1.version.bytes >= 12,
              "bytes=\(keptV1.version.bytes)")
        let keptDir = ModelStore.directory(root: root, version: keptV1.version)
        check("the kept copy holds the files as installed",
              fm.fileExists(atPath: (keptDir as NSString).appendingPathComponent("tags/keep_prompts.f32")) &&
              fm.fileExists(atPath: (keptDir as NSString).appendingPathComponent("tags/keep_prompts.json")))
        check("the manifest is written",
              fm.fileExists(atPath: (keptDir as NSString).appendingPathComponent("version.json")))
        check("staging is not left behind", !fm.fileExists(atPath: keptDir + ".keeping"))
        check("a kept version is not live without a receipt",
              !keptV1.version.isLive(root: root))
        // The row names it the way the user saw it in the catalogue, plus the
        // revision that tells two kept versions of it apart.
        check("a kept version describes itself",
              keptV1.version.summary == "Pack keep-a · revision r1", keptV1.version.summary)

        // --- 2. one directory per catalog entry ---------------------------------
        let again = try ModelStore.keep(root: root, bundle: v1)
        check("keeping the same entry again is a no-op",
              again.version.token == keptV1.version.token &&
              ModelStore.versions(root: root, bundleID: "keep-a").count == 1,
              "first=\(keptV1.version.token) again=\(again.version.token) count=\(ModelStore.versions(root: root, bundleID: "keep-a").count)")
        check("nothing was dropped re-keeping one version", again.dropped.isEmpty)

        // A changed bundle is a new version: same id, different bytes.
        let promptsV2 = try write("tags/keep_prompts.f32", "rows-v2")
        let tableV2 = try write("tags/keep_prompts.json", "{\"v\":2}")
        let v2 = bundle("keep-a", revision: "r2", assets: [promptsV2, tableV2])
        let keptV2 = try ModelStore.keep(root: root, bundle: v2)
        check("a changed bundle is a second version",
              keptV2.version.token != keptV1.version.token &&
              ModelStore.versions(root: root, bundleID: "keep-a").count == 2)
        check("the newest kept version is listed first",
              ModelStore.versions(root: root, bundleID: "keep-a").first?.token == keptV2.version.token)

        // --- 3. an unfinished copy is invisible ---------------------------------
        let deadDir = ModelStore.directory(root: root, bundleID: "keep-a", token: "deadbeef0000")
        try fm.createDirectory(atPath: deadDir, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: URL(fileURLWithPath: (deadDir as NSString).appendingPathComponent("junk")))
        check("a copy with no manifest is not a version",
              ModelStore.versions(root: root, bundleID: "keep-a").count == 2)
        try? fm.removeItem(atPath: deadDir)

        // A copy that died between writing its manifest and being moved into
        // place leaves `<token>.keeping/version.json` behind — and that manifest
        // names a version whose directory does not exist. Listing it would show
        // a phantom in the Kept row, let it occupy a kept slot so a real version
        // gets pruned in its place, and report bytes nothing could ever reclaim,
        // because both `remove` and `prune` would skip a directory that is not
        // there. The manifest must name the directory it sits in.
        let halfDir = ModelStore.directory(root: root, bundleID: "keep-a", token: "feedface0000") + ".keeping"
        try fm.createDirectory(atPath: halfDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(keptV1.version).write(
            to: URL(fileURLWithPath: (halfDir as NSString).appendingPathComponent("version.json")))
        check("a copy that died mid-keep is not a version",
              ModelStore.versions(root: root, bundleID: "keep-a").count == 2,
              "\(ModelStore.versions(root: root, bundleID: "keep-a").count) listed")
        try? fm.removeItem(atPath: halfDir)

        // The same rule is the only thing standing between a manifest and the
        // rest of the disk: the token is a path component in `directory`, in
        // `remove` and in `prune`, so a manifest that was not written here must
        // not be able to name a directory outside the store.
        let strangerDir = ModelStore.directory(root: root, bundleID: "keep-a", token: "deadc0de0000")
        try fm.createDirectory(atPath: strangerDir, withIntermediateDirectories: true)
        var stolen = keptV1.version
        stolen.token = "../../../tags"
        try JSONEncoder().encode(stolen).write(
            to: URL(fileURLWithPath: (strangerDir as NSString).appendingPathComponent("version.json")))
        check("a manifest naming another directory is not a version",
              ModelStore.versions(root: root, bundleID: "keep-a").count == 2,
              "\(ModelStore.versions(root: root, bundleID: "keep-a").count) listed")
        var refusedDeletion = false
        do {
            try ModelStore.remove(root: root, version: stolen)
        } catch {
            refusedDeletion = true
        }
        check("and it cannot be used to delete outside the store", refusedDeletion)
        check("and nothing outside the store was touched",
              fm.fileExists(atPath: (root as NSString).appendingPathComponent("tags/keep_prompts.f32")))
        try? fm.removeItem(atPath: strangerDir)

        // --- 4. a failed keep leaves nothing ------------------------------------
        let lying = bundle("keep-b", revision: "r1",
                           assets: [AIBundleAsset(url: "https://example.invalid/x",
                                                  sha256: String(repeating: "c", count: 64),
                                                  bytes: 4, kind: .file, install: "tags/keep_b.f32")])
        try write("tags/keep_b.f32", "actual bytes")
        var mismatch = false
        do {
            _ = try ModelStore.keep(root: root, bundle: lying)
        } catch let error as ModelInstallError {
            if case .hashMismatch = error { mismatch = true }
        }
        check("a live file that does not match its checksum is not kept", mismatch)
        check("a failed keep leaves no version",
              ModelStore.versions(root: root, bundleID: "keep-b").isEmpty)

        let absent = bundle("keep-c", revision: "r1",
                            assets: [AIBundleAsset(url: "https://example.invalid/y",
                                                   sha256: String(repeating: "d", count: 64),
                                                   bytes: 4, kind: .file, install: "tags/keep_c.f32")])
        var missing = false
        do {
            _ = try ModelStore.keep(root: root, bundle: absent)
        } catch {
            missing = true
        }
        check("a bundle that is not installed cannot be kept", missing)
        check("and leaves no version", ModelStore.versions(root: root, bundleID: "keep-c").isEmpty)

        // A compiled package is kept as a directory.
        let model = try writePackage("tags/keep_pkg.mlmodelc", "compiled")
        let pkg = bundle("keep-d", revision: "r1", assets: [model])
        let keptPkg = try ModelStore.keep(root: root, bundle: pkg)
        check("a compiled package is kept whole",
              fm.fileExists(atPath: (ModelStore.directory(root: root, version: keptPkg.version) as NSString)
                .appendingPathComponent("tags/keep_pkg.mlmodelc/coremldata.bin")))

        // --- 5. a kept copy is re-checked before it is used ---------------------
        check("a healthy kept version is trusted", ModelStore.trust(root: root, version: keptV1.version) == nil)

        let promptsPath = (keptDir as NSString).appendingPathComponent("tags/keep_prompts.f32")
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: promptsPath))
        let tampered = ModelStore.trust(root: root, version: keptV1.version)
        check("a tampered kept file is not trusted",
              tampered != nil && (tampered ?? "").contains("checksum"), tampered ?? "nil")
        var refused = false
        do {
            let staging = (root as NSString).appendingPathComponent("models/downloads/activate-refused")
            _ = try ModelStore.prepared(root: root, version: keptV1.version, staging: staging)
        } catch {
            refused = true
        }
        check("activation does not stage an untrustworthy version", refused)
        check("nothing was staged", !fm.fileExists(atPath: (root as NSString).appendingPathComponent("models/downloads/activate-refused")))

        // Put the healthy bytes back for the activation checks.
        try Data("rows-v1".utf8).write(to: URL(fileURLWithPath: (keptDir as NSString).appendingPathComponent("tags/keep_prompts.f32")))

        // --- 6. isLive is the receipt's answer ----------------------------------
        let liveF32 = try ModelCatalogPolicy.destination(promptsV1.install, root: root).path
        let liveJSON = try ModelCatalogPolicy.destination(tableV1.install, root: root).path
        try InstalledReceipt.write(bundle: v1,
                                   assets: [(promptsV1, liveF32), (tableV1, liveJSON)],
                                   root: root)
        check("the receipt makes that version live", keptV1.version.isLive(root: root))
        check("and the newer kept version is not the live one", !keptV2.version.isLive(root: root))

        // --- 7. the store is bounded --------------------------------------------
        // One bundle grows a fourth revision: the oldest is dropped, its own
        // cap only, and the others are left alone.
        var lastDropped: [StoredVersion] = []
        for revision in 3...6 {
            let asset = try write("tags/keep_many_\(revision).f32", "rev-\(revision)")
            let b = bundle("keep-many", revision: "r\(revision)", assets: [asset])
            lastDropped = try ModelStore.keep(root: root, bundle: b,
                                              at: Date(timeIntervalSince1970: Double(revision))).dropped
        }
        let many = ModelStore.versions(root: root, bundleID: "keep-many")
        check("only the kept count survives", many.count == ModelStore.keepPerBundle, "count=\(many.count)")
        check("the newest revisions are the ones kept",
              Set(many.map { $0.revision }) == Set(["r4", "r5", "r6"]),
              many.map { $0.revision }.joined(separator: ","))
        check("the keep that overflowed says what it dropped",
              lastDropped.map { $0.revision } == ["r3"],
              lastDropped.map { $0.revision }.joined(separator: ","))
        check("another bundle's versions are not touched by that cap",
              ModelStore.versions(root: root, bundleID: "keep-a").count == 2,
              "keep-a=\(ModelStore.versions(root: root, bundleID: "keep-a").count)")

        // Ordering by when a version was kept is only as good as the clock: a
        // backwards step between two keeps would otherwise make the store drop
        // the copy it had just made, so `prune` is told which one to spare. The
        // cap then bends by one rather than costing the user the way back.
        _ = try ModelStore.keep(root: root,
                                bundle: bundle("keep-e", revision: "r1",
                                               assets: [write("tags/keep_e.f32", "e-one")]),
                                at: Date(timeIntervalSince1970: 2_000_000_000))
        _ = try ModelStore.keep(root: root,
                                bundle: bundle("keep-e", revision: "r2",
                                               assets: [write("tags/keep_e.f32", "e-two")]),
                                at: Date(timeIntervalSince1970: 2_000_000_001))
        _ = try ModelStore.keep(root: root,
                                bundle: bundle("keep-e", revision: "r3",
                                               assets: [write("tags/keep_e.f32", "e-three")]),
                                at: Date(timeIntervalSince1970: 2_000_000_002))
        let steppedBack = try ModelStore.keep(root: root,
                                              bundle: bundle("keep-e", revision: "r4",
                                                             assets: [write("tags/keep_e.f32", "e-four")]),
                                              at: Date(timeIntervalSince1970: 1_000_000_000))
        check("a clock that stepped backwards does not cost the version just kept",
              ModelStore.versions(root: root, bundleID: "keep-e").contains { $0.token == steppedBack.version.token },
              "kept=\(steppedBack.version.token) listed=\(ModelStore.versions(root: root, bundleID: "keep-e").map { $0.token }.joined(separator: ","))")
        check("and the store does not claim to have dropped it",
              !steppedBack.dropped.contains { $0.token == steppedBack.version.token })
        check("the cap bends by one rather than lying about it",
              ModelStore.versions(root: root, bundleID: "keep-e").count == 4,
              "\(ModelStore.versions(root: root, bundleID: "keep-e").count)")

        // --- 8. staging copies, and removal is not a removal of the install -----
        let staging = (root as NSString).appendingPathComponent("models/downloads/activate-test")
        let first = try ModelStore.prepared(root: root, version: keptV1.version, staging: staging)
        check("prepared hands over one url per asset", first.count == v1.assets.count)
        check("the store still holds its own copy",
              fm.fileExists(atPath: (keptDir as NSString).appendingPathComponent("tags/keep_prompts.f32")))
        let second = try ModelStore.prepared(root: root, version: keptV1.version, staging: staging)
        check("and can be prepared again", second.count == v1.assets.count)
        try? fm.removeItem(atPath: staging)

        let liveBefore = try Data(contentsOf: URL(fileURLWithPath: liveF32))
        try ModelStore.remove(root: root, version: keptV2.version)
        check("removing a kept version forgets it",
              ModelStore.versions(root: root, bundleID: "keep-a").count == 1)
        check("removing a kept version leaves the install alone",
              (try? Data(contentsOf: URL(fileURLWithPath: liveF32))) == liveBefore)
        check("the live version is still live", keptV1.version.isLive(root: root))

        var nothingToRemove = false
        do {
            try ModelStore.remove(root: root, version: keptV2.version)
        } catch let error as ModelInstallError {
            if case .nothingToRemove = error { nothingToRemove = true }
        }
        check("removing a version twice says so rather than pretending", nothingToRemove)

        // --- byte accounting ----------------------------------------------------
        check("the store can say what it costs",
              ModelStore.totalBytes(root: root) >= keptPkg.version.bytes,
              "\(ModelStore.totalBytes(root: root))")

        // --- 9. a catalogue cannot write the store ------------------------------
        var storeReserved = false
        do {
            try ModelCatalogPolicy.validatePath("models/packs/keep-a/deadbeef0000/version.json")
        } catch {
            storeReserved = true
        }
        check("an install path inside the store is refused", storeReserved)

        var packsReserved = false
        do {
            try ModelCatalogPolicy.validatePath("models/packs")
        } catch {
            packsReserved = true
        }
        check("an install path AT the store is refused", packsReserved)

        print(failures == 0 ? "ALL PASS model store" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { exit(1) }
    }
}
