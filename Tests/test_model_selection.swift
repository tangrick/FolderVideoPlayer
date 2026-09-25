// T02 — the pack registry and the persisted choice of which pack a capability
// uses, without a network.
//
// Until this existed, "which model is in force" was an accident of the disk: the
// first bundle the catalogue happened to list for a feature, and after an
// install, whatever that install left behind. With one pack per feature that is
// indistinguishable from a choice; with two it is a coin toss nobody recorded.
// So the things worth proving are:
//
//   1. a choice round-trips, and names the pack it was made for;
//   2. there is at most ONE choice per capability — a second replaces the first,
//      or "which pack is in force" would have two answers;
//   3. an incompatible pack is REFUSED with its reason, and records nothing —
//      a record naming such a pack is a promise the app breaks at load time;
//   4. a catalogue cannot write the choice file: a download that could choose
//      which model the app loads is choosing for the user;
//   5. removing a pack forgets it, and a choice that outlives its pack does not
//      refuse a feature the catalogue can still serve;
//   6. nothing chosen (and no file at all) behaves exactly as it did before
//      selections existed — the metadata and manual-tagging paths must not
//      depend on any of this.
//
// `@main` rather than top-level code: this file compiles alongside the app's
// model layer and only main.swift may carry top-level statements.
//
// Run: Tests/run_model_selection.sh

@testable import FVPModel
import Foundation

@main
struct ModelSelectionTest {
    /// Wrapped rather than `throws`, so a thrown error prints the checks that
    /// already ran instead of losing them to the runtime's top-level abort.
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
        let root = NSTemporaryDirectory() + "fvp-selection-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let choiceFile = ModelRegistry.file(root: root)

        // --- 1. a choice round-trips --------------------------------------------
        func pack(_ id: String, adapter: String = "siglip2-base-v1",
                  revision: String = "r1", model: String = "siglip2-base") -> ModelPackDescriptor {
            ModelPackDescriptor(version: 1, modelID: model, revision: revision, adapter: adapter,
                                minimumMacOS: "14.0", architectures: ["arm64", "x86_64"],
                                license: "apache-2.0", sourceURL: "https://example.invalid/model")
        }
        func bundle(_ id: String, feature: String = "tags",
                    descriptor: ModelPackDescriptor?) -> AIBundle {
            AIBundle(id: id, title: "Pack \(id)", what: "fixture", feature: feature,
                     assets: [AIBundleAsset(url: "https://example.invalid/hello",
                                            sha256: String(repeating: "a", count: 64),
                                            bytes: 5, kind: .file, install: "tags/\(id)")],
                     pack: descriptor)
        }

        check("an absent choice file reads as nothing chosen",
              ModelRegistry.read(root: root).selections.isEmpty)
        check("…and the file is where the app will look for it",
              choiceFile == (root as NSString).appendingPathComponent("models/selected.json"))

        let first = bundle("tags-siglip2-base", descriptor: pack("tags-siglip2-base"))
        let registry = try ModelRegistry.choose(first, root: root, at: Date(timeIntervalSince1970: 1_700_000_000))
        let chosen = registry.selection(for: .tags)
        check("a choice is recorded for its capability", chosen?.bundleID == first.id,
              chosen?.bundleID ?? "none")
        check("…and names the pack and revision it was made for",
              chosen?.modelID == "siglip2-base" && chosen?.revision == "r1",
              chosen.map { "\($0.modelID) \($0.revision)" } ?? "none")
        check("…and the choice survives a re-read",
              ModelRegistry.read(root: root).selection(for: .tags)?.bundleID == first.id)
        check("…and reads back as a line a user could report",
              chosen?.summary == "siglip2-base · revision r1", chosen?.summary ?? "none")

        // --- 2. one choice per capability ----------------------------------------
        let other = bundle("tags-siglip2-large", descriptor: pack("tags-siglip2-large",
                                                                  revision: "r2",
                                                                  model: "siglip2-large"))
        _ = try ModelRegistry.choose(other, root: root)
        let afterSecond = ModelRegistry.read(root: root)
        check("a second choice replaces the first for that capability",
              afterSecond.selections.count == 1 && afterSecond.selection(for: .tags)?.bundleID == other.id,
              "\(afterSecond.selections.count) selection(s)")
        check("…and the replaced pack is no longer chosen", !afterSecond.isChosen(first))

        let faces = bundle("faces-yunet-sface", feature: "faces",
                           descriptor: pack("faces-yunet-sface", adapter: "yunet-sface-v1"))
        _ = try ModelRegistry.choose(faces, root: root)
        check("a choice for another capability does not disturb the first",
              ModelRegistry.read(root: root).selection(for: .tags)?.bundleID == other.id)

        // --- 3. an incompatible pack is refused, and records nothing -------------
        let wrongAdapter = bundle("tags-foreign", descriptor: pack("tags-foreign", adapter: "other-v9"))
        var refusal: String?
        do { _ = try ModelRegistry.choose(wrongAdapter, root: root) }
        catch { refusal = ModelDownloader.sentence(error) }
        check("a pack this build cannot run is refused with its reason",
              (refusal ?? "").contains("adapter"), refusal ?? "no error")
        check("…and nothing was recorded for it",
              ModelRegistry.read(root: root).selection(for: .tags)?.bundleID == other.id)

        // Deliberately a name the app will never have. This check used "speech"
        // as its example of an unknown feature until speech became a real one,
        // at which point the pack was refused for its ADAPTER instead and the
        // check failed — correct behaviour, but the fixture no longer meant what
        // the label said. Never point this at a planned feature name.
        let unknownFeature = bundle("tags-x", feature: "not-a-feature", descriptor: pack("tags-x"))
        refusal = nil
        do { _ = try ModelRegistry.choose(unknownFeature, root: root) }
        catch { refusal = ModelDownloader.sentence(error) }
        check("a download that is not one of the app's features is refused",
              (refusal ?? "").contains("not one of this app's AI features"), refusal ?? "no error")

        // A choice can outlive the build that made it: the recorded contract is
        // re-asked on every probe, and answers with the descriptor's own words.
        let recorded = ModelSelection(feature: "tags", bundleID: "old", title: "Old",
                                      pack: pack("old", adapter: "retired-v2"),
                                      chosenAt: Date())
        check("a recorded choice whose adapter this build no longer has refuses worthily",
              (recorded.incompatibility(feature: .tags) ?? "").contains("adapter"),
              recorded.incompatibility(feature: .tags) ?? "no refusal")
        check("…and never fires for a legacy pack that declared no descriptor",
              ModelSelection(feature: "tags", bundleID: "legacy", title: "Legacy",
                             pack: nil, chosenAt: Date()).incompatibility(feature: .tags) == nil)

        // --- 4. a catalogue cannot write the choice file -------------------------
        var forgery = bundle("tags-forge", descriptor: pack("tags-forge"))
        forgery.assets[0] = AIBundleAsset(url: "https://example.invalid/hello",
                                          sha256: String(repeating: "a", count: 64),
                                          bytes: 5, kind: .file, install: "models/selected.json")
        check("a catalog asset may not sit where the choice is written",
              (try? ModelCatalogPolicy.validate(forgery)) == nil)

        // --- 5. removal forgets, and an orphaned choice does not refuse ----------
        let forgotten = ModelRegistry.forget(bundleID: other.id, root: root)
        check("removing a pack forgets the capability that had chosen it",
              forgotten.selection(for: .tags) == nil)
        check("…and leaves other capabilities alone",
              forgotten.selection(for: .faces)?.bundleID == faces.id)
        check("…and the forgetting survives a re-read",
              ModelRegistry.read(root: root).selection(for: .tags) == nil)

        // --- 6. a corrupt or newer file is not a choice --------------------------
        try Data("{\"version\": 9, \"selections\": []}".utf8).write(to: URL(fileURLWithPath: choiceFile))
        check("a choice file from a newer build is refused, not misread",
              ModelRegistry.read(root: root).selections.isEmpty)
        try Data("not json at all".utf8).write(to: URL(fileURLWithPath: choiceFile))
        check("a hand-edited choice file falls back to nothing chosen",
              ModelRegistry.read(root: root).selections.isEmpty)

        // --- 7. the downloader's side: the choice decides which pack is offered ---
        final class FixtureTransport: ModelTransport, @unchecked Sendable {
            var catalogue = Data()
            func fetch(_ url: URL) async throws -> Data { catalogue }
            func download(_ url: URL, to destination: URL,
                          progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
                try Data("hello".utf8).write(to: destination)
                progress(5, 5)
            }
        }
        let served = FixtureTransport()
        let manifest = AIBundleManifest(version: 1, bundles: [first, other])
        served.catalogue = try JSONEncoder().encode(manifest)

        let shopRoot = root + "/shop"
        try fm.createDirectory(atPath: shopRoot, withIntermediateDirectories: true)
        let shop = ModelDownloader(root: shopRoot, transport: served,
                                   prepare: { url, _ in url },
                                   catalogueURL: URL(string: "https://example.invalid/bundles.json")!)
        await shop.refreshCatalogue()
        check("with nothing chosen, the first compatible pack is the one on offer",
              shop.bundle(for: .tags)?.id == first.id, shop.bundle(for: .tags)?.id ?? "none")
        check("…and the picker sees both packs",
              shop.bundles(for: .tags).map(\.id) == [first.id, other.id])
        check("…and nothing is claimed to be in use",
              shop.chosenPack(for: .tags) == nil)

        shop.choose(other)
        check("choosing a pack makes it the one on offer",
              shop.bundle(for: .tags)?.id == other.id, shop.bundle(for: .tags)?.id ?? "none")
        check("…and the row can name it", shop.chosenPack(for: .tags)?.modelID == "siglip2-large")
        check("…and it is on disk for the next launch",
              ModelRegistry.read(root: shopRoot).selection(for: .tags)?.bundleID == other.id)

        shop.choose(wrongAdapter)
        if case .failed(_, let why) = shop.state {
            check("choosing an incompatible pack is refused out loud",
                  why.contains("adapter"), why)
        } else {
            check("choosing an incompatible pack is refused out loud", false, "\(shop.state)")
        }
        check("…and the choice still stands", shop.bundle(for: .tags)?.id == other.id)

        // The pack the user chose was installed and then removed: the capability
        // must fall back to what the catalogue offers, not to a name that is gone.
        _ = ModelRegistry.forget(bundleID: other.id, root: shopRoot)
        await shop.refreshCatalogue()
        check("a removed pack is forgotten and the first pack is offered again",
              shop.chosenPack(for: .tags) == nil && shop.bundle(for: .tags)?.id == first.id)

        // --- 7. speech loads the chosen pack's folder -----------------------------
        // Each speech pack has its own folder; the transcriber must read the one
        // the user chose when it is installed, and whichever is installed when not.
        let speechRoot = root + "/speech"
        func installSpeech(_ folder: String) throws {
            for model in ["AudioEncoder", "TextDecoder", "MelSpectrogram"] {
                try fm.createDirectory(atPath: "\(speechRoot)/\(folder)/\(model).mlmodelc",
                                       withIntermediateDirectories: true)
            }
        }
        func speechBundle(_ id: String, adapter: String) -> AIBundle {
            bundle(id, feature: "speech", descriptor: pack(id, adapter: adapter))
        }
        check("with no speech pack installed there is nothing to transcribe with",
              AICapability.speechPack(root: speechRoot) == nil)

        try installSpeech("models/speech-base")
        check("the only installed pack is used even when nothing is chosen",
              AICapability.speechPack(root: speechRoot)?.adapter == "whisperkit-base-v1")

        try installSpeech("models/speech")
        check("with nothing chosen the largest installed pack is used",
              AICapability.speechPack(root: speechRoot)?.adapter == "whisperkit-large-v3-turbo-v1")

        try ModelRegistry.choose(speechBundle("speech-base", adapter: "whisperkit-base-v1"),
                                 root: speechRoot)
        let chosenSpeech = AICapability.speechPack(root: speechRoot)
        check("choosing the smaller pack makes the transcriber load its folder",
              chosenSpeech?.adapter == "whisperkit-base-v1"
                && chosenSpeech?.folder.path.hasSuffix("/models/speech-base") == true,
              chosenSpeech?.folder.path ?? "none")

        try ModelRegistry.choose(speechBundle("speech-small", adapter: "whisperkit-small-216mb-v1"),
                                 root: speechRoot)
        check("a chosen pack that is not installed yet falls back to an installed one",
              AICapability.speechPack(root: speechRoot)?.adapter == "whisperkit-large-v3-turbo-v1")

        try fm.removeItem(atPath: "\(speechRoot)/models/speech-base/TextDecoder.mlmodelc")
        try ModelRegistry.choose(speechBundle("speech-base", adapter: "whisperkit-base-v1"),
                                 root: speechRoot)
        check("a half-installed pack is never loaded",
              AICapability.speechPack(root: speechRoot)?.adapter == "whisperkit-large-v3-turbo-v1")

        check("a speech adapter this build does not know is refused",
              pack("x", adapter: "whisperkit-tiny-v1").incompatibility(feature: "speech") != nil)

        print(failures == 0 ? "\nALL PASS model selection" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
