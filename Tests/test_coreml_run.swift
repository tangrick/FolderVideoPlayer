// The classify path through the real controller: `AnalysisEngine.run` with
// FVP_ENGINE=coreml, a real video, the real model and the real prompt table.
//
// This is the gate that matters for Task 2.5: the pieces can each pass their own
// tests while the branch is never actually taken, or is taken and still spawns a
// Python child. So this drives the same entry point the Classify button drives
// and checks the things a stranger's Mac depends on:
//
//   1. no model installed -> an honest broken state, naming what is missing,
//      and NOT a single python process or engine script on disk;
//   2. model installed    -> the row goes queued -> done with a verdict whose
//      provenance says which engine and classifier produced it;
//   3. the vectors it paid for are in the cache, under the new slug;
//   4. the store on disk agrees with the store in memory;
//   5. a finished row is never re-asked;
//   6. a missing Safe/NSFW model refuses by name, not with a number.
//
// `@main` rather than top-level code: this file compiles alongside the app's
// model layer, and only a file named main.swift may carry top-level statements.
//
// Run: Tests/run_coreml.sh

import Foundation
import Darwin
import AVFoundation
import CoreML

@main
struct CoreMLRunTest {
    @MainActor
    static func main() async throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }

        let args = CommandLine.arguments
        guard args.count >= 5 else {
            print("usage: coreml_run <model.mlpackage> <prompt-dir> <video> <nsfw.mlpackage>")
            exit(2)
        }
        let modelPath = args[1]
        let promptDir = args[2]
        let video = args[3]
        let nsfwPath = args[4]

        // Two constants that must not drift apart: the cache namespace the
        // encoder writes under, and the file the fitted heads are stored in.
        // This runner is the only place both files are compiled.
        check("the fitted heads use the same slug as the encoder",
              TrainedHeads.defaultSlug == VisionEmbedder.modelSlug)
        check("a fitted head file is named after that slug, under a profile",
              TrainedHeads.file(root: "/tmp/x")
                  .hasSuffix("/\(ProfileBundle.relativeDir(Paths.activeProfile))"
                             + "/\(ProfileBundle.headsRelative(VisionEmbedder.modelSlug, "_trained_heads.json"))"))

        // The switch the whole port hangs on. Set before anything reads it.
        setenv("FVP_ENGINE", "coreml", 1)

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-coreml-run-\(UUID().uuidString)"
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        // Redirect before the store or the engine is built: Paths is read at
        // first touch, and a test must never reach a real library.
        Paths.support = scratch

        check("FVP_ENGINE=coreml selects the Core ML engine",
              CoreMLClassifier.mode == .coreml)
        check("classify is unavailable with nothing installed",
              !AICapability.probe().works(.classify))

        // --- 1. nothing installed: honest failure, nothing spawned -----------
        let store = AnalysisStore()
        store.enqueue([video])
        check("the video is queued", store.analysis(for: video)?.phase == .queued)

        let engine = AnalysisEngine()
        await engine.run(store: store, paths: [video])

        var brokenText = ""
        if case .broken(let why) = engine.phase { brokenText = why }
        check("no model -> a broken state, not a silent no-op", !brokenText.isEmpty)
        check("the reason names what is missing (\(brokenText.prefix(60))…)",
              brokenText.lowercased().contains("not installed"))
        check("no python blocker is claimed under the Core ML engine",
              !(AICapability.probe().blockers[.classify] ?? []).contains(.noPython))
        check("the un-served row is still queued, not marked failed",
              store.analysis(for: video)?.phase == .queued)
        check("no child process exists", engine.debugIsRunning == false)
        check("no engine script was written (prepare() was skipped)",
              !fm.fileExists(atPath: (scratch as NSString).appendingPathComponent("engine/engine.py")))
        check("no engine log was opened",
              !fm.fileExists(atPath: (scratch as NSString).appendingPathComponent("engine/engine.log")))
        check("stderr was never collected", engine.debugStderr.isEmpty)

        // --- 2. install the two files, and the same engine recovers ----------
        let compiled: URL
        if modelPath.hasSuffix(".mlpackage") {
            compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
        } else {
            compiled = URL(fileURLWithPath: modelPath)
        }
        let dest = VisionEmbedder.modelURL(root: scratch)
        try fm.createDirectory(atPath: dest.deletingLastPathComponent().path,
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: compiled, to: dest)
        for name in ["siglip2_base_prompts.json", "siglip2_base_prompts.f32"] {
            try fm.copyItem(atPath: (promptDir as NSString).appendingPathComponent(name),
                            toPath: (scratch as NSString).appendingPathComponent("tags/\(name)"))
        }
        // The image model and the prompt table are not enough any more: the
        // verdict belongs to Falconsai, so the probe must say so by name rather
        // than let a run fail later with a different sentence.
        check("classify is still unavailable without the Safe/NSFW model",
              !AICapability.probe().works(.classify))
        check("the model that is missing is named",
              (AICapability.probe().blockers[.classify] ?? [])
                  .contains(.modelMissing("Safe / NSFW classifier")))

        // `install` owns the rename trap (compileModel names the output after
        // the package), so this also proves the app can find what it installed.
        try NSFWClassifier.install(package: URL(fileURLWithPath: nsfwPath), root: scratch)
        check("the Safe/NSFW model lands under the name the app reads",
              NSFWClassifier.isInstalled(root: scratch))
        check("classify works once all three files are there",
              AICapability.probe().works(.classify))

        await engine.run(store: store, paths: [video])
        check("still no child process — the whole run was in-process",
              engine.debugIsRunning == false)
        // A run that does not finish has to SAY why, or the next person reads
        // four bare FAILs with nothing to go on. Printed only when something is
        // wrong, so a good run stays quiet.
        if engine.phase != .idle || engine.doneCount != 1 || engine.failedCount != 0 {
            print("     run did not finish: phase=\(engine.phase.title) "
                  + "done=\(engine.doneCount) failed=\(engine.failedCount)")
            print("     status: \(engine.statusText)")
            if case .broken(let why) = engine.phase { print("     broken: \(why)") }
            if let row = store.analysis(for: video) { print("     row phase: \(row.phase)") }
        }
        check("the run finished cleanly", engine.phase == .idle)
        check("one video done, none failed", engine.doneCount == 1 && engine.failedCount == 0)
        check("the status line was cleared when the run ended",
              engine.statusText.isEmpty && engine.currentName == nil)

        let record = store.analysis(for: video)
        check("the row is done", record?.phase == .done)
        guard let record, let prediction = record.prediction else {
            print("FAIL no verdict was stored at all")
            print("\n\(failures + 1) FAILURES")
            exit(1)
        }

        check("the verdict names the embedding space AND the model that scored it",
              prediction.modelID == "siglip2-base"
              && prediction.classifier == NSFWClassifier.classifierID
              && prediction.aggregation == NSFWClassifier.aggregationID)
        check("the interim preview's provenance is not stored any more",
              prediction.classifier != CoreMLClassifier.previewClassifierID)
        check("the bar is the 0.5 the review window files Safe/NSFW at",
              prediction.threshold == 0.5)
        check("it is NOT labelled as the old engine's space",
              prediction.modelID != "openai/clip-vit-large-patch14")
        check("frames were scored", prediction.frames > 0
              && prediction.frames == record.frameScores.count)
        check("the score is a probability",
              prediction.score >= 0 && prediction.score <= 1)
        check("the video score is the best frame",
              prediction.score == (record.frameScores.map(\.score).max() ?? -1))
        check("framesAbove counts frames at or above the threshold",
              prediction.framesAbove == record.frameScores.filter { $0.score >= prediction.threshold }.count)
        check("classifiedAt is set", prediction.classifiedAt > 0)

        // --- 3. the vectors it paid for are on disk, under the new slug ------
        let cache = EmbeddingCache(root: (scratch as NSString).appendingPathComponent("frames"))
        check("every scored frame's vector is cached",
              cache.misses(in: record.frameScores.map(\.hash)).isEmpty)
        check("the old ViT-L/14 namespace was never touched",
              !fm.fileExists(atPath: (cache.root as NSString)
                  .appendingPathComponent("openai_clip-vit-large-patch14")))

        // --- 4. what the app would show the user -----------------------------
        let bucket = AnalysisStore.bucket(record: record)
        check("the record files itself the way the review window reads it",
              bucket == (prediction.score < 0.5 ? .safe : .nsfw))

        let onDisk: [String: VideoAnalysis] = JSONStore.load(Paths.analysisFile, fallback: [:])
        check("analysis.json holds the same verdict the memory store does",
              onDisk[Paths.tagKey(video)]?.prediction?.score == prediction.score
              && onDisk[Paths.tagKey(video)]?.phase == .done)

        // --- 5. a finished row is never re-asked -----------------------------
        await engine.run(store: store, paths: [video])
        check("a second run over a done row does nothing",
              engine.doneCount == 0 && engine.failedCount == 0)
        check("the stored verdict did not move",
              store.analysis(for: video)?.prediction?.score == prediction.score)

        // A stop with nothing running must stay a no-op rather than a state.
        engine.stop()
        check("stop() while idle changes nothing", engine.phase == .idle)

        // --- 7. suggestions, in-process (Phase 4's merge, wired) --------------
        // The arithmetic is gated separately — `run_tag_suggester.sh` checks the
        // four sources, the merge rules and the cap against engine.py's own
        // answers. What this checks is that the app takes this branch at all,
        // that it needs no Python to do it, and that what comes back is a
        // ranked, capped list from THIS space.
        let answer = await engine.suggestTags(for: video, paired: false)
        check("a suggestion request is answered in-process", answer != nil)
        check("no child process was started for it", engine.debugIsRunning == false)
        check("and no engine script was written for it",
              !fm.fileExists(atPath: (scratch as NSString).appendingPathComponent("engine/engine.py")))
        if let answer {
            check("the suggestion names the Core ML space", answer.model == "siglip2-base")
            check("it saw the same frames the verdict did",
                  answer.framesSeen == prediction.frames)
            // Faces are ported as of 6.2–6.4, so the claim is no longer "this
            // path has no embedder" — it is "no embedder is INSTALLED here".
            // `Paths.support` is the scratch dir, which has no
            // `tags/sface.mlmodelc` and no registry.
            //
            // The count is **0**, not nil, and that is the oracle's own answer:
            // `engine.py` starts at `faces_detected = 0` and reports it whether
            // the pass found nothing or could not run at all. Nil reaches the
            // store only from an engine that predates the field
            // (`event.value("faces_detected") as? Int`), which is what
            // `hasSuggestions` keys its one-time re-ask on. Inventing a nil here
            // to mean "not installed" would be a new claim, not parity.
            check("no face candidate comes from a machine with no face embedder",
                  answer.faceHashes.isEmpty
                      && !answer.tags.contains { $0.source == "face" }
                      && (answer.facesDetected ?? 0) == 0)
            let tags = answer.tags
            check("the list is capped at SUGGEST_MAX_TAGS", tags.count <= TagSuggester.maxTags)
            check("and ranked strongest first",
                  zip(tags, tags.dropFirst()).allSatisfy { $0.confidence >= $1.confidence })
            check("every candidate carries the frame count it was judged on",
                  tags.allSatisfy { $0.frames >= 1 })
            check("all zero-shot, since no library and no head were handed over",
                  tags.allSatisfy { $0.source == "zeroshot" })
            check("no tag appears twice", Set(tags.map(\.tag)).count == tags.count)
        }

        // Faces under Core ML are refused while their two packages are not
        // installed — and the ONNX files being present changes nothing, because
        // they are the *Python* engine's models and this mode never spawns a
        // child. Reporting "ready" off them would make a press fail, which is
        // the thing this mode exists to stop.
        //
        // Until 6.5 this asserted a reason containing "Phase 6" ("not ported to
        // Core ML yet"). That was true when it was written and is not now, so
        // the check follows the contract rather than the old wording: the
        // blocker must be the DOWNLOADABLE one, which is what puts an Install
        // button on the row instead of a pointer to a bundle nobody published.
        let modelsDir = (scratch as NSString).appendingPathComponent("models")
        try fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        for onnx in ["face_detection_yunet_2023mar.onnx", "face_recognition_sface_2021dec.onnx"] {
            fm.createFile(atPath: (modelsDir as NSString).appendingPathComponent(onnx),
                          contents: Data("x".utf8))
        }
        let faceBlockers = AICapability.probe().blockers[.faces] ?? []
        check("faces are refused under Core ML while their packages are absent",
              !AICapability.probe().works(.faces))
        check("and the reason names the face recognition download",
              faceBlockers.contains {
                  if case .modelMissing(let what) = $0 { return what.contains("face") }
                  return false
              })
        check("and the app can fix every face blocker itself, so the row installs",
              faceBlockers.allSatisfy(\.fixableInApp))

        // Nothing on the Python-only path may deploy the script or start a child
        // in this mode. FaceStore asks for people at launch and swallows the
        // answer, so before the guard it deployed engine.py into the library and
        // started python that was never given a single command.
        let deployed = (scratch as NSString).appendingPathComponent("engine/engine.py")
        var refused = false
        do { _ = try await engine.facePeople() } catch { refused = true }
        check("a Python-only command is refused in Core ML mode", refused)
        check("and no engine script was deployed for it", !fm.fileExists(atPath: deployed))

        // --- the engine default, and the file that opts OUT of it ------------
        //
        // Core ML is what a downloaded DMG runs, so it is the default: a
        // stranger gets the engine the app downloads models for without
        // configuring anything. The Python child is a development tool now, and
        // `mode=python` in ~/.fvp-engine is how a session asks for it — a file
        // Xcode cannot rewrite, unlike the scheme's environment variables, which
        // it silently reverted three times on 2026-09-12.
        check("a test binary ignores the dev override file",
              !DevOverride.inUse && DevOverride.support == nil)

        check("no environment and no override is Core ML",
              CoreMLClassifier.mode(environment: nil, override: [:]) == .coreml)
        check("mode=python selects the child",
              CoreMLClassifier.mode(environment: nil,
                                    override: ["mode": "python"]) == .python)
        check("mode=coreml is Core ML, with or without a support dir",
              CoreMLClassifier.mode(environment: nil,
                                    override: ["mode": "coreml"]) == .coreml
              && CoreMLClassifier.mode(environment: nil,
                                       override: ["mode": "coreml",
                                                  "support": "/tmp/x"]) == .coreml)
        check("a support dir alone does not change the engine",
              CoreMLClassifier.mode(environment: nil,
                                    override: ["support": "/tmp/x"]) == .coreml)
        check("an environment variable still wins over the file",
              CoreMLClassifier.mode(environment: "python",
                                    override: ["mode": "coreml",
                                               "support": "/tmp/x"]) == .python
              && CoreMLClassifier.mode(environment: "coreml",
                                       override: ["mode": "python"]) == .coreml)
        check("an empty environment variable falls through to the file",
              CoreMLClassifier.mode(environment: "",
                                    override: ["mode": "python"]) == .python)
        check("a value this build does not know falls to the default, not Python",
              CoreMLClassifier.mode(environment: "cloreml", override: [:]) == .coreml)

        // The window has to SAY which engine is running. Both look identical in
        // use, and Xcode drops the scheme's environment variables whenever it
        // rewrites the file, so a Core ML session can silently become a Python
        // one. The title is the only thing standing between that and a test
        // session spent on the wrong engine.
        let title = PlayerWindowTitle.windowTitle(playlistEmpty: true, sessionLabel: "x",
                                                  mode: CoreMLClassifier.mode,
                                                  support: Paths.support)
        check("the window title names the Core ML engine (\(title))",
              title.contains("Core ML"))
        check("...and the library it is pointed at",
              title.contains((Paths.support as NSString).lastPathComponent))
        check("Python mode carries no badge",
              PlayerWindowTitle.windowTitle(playlistEmpty: true, sessionLabel: "x",
                                            mode: .python, support: Paths.support)
              == "FolderVideoPlayer")

        // --- the library-tag payload (a bug that hid for 558 videos) ---------
        //
        // `prefix(n) as? [String]` ALWAYS fails — ArraySlice is not Array — so
        // every video was skipped, the payload was always empty, and the
        // `library` source (which suggests the user's OWN tags by look-alike)
        // never fired once. Nothing said anything; the chips just never came.
        // These checks exist so it cannot go quiet again.
        // The current video carries Studio, so Studio is excluded EVERYWHERE
        // (no point offering a tag the video already has) — which is why the
        // other videos here carry Iceland instead.
        let tagStore = ["v1": ["Studio"], "v2": ["Iceland"], "v3": ["Iceland"]]
        let tagPayload = LibraryTagPayload.build(
            current: "v1", tags: tagStore,
            frameHashes: { key in
                switch key {
                case "v2": return ["h1", "h2", "h3"]
                case "v3": return []              // tagged but never analysed
                default: return ["x"]
                }
            })
        check("a tagged, analysed video produces a payload", !tagPayload.isEmpty)
        check("...keyed by the tag the user applied",
              tagPayload["Iceland"]?["v2"] == ["h1", "h2", "h3"])
        check("...and excluding the video's OWN tags", tagPayload["Studio"] == nil)
        check("...and skipping videos with no cached frames",
              tagPayload["Iceland"]?["v3"] == nil)

        // The exact shape of the old bug: more frames than the cap must still
        // CONTRIBUTE (that is a slice) rather than drop the video.
        let long = LibraryTagPayload.build(
            current: "v1", tags: tagStore,
            frameHashes: { _ in (1...30).map { "h\($0)" } })
        check("a video with more frames than the cap still contributes",
              long["Iceland"]?["v2"]?.count == 10)
        check("...taking the first frames", long["Iceland"]?["v2"]?.first == "h1")

        let many = LibraryTagPayload.build(
            current: "v0",
            tags: Dictionary(uniqueKeysWithValues: (1...12).map { ("v\($0)", ["Tag"]) }),
            frameHashes: { _ in ["h"] })
        check("the per-tag video cap holds", many["Tag"]?.count == 8)
        check("nothing to send, nothing sent",
              LibraryTagPayload.build(current: "v1", tags: [:],
                                      frameHashes: { _ in ["h"] }).isEmpty)

        // --- "why did you suggest this?" -------------------------------------
        //
        // A chip carries no evidence: the store keeps a confidence and a frame
        // count and nothing else. The explanation is recomputed from the cached
        // vectors. The strongest possible check is a frame built FROM a phrase
        // in the table — it must come back naming that exact phrase, which also
        // proves the phrase texts really reached the app.
        if let explainTable = try? PromptTable(root: scratch),
           !explainTable.phrases.isEmpty,
           let wedding = explainTable.tags.first(where: { $0.name == "Wedding" }) {
            let row = wedding.rows.lowerBound
            let dim = explainTable.dim
            let rowVec = Array(explainTable.matrix[(row * dim)..<((row + 1) * dim)])
            // A frame built straight from a phrase row is NOT realistic: the
            // nearest neighbour of a text embedding is another text embedding
            // ("an ordinary moment" sits at 0.9852 from "a wedding ceremony"),
            // so a text frame barely clears the pool. Discovered here, worth
            // knowing: it is why the zero-shot bar is so easy in the first
            // place. To exercise the HIT path the frame has to be a real
            // direction, so remove the pool's own best direction and renormalise.
            let bgRow = explainTable.background.lowerBound
            let bgVec = Array(explainTable.matrix[(bgRow * dim)..<((bgRow + 1) * dim)])
            let along = zip(rowVec, bgVec).map(*).reduce(0, +)
            var orth = zip(rowVec, bgVec).map { $0 - along * $1 }
            let norm = sqrt(orth.map { $0 * $0 }.reduce(0, +))
            orth = orth.map { $0 / norm }
            let separating = SuggestionWhy.Frame(vector: orth, hash: "h1", at: 2.5)

            if let why = SuggestionWhy.explain(table: explainTable, tag: "Wedding",
                                               source: "zeroshot", frames: [separating]) {
                check("a suggestion names the phrase that won (\(why.winningPhrase ?? "-"))",
                      why.winningPhrase != nil
                      && explainTable.phrases[wedding.rows].contains(why.winningPhrase!))
                check("...names the bland phrase it beat", why.poolPhrase != nil)
                check("...reports the bar it had to clear",
                      abs(why.bar - Double(explainTable.constants.suggestMargin)) < 1e-6)
                check("...reports the one frame it saw", why.framesSeen == 1)
                check("...counts that frame as agreeing", why.framesAgreed == 1)
                check("...lists it with its hash and time",
                      why.hits.count == 1 && why.hits[0].hash == "h1"
                      && why.hits[0].at == 2.5)
                check("...and always keeps hits consistent with the count",
                      why.framesAgreed == why.hits.count)
                check("...with a headline naming the tag", why.headline.contains("Wedding"))
            } else {
                check("a zero-shot suggestion can be explained", false)
            }

            // The raw text frame: explained, but it does NOT agree — the bar is
            // only just missed because the nearest phrase to a phrase is another
            // phrase. Asserted so the day this changes, it is noticed.
            if let textWhy = SuggestionWhy.explain(table: explainTable, tag: "Wedding",
                                                   source: "zeroshot",
                                                   frames: [SuggestionWhy.Frame(
                                                       vector: rowVec, hash: "t1", at: 0)]) {
                check("a text-only frame explains itself but does not clear the bar",
                      textWhy.winningPhrase != nil
                      && textWhy.framesAgreed == textWhy.hits.count)
            }

            let lib = SuggestionWhy.explain(table: explainTable, tag: "Iceland",
                                            source: "library", frames: [separating],
                                            learnedFrom: ["a.mov", "b.mov"])
            check("a library suggestion reports the videos it learned from",
                  lib?.headline.contains("2 of your videos") == true)

            check("a person chip names the person",
                  SuggestionWhy.explain(table: explainTable, tag: "Bob Meyer", source: "face",
                                        frames: [separating], person: "Bob Meyer")?
                      .headline.contains("Bob Meyer") == true)

            check("a tag the table does not carry cannot be explained",
                  SuggestionWhy.explain(table: explainTable, tag: "NotATag",
                                        source: "zeroshot", frames: [separating]) == nil)
            check("no frames, no explanation",
                  SuggestionWhy.explain(table: explainTable, tag: "Wedding",
                                        source: "zeroshot", frames: []) == nil)
        }

        // A head fitted on THIS space must come back as a `trained` candidate:
        // it is the one source that needs a file on disk to be believed. The
        // weights are the video's own mean frame, so it has to fire on every
        // frame — a head that cannot fire proves nothing.
        let headsFile = TrainedHeads.file(root: scratch)
        try fm.createDirectory(atPath: (headsFile as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        let vectors = record.frameScores.compactMap { cache.read($0.hash) }
        check("every scored frame's vector is readable for the head",
              vectors.count == record.frameScores.count)
        var mean = [Double](repeating: 0, count: VisionEmbedder.dim)
        for v in vectors { for i in 0..<VisionEmbedder.dim { mean[i] += Double(v[i]) } }
        let w = mean.map { Float($0 / Double(max(vectors.count, 1))) }
        var writable = w
        let payload = writable.withUnsafeBytes { Data($0) }.base64EncodedString()
        let headsJSON = """
        {"version":1,"slug":"\(TrainedHeads.defaultSlug)","dim":\(VisionEmbedder.dim),\
        "tags":{"Kite":{"w":"\(payload)","b":6.0,"n":\(vectors.count)}}}
        """
        try Data(headsJSON.utf8).write(to: URL(fileURLWithPath: headsFile))
        let heads = TrainedHeads.load(root: scratch)
        check("the fitted head loads from the file the app writes",
              heads.tags["Kite"] != nil && heads.problem == nil)

        let second = await engine.suggestTags(for: video, paired: false)
        check("and it produces a trained candidate",
              (second?.tags ?? []).contains { $0.tag == "Kite" && $0.source == "trained" })

        // --- 6. the refusal a stranger sees before the model is downloaded ----
        // It has to name the model. "The engine is broken" is the class of
        // failure this app has already fixed once, and the downloader in Phase 5
        // will hit exactly this state.
        let installedModel = NSFWClassifier.modelURL(root: scratch)
        try fm.moveItem(at: installedModel,
                        to: URL(fileURLWithPath: scratch + "/falconsai_hidden"))
        do {
            _ = try NSFWClassifier(root: scratch)
            check("a missing Safe/NSFW model refuses", false)
        } catch {
            check("a missing Safe/NSFW model refuses by name",
                  "\(error)".lowercased().contains("not installed"))
        }

        let tagsOnlyClassifier = CoreMLClassifier(root: scratch)
        var tagsOnlyFrames = 0
        do {
            let tagsOnly = try await tagsOnlyClassifier.suggest(path: video, paired: false, faces: false)
            tagsOnlyFrames = tagsOnly.framesSeen
        } catch { print("  tags-only error: \(error)") }
        check("a cold tag-only installation produces suggestions without Falconsai", tagsOnlyFrames > 0)
        var tagsOnlyClassifyRefused = false
        do { _ = try await tagsOnlyClassifier.analyse(path: video) }
        catch { tagsOnlyClassifyRefused = "\(error)".lowercased().contains("not installed") }
        check("classification still requires Falconsai after a tags-only warm", tagsOnlyClassifyRefused)

        // A late load failure must not retain the earlier table/encoder.
        let partialLoad = CoreMLClassifier(root: scratch)
        var missingDependencyRefused = false
        do { _ = try await partialLoad.warm() }
        catch { missingDependencyRefused = true }
        check("a late missing dependency fails the initial model load", missingDependencyRefused)

        // --- 7. the look-alike search under the Core ML engine ----------------
        // It used to be the one AI command with no Core ML version: the button
        // went through prepare() and refused with "that still needs the Python
        // engine" — although `LookAlikes.rank` had answered the same question
        // in-process since Phase 3, and `run_look_alikes.sh` was already
        // checking it against engine.py's own `tag_candidates`. What was
        // missing was the wiring, so this is what this section checks: the
        // search answers with NO child process, over the cache this very run
        // just wrote.
        //
        // The fixture is built from the video's own frames, so the candidate
        // has to be FOUND rather than merely tolerated — and the CORPUS has to
        // be mostly unrelated videos. The margin is measured above the library
        // mean, so a pool that mostly points the same way as the tag flattens
        // the margin to zero: that is a property of the rule (a tag is only a
        // look if it stands out), and a fixture that ignores it tests nothing.
        //   - three tagged videos on the video's own direction -> the prototype;
        //   - one pool video on that direction -> must be offered;
        //   - twelve pool videos on unrelated directions -> must not be;
        //   - one pool video pointing backwards -> must not be;
        //   - one pool video with a hash and no cached frames -> counted unseen.
        func put(_ name: String, _ vector: [Float]) -> String {
            let hash = EmbeddingCache.frameHash(Data(name.utf8))
            let path = cache.path(for: hash)
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? vector.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: path))
            return hash
        }
        func corner(_ index: Int, _ seed: Int) -> [Float] {
            var v = [Float](repeating: 0, count: VisionEmbedder.dim)
            v[(index * 7 + seed) % VisionEmbedder.dim] = 1          // a direction of its own
            return v
        }
        let direction = vectors[0]
        var lookTagged: [String: [String]] = [:]
        for name in ["look_a", "look_b", "look_c"] {
            lookTagged[name] = [put(name + "_1", direction), put(name + "_2", direction)]
        }
        var lookPool: [String: [String]] = [
            "pool_near": [put("pool_near_1", direction)],
            "pool_backwards": [put("pool_back_1", direction.map { -$0 })],
            "pool_unseen": ["5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"],     // hash, no file
        ]
        for k in 0..<12 {
            lookPool["pool_other_\(k)"] = [put("pool_other_\(k)_1", corner(k, 0)),
                                           put("pool_other_\(k)_2", corner(k, 1))]
        }
        let lookup = try await engine.tagCandidates(tag: "Kite", tagged: lookTagged,
                                                   pool: lookPool, limit: 30)
        check("the look-alike search answers under the Core ML engine",
              lookup.candidates.contains { $0.key == "pool_near" })
        check("and it does not offer the unrelated videos",
              !lookup.candidates.contains { $0.key.hasPrefix("pool_other") })
        check("nor the video looking the other way",
              !lookup.candidates.contains { $0.key == "pool_backwards" })
        check("a pool video with nothing cached is counted, not scored",
              lookup.unseen == 1)
        check("no child process — the search was answered in-process",
              engine.debugIsRunning == false)
        let tooFew = try await engine.tagCandidates(tag: "Kite", tagged: ["look_a": lookTagged["look_a"]!],
                                                    pool: lookPool, limit: 30)
        check("one tagged video is refused in the engine's own words",
              tooFew.candidates.isEmpty
                  && (tooFew.reason ?? "").contains("need 2+ tagged videos"))

        // --- 7b. a record from another tower is not an analysed video ---------
        // The Kite symptom, measured on a real library: a tag with 36 tagged
        // videos reported "need 2+ tagged videos to form a prototype (have 1)".
        // Nothing was wrong with the tagging. 34 of the 36 carried frameScores
        // written by the PREVIOUS tower, and `frameScores[].hash` names a file
        // under `frames/<space>/` — so those hashes pointed into
        // `frames/mobileclip_s2/`, a directory the engine running now never
        // opens. It found one readable prototype and said so, accurately and
        // uselessly: "not enough tagged videos" to someone who tagged plenty,
        // with no path to fixing it, because the shortfall logic counted the
        // dead records as ready and never re-analysed them.
        //
        // The record already knew which space wrote it (`prediction.modelID`);
        // nothing read it. These three checks are that reading.
        var oldSpace = VideoAnalysis()
        oldSpace.phase = .done
        oldSpace.prediction = NsfwPrediction(score: 0.1, maxFrame: 0.1, meanFrame: 0.1,
                                             frames: 1, framesAbove: 0, threshold: 0.5,
                                             aggregation: "weighted_max_frac",
                                             modelID: "mobileclip-s2",
                                             classifier: "zeroshot-nsfw-v1",
                                             classifiedAt: 0)
        oldSpace.frameScores = [FrameScore(at: 0, score: 0.1, hash: "aa")]
        check("a record embedded by an earlier tower is not an analysed video",
              oldSpace.frameScores.isEmpty == false && oldSpace.isInCurrentSpace == false)
        var currentSpace = oldSpace
        currentSpace.prediction?.modelID = EmbeddingSpace.current
        check("a record embedded by the tower running now is readable",
              currentSpace.isInCurrentSpace)
        var noVerdict = VideoAnalysis()
        noVerdict.frameScores = [FrameScore(at: 0, score: 0.1, hash: "aa")]
        check("hashes with no verdict behind them are not readable either",
              noVerdict.isInCurrentSpace == false)
        // The branch that decides the WORDS. Calling a never-analysed video
        // "analysed with an earlier model" tells the user their work was thrown
        // away when it was never done — which is what the first version of this
        // note said, against a real library where 32 of Kite's 36 videos had no
        // verdict at all. `prediction` is what tells the two apart, so it is
        // pinned here rather than left to the wording to remember.
        check("a never-analysed record has no verdict to blame on an earlier model",
              noVerdict.prediction == nil && oldSpace.prediction != nil)

        // --- 8. training under the Core ML engine -----------------------------
        // The last command that refused: Train Tags / Train NSFW went through
        // prepare() and said "that still needs the Python engine" — although
        // LogisticTrainer.fitTags / fitNSFW and TrainedHeads.save had been
        // ported and gated since Phase 4, with no call site anywhere in the app.
        // So this is what this section checks: a fit that answers in-process,
        // out of the cache, and lands in the file the classifier reads back.
        //
        // Six videos on the tag's own direction and six on unrelated ones. The
        // hold-out rule is every fifth video, so a twelve-video fixture leaves
        // nine to learn from and three to be scored on — counted here, not
        // guessed at. Separable directions keep the numbers honest without
        // pinning a float that the next float32 tweak would break.
        check("the engine is idle before the fit", !engine.isBusy)
        var trainFrames: [String: [String]] = [:]
        var tagLabels: [String: Bool] = [:]
        var nsfwLabels: [String: Bool] = [:]
        for k in 0..<6 {
            let pos = "fvp_pos_\(k)"
            let neg = "fvp_neg_\(k)"
            trainFrames[pos] = [put("\(pos)_1", direction)]
            trainFrames[neg] = [put("\(neg)_1", corner(k, 3))]
            tagLabels[pos] = true
            tagLabels[neg] = false
            // "looks like this tag" and "is NSFW" are different questions; the
            // same twelve videos are a fixture for both.
            nsfwLabels[pos] = true
            nsfwLabels[neg] = false
        }
        let fits = try await engine.trainHeads(labels: ["FvpTrained": tagLabels],
                                               frameHashes: trainFrames)
        check("training answers under the Core ML engine",
              fits.count == 1 && (fits.first?.fitted ?? false))
        check("and reports the videos it learned from and held out",
              (fits.first?.videos ?? 0) == 12 && (fits.first?.heldOut ?? 0) == 3)
        check("no child process — the fit ran in-process", engine.debugIsRunning == false)
        let trained = TrainedHeads.load(root: scratch, slug: cache.slug)
        check("the fitted head is on disk where the classifier reads it back",
              trained.tags["FvpTrained"] != nil && trained.dim == VisionEmbedder.dim)

        // A tag with too few judgements is refused in the port's own words, and
        // nothing is written for it: a refused fit must never look like a fit.
        let tooFewFit = try await engine.trainHeads(
            labels: ["FvpTooFew": ["fvp_pos_0": true, "fvp_pos_1": true]],
            frameHashes: trainFrames)
        check("a tag with too few examples is refused by the trainer",
              tooFewFit.count == 1 && !(tooFewFit.first?.fitted ?? true)
                  && (tooFewFit.first?.reason ?? "").contains("need 4+ accepted"))
        check("and nothing was written for a refused fit",
              TrainedHeads.load(root: scratch, slug: cache.slug).tags["FvpTooFew"] == nil)

        // The Safe/NSFW head — and the merge: two fits, one file, neither one
        // erasing the other.
        let correction = try await engine.trainNsfw(labels: nsfwLabels,
                                                   frameHashes: trainFrames)
        check("the Safe/NSFW head fits in-process too", correction.fitted)
        let merged = TrainedHeads.load(root: scratch, slug: cache.slug)
        check("and lands in the file the classifier reads back", merged.nsfw != nil)
        check("training the second head did not erase the first",
              merged.tags["FvpTrained"] != nil)

        // Measure the actual shared classify -> suggest route, with real
        // installed models, rather than deriving savings from planned counts.
        try fm.moveItem(at: URL(fileURLWithPath: scratch + "/falconsai_hidden"), to: installedModel)
        let sharedClassifier = CoreMLClassifier(root: scratch)
        let beforeShared = SamplingPlan.lastCounters
        _ = try await sharedClassifier.analyse(path: video)
        let afterClassify = SamplingPlan.lastCounters
        _ = try await sharedClassifier.suggest(path: video, paired: false, faces: false)
        let afterSuggest = SamplingPlan.lastCounters
        let firstDecodes = afterClassify.framesDecoded - beforeShared.framesDecoded
        let secondDecodes = afterSuggest.framesDecoded - afterClassify.framesDecoded
        let reused = afterSuggest.memoHits - afterClassify.memoHits
        check("real classify pass records decoded frames", firstDecodes > 0)
        // The decode cap is the whole point of `maxAnalysisFrames`: decoding
        // was measured as the dominant cost of a pass, and a cap that the
        // sampler quietly ignored would leave the cost exactly where it was.
        check("a pass never decodes more than the analysis cap",
              firstDecodes <= CoreMLClassifier.maxAnalysisFrames)
        check("real suggestion pass reuses frames without another decode",
              secondDecodes == 0 && reused == firstDecodes)
        check("memo reuse also avoids PNG rehashing",
              afterSuggest.framesHashed == afterClassify.framesHashed)
        check("real cache hits are counted during reuse",
              afterSuggest.cacheHits - afterClassify.cacheHits == reused)
        print("MEASURE shared classify+suggest: first_decodes=\(firstDecodes), second_decodes=\(secondDecodes), reused=\(reused)")

        let changedSpace = ModelSpace(adapter: "siglip2-base-v1",
                                      digest: String(repeating: "f", count: 64), dim: 768)
        try JSONEncoder().encode(changedSpace).write(
            to: URL(fileURLWithPath: ModelSpace.digestFile(root: scratch)))
        var changedRefused = false
        do { _ = try await sharedClassifier.analyse(path: video) }
        catch CoreMLClassifier.ClassifierError.spaceMismatch { changedRefused = true }
        check("a loaded classifier refuses a replacement space until restart", changedRefused)

        var partialRetryRefused = false
        do { _ = try await partialLoad.warm() }
        catch CoreMLClassifier.ClassifierError.spaceMismatch { partialRetryRefused = true }
        check("retry after partial load validates the replacement instead of retaining old components",
              partialRetryRefused)

        // The marker checked against the REAL installed tower. Every guard
        // above compares one marker to another; this is the case none of them
        // can see — the marker stays put and the bytes underneath it change.
        try ModelSpace.write(adapter: "siglip2-base-v1", dim: VisionEmbedder.dim,
                             root: scratch, preprocess: ModelSpace.declaredPreprocess)
        let honestStart = Date()
        var honestWarmed = false
        do { honestWarmed = try await CoreMLClassifier(root: scratch).warm() } catch { honestWarmed = false }
        let honestCost = Date().timeIntervalSince(honestStart)
        check("a cold classifier warms when the marker matches the installed tower", honestWarmed)

        // Swap one byte of the real tower, same length, without re-stamping.
        let realTowerFile = ModelSpace.towerDirectory(root: scratch)
            .appendingPathComponent("model.mil")
        let realBytes = try Data(contentsOf: realTowerFile)
        var tampered = realBytes
        tampered[tampered.count - 1] = realBytes[realBytes.count - 1] ^ 0xFF
        try tampered.write(to: realTowerFile)
        var staleWhy = ""
        do { _ = try await CoreMLClassifier(root: scratch).warm() }
        catch CoreMLClassifier.ClassifierError.spaceMismatch(let why) { staleWhy = why }
        catch { staleWhy = "other: \(error)" }
        // The message matters: it must be the BYTE check refusing, not the
        // marker-to-marker guard that cannot see this case at all.
        check("a cold classifier refuses a tower swapped underneath its marker",
              staleWhy.contains("do not match the model the app recorded"))
        if !staleWhy.contains("do not match the model the app recorded") { print("  got: \(staleWhy)") }
        try realBytes.write(to: realTowerFile)
        print("MEASURE marker byte-check on the real tower: \(String(format: "%.2f", honestCost))s cold warm")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
