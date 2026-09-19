// The packed catalogue, checked by the code that will refuse it.
//
// test_face_engine decodes a packed catalogue and looks at the faces bundle.
// This one asks the harder question: does `ModelCatalogPolicy.validate` —
// the function that stands between a catalogue and the user's disk — accept
// the whole document, and does the app agree with the catalogue about where
// the speech pack goes?
//
// The second half is not ceremony. Writing this slice, `install` paths were
// first chosen as "speech/…" while the app only permits "tags/" or "models/":
// the app would have refused the ENTIRE catalogue — every bundle, not just the
// new one — and the mistake was invisible until the Swift validator ran. The
// coherence checks below are that validator's concerns lifted into the gate.
//
// Skips in one piece when no catalogue is handed over: dist/ is build output,
// not something in the repository, so a clone without a packed release is
// normal (same convention as test_face_engine).
//
//   FVP_BUNDLES=/path/to/dist/ai-bundles.json sh Tests/run_catalogue_check.sh

import Foundation

@main
struct CatalogueHarness {
    static var failures = 0
    static var skipped = 0

    static func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("ok   \(what)")
        } else {
            failures += 1
            print("FAIL \(what)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func skip(_ what: String) {
        skipped += 1
        print("skip \(what)")
    }

    static func main() {
        guard let path = ProcessInfo.processInfo.environment["FVP_BUNDLES"],
              !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            skip("no packed catalogue to check — set FVP_BUNDLES to a dist/ai-bundles.json")
            print("\nSKIPPED catalogue (\(skipped) skip)")
            exit(0)
        }

        print("catalogue: \(path)\n")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            check("the catalogue is readable", false, path)
            exit(1)
        }
        guard let manifest = try? JSONDecoder().decode(AIBundleManifest.self, from: data) else {
            check("the catalogue decodes as an AIBundleManifest", false, "\(data.count) bytes")
            exit(1)
        }
        check("the catalogue decodes as an AIBundleManifest", true)

        // --- 1. the validator that runs at install time -----------------------
        do {
            try ModelCatalogPolicy.validate(manifest)
            check("the shipped catalogue passes ModelCatalogPolicy.validate", true)
        } catch {
            check("the shipped catalogue passes ModelCatalogPolicy.validate", false, "\(error)")
        }

        // --- 2. one bundle per feature, ids unique ----------------------------
        let features = manifest.bundles.compactMap(\.capabilityFeature)
        check("no two bundles claim the same feature", Set(features).count == features.count,
              features.map(\.rawValue).joined(separator: ", "))

        // --- 3. the speech bundle, if the catalogue offers one ----------------
        guard let speech = manifest.bundles.first(where: { $0.id == "speech" }) else {
            skip("this catalogue offers no speech bundle (older catalogue — the app still works)")
            print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURES") catalogue"
                  + " (\(skipped) skip)")
            exit(failures == 0 ? 0 : 1)
        }

        check("the speech bundle is what the Speech row asks for",
              speech.capabilityFeature == .speech, speech.capabilityFeature?.rawValue ?? "nil")
        check("the speech bundle carries a pack descriptor", speech.pack != nil)
        check("the speech bundle has 22 assets (\(speech.assets.count))", speech.assets.count == 22)
        let total = speech.assets.reduce(Int64(0)) { $0 + $1.bytes }
        check("the speech bundle's size is the pack's (\(total / 1_000_000) MB)", total > 600_000_000)

        for asset in speech.assets {
            check("speech: \(asset.install) is https and credential-free",
                  ModelCatalogPolicy.secureURL(asset.url) != nil, asset.url)
        }

        // The URL's path and the install path must describe the SAME file, and
        // no path component may repeat. A doubled path (.../632MB/632MB/...)
        // 404s for every user ("Entry not found") while still being https,
        // token-free, commit-pinned and ending in the right file name — every
        // other check here passes — so the repeated-component rule is the one
        // that catches it. Only a real fetch can prove a 200; the suite runs
        // offline by design, so that proof lives in the fetch harness.
        var mismatched: [String] = []
        var repeated: [String] = []
        var seen: [String: String] = [:]
        for asset in speech.assets {
            // Basename, not the whole path: the Hub URL carries the PACK folder
            // where the install path carries "models/speech", so the parent
            // segment legitimately differs. The leaf cannot.
            let leaf = String(asset.install.split(separator: "/").last ?? "")
            if !asset.url.hasSuffix("/" + leaf) { mismatched.append(asset.install) }
            let segs = URL(string: asset.url)?.path.split(separator: "/").map(String.init) ?? []
            if zip(segs, segs.dropFirst()).contains(where: { $0 == $1 }) {
                repeated.append(asset.install)
            }
            if seen[asset.url] != nil { repeated.append("duplicate URL: " + asset.install) }
            seen[asset.url] = asset.install
        }
        check("every speech asset's URL names the same file as its install path",
              mismatched.isEmpty, mismatched.prefix(2).joined(separator: " | "))
        check("no speech asset URL repeats a component or duplicates another",
              repeated.isEmpty, repeated.prefix(2).joined(separator: " | "))

        // --- 4. pinned to a commit, never a branch ----------------------------
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for asset in speech.assets {
            let pinned = asset.url.range(of: "/resolve/") != nil
                && asset.url.range(of: "/main/") == nil
            let commit = asset.url.split(separator: "/")
                .first { $0.count == 40 && $0.unicodeScalars.allSatisfy(hex.contains) } != nil
            check("speech: \(asset.install) is pinned to a commit", pinned && commit,
                  pinned ? "no 40-hex commit in the URL" : "not a /resolve/ URL, or points at a branch")
        }

        // --- 5. the app and the catalogue agree on where it goes --------------
        // Every asset must land inside the folder the Speech row reads for its
        // "what is installed" list, or the row reports nothing after a
        // successful install.
        let roots = AICapability.Feature.speech.modelLocations.map { $0 + "/" }
        for asset in speech.assets {
            check("speech: \(asset.install) lands in the folder the row reads",
                  roots.contains { asset.install.hasPrefix($0) },
                  "the row looks in \(roots.joined(separator: ", "))")
        }

        // --- 6. the descriptor must be usable HERE ----------------------------
        if let pack = speech.pack {
            let here = ModelPackEnvironment(architecture: "arm64", macOSVersion: "14.0")
            check("the speech pack is compatible on Apple silicon and macOS 14",
                  pack.incompatibility(feature: "speech", environment: here) == nil,
                  pack.incompatibility(feature: "speech", environment: here) ?? "")
            // The adapter is per feature. A pack for speech must not be
            // acceptable as the tag model, or a description could talk the app
            // into loading it for the wrong job.
            check("the speech pack is not accepted as the tag model",
                  pack.incompatibility(feature: "tags", environment: here) != nil)
            check("the speech pack names its licence for the release notes",
                  !pack.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pack.license)
            check("the speech pack names the revision it was built from",
                  pack.revision == "0f63a7800b00dd0226abd051b906c246e1907482", pack.revision)
            check("the speech pack points at the repository it came from",
                  pack.sourceURL.contains("huggingface.co/argmaxinc/whisperkit-coreml"), pack.sourceURL)
        }

        print("")
        if failures == 0 {
            print("ALL PASS catalogue (\(skipped) skip)")
            exit(0)
        }
        print("\(failures) FAILURES")
        exit(1)
    }
}
