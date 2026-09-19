// The prompt table, checked against numpy's own arithmetic.
//
// The Swift table is only worth having if it produces the SAME numbers Python
// produced — a wrong row offset, a transposed read or a 511-wide dot product
// would all still return plausible scores. So every number here is compared
// against a fixture generated from the same table by
// docs/coreml-spike/table_parity.py, and the two are tied together by
// prompt_sha256.
//
// Also covers the boundaries the caller cares about: the short-clip frame
// requirement (1/2/3 frames) and the tag chip cap — and the private overlay:
// the real one when it sits beside the table, and always a synthetic one, so
// the merge is checked on a machine that has no private vocabulary.
//
// `@main` rather than top-level code: this file is compiled alongside
// PromptTable.swift, and only a file literally named main.swift may carry
// top-level statements.
//
// Run: Tests/run_prompt_table.sh

import Foundation

@main
struct PromptTableTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }
        func checkClose(_ name: String, _ got: Double, _ want: Double, _ tol: Double = 1e-5) {
            let ok = abs(got - want) <= tol
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }

        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: prompt_table <table-dir> <parity-fixture.json>")
            exit(2)
        }
        let tableDir = args[1]
        let fixturePath = args[2]

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-prompt-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        // --- 1. the layout the app resolves at runtime -----------------------
        check("a bare root has no table", !PromptTable.isInstalled(root: scratch))

        let tagsDir = (scratch as NSString).appendingPathComponent("tags")
        try! fm.createDirectory(atPath: tagsDir, withIntermediateDirectories: true)
        for name in ["siglip2_base_prompts.json", "siglip2_base_prompts.f32",
                     "siglip2_base_prompts.private.json", "siglip2_base_prompts.private.f32"] {
            let from = (tableDir as NSString).appendingPathComponent(name)
            // The overlay is optional; the table is not (the copy traps if absent).
            if name.contains(".private."), !fm.fileExists(atPath: from) { continue }
            try! fm.copyItem(atPath: from,
                             toPath: (tagsDir as NSString).appendingPathComponent(name))
        }
        check("isInstalled sees <root>/tags/\(PromptTable.slug).*",
              PromptTable.isInstalled(root: scratch))
        check("jsonURL is <root>/tags/\(PromptTable.slug).json",
              PromptTable.jsonURL(root: scratch).path.hasSuffix("/tags/\(PromptTable.slug).json"))

        let table: PromptTable
        do {
            table = try PromptTable(root: scratch)
        } catch {
            print("FAIL loading the table: \(error)")
            exit(1)
        }

        // --- 2. shape and constants -----------------------------------------
        let fixture = (try! JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: fixturePath)))) as! [String: Any]

        check("prompt_sha256 matches the fixture (same table, not a stale copy)",
              table.promptSHA == (fixture["prompt_sha256"] as? String ?? "-"))
        // The literal, not `VisionEmbedder.dim`: this rig compiles PromptTable
        // alone (`run_prompt_table.sh`), so the embedder is not in scope here.
        check("dim 768 (SigLIP 2 B/16)",
              table.dim == 768 && table.dim == (fixture["dim"] as? Int ?? 0))
        check("row count matches the json and the fixture",
              table.rowCount == (fixture["rows"] as? Int ?? -1)
              && table.matrix.count == table.rowCount * table.dim)
        // Section bounds come from numpy's reading of the same files (overlay
        // appended), not from literals: the public table starts at neutral.
        let layout = fixture["layout"] as? [String: [Int]] ?? [:]
        func bounds(_ key: String) -> Range<Int> {
            guard let p = layout[key], p.count == 2 else { return 0..<0 }
            return p[0]..<p[1]
        }
        let hasOverlay = fixture["has_overlay"] as? Bool ?? false
        check("NSFW rows are numpy's (empty without the overlay)",
              table.nSFW == (hasOverlay ? bounds("nsfw") : 0..<0))
        check("neutral rows are numpy's", table.neutral == bounds("neutral") && !table.neutral.isEmpty)
        check("background rows are numpy's", table.background == bounds("background") && !table.background.isEmpty)
        // The tag count comes from numpy's own pass over the same table, which
        // reads engine.py's SUGGEST_VOCAB — a hardcoded number here just means a
        // vocabulary edit fails as "the table is wrong" instead of "the list
        // changed", and it would not catch the two sides disagreeing.
        check("the tag list matches numpy's, name for name",
              Set(table.tags.map(\.name))
              == Set((fixture["tag_margins"] as? [String: Any] ?? [:]).keys))

        // Five tags were cut on 2026-09-12 after measurement: offered ~75 times
        // across two engines and accepted ZERO times, and never once applied by
        // hand in 4,747 real tag applications. They are generic human-presence
        // detectors ("a close up of one person's face") that beat the bland
        // background pool on any footage with a person in it, so they crowded
        // out real answers in a list capped at 8. Re-adding one should fail
        // here and be argued with evidence.
        let cut = ["Speech", "Portrait", "Cooking", "Screen Recording", "Zoo"]
        check("the five never-accepted tags stay out of the vocabulary",
              !table.tags.contains { cut.contains($0.name) })
        let wantPaired = fixture["paired_names"] as? [String] ?? []
        check("the paired tags are numpy's (none without the overlay), and NOT in the suggestion list",
              table.pairedTags.map(\.name) == wantPaired
              && (hasOverlay || wantPaired.isEmpty)
              && !table.tags.contains { wantPaired.contains($0.name) })
        // Suggestion rows sit AFTER the three pools, and no tag may reach into
        // them: a tag scored against the wrong rows still looks like a number.
        check("every tag owns at least one row",
              table.tags.allSatisfy { !$0.rows.isEmpty })
        check("no tag row reaches into the neutral/background pools",
              table.tags.allSatisfy { $0.rows.lowerBound >= table.background.upperBound }
              && table.pairedTags.allSatisfy {
                  $0.rows.lowerBound >= (table.tags.last?.rows.upperBound ?? 0) })

        // The constants come from engine.py, not from this file: a drift there
        // changes a verdict without changing any code a reader would look at.
        check("MARGIN_BIAS 0.03", abs(Double(table.constants.marginBias) - 0.03) < 1e-9)
        check("MARGIN_TEMPERATURE 40.0", abs(Double(table.constants.marginTemperature) - 40.0) < 1e-9)
        check("NSFW_THRESHOLD 0.5", table.constants.nsfwThreshold == 0.5)
        check("SUGGEST_MARGIN 0.02", abs(Double(table.constants.suggestMargin) - 0.02) < 1e-9)
        check("SUGGEST_MAX_TAGS 8", table.constants.suggestMaxTags == 8)
        check("the table records the engine.py it was built from",
              table.engineSHA.count == 64 && !table.promptSHA.isEmpty)

        // Every row is unit-length, so a dot product IS the cosine similarity.
        // If this ever fails, every score in the app is off by a scale factor.
        var worstNorm = 0.0
        for row in 0..<table.rowCount {
            let base = row * table.dim
            var sum = 0.0
            for i in 0..<table.dim {
                sum += Double(table.matrix[base + i]) * Double(table.matrix[base + i])
            }
            worstNorm = max(worstNorm, abs(sum.squareRoot() - 1.0))
        }
        checkClose("all rows unit-normalised", worstNorm, 0.0, 1e-5)

        // --- 3. the same arithmetic as numpy ---------------------------------
        // The probe vector is sin(i * 0.7) normalised — closed form, so both
        // languages build the identical input rather than trusting two PRNGs to
        // agree.
        var probe = [Double](repeating: 0, count: table.dim)
        for i in 0..<table.dim { probe[i] = sin(Double(i) * 0.7) }
        let probeNorm = (probe.reduce(0) { $0 + $1 * $1 }).squareRoot()
        let vector = probe.map { Float($0 / probeNorm) }

        let wantedVector = fixture["vector"] as! [Double]
        var vectorDelta = 0.0
        for i in 0..<table.dim {
            vectorDelta = max(vectorDelta, abs(Double(vector[i]) - wantedVector[i]))
        }
        checkClose("probe vector matches the fixture", vectorDelta, 0.0, 1e-6)

        if let want = fixture["nsfw_score"] as? Double {
            checkClose("nsfwScore matches numpy", table.nsfwScore(vector: vector) ?? -1, want)
        } else {
            check("no NSFW pool, no NSFW score", table.nsfwScore(vector: vector) == nil)
        }

        let wantMargins = fixture["tag_margins"] as! [String: Double]
        let gotMargins = table.tagMargins(vector: vector)
        check("one margin per suggestion tag", gotMargins.count == table.tags.count)
        var worstMargin = 0.0
        var worstTag = ""
        for (tag, margin) in gotMargins {
            guard let want = wantMargins[tag] else {
                print("FAIL tag '\(tag)' is in the table but not the fixture")
                failures += 1
                continue
            }
            if abs(Double(margin) - want) > worstMargin {
                worstMargin = abs(Double(margin) - want)
                worstTag = tag
            }
        }
        checkClose("all \(gotMargins.count) tag margins match numpy (worst: \(worstTag))",
                   worstMargin, 0.0, 1e-5)

        // --- 4. the suggestion pass composes those margins right -------------
        let oneFrame = table.suggestions(vectors: [vector])
        let wantAll = fixture["suggest_1frame_all"] as! [String]
        let wantCapped = fixture["suggest_1frame_capped"] as! [String]
        check("one frame fires \(wantAll.count) tags, capped to \(wantCapped.count)",
              oneFrame.map(\.tag) == wantCapped)
        check("every returned chip clears SUGGEST_MARGIN",
              oneFrame.allSatisfy { $0.confidence >= Double(table.constants.suggestMargin) })
        check("strongest first",
              oneFrame.map(\.confidence) == oneFrame.map(\.confidence).sorted(by: >))
        check("source is zeroshot", oneFrame.allSatisfy { $0.source == "zeroshot" })
        check("frame count is 1 for a single frame", oneFrame.allSatisfy { $0.frames == 1 })

        // minFrames boundaries — the <= vs < cases a boundary bug hides in.
        check("minFrames: 1 frame -> 1", PromptTable.minFrames(for: 1) == 1)
        check("minFrames: 3 frames -> 1", PromptTable.minFrames(for: 3) == 1)
        check("minFrames: 4 frames -> 2 (boundary)", PromptTable.minFrames(for: 4) == 2)
        check("minFrames: 10 frames -> 2", PromptTable.minFrames(for: 10) == 2)
        check("minFrames: 11 frames -> 3 (boundary)", PromptTable.minFrames(for: 11) == 3)
        check("minFrames: 250 frames -> 3", PromptTable.minFrames(for: 250) == 3)
        check("no frames, no chips", table.suggestions(vectors: []).isEmpty)

        // The frame requirement has to bite: a zero vector scores 0 against
        // every row, so it contributes no hits and the probe frame contributes
        // exactly the hits the single-frame case saw. Three frames need one
        // hit, four need two — so the same single strong frame must be offered
        // at 3 and withheld at 4.
        let zero = [Float](repeating: 0, count: table.dim)
        check("a tag strong on 1 of 3 frames IS offered (minFrames 1)",
              table.suggestions(vectors: [vector, zero, zero]).map(\.tag) == oneFrame.map(\.tag))
        check("a tag strong on 1 of 4 frames is NOT offered (minFrames 2)",
              table.suggestions(vectors: [vector, zero, zero, zero]).isEmpty)
        check("the same tag on 2 of 4 frames IS offered (boundary)",
              table.suggestions(vectors: [vector, vector, zero, zero]).map(\.tag) == oneFrame.map(\.tag))

        // --- 5. a broken file is refused, not mis-read -----------------------
        let jsonData = try! Data(contentsOf: URL(fileURLWithPath: (tagsDir as NSString)
            .appendingPathComponent(PromptTable.slug + ".json")))
        let binData = try! Data(contentsOf: URL(fileURLWithPath: (tagsDir as NSString)
            .appendingPathComponent(PromptTable.slug + ".f32")))

        func mutated(_ json: Data, _ change: (inout [String: Any]) -> Void) -> Data {
            var object = (try! JSONSerialization.jsonObject(with: json)) as! [String: Any]
            change(&object)
            return try! JSONSerialization.data(withJSONObject: object)
        }
        func refused(_ name: String, json: Data, bin: Data) {
            do {
                _ = try PromptTable(json: json, bin: bin)
                print("FAIL \(name) — was accepted")
                failures += 1
            } catch {
                print("ok   \(name)")
            }
        }

        refused("a truncated float table is refused", json: jsonData, bin: binData.dropLast(4))
        refused("an empty float table is refused", json: jsonData, bin: Data())
        refused("a version from the future is refused",
                json: mutated(jsonData) { $0["version"] = 99 }, bin: binData)
        refused("a layout that names no neutral rows is refused",
                json: mutated(jsonData) { object in
                    var layout = object["layout"] as! [String: Any]
                    layout["neutral"] = [0, 0]
                    object["layout"] = layout
                }, bin: binData)
        refused("a layout section past the end of the table is refused",
                json: mutated(jsonData) { object in
                    var layout = object["layout"] as! [String: Any]
                    layout["nsfw"] = [0, 100_000]
                    object["layout"] = layout
                }, bin: binData)

        // --- 6. the private overlay, built here from the table's own rows -----
        //
        // Two rows as the NSFW pool, then a pair of one row each. Rows copied
        // from the table, so the arithmetic below has a known answer.
        let base = try! PromptTable(json: jsonData, bin: binData)
        let d = base.dim
        let src = [base.background.lowerBound, base.background.lowerBound + 1,
                   base.neutral.lowerBound, base.neutral.lowerBound + 1]
        var overlayFloats: [Float] = []
        for r in src { overlayFloats += base.matrix[(r * d)..<((r + 1) * d)] }
        let overlayBin = overlayFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let baseObject = (try! JSONSerialization.jsonObject(with: jsonData)) as! [String: Any]
        func overlayJSON(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
            var o: [String: Any] = [
                "version": 1, "dim": d, "rows": src.count,
                "layout": ["nsfw": [0, 2], "paired": [2, 4]],
                "tags": [] as [Any],
                "paired_tags": [["tag": "Dawn", "rows": [2, 3]], ["tag": "Dusk", "rows": [3, 4]]],
                "texts": ["n0", "n1", "dawn", "dusk"],
                "constants": baseObject["constants"]!,
                "engine_py_sha256": baseObject["engine_py_sha256"]!,
                "prompt_sha256": "overlay",
            ]
            change(&o)
            return try! JSONSerialization.data(withJSONObject: o)
        }
        do {
            let merged = try PromptTable(json: jsonData, bin: binData,
                                         overlay: (overlayJSON(), overlayBin))
            let n = base.rowCount
            check("the overlay's rows are appended after the table's",
                  merged.rowCount == n + 4 && merged.matrix.count == (n + 4) * d
                  && Array(merged.matrix[(n * d)..<((n + 1) * d)])
                      == Array(base.matrix[(src[0] * d)..<((src[0] + 1) * d)]))
            check("the overlay's NSFW pool replaces the table's, offset",
                  merged.nSFW == n..<(n + 2))
            check("the overlay's pair arrives offset, in its order",
                  merged.pairedTags.map(\.name) == ["Dawn", "Dusk"]
                  && merged.pairedTags.map(\.rows) == [(n + 2)..<(n + 3), (n + 3)..<(n + 4)])
            check("the public sections and tags are untouched",
                  merged.neutral == base.neutral && merged.background == base.background
                  && merged.tags == base.tags)
            check("an overlay makes an NSFW score where there was none (or keeps one)",
                  merged.nsfwScore(vector: vector) != nil)
            check("phrase texts stay aligned: table's, then the overlay's",
                  base.phrases.isEmpty || merged.phrases.suffix(4) == ["n0", "n1", "dawn", "dusk"])
            check("the paired tags compete in vocabSimilarities, after the tags",
                  merged.vocabSimilarities(vector: vector).map(\.tag).suffix(2) == ["Dawn", "Dusk"])
        } catch {
            print("FAIL a well-formed overlay was refused — \(error)")
            failures += 1
        }
        func overlayRefused(_ name: String, json: Data, bin: Data) {
            do {
                _ = try PromptTable(json: jsonData, bin: binData, overlay: (json, bin))
                print("FAIL \(name) — was accepted")
                failures += 1
            } catch {
                print("ok   \(name)")
            }
        }
        overlayRefused("a truncated overlay is refused", json: overlayJSON(), bin: overlayBin.dropLast(4))
        overlayRefused("an overlay of another width is refused",
                       json: overlayJSON { $0["dim"] = d / 2; $0["rows"] = 8 }, bin: overlayBin)
        overlayRefused("an overlay tag outside the overlay is refused",
                       json: overlayJSON { $0["paired_tags"] = [["tag": "Dawn", "rows": [3, 9]]] },
                       bin: overlayBin)
        // Spaces are only compared when both sides are bound to one.
        do {
            _ = try PromptTable(json: mutated(jsonData) { $0["space_digest"] = "this-one" },
                                bin: binData,
                                overlay: (overlayJSON { $0["space_digest"] = "not-this-one" }, overlayBin))
            print("FAIL an overlay from another embedding space is refused — was accepted")
            failures += 1
        } catch {
            print("ok   an overlay from another embedding space is refused")
        }
        refused("a tag whose rows fall outside the table is refused",
                json: mutated(jsonData) { $0["tags"] = [["tag": "Nonsense", "rows": [900, 901]]] },
                bin: binData)
        refused("a json that is not a table at all is refused",
                json: Data("{}".utf8), bin: binData)

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
