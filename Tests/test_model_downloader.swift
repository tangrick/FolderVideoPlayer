// Phase 5, Task 5.1 — the download and install path, without a network.
//
// The downloader is the one feature where a failure is expensive and invisible:
// a truncated 164 MB model that installs anyway is a Core ML load failure three
// screens later, and a bundle that half-installs is a feature that says "Ready"
// and then fails on the first frame. So the things worth proving are the ugly
// ones:
//
//   1. the hash check actually checks — against a digest computed by somebody
//      else (the published SHA-256 of "hello"), not one this file produced;
//   2. a corrupted asset installs NOTHING, including the assets that were fine
//      before it (all of them are verified before any of them is installed);
//   3. every install lands whole — no `.partial` is ever left where the app
//      could read it, on success or on failure;
//   4. removing a bundle removes what it installed, and says so when there is
//      nothing to remove instead of reporting success;
//   5. a catalogue that cannot be read is REPORTED, with its reason — never a
//      button that quietly downloads nothing (pitfall 0);
//   6. the installer's own staging names are reserved from the catalogue. A
//      catalog asset at `<anything>.partial` is a license to destroy: the
//      installer stages every placement beside its destination under exactly
//      that name and replaces whatever is there, so installing a later asset
//      silently deleted an earlier one (reproduced 2026-09-16 with
//      `tags/model.partial` + `tags/model`);
//   7. activation is transactional: a placement failure mid-bundle rolls back
//      to the complete previous version, a crash leaves only installer-owned
//      names that recovery resolves, and an installed receipt — not file
//      existence — is what the app treats as installed.
//
// A Core ML package is a zipped directory, so the app's unwrap-and-compile step
// is injected here: the gate drives the whole install path with a fixture, and
// no test needs an 83 MB model to do it.
//
// `@main` rather than top-level code, because this file compiles alongside the
// app's model layer and only main.swift may carry top-level statements.
//
// Run: Tests/run_model_downloader.sh

import Foundation

/// A progress log the download callback can append to from any thread.
///
/// The installer's report closure is `@Sendable`, so a plain captured `var`
/// would be a data race the compiler is right to flag.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int64, Int64)] = []

    func note(_ received: Int64, _ total: Int64) {
        lock.lock(); items.append((received, total)); lock.unlock()
    }

    var all: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Serves bytes from a directory, and can be told to lie about one file.
///
/// `url.lastPathComponent` names the fixture, so a bundle can point at
/// example.invalid and still be driven end to end.
final class FixtureTransport: ModelTransport, @unchecked Sendable {
    private let directory: String
    /// File names to serve with the first byte flipped.
    var corrupt: Set<String> = []
    /// Set to fail every transfer, as an unreachable host does.
    var failing = false
    /// Serve these file names with different bytes than the fixture file
    /// holds — the oversize guard is what has to catch a lying host.
    var inflate: [String: String] = [:]
    /// Fail only the asset downloads, so the catalogue still reads and the
    /// failure under test is the one the install path has to survive.
    var failingDownloads = false
    private(set) var asked: [String] = []

    init(directory: String) { self.directory = directory }

    struct Unreachable: LocalizedError {
        var errorDescription: String? { "the network is unreachable" }
    }

    func fetch(_ url: URL) async throws -> Data {
        if failing { throw Unreachable() }
        let path = (directory as NSString).appendingPathComponent(url.lastPathComponent)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw Unreachable()
        }
        return data
    }

    func download(_ url: URL, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        if failing || failingDownloads { throw Unreachable() }
        let name = url.lastPathComponent
        asked.append(name)
        let path = (directory as NSString).appendingPathComponent(name)
        guard var data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw Unreachable()
        }
        if corrupt.contains(name), !data.isEmpty { data[0] ^= 0xFF }
        if let extra = inflate[name] { data = Data(extra.utf8) }
        try data.write(to: destination)
        progress(Int64(data.count), Int64(data.count))
    }
}

@main
struct ModelDownloaderTest {
    /// Wrapped rather than `throws`, so a thrown error prints the checks that
    /// already ran instead of losing them to the runtime's top-level abort.
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            print("\nFAIL the harness threw: \(ModelDownloader.sentence(error))")
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
        let scratch = NSTemporaryDirectory() + "fvp-download-\(UUID().uuidString)"
        let served = scratch + "/served"
        let root = scratch + "/support"
        try fm.createDirectory(atPath: served, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        // Never the real library: every path in this file is passed explicitly,
        // but the app's own defaults read Paths, so they are pointed at scratch
        // as well. A test that can reach a real install is a test that will.
        Paths.support = root

        // --- 1. the hasher, against a number this file did not compute -------
        let hello = served + "/hello"
        try Data("hello".utf8).write(to: URL(fileURLWithPath: hello))
        let helloDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        check("sha256 of \"hello\" is the published digest",
              (try? ModelVerifier.sha256(fileAt: hello)) == helloDigest,
              (try? ModelVerifier.sha256(fileAt: hello)) ?? "threw")
        check("a file whose digest disagrees does not match",
              !ModelVerifier.matches(fileAt: hello, sha256: helloDigest.replacingOccurrences(of: "2c", with: "00")))
        check("an unreadable path does not match rather than crashing",
              !ModelVerifier.matches(fileAt: scratch + "/nope", sha256: helloDigest))

        // --- fixtures ---------------------------------------------------------
        func asset(_ name: String, install: String,
                   kind: AIBundleAsset.Kind = .file) throws -> AIBundleAsset {
            let path = (served as NSString).appendingPathComponent(name)
            try Data(name.utf8).write(to: URL(fileURLWithPath: path))
            return AIBundleAsset(url: "https://example.invalid/\(name)",
                                 sha256: try ModelVerifier.sha256(fileAt: path),
                                 bytes: Int64(name.utf8.count),
                                 kind: kind, install: install)
        }
        /// A stand-in for unwrap-and-compile: hands back a directory, which is
        /// what `MLModel.compileModel` hands back.
        let prepare: ModelInstaller.Preparer = { file, asset in
            guard asset.kind == .coreMLPackage else { return file }
            let into = file.deletingLastPathComponent()
                .appendingPathComponent("compiled-\(file.lastPathComponent)")
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: into.appendingPathComponent("model.bin"))
            return into
        }

        let promptA = try asset("promptA.txt", install: "tags/siglip2_base_prompts.json")
        let promptB = try asset("promptB.txt", install: "tags/siglip2_base_prompts.f32")
        let package = try asset("model.zip", install: "tags/siglip2_base.mlmodelc",
                                kind: .coreMLPackage)
        let bundle = AIBundle(id: "tags", title: "Tags", what: "suggestions",
                              feature: AICapability.Feature.tags.rawValue,
                              assets: [promptA, promptB, package])

        func anyPartial(_ under: String) -> Bool {
            let walker = fm.enumerator(at: URL(fileURLWithPath: under), includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                if url.lastPathComponent.contains(".partial") { return true }
            }
            return false
        }

        // --- 2. a good bundle installs everything -----------------------------
        check("nothing is installed to begin with", !bundle.isInstalled(root: root))
        let transport = FixtureTransport(directory: served)
        let log = ProgressLog()
        try await ModelInstaller.install(bundle, root: root, transport: transport,
                                         prepare: prepare) { got, total in
            log.note(got, total)
        }
        let reports = log.all
        check("the bundle reports itself installed", bundle.isInstalled(root: root))
        check("the prompt table landed where the app reads it",
              fm.fileExists(atPath: root + "/tags/siglip2_base_prompts.json")
                && fm.fileExists(atPath: root + "/tags/siglip2_base_prompts.f32"))
        check("the compiled package landed at the path the catalogue named",
              fm.fileExists(atPath: root + "/tags/siglip2_base.mlmodelc/model.bin"))
        check("progress ran to the end",
              reports.last.map { $0.0 == $0.1 } == true, "\(reports.last ?? (0, 0))")
        check("progress never went backwards",
              zip(reports, reports.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
        check("progress was reported more than once, so a row can animate",
              reports.count > 1, "\(reports.count)")
        check("nothing was left half-installed", !anyPartial(root), "a .partial is present")
        check("the staging area is not left behind",
              ((try? fm.contentsOfDirectory(atPath: ModelInstaller.scratchDir(root: root))) ?? []).isEmpty)

        // --- 3. a corrupt asset installs nothing ------------------------------
        let badRoot = scratch + "/bad-support"
        try fm.createDirectory(atPath: badRoot, withIntermediateDirectories: true)
        let lying = FixtureTransport(directory: served)
        lying.corrupt = ["promptB.txt"]        // the SECOND asset; the first is good
        var corruption: String?
        do {
            try await ModelInstaller.install(bundle, root: badRoot, transport: lying,
                                             prepare: prepare) { _, _ in }
        } catch {
            corruption = ModelDownloader.sentence(error)
        }
        check("a corrupted download fails", corruption != nil)
        check("…and the reason names the checksum",
              (corruption ?? "").contains("checksum"), corruption ?? "no error")
        check("…and says nothing was installed",
              (corruption ?? "").contains("nothing was installed"), corruption ?? "no error")
        check("the good asset before it was NOT installed either",
              !fm.fileExists(atPath: badRoot + "/tags/siglip2_base_prompts.json"))
        check("no half-installed file is left in its place", !anyPartial(badRoot))
        check("the bundle still reports itself missing",
              !bundle.isInstalled(root: badRoot))

        // --- 4. a failure while installing leaves no `.partial` ---------------
        let prepareHalfway: ModelInstaller.Preparer = { file, asset in
            guard asset.kind == .coreMLPackage else { return file }
            throw ModelInstallError.installFailed("model.zip", "the compiler gave up")
        }
        let halfRoot = scratch + "/half-support"
        try fm.createDirectory(atPath: halfRoot, withIntermediateDirectories: true)
        var halfway: String?
        do {
            try await ModelInstaller.install(bundle, root: halfRoot,
                                             transport: FixtureTransport(directory: served),
                                             prepare: prepareHalfway) { _, _ in }
        } catch {
            halfway = ModelDownloader.sentence(error)
        }
        check("a failing compile is reported", (halfway ?? "").contains("the compiler gave up"),
              halfway ?? "no error")
        check("a failing compile leaves no .partial", !anyPartial(halfRoot))

        check("a failing compile leaves every new asset uninstalled",
              !fm.fileExists(atPath: halfRoot + "/tags/siglip2_base_prompts.json")
                && !fm.fileExists(atPath: halfRoot + "/tags/siglip2_base_prompts.f32"))
        // An upgrade must not overwrite a working prompt table before the
        // replacement model has even compiled.
        let originalPrompt = try Data(contentsOf: URL(fileURLWithPath: root + "/tags/siglip2_base_prompts.json"))
        var upgrade = bundle
        upgrade.assets[0] = try asset("new-prompts", install: bundle.assets[0].install)
        do {
            try await ModelInstaller.install(upgrade, root: root,
                                             transport: FixtureTransport(directory: served),
                                             prepare: prepareHalfway) { _, _ in }
            check("failed upgrade is refused", false)
        } catch {
            check("failed upgrade preserves the installed prompt table",
                  (try? Data(contentsOf: URL(fileURLWithPath: root + "/tags/siglip2_base_prompts.json"))) == originalPrompt)
            check("failed upgrade preserves the installed model", bundle.isInstalled(root: root))
        }

        // Catalog-controlled paths affect both installs AND removals. A bad
        // second path must not delete the valid first one during preflight.
        var hostile = bundle
        hostile.assets[1].install = "../outside"
        let hostileTransport = FixtureTransport(directory: served)
        do {
            try await ModelInstaller.install(hostile, root: root, transport: hostileTransport,
                                             prepare: prepare) { _, _ in }
            check("path traversal refused before downloading", false)
        } catch {
            check("path traversal refused before downloading", hostileTransport.asked.isEmpty)
        }
        do {
            try ModelInstaller.remove(hostile, root: root)
            check("unsafe removal preflight rejects whole bundle", false)
        } catch {
            check("unsafe removal preflight preserves the first asset", bundle.isInstalled(root: root))
        }
        for path in ["/tmp/outside", "tags/../state.json", "state.json", "tags//x",
                     "models/downloads", "models/downloads/other-job", "tags/./x"] {
            var invalid = bundle
            invalid.assets[0].install = path
            check("catalog rejects unsafe destination \(path)",
                  (try? ModelCatalogPolicy.validate(invalid)) == nil)
        }
        var overlap = bundle
        overlap.assets[1].install = overlap.assets[0].install.uppercased()
        check("case-insensitive duplicate destinations are rejected",
              (try? ModelCatalogPolicy.validate(overlap)) == nil)
        overlap.assets[1].install = overlap.assets[0].install + "/child"
        check("parent/child destinations are rejected",
              (try? ModelCatalogPolicy.validate(overlap)) == nil)
        var overflow = bundle
        overflow.assets[0].bytes = Int64.max
        check("overflowing download size is rejected without trapping",
              overflow.bytes == Int64.max && (try? ModelCatalogPolicy.validate(overflow)) == nil)
        var duplicateID = bundle
        duplicateID.assets = [try asset("different", install: "tags/different")]
        check("duplicate bundle IDs are rejected",
              (try? ModelCatalogPolicy.validate(AIBundleManifest(version: 1, bundles: [bundle, duplicateID]))) == nil)
        duplicateID.id = "different"
        duplicateID.assets = bundle.assets
        check("cross-bundle overlapping destinations are rejected",
              (try? ModelCatalogPolicy.validate(AIBundleManifest(version: 1, bundles: [bundle, duplicateID]))) == nil)

        // --- staging names are reserved ---------------------------------------
        // `ModelInstaller.place` stages every placement as `<destination>.partial`
        // and replaces whatever is already there — that is the crash guard. The
        // reproduced collision listed `tags/model.partial` and `tags/model` in
        // one bundle: validation accepted both, the install reported success,
        // and the second asset's staging name was the first asset. The rule is
        // the installer's SHAPE, not these fixture filenames: any `.partial`
        // component, any case, any bundle, rejected before a byte is fetched.
        func stagingBundle(_ installs: [String]) -> AIBundle {
            AIBundle(id: "staging", title: "Staging", what: "fixture", feature: "tags",
                     assets: installs.map {
                         AIBundleAsset(url: "https://example.invalid/hello",
                                       sha256: helloDigest, bytes: 5, kind: .file,
                                       install: $0)
                     })
        }
        // Either order must refuse: the check is syntactic, so a catalog cannot
        // smuggle the staging name past by listing it first.
        for installs in [["tags/model", "tags/model.partial"],
                         ["tags/model.partial", "tags/model"]] {
            check("catalog refuses the reproduced staging collision (\(installs.joined(separator: " then ")))",
                  (try? ModelCatalogPolicy.validate(stagingBundle(installs))) == nil)
        }
        check("catalog refuses a staging destination whose base is never listed",
              (try? ModelCatalogPolicy.validate(stagingBundle(["tags/other", "tags/model.partial"]))) == nil)
        check("catalog refuses a staging name as a directory component",
              (try? ModelCatalogPolicy.validate(stagingBundle(["tags/model", "tags/model.partial/inside"]))) == nil)
        check("catalog refuses staging names in any case",
              (try? ModelCatalogPolicy.validate(stagingBundle(["tags/model", "tags/MODEL.Partial"]))) == nil)
        check("catalog refuses staging names across bundles",
              (try? ModelCatalogPolicy.validate(AIBundleManifest(version: 1, bundles: [
                  stagingBundle(["tags/model", "tags/other"]),
                  stagingBundle(["tags/elsewhere", "tags/model.partial"])]))) == nil)
        check("the write boundary refuses a staging destination on its own",
              (try? ModelCatalogPolicy.destination("tags/model.partial", root: root)) == nil)
        // Not over-reached: a name that merely CONTAINS `.partial` is a legal
        // destination — its own staging sibling is `…bin.partial`, which no
        // other destination may take but nothing here collides with.
        check("a destination containing .partial without ending in it stays installable",
              (try? ModelCatalogPolicy.validate(stagingBundle(["tags/model", "tags/model.partial.bin"]))) != nil)

        // --- the space identity is installer-owned, not catalog-owned ---------
        // The marker beside the artifacts identifies the installed embedding
        // space; a catalog that could write it could forge the identity of its
        // own space, and everything fitted against the previous one would mix
        // into it. Reserved like `.partial`, `.previous` and the receipts.
        for path in ["tags/installed.digest", "tags/INSTALLED.DIGEST",
                     "tags/installed.digest/inside"] {
            check("catalog refuses the space-identity path \(path)",
                  (try? ModelCatalogPolicy.validate(stagingBundle([path]))) == nil)
        }
        check("the space-identity marker is refused at the write boundary too",
              (try? ModelCatalogPolicy.destination("tags/installed.digest", root: root)) == nil)

        // --- installing stamps the identity of the space that landed ----------
        // The stamp is re-derived from disk whenever a bundle with a pack
        // descriptor lands, so any change to the tower changes the digest, and
        // every consumer bound to the old digest refuses rather than mix. The
        // preparer bumps a counter so each install really does land different
        // tower bytes — which is also the reality for a compiled package.
        let stampRoot = scratch + "/stamp-support"
        try fm.createDirectory(atPath: stampRoot + "/tags", withIntermediateDirectories: true)
        var compileCount = 0
        let stampPrepare: ModelInstaller.Preparer = { file, asset in
            guard asset.kind == .coreMLPackage else { return file }
            compileCount += 1
            let into = file.deletingLastPathComponent()
                .appendingPathComponent("compiled-\(compileCount)-\(file.lastPathComponent)")
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            try Data("compiled v\(compileCount)".utf8).write(to: into.appendingPathComponent("model.bin"))
            return into
        }
        var stamped = bundle
        stamped.pack = ModelPackDescriptor(
            version: 1, modelID: "siglip2-base", revision: "fixture-r1",
            adapter: "siglip2-base-v1", minimumMacOS: "14.0",
            architectures: ["arm64", "x86_64"], license: "test",
            sourceURL: "https://example.invalid/source")
        func towerDigest(_ root: String) -> String? {
            // The stamp folds the declared preprocessing into the digest — the
            // identity is of the space, not merely of the bytes.
            ModelSpace.digestOfDirectory(
                at: URL(fileURLWithPath: root + "/tags/siglip2_base.mlmodelc"),
                preprocess: ModelSpace.declaredPreprocess)
        }
        try await ModelInstaller.install(stamped, root: stampRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        let firstStamp = ModelSpace.read(root: stampRoot)
        check("an install with a pack descriptor stamps the space identity",
              firstStamp?.adapter == "siglip2-base-v1" && firstStamp?.dim == VisionEmbedder.dim
                && firstStamp?.digest == towerDigest(stampRoot),
              "\(String(describing: firstStamp))")

        // Same catalog, different compiled bytes: a different space, and the
        // stamp has to move with what is actually on disk.
        try await ModelInstaller.install(stamped, root: stampRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        let secondStamp = ModelSpace.read(root: stampRoot)
        check("a reinstall that changed the tower bytes re-stamps the identity",
              secondStamp?.digest == towerDigest(stampRoot) && secondStamp?.digest != firstStamp?.digest,
              "\(String(describing: secondStamp?.digest.prefix(12)))) vs \(String(describing: firstStamp?.digest.prefix(12))))")

        // A legacy catalog (no descriptor) must not clobber the marker: a
        // routine prompt-table refresh is not a space change.
        try await ModelInstaller.install(bundle, root: stampRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        check("a legacy bundle leaves the installed identity alone",
              ModelSpace.read(root: stampRoot)?.digest == secondStamp?.digest)

        // Removing a bundle that does NOT own the tower leaves the marker:
        // taking the prompts out does not make the installed tower someone
        // else's. (The tower bundle is `stamped`; this one carries only files.)
        var promptsOnly = stamped
        promptsOnly.id = "promptsonly"
        promptsOnly.pack = nil
        promptsOnly.assets = [bundle.assets[0]]
        try await ModelInstaller.install(promptsOnly, root: stampRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        try ModelInstaller.remove(promptsOnly, root: stampRoot)
        check("removing an unrelated bundle keeps the installed identity",
              ModelSpace.read(root: stampRoot)?.digest == secondStamp?.digest)

        // Removing the bundle that owns the tower removes the identity with
        // it — nothing installed means nothing to bind to.
        try ModelInstaller.remove(stamped, root: stampRoot)
        check("removing the tower bundle removes the space marker",
              ModelSpace.read(root: stampRoot) == nil)

        // --- the marker is checked against the bytes it identifies ------------
        // Marker-to-marker comparison only proves the RECORD changed. A tower
        // replaced underneath a marker that stayed put — restore from backup,
        // a hand-copied model, a reinstall that died after placing and before
        // stamping — leaves a digest describing bytes that are gone, and the
        // new tower's vectors would be written under the old space's namespace
        // and scored against the old space's prompts.
        let bytesRoot = scratch + "/marker-bytes-support"
        try fm.createDirectory(atPath: bytesRoot + "/tags", withIntermediateDirectories: true)
        try await ModelInstaller.install(stamped, root: bytesRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        let installedMarker = ModelSpace.read(root: bytesRoot)
        check("a freshly installed marker matches the bytes on disk",
              installedMarker?.matchesInstalledBytes(root: bytesRoot) == true)

        let towerFile = ModelSpace.towerDirectory(root: bytesRoot)
            .appendingPathComponent("model.bin")
        let originalBytes = try Data(contentsOf: towerFile)
        // SAME LENGTH as the original: size alone cannot catch this, which is
        // why the check re-derives the content digest rather than stat-ing.
        var swapped = originalBytes
        swapped[swapped.count - 1] = originalBytes[originalBytes.count - 1] ^ 0xFF
        check("the fixture swap keeps the byte count identical",
              swapped.count == originalBytes.count && swapped != originalBytes)
        try swapped.write(to: towerFile)
        check("the marker is unchanged by a tower swapped outside the installer",
              ModelSpace.read(root: bytesRoot)?.digest == installedMarker?.digest)
        check("a marker whose tower was replaced underneath it fails the byte check",
              ModelSpace.read(root: bytesRoot)?.matchesInstalledBytes(root: bytesRoot) == false)

        try originalBytes.write(to: towerFile)
        check("restoring the original bytes makes the marker match again",
              ModelSpace.read(root: bytesRoot)?.matchesInstalledBytes(root: bytesRoot) == true)

        // A marker for artifacts that are not there describes nothing.
        try fm.removeItem(at: ModelSpace.towerDirectory(root: bytesRoot))
        check("a marker with no tower on disk fails the byte check rather than passing",
              installedMarker?.matchesInstalledBytes(root: bytesRoot) == false)

        // A marker written before `preprocess` existed is re-checked as it was
        // written — legacy installs must not be condemned by a field they
        // never had.
        let legacyRoot = scratch + "/marker-legacy-support"
        let legacyTower = ModelSpace.towerDirectory(root: legacyRoot)
        try fm.createDirectory(atPath: legacyTower.path, withIntermediateDirectories: true)
        try Data("legacy tower".utf8).write(to: legacyTower.appendingPathComponent("model.bin"))
        let legacyDigest = ModelSpace.digestOfDirectory(at: legacyTower)
        let legacyMarker = ModelSpace(adapter: "siglip2-base-v1",
                                      digest: legacyDigest ?? "", dim: VisionEmbedder.dim)
        check("a legacy marker with no declared preprocessing still matches its bytes",
              legacyMarker.preprocess == nil
                && legacyMarker.matchesInstalledBytes(root: legacyRoot) == true)
        check("a legacy marker is not silently checked under today's preprocessing",
              legacyDigest != ModelSpace.digestOfDirectory(
                  at: legacyTower, preprocess: ModelSpace.declaredPreprocess))

        // --- space mismatch is refused at the consumer ------------------------
        // The whole point of the marker: a table computed in one space must
        // refuse to score against another space's vectors, even when the
        // dimensions match. A minimal REAL table (3 rows x 4 floats, one tag)
        // drives the fixture, so loads fail for the right reason or not at all.
        func minimalTable(_ spaceDigest: String?) throws -> (json: Data, bin: Data) {
            var meta: [String: Any] = [
                "version": 1, "dim": 4, "rows": 3,
                "layout": ["nsfw": [0, 1], "neutral": [1, 2], "background": [2, 3]],
                "tags": [["tag": "A photo", "rows": [0, 1]]],
                "paired_tags": [["tag": "Upright", "rows": [0, 1]]],
                "constants": ["MARGIN_BIAS": 0.05, "MARGIN_TEMPERATURE": 12.0,
                              "NSFW_THRESHOLD": 0.5, "SUGGEST_MARGIN": 0.03,
                              "SUGGEST_MAX_TAGS": 8, "SAMPLE_INTERVAL_S": 2.0,
                              "MAX_FRAMES": 12, "SAMPLE_SHORT_SIDE": 224.0],
                "engine_py_sha256": String(repeating: "0", count: 64),
                "prompt_sha256": String(repeating: "1", count: 64),
                "texts": ["a photo"]]
            if let bound = spaceDigest { meta["space_digest"] = bound }
            var floats: [Float] = [0.5, 0, 0, 0, 0.5, 0, 0, 0, 1, 0, 0, 0]
            return (try JSONSerialization.data(withJSONObject: meta),
                    floats.withUnsafeBytes { Data($0) })
        }
        func writeTable(_ root: String, boundTo digest: String?) throws {
            let table = try minimalTable(digest)
            try table.json.write(
                to: URL(fileURLWithPath: root + "/tags/siglip2_base_prompts.json"))
            try table.bin.write(
                to: URL(fileURLWithPath: root + "/tags/siglip2_base_prompts.f32"))
        }
        let foreignDigest = String(repeating: "a", count: 64)
        let mismatchRoot = scratch + "/mismatch-support"
        try fm.createDirectory(atPath: mismatchRoot + "/tags", withIntermediateDirectories: true)
        // Seed an identity the installer did not write, as if a different
        // tower had been installed here before.
        try JSONEncoder().encode(ModelSpace(adapter: "siglip2-base-v1", digest: foreignDigest,
                                            dim: VisionEmbedder.dim)).write(
            to: URL(fileURLWithPath: ModelSpace.digestFile(root: mismatchRoot)))
        try writeTable(mismatchRoot, boundTo: nil)
        check("an unbound table loads under a foreign marker (legacy rule)",
              (try? PromptTable(root: mismatchRoot)) != nil)

        // The descriptor-carrying install replaces the identity with the one
        // it just put on disk…
        try await ModelInstaller.install(stamped, root: mismatchRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        check("the install stamps its own identity over the foreign one",
              ModelSpace.read(root: mismatchRoot)?.digest == towerDigest(mismatchRoot)
                && ModelSpace.read(root: mismatchRoot)?.digest != foreignDigest)

        // …so a table still bound to the old digest is now refused — and the
        // positive control proves the refusal is about the digest, not a
        // broken table: the same bytes bound to the CURRENT space load fine.
        try writeTable(mismatchRoot, boundTo: foreignDigest)
        if let why = PromptTable.spaceBindingError(root: mismatchRoot) {
            check("a table bound to another space is refused with the reason",
                  why.contains("another embedding space"), why)
        } else {
            check("a table bound to another space is refused with the reason", false,
                  "spaceBindingError returned nil for a foreign binding")
        }
        check("...and the table refuses to load",
              (try? PromptTable(root: mismatchRoot)) == nil)
        try writeTable(mismatchRoot,
                       boundTo: ModelSpace.read(root: mismatchRoot)?.digest)
        check("the same table bound to the installed space loads",
              PromptTable.spaceBindingError(root: mismatchRoot) == nil
                && (try? PromptTable(root: mismatchRoot)) != nil)

        // --- the embedding cache is keyed by the space, not by a name --------
        // The cache's namespace used to be a hand-written slug, so a changed
        // tower kept hitting the old tree: same frame bytes, wrong space, and
        // nothing refused it. With a marker, the tree is keyed by the digest
        // itself; without one, the legacy slug keeps the Python engine and the
        // Swift app sharing one tree.
        let cacheRoot = scratch + "/cache-support"
        try fm.createDirectory(atPath: cacheRoot + "/frames", withIntermediateDirectories: true)
        let legacyCache = EmbeddingCache(root: cacheRoot + "/frames")
        check("with no marker the cache keys by the legacy slug (engine sharing)",
              EmbeddingCache.cacheKey(root: cacheRoot) == VisionEmbedder.modelSlug
                && legacyCache.namespace == VisionEmbedder.modelSlug)
        let frameBytes = Data("frame-bytes".utf8)
        let frameHash = EmbeddingCache.frameHash(frameBytes)
        var vector = [Float](repeating: 0, count: VisionEmbedder.dim)
        vector[0] = 1
        legacyCache.write(frameHash, vector)
        check("a legacy cache serves under the slug tree",
              legacyCache.read(frameHash)?.count == VisionEmbedder.dim)

        // Stamp the space: the very same cache object now reads a different
        // tree — the old vectors are out of reach without anyone deleting a
        // thing or renaming anything.
        try await ModelInstaller.install(stamped, root: cacheRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        let stampedCache = EmbeddingCache(root: cacheRoot + "/frames")
        check("a stamped space re-keys the cache to the digest tree",
              EmbeddingCache.cacheKey(root: cacheRoot) == ModelSpace.read(root: cacheRoot)?.digest
                && stampedCache.namespace == ModelSpace.read(root: cacheRoot)?.digest)
        check("the old tree is out of reach after a re-key (miss, not a wrong vector)",
              stampedCache.read(frameHash) == nil)
        stampedCache.write(frameHash, vector)
        check("the new tree serves what it was written under",
              stampedCache.read(frameHash)?.count == VisionEmbedder.dim
                && stampedCache.read(frameHash) != legacyCache.read(frameHash)
                || stampedCache.read(frameHash) != nil)

        // Re-stamp with different tower bytes (the counter preparer): the
        // digest tree moves AGAIN — a change of space can never read the old
        // space's vectors, on its own, with no human step. The current tree is
        // the digest of the CURRENT bytes with the declared preprocessing
        // folded in; the tower-only digest is therefore necessarily different
        // when the marker is stamped — the check only means something because
        // `towerDigest` and the stamp use the same arithmetic.
        let beforeRestamp = EmbeddingCache.cacheKey(root: cacheRoot)
        let pinnedCache = stampedCache.pinned(to: beforeRestamp)
        try await ModelInstaller.install(stamped, root: cacheRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: stampPrepare) { _, _ in }
        let afterRestamp = EmbeddingCache.cacheKey(root: cacheRoot)
        check("a re-stamp moves the cache tree again",
              afterRestamp != beforeRestamp
                && afterRestamp == towerDigest(cacheRoot))

        check("an in-flight cache retains its loaded model namespace after activation",
              pinnedCache.namespace == beforeRestamp && pinnedCache.read(frameHash) == vector)
        let lateHash = EmbeddingCache.frameHash(Data("late-frame".utf8))
        pinnedCache.write(lateHash, vector)
        check("a late old-model write cannot pollute the newly activated space",
              pinnedCache.read(lateHash) == vector && stampedCache.read(lateHash) == nil)

        check("baseline enumeration stays in the pinned model space after replacement",
              Set(pinnedCache.hashes()) == Set([frameHash, lateHash]))
        check("replacement model cannot enumerate the old model baseline",
              stampedCache.hashes().isEmpty)
        let replacementHash = EmbeddingCache.frameHash(Data("replacement-frame".utf8))
        stampedCache.write(replacementHash, vector)
        check("replacement baseline enumerates only readable replacement vectors",
              stampedCache.hashes() == [replacementHash]
                && stampedCache.hashes().allSatisfy { stampedCache.read($0) == vector }
                && !pinnedCache.hashes().contains(replacementHash))
        check("legacy baseline remains available when explicitly bound to legacy space",
              legacyCache.pinned(to: VisionEmbedder.modelSlug).hashes() == [frameHash])

        // Preprocessing identity: same bytes, different declared preprocessing
        // is a different space — the digest moves, prompts/heads/cache with it.
        let towerOnly = ModelSpace.digestOfDirectory(
            at: URL(fileURLWithPath: cacheRoot + "/tags/siglip2_base.mlmodelc"))
        let withPre = ModelSpace.digestOfDirectory(
            at: URL(fileURLWithPath: cacheRoot + "/tags/siglip2_base.mlmodelc"),
            preprocess: "resize-224-hard")
        check("a preprocessing change is part of the identity",
              towerOnly != nil && withPre != nil && towerOnly != withPre)

        print(failures == 0 ? "\nALL PASS model downloader" : "\n\(failures) FAILURES")
        let collisionTransport = FixtureTransport(directory: served)
        var stagedRefusal: String?
        do {
            try await ModelInstaller.install(stagingBundle(["tags/model", "tags/model.partial"]),
                                             root: root, transport: collisionTransport,
                                             prepare: prepare) { _, _ in }
        } catch { stagedRefusal = ModelDownloader.sentence(error) }
        check("a staging collision is refused at install time, with the reason",
              (stagedRefusal ?? "").contains("reserved staging name"), stagedRefusal ?? "no error")
        check("…before anything was downloaded", collisionTransport.asked.isEmpty)
        check("…leaving the already-installed bundle untouched", bundle.isInstalled(root: root))
        for address in ["http://example.invalid/model", "file:///tmp/model", "ftp://example.invalid/model",
                        "https://user:password@example.invalid/model"] {
            var invalid = bundle
            invalid.assets[0].url = address
            check("catalog rejects non-secure or credential-bearing address",
                  (try? ModelCatalogPolicy.validate(invalid)) == nil)
        }
        let linkRoot = scratch + "/link-support"
        let outside = scratch + "/outside"
        try fm.createDirectory(atPath: linkRoot, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkRoot + "/tags", withDestinationPath: outside)
        check("symlinked install parent is refused",
              (try? ModelCatalogPolicy.destination("tags/model", root: linkRoot)) == nil)
        let linkTransport = FixtureTransport(directory: served)
        do {
            try await ModelInstaller.install(bundle, root: linkRoot, transport: linkTransport,
                                             prepare: prepare) { _, _ in }
            check("symlink install refused before download", false)
        } catch {
            check("symlink install refused before download", linkTransport.asked.isEmpty)
        }

        let pack = ModelPackDescriptor(version: 1, modelID: "google/siglip2-base-patch16-224",
                                       revision: "fixture-revision", adapter: "siglip2-base-v1",
                                       minimumMacOS: "14.0", architectures: ["arm64"],
                                       license: "Apache-2.0", sourceURL: "https://example.invalid/model")
        let modernMac = ModelPackEnvironment(architecture: "arm64", macOSVersion: "26.6.2")
        check("supported descriptor accepts compatible Mac",
              pack.incompatibility(feature: "tags", environment: modernMac) == nil)
        check("descriptor rejects the wrong capability adapter",
              pack.incompatibility(feature: "faces", environment: modernMac) != nil)
        check("descriptor rejects unsupported architecture",
              pack.incompatibility(feature: "tags", environment: .init(architecture: "x86_64", macOSVersion: "26")) != nil)
        check("descriptor rejects older OS",
              pack.incompatibility(feature: "tags", environment: .init(architecture: "arm64", macOSVersion: "13.9")) != nil)
        check("descriptor accepts exact OS boundary",
              pack.incompatibility(feature: "tags", environment: .init(architecture: "arm64", macOSVersion: "14")) == nil)
        var futurePack = pack
        futurePack.version = 99
        check("unknown descriptor schema cannot activate",
              futurePack.incompatibility(feature: "tags", environment: modernMac) != nil)
        var incompatible = bundle
        incompatible.pack = futurePack
        let incompatibleTransport = FixtureTransport(directory: served)
        do {
            try await ModelInstaller.install(incompatible, root: root, transport: incompatibleTransport,
                                             prepare: prepare) { _, _ in }
            check("unsupported pack cannot download", false)
        } catch {
            check("unsupported pack cannot download", incompatibleTransport.asked.isEmpty)
            check("unsupported pack leaves existing installation alone", bundle.isInstalled(root: root))
        }
        var described = bundle
        described.pack = pack
        check("pack descriptor round-trips with the legacy bundle shape",
              (try? JSONDecoder().decode(AIBundle.self, from: JSONEncoder().encode(described))) == described)

        // --- 4b. transactional activation, recovery, receipts -----------------
        // A bundle is the old complete version or the new complete version.
        // `activate` moves every asset through `.partial`/`.previous` and only
        // then writes the receipt; a failure anywhere rolls the moved assets
        // back. The fixture here drives `activate` directly so the failure can
        // land between assets, which `install`'s happy path cannot.
        let txRoot = scratch + "/tx-support"
        try fm.createDirectory(atPath: txRoot, withIntermediateDirectories: true)
        func stagedFile(_ bytes: [UInt8]) throws -> URL {
            let url = URL(fileURLWithPath: (scratch as NSString)
                .appendingPathComponent("tx-" + UUID().uuidString))
            try Data(bytes).write(to: url)
            return url
        }
        let receiptBundle = stagingBundle(["tags/tx-a", "tags/tx-b"])
        let helloBytes = Array("hello".utf8)          // matches the served fixture's digest
        let freshBytes = Array("fresh".utf8)          // an upgrade's new bytes

        try await ModelInstaller.install(receiptBundle, root: txRoot,
                                         transport: FixtureTransport(directory: served),
                                         prepare: prepare) { _, _ in }
        let firstReceipt = InstalledReceipt.read(bundleID: receiptBundle.id, root: txRoot)
        check("a completed install writes a receipt for the whole bundle",
              firstReceipt != nil)
        check("…and the receipt's digests verify against what landed",
              firstReceipt?.verify(root: txRoot) == true)
        check("…and the bundle reads as installed through the receipt",
              receiptBundle.isInstalled(root: txRoot))

        // A mid-transaction failure: the second destination is a symlink, which
        // the write boundary refuses AFTER the first asset has been placed.
        try fm.createSymbolicLink(atPath: txRoot + "/tags/tx-link",
                                  withDestinationPath: "/tmp/fvp-tx-nowhere")
        let linkAsset = AIBundleAsset(url: "https://example.invalid/hello",
                                      sha256: helloDigest, bytes: 5, kind: .file,
                                      install: "tags/tx-link")
        var midFailure: Error?
        do {
            try ModelInstaller.activate([
                (receiptBundle.assets[0], try stagedFile(freshBytes)),
                (linkAsset, try stagedFile(freshBytes))],
                bundle: receiptBundle, root: txRoot)
        } catch { midFailure = error }
        check("a placement failure mid-bundle is reported", midFailure != nil)
        check("…the placed asset is rolled back to its previous version",
              (try? ModelVerifier.sha256(fileAt: txRoot + "/tags/tx-a")) == helloDigest)
        check("…no .previous backups are left behind",
              !fm.fileExists(atPath: txRoot + "/tags/tx-a.previous"))
        check("…the old receipt is kept and still verifies",
              InstalledReceipt.read(bundleID: receiptBundle.id, root: txRoot) == firstReceipt
                && firstReceipt?.verify(root: txRoot) == true)

        // A bundle where the first asset is NEW (no old version to restore):
        // rollback must remove it, not leave it half-installed.
        let fresh = AIBundle(id: "fresh", title: "Fresh", what: "fixture", feature: "tags",
                             assets: [AIBundleAsset(url: "https://example.invalid/hello",
                                                    sha256: helloDigest, bytes: 5, kind: .file,
                                                    install: "tags/tx-fresh")])
        do {
            try ModelInstaller.activate([
                (fresh.assets[0], try stagedFile(freshBytes)),
                (receiptBundle.assets[1], try stagedFile(freshBytes)),
                (linkAsset, try stagedFile(freshBytes))],
                bundle: fresh, root: txRoot)
        } catch { }
        check("a rollback removes an asset that had no previous version",
              !fm.fileExists(atPath: txRoot + "/tags/tx-fresh"))
        check("…and restores the replaced one",
              (try? ModelVerifier.sha256(fileAt: txRoot + "/tags/tx-b")) == helloDigest)

        // A successful upgrade replaces the receipt's identities wholesale.
        let beforeUpgrade = InstalledReceipt.read(bundleID: receiptBundle.id, root: txRoot)
        try ModelInstaller.activate([
            (receiptBundle.assets[0], try stagedFile(freshBytes)),
            (receiptBundle.assets[1], try stagedFile(freshBytes))],
            bundle: receiptBundle, root: txRoot)
        check("a successful upgrade rewrites the receipt and frees the backups",
              InstalledReceipt.read(bundleID: receiptBundle.id, root: txRoot) != beforeUpgrade
                && !fm.fileExists(atPath: txRoot + "/tags/tx-a.previous"))

        // A crash mid-activation leaves only installer-owned names: live
        // destinations hold the new bytes, backups hold the previous ones.
        try Data("fresh".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-a"))
        try Data("hello".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-a.previous"))
        try Data("fresh".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-b"))
        try Data("hello".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-b.previous"))
        try Data("stage".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-b.partial"))
        let staleScratch = (ModelInstaller.scratchDir(root: txRoot) as NSString)
            .appendingPathComponent("\(receiptBundle.id)-crashed")
        try fm.createDirectory(atPath: staleScratch, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: staleScratch + "/asset-0"))
        let otherScratch = (ModelInstaller.scratchDir(root: txRoot) as NSString)
            .appendingPathComponent("other-1")
        try fm.createDirectory(atPath: otherScratch, withIntermediateDirectories: true)
        try ModelInstaller.recover(receiptBundle, root: txRoot)
        check("recovery restores the previous version over a half-moved destination",
              (try? ModelVerifier.sha256(fileAt: txRoot + "/tags/tx-a")) == helloDigest
                && (try? ModelVerifier.sha256(fileAt: txRoot + "/tags/tx-b")) == helloDigest)
        check("recovery discards the staged .partial",
              !fm.fileExists(atPath: txRoot + "/tags/tx-b.partial"))
        check("recovery removes this bundle's stale download scratch",
              !fm.fileExists(atPath: staleScratch))
        check("recovery leaves another bundle's scratch alone",
              fm.fileExists(atPath: otherScratch))

        // The receipt is trust, not existence. Same-size tampering passes the
        // cheap size check and the legacy existence check, but the receipt's
        // digests — the numbers the installer verified at download time — do not.
        let receipt = InstalledReceipt.read(bundleID: receiptBundle.id, root: txRoot)
        try Data("fresh".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-a"))
        check("same-size tampering is invisible to existence and size checks",
              fm.fileExists(atPath: txRoot + "/tags/tx-a") && receipt?.matches(root: txRoot) == true)
        check("…but receipt verification refuses it",
              receipt?.verify(root: txRoot) == false)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-a"))
        check("restoring the bytes restores verification",
              receipt?.verify(root: txRoot) == true)
        try fm.removeItem(atPath: txRoot + "/tags/tx-b")
        check("a deleted asset fails receipt verification",
              receipt?.verify(root: txRoot) == false)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-b"))

        // Legacy packs installed before receipts existed keep working.
        let legacy = AIBundle(id: "legacy", title: "Legacy", what: "fixture", feature: "tags",
                              assets: [AIBundleAsset(url: "https://example.invalid/hello",
                                                     sha256: helloDigest, bytes: 5, kind: .file,
                                                     install: "tags/tx-legacy")])
        try Data("hello".utf8).write(to: URL(fileURLWithPath: txRoot + "/tags/tx-legacy"))
        check("a pre-receipt installation still reads as installed",
              legacy.isInstalled(root: txRoot))

        // The app's wrapper runs one operation at a time.
        final class HangingTransport: ModelTransport, @unchecked Sendable {
            let gate = DispatchSemaphore(value: 0)
            func fetch(_ url: URL) async throws -> Data { Data() }
            func download(_ url: URL, to destination: URL,
                          progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
                _ = gate.wait(wallTimeout: .distantFuture)
                try Data("hello".utf8).write(to: destination)
                progress(5, 5)
            }
        }
        let serialRoot = scratch + "/serial-support"
        try fm.createDirectory(atPath: serialRoot, withIntermediateDirectories: true)
        let hanging = HangingTransport()
        let serial = ModelDownloader(root: serialRoot, transport: hanging,
                                     prepare: prepare,
                                     catalogueURL: URL(string: "https://example.invalid/ai-bundles.json")!)
        check("no operation is in flight to begin with", serial.inFlight == nil)
        async let first: Void = serial.install(receiptBundle)
        var spins = 0
        while serial.inFlight == nil, spins < 10_000 { spins += 1; await Task.yield() }
        check("the wrapper marks its operation in flight", serial.inFlight == receiptBundle.id)
        // Free the download BEFORE trying the second operation: the wrapper
        // marks the slot in flight before the download starts, and this
        // transport blocks INSIDE the download. (The wrapper itself is not
        // deadlocked — recovery and download are distinct steps.)
        hanging.gate.signal()
        await serial.install(stagingBundle(["tags/serial-refused"]))
        if case .failed(_, let why) = serial.state {
            check("a second operation while one runs is refused with a reason",
                  why.contains("already running"), why)
        } else {
            check("a second operation while one runs is refused with a reason", false,
                  "\(serial.state)")
        }
        check("the refused operation did not take the slot", serial.inFlight == receiptBundle.id)
        // The installer downloads EACH asset through the transport, and this
        // transport blocks every download — free one per asset, not one total.
        for _ in receiptBundle.assets { hanging.gate.signal() }
        await first
        check("the first operation completes and frees the slot", serial.inFlight == nil)
        check("…and its bundle is installed", serial.isInstalled(receiptBundle))
        await serial.remove(receiptBundle)
        check("removal through the wrapper ends idle and removes the bundle",
              serial.state == .idle && !serial.isInstalled(receiptBundle))
        check("the receipt goes with the bundle",
              InstalledReceipt.read(bundleID: receiptBundle.id, root: serialRoot) == nil)

        // --- 4d. a model may not be swapped under a running pass ----------------
        // Installing or removing a bundle rewrites the very files a pass is
        // reading: the load either crashes or answers from a mix of both
        // versions. Both directions are refused, each on the side that can see
        // the other — the downloader asks the AI whether it is working, and the
        // engine asks the downloader whether a model is being replaced.
        let swapsRoot = serialRoot + "/swaps"
        try fm.createDirectory(atPath: swapsRoot, withIntermediateDirectories: true)
        let swaps = ModelDownloader(root: swapsRoot,
                                    transport: FixtureTransport(directory: served),
                                    prepare: prepare,
                                    catalogueURL: URL(string: "https://example.invalid/ai-bundles.json")!)
        let swapBundle = stagingBundle(["tags/swaps"])
        swaps.isInferring = { true }
        await swaps.install(swapBundle)
        if case .failed(let id, let why) = swaps.state {
            check("an install is refused while the AI is working",
                  id == swapBundle.id && why.contains("the AI is working"), why)
        } else {
            check("an install is refused while the AI is working", false, "\(swaps.state)")
        }
        check("…the refused install took no slot", swaps.inFlight == nil)
        check("…and put nothing on disk", !swaps.isInstalled(swapBundle))
        await swaps.remove(swapBundle)
        if case .failed(_, let why) = swaps.state {
            check("removal is refused the same way", why.contains("the AI is working"), why)
        } else {
            check("removal is refused the same way", false, "\(swaps.state)")
        }
        swaps.isInferring = { false }
        await swaps.install(swapBundle)
        check("with nothing running the same install goes through",
              swaps.isInstalled(swapBundle), "\(swaps.state)")
        check("…and the slot is free again", swaps.inFlight == nil)

        // The engine's half, and what it must NOT do: a transient replacement may
        // not leave the sticky `.broken` state behind, or suggestions would stay
        // off until the user found Retry.
        let guarded = AnalysisEngine()
        check("a fresh engine is not inferring", !guarded.isInferring)
        guarded.isReplacingModels = { true }
        await guarded.run(store: AnalysisStore(), paths: ["/nonexistent"])
        if case .broken(let why) = guarded.phase {
            check("a run refused mid-replacement does not leave the engine broken", false, why)
        } else {
            check("a run refused mid-replacement does not leave the engine broken", true)
        }
        check("…and says why in the status line",
              guarded.statusText.contains("a model is being installed or removed"),
              guarded.statusText)
        check("…and a suggestion pass is simply not run, not reported",
              await guarded.suggestTags(for: "/nonexistent") == nil)
        guarded.isReplacingModels = { false }

        // The counter the two sides share. Counted, never below zero — one stuck
        // counter would refuse every install from then on.
        let counter = InferenceCounter()
        check("a fresh counter reports no work", !counter.isOn)
        counter.begin(); counter.begin()
        check("begun work is reported", counter.isOn)
        counter.end()
        check("…and stays reported while anything is still open", counter.isOn)
        counter.end()
        check("…and is clear once the last one ends", !counter.isOn)
        counter.end(); counter.end()
        check("an extra end never leaves it stuck on", !counter.isOn)

        // --- 4c. oversize and expansion limits ---------------------------------
        // A host may not stuff the staging file with more bytes than the
        // catalog declared: the size bound is checked before the hash, so the
        // catalog's own number catches a lying host.
        // The transport serves by the URL's last path component and refuses
        // names it has no file for, so the lying host gets a real fixture file
        // whose SERVED bytes are bigger than the catalog declared.
        try Data(repeating: 0x78, count: 12).write(
            to: URL(fileURLWithPath: served + "/big.txt"))
        var oversizedAsset = stagingBundle(["tags/limit"])
        oversizedAsset.assets[0] = AIBundleAsset(url: "https://example.invalid/big.txt",
                                                 sha256: helloDigest, bytes: 5,
                                                 kind: .file, install: "tags/limit")
        var oversize: String?
        do {
            try await ModelInstaller.install(oversizedAsset, root: root,
                                             transport: FixtureTransport(directory: served),
                                             prepare: prepare) { _, _ in }
        } catch { oversize = ModelDownloader.sentence(error) }
        check("a download bigger than its declared size is refused by name",
              (oversize ?? "").contains("bigger than the 5-byte size"), oversize ?? "no error")
        check("…nothing was placed", !fm.fileExists(atPath: root + "/tags/limit"))

        // The budget arithmetic, at its boundaries.
        check("the budget is the proportional ceiling for a small archive",
              ModelArchive.budget(forCompressed: 100) == 800)
        check("…capped by the absolute ceiling for a huge one",
              ModelArchive.budget(forCompressed: 10_000_000_000) == ModelArchive.absoluteCeiling)
        check("an honest eighth-of-size expansion fits",
              !ModelArchive.wouldOvershoot(compressed: 800, expanded: 6_400, free: 10_000))
        check("…a ninth does not",
              ModelArchive.wouldOvershoot(compressed: 900, expanded: 8_100, free: 10_000))
        check("…nor anything past the disk's free space",
              ModelArchive.wouldOvershoot(compressed: 1, expanded: 2, free: 1))
        check("…nor a zero-length archive, which cannot be trusted",
              ModelArchive.wouldOvershoot(compressed: 0, expanded: 0, free: 10_000))

        // Scratch made by THIS process may belong to an install still running:
        // recovery leaves it, and only other-process leftovers are swept.
        let liveRoot = scratch + "/live-support"
        try fm.createDirectory(atPath: liveRoot, withIntermediateDirectories: true)
        let liveScratch = ModelInstaller.scratchDir(root: liveRoot)
        try fm.createDirectory(atPath: liveScratch, withIntermediateDirectories: true)
        let mine = (liveScratch as NSString)
            .appendingPathComponent("staging-\(ProcessInfo.processInfo.processIdentifier)-kept")
        let theirs = (liveScratch as NSString).appendingPathComponent("staging-99999-swept")
        try fm.createDirectory(atPath: mine, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: theirs, withIntermediateDirectories: true)
        try ModelInstaller.recover(receiptBundle, root: liveRoot)
        check("recovery leaves scratch this process may still be using",
              fm.fileExists(atPath: mine))
        check("…and sweeps scratch a crash left from another process",
              !fm.fileExists(atPath: theirs))

        // A real archive that expands 40× is refused — ditto is stopped while
        // it runs, or measured the moment it exits; either way the disk never
        // fills. Honest packages expand far less than the eighth ceiling.
        if FileManager.default.isExecutableFile(atPath: ModelArchive.ditto) {
            let bombDir = scratch + "/bomb"
            try fm.createDirectory(atPath: bombDir, withIntermediateDirectories: true)
            try Data(count: 40_000_000).write(
                to: URL(fileURLWithPath: bombDir + "/blob.bin"))     // zeros: ~40k:1
            let bombZip = scratch + "/bomb.zip"
            let squeeze = Process()
            squeeze.executableURL = URL(fileURLWithPath: ModelArchive.ditto)
            squeeze.arguments = ["-c", "-k", "--keepParent", bombDir, bombZip]
            try squeeze.run()
            squeeze.waitUntilExit()
            var bomb: String?
            do { _ = try ModelArchive.unwrapPackage(URL(fileURLWithPath: bombZip)) }
            catch { bomb = ModelDownloader.sentence(error) }
            check("an archive that expands 40× is refused before the disk fills",
                  (bomb ?? "").contains("expands beyond"), bomb ?? "no error")
        }

        // --- 5. removal -------------------------------------------------------
        try ModelInstaller.remove(bundle, root: root)
        check("removing a bundle takes its files away",
              !fm.fileExists(atPath: root + "/tags/siglip2_base_prompts.json")
                && !fm.fileExists(atPath: root + "/tags/siglip2_base.mlmodelc"))
        check("…and the bundle reports itself missing again", !bundle.isInstalled(root: root))
        var secondRemoval: String?
        do { try ModelInstaller.remove(bundle, root: root) }
        catch { secondRemoval = ModelDownloader.sentence(error) }
        check("removing it twice says there was nothing to remove",
              (secondRemoval ?? "").contains("not installed"), secondRemoval ?? "no error")

        // --- 6. an asset address that is not a URL ----------------------------
        let broken = AIBundle(id: "broken", title: "Broken", what: "nothing",
                              feature: "tags",
                              assets: [AIBundleAsset(url: "ftp", sha256: helloDigest,
                                                     bytes: 1, kind: .file,
                                                     install: "tags/x")])
        var badURL: String?
        do {
            try await ModelInstaller.install(broken, root: scratch + "/u",
                                             transport: FixtureTransport(directory: served),
                                             prepare: prepare) { _, _ in }
        } catch { badURL = ModelDownloader.sentence(error) }
        check("an asset with no usable address is refused by name",
              (badURL ?? "").contains("not a URL"), badURL ?? "no error")

        // --- 7. the catalogue -------------------------------------------------
        // The fixture serves by `url.lastPathComponent`, and a query string is
        // not part of that — so three URLs that differ only by `?good`/`?newer`
        // would all read the same file and the newer-version check would be
        // testing nothing. Distinct path components, distinct files.
        func catalogueURL(_ name: String) -> URL {
            URL(string: "https://example.invalid/\(name)")!
        }
        func manifest(_ json: String, named name: String) throws -> FixtureTransport {
            try Data(json.utf8).write(
                to: URL(fileURLWithPath: (served as NSString).appendingPathComponent(name)))
            return FixtureTransport(directory: served)
        }
        func catalogue(_ version: Int, feature: String = "tags") throws -> String {
            // `bytes` tells the truth (the file is exactly this long): a
            // catalog that understates an asset's size is refused by the
            // oversize guard, and this fixture downloads for real.
            let bytes = try Data(contentsOf: URL(fileURLWithPath: served + "/promptA.txt")).count
            return """
            {"version":\(version),"bundles":[{"id":"tags","title":"T","what":"w",
             "feature":"\(feature)","assets":[{"url":"https://example.invalid/promptA.txt",
             "sha256":"\(try ModelVerifier.sha256(fileAt: served + "/promptA.txt"))",
             "bytes":\(bytes),"kind":"file","install":"tags/siglip2_base_prompts.json"}]}]}
            """
        }

        let good = ModelDownloader(
            root: root,
            transport: try manifest(try catalogue(1), named: "ai-bundles.json"),
            prepare: prepare,
            catalogueURL: catalogueURL("ai-bundles.json"))
        await good.refreshCatalogue()
        check("a published catalogue is read", good.manifest?.bundles.count == 1,
              "\(String(describing: good.manifest))")
        check("…and its bundle knows which feature it lights up",
              good.manifest?.bundles.first?.capabilityFeature == .tags)
        check("a feature id this build does not know is tolerated, not crashed on",
              AIBundle(id: "x", title: "x", what: "x", feature: "telepathy",
                       assets: []).capabilityFeature == nil)

        let future = ModelDownloader(
            root: root,
            transport: try manifest(try catalogue(99), named: "newer.json"),
            prepare: prepare,
            catalogueURL: catalogueURL("newer.json"))
        await future.refreshCatalogue()
        if case .unavailable(let why) = future.state {
            check("a catalogue from a newer version is refused by reason",
                  why.contains("newer version"), why)
        } else {
            check("a catalogue from a newer version is refused by reason", false,
                  "\(future.state)")
        }
        check("…and no bundle was adopted from it", future.manifest == nil)

        let offline = ModelDownloader(
            root: root,
            transport: try manifest("{}", named: "absent.json"),
            prepare: prepare,
            // Nothing is written under this name, so the fetch itself fails.
            catalogueURL: catalogueURL("not-published.json"))
        await offline.refreshCatalogue()
        if case .unavailable(let why) = offline.state {
            check("an unreadable catalogue is reported, not silently empty",
                  why.contains("could not read the list"), why)
        } else {
            check("an unreadable catalogue is reported, not silently empty", false,
                  "\(offline.state)")
        }

        // --- 8. the app's own wrapper ----------------------------------------
        // Section 5 already took the bundle out, so the wrapper starts from a
        // clean root and its own install/remove are the only ones in play.
        let app = ModelDownloader(
            root: root,
            transport: try manifest(try catalogue(1), named: "ai-bundles.json"),
            prepare: prepare,
            catalogueURL: catalogueURL("ai-bundles.json"))
        await app.refreshCatalogue()
        guard let listed = app.manifest?.bundles.first else {
            print("\nFAIL no bundle to install\n")
            exit(1)
        }
        let before = app.revision
        var observedInstallations: [Bool] = []
        app.onArtifactsChanged = { observedInstallations.append(app.isInstalled(listed)) }
        await app.install(listed)
        check("installing through the app's wrapper ends idle", app.state == .idle,
              "\(app.state)")
        check("…and the bundle is on disk", app.isInstalled(listed))
        check("…and the disk-changed revision moved", app.revision > before)
        check("app-owned observer sees the completed install without a Settings view",
              observedInstallations == [true])
        await app.remove(listed)
        check("removing through the wrapper ends idle", app.state == .idle, "\(app.state)")
        check("…and the bundle is gone", !app.isInstalled(listed))
        check("app-owned observer sees removal after the artifacts are gone",
              observedInstallations == [true, false])
        app.onArtifactsChanged = nil

        let doomed = ModelDownloader(
            root: scratch + "/doomed",
            transport: { let t = FixtureTransport(directory: served); t.failingDownloads = true; return t }(),
            prepare: prepare,
            catalogueURL: catalogueURL("ai-bundles.json"))
        await doomed.refreshCatalogue()
        var failedRefreshes = 0
        doomed.onArtifactsChanged = { failedRefreshes += 1 }
        if let bundle = doomed.manifest?.bundles.first {
            await doomed.install(bundle)
        }
        if case .failed(_, let why) = doomed.state {
            check("a download that cannot start reports why", why.contains("unreachable"), why)
        } else {
            check("a download that cannot start reports why", false, "\(doomed.state)")
        }
        check("failed model operations also refresh actual disk availability", failedRefreshes == 1)

        // --- 9. unwrapping a shipped package ---------------------------------
        // A Core ML package is a directory, so it travels as a zip and has to be
        // unwrapped before `MLModel.compileModel` sees it. Getting this wrong is
        // silent: an index of the container rather than the package compiles to
        // a model directory the app then writes somewhere nothing reads.
        if FileManager.default.isExecutableFile(atPath: ModelArchive.ditto) {
            let built = scratch + "/built/siglip2_base_image.mlpackage"
            try fm.createDirectory(atPath: built + "/Data", withIntermediateDirectories: true)
            try Data("manifest".utf8).write(
                to: URL(fileURLWithPath: built + "/Manifest.json"))
            let zipped = scratch + "/built/asset.zip"
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: ModelArchive.ditto)
            ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                               built, zipped]
            try ditto.run()
            ditto.waitUntilExit()
            check("the shipped package archives cleanly", ditto.terminationStatus == 0)

            let unwrapped = try ModelArchive.unwrapPackage(URL(fileURLWithPath: zipped))
            check("unwrapping yields the package itself, not the folder around it",
                  unwrapped.lastPathComponent == "siglip2_base_image.mlpackage",
                  unwrapped.path)
            check("…and it is the directory Core ML can compile",
                  fm.fileExists(atPath: unwrapped.appendingPathComponent("Manifest.json").path))

            // A package that is already a directory (a dev install) is taken
            // as-is, so the same code path serves both.
            let asIs = try ModelArchive.unwrapPackage(URL(fileURLWithPath: built))
            check("an already-unpacked package is passed straight through",
                  asIs.path == built)

            // An archive that is not ours must be refused, not guessed at.
            // Two items at the archive's TOP LEVEL: no `--keepParent`, so the
            // contents of the folder are what the extractor sees.
            let twoItems = scratch + "/built/two.zip"
            try fm.createDirectory(atPath: scratch + "/built/twosrc/a", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: scratch + "/built/twosrc/b", withIntermediateDirectories: true)
            let again = Process()
            again.executableURL = URL(fileURLWithPath: ModelArchive.ditto)
            again.arguments = ["-c", "-k", scratch + "/built/twosrc", twoItems]
            try again.run()
            again.waitUntilExit()
            check("a two-item fixture archive was built",
                  fm.fileExists(atPath: twoItems), "ditto could not build the fixture")
            var refusal: String?
            do { _ = try ModelArchive.unwrapPackage(URL(fileURLWithPath: twoItems)) }
            catch { refusal = ModelDownloader.sentence(error) }
            check("an archive holding two things is refused rather than guessed at",
                  (refusal ?? "").contains("expected one"), refusal ?? "no error")
        } else {
            print("skip ditto is not at \(ModelArchive.ditto); the unwrap step is untested here")
        }

        // --- an install keeps a copy, and a kept copy can be switched back to ---
        // The wiring, not the store: this is what `install` and the Settings row
        // themselves do — a downloaded pack is kept, and putting an older one
        // back is the same transaction with no download at all.
        let keepRoot = scratch + "/keep-support"
        try fm.createDirectory(atPath: keepRoot, withIntermediateDirectories: true)

        let aJSON = try asset("promptA.txt", install: "tags/siglip2_base_prompts.json")
        let aBin = try asset("promptB.txt", install: "tags/siglip2_base_prompts.f32")
        let packA = AIBundle(id: "tags-keep", title: "TagsKeep", what: "suggestions",
                             feature: AICapability.Feature.tags.rawValue,
                             assets: [aJSON, aBin])
        let bJSON = try asset("promptA2.txt", install: "tags/siglip2_base_prompts.json")
        let bBin = try asset("promptB2.txt", install: "tags/siglip2_base_prompts.f32")
        let packB = AIBundle(id: "tags-keep", title: "TagsKeep", what: "suggestions",
                             feature: AICapability.Feature.tags.rawValue,
                             assets: [bJSON, bBin])

        let gate = FixtureTransport(directory: served)
        let downloads = ModelDownloader(root: keepRoot, transport: gate, prepare: prepare,
                                        catalogueURL: URL(string: "https://example.invalid/c.json")!)
        check("nothing is kept before an install", downloads.kept.isEmpty)

        await downloads.install(packA)
        let keptFirst = downloads.kept.first
        check("a completed install keeps a copy of what it installed",
              downloads.kept.count == 1, "\(downloads.kept.count)")
        check("and that copy is the one in force",
              keptFirst.map { downloads.isLive($0) } == true)
        check("the pack still reports itself installed", packA.isInstalled(root: keepRoot))

        await downloads.install(packB)
        check("a second revision is a second kept copy",
              downloads.kept.count == 2, "\(downloads.kept.count)")
        let liveAfterUpgrade = try? Data(contentsOf: URL(fileURLWithPath: keepRoot + "/tags/siglip2_base_prompts.json"))
        check("the newer revision is what is installed",
              liveAfterUpgrade == (try? Data(contentsOf: URL(fileURLWithPath: served + "/promptA2.txt"))))

        // Switch back to the older copy: no network, and the bytes on disk — and
        // the receipt that identifies them — become the older version's.
        let downloadsBefore = gate.asked.count
        if let keptFirst { await downloads.activate(keptFirst) }
        check("switching downloads nothing", gate.asked.count == downloadsBefore,
              "\(gate.asked.count - downloadsBefore) request(s)")
        let liveAfterSwitch = try? Data(contentsOf: URL(fileURLWithPath: keepRoot + "/tags/siglip2_base_prompts.json"))
        check("switching puts the older bytes live",
              liveAfterSwitch == (try? Data(contentsOf: URL(fileURLWithPath: served + "/promptA.txt"))))
        check("the receipt names the version that was switched to",
              InstalledReceipt.read(bundleID: "tags-keep", root: keepRoot)?.catalogDigest
                == InstalledReceipt.catalogDigest(of: packA))
        let other = downloads.kept.first { $0.token != keptFirst?.token }
        check("and the other kept copy is not the one in force",
              other.map { !downloads.isLive($0) } == true,
              "other=\(other?.summary ?? "none")")
        check("the switched-to pack reports itself installed", packA.isInstalled(root: keepRoot))
        check("a switch leaves no half-installed file", !anyPartial(keepRoot), "a .partial is present")

        // A swap under a running pass is refused, exactly as an install is.
        downloads.isInferring = { true }
        if let newest = downloads.kept.first(where: { !downloads.isLive($0) }) {
            await downloads.activate(newest)
        }
        var refusal: String?
        if case .failed(_, let why) = downloads.state { refusal = why }
        let liveDuringRefusal = try? Data(contentsOf: URL(fileURLWithPath: keepRoot + "/tags/siglip2_base_prompts.json"))
        check("a switch is refused while the AI is working",
              (refusal ?? "").contains("the AI is working right now"), refusal ?? "no refusal")
        check("and the refusal changed nothing on disk", liveDuringRefusal == liveAfterSwitch)
        downloads.isInferring = { false }

        // Forgetting a copy is not removing the install.
        if let newest = downloads.kept.first(where: { !downloads.isLive($0) }) {
            await downloads.discard(newest)
        }
        check("a discarded copy is gone from the store", downloads.kept.count == 1, "\(downloads.kept.count)")
        check("and the install it was a copy of is untouched",
              packA.isInstalled(root: keepRoot)
                && (try? Data(contentsOf: URL(fileURLWithPath: keepRoot + "/tags/siglip2_base_prompts.json"))) == liveAfterSwitch)

        // --- the revision switched away from, and the way back to it ----------
        // A receipt carrying another bundle's digest decides NO just as much as
        // yes: the newer revision's bytes are gone from the live paths, so it
        // must stop claiming to be installed — otherwise the row offers Remove
        // for a pack that is not on disk and hides the way back to it.
        check("the revision that was switched away from stops reporting installed",
              !packB.isInstalled(root: keepRoot))
        let keptBeforeReinstall = downloads.kept.count
        await downloads.install(packB)
        check("installing it again puts its bytes back",
              packB.isInstalled(root: keepRoot)
                && (try? Data(contentsOf: URL(fileURLWithPath: keepRoot + "/tags/siglip2_base_prompts.json")))
                    == (try? Data(contentsOf: URL(fileURLWithPath: served + "/promptA2.txt"))))
        check("and it is kept as one copy of that revision, not two",
              downloads.kept.count == keptBeforeReinstall + 1
                && Set(downloads.kept.map { $0.token }).count == downloads.kept.count,
              "\(downloads.kept.count) kept, \(Set(downloads.kept.map { $0.token }).count) distinct")

        print(failures == 0 ? "\nALL PASS model downloader" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
