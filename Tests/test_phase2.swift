// Phase 2 integration test — the three new files, compiled standalone with
// CoreML/AVFoundation/Vision linked (as the app does), exercised against a
// real video.
//
//  1. sampler arithmetic parity with engine.py (short-clip clamp, cap)
//  2. FrameSampler on a real video: frame count == ffmpeg's, in order
//  3. VisionEmbedder on those frames: 768-dim (SigLIP 2), unit-normalised, cached and
//     identical on second pass
//  4. EmbeddingCache: layout, tmp+rename, corrupt-file-as-miss, slug isolation
//
// The verdict it checks is Falconsai's (Phase 4), so this path needs that model
// installed as well as the embedding one — the same three files the app reads.
//
// Run: Tests/run_phase2.sh <video>   (FVP_PHASE2_MODEL / FVP_NSFW_MODEL override)

@testable import FVPModel
import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print(cond ? "ok   \(name)" : "FAIL \(name)")
    if !cond { failures += 1 }
}

import AVFoundation
import CoreML

@main
struct Phase2Test {
    static func main() async throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("usage: phase2 <model> <video> [supportDir]")
        exit(2)
    }
    let modelPath = args[1]
    let videoPath = args[2]
    let support = args.count > 3 ? args[3]
        : NSTemporaryDirectory() + "fvp-phase2-\(UUID().uuidString)"
    let nsfwPath = args.count > 5 ? args[5]
        : (ProcessInfo.processInfo.environment["FVP_NSFW_MODEL"] ?? "")

    // Point Paths.support at scratch so the cache default() never touches a real
    // library, whatever the test does.
    Paths.support = support

    // --- 1. arithmetic parity ----------------------------------------------------
    check("clamp: 2 s clip -> 0.5 s interval",
          FrameSampler.clampInterval(duration: 2.1) == 2.1 / 4.0)
    check("clamp: 10 s clip -> 2.5 s interval",
          FrameSampler.clampInterval(duration: 10.0) == 10.0 / 4.0)
    check("clamp: 60 s video -> 5 s interval",
          FrameSampler.clampInterval(duration: 60.0) == 5.0)
    check("clamp: unknown duration -> 5 s interval",
          FrameSampler.clampInterval(duration: nil) == 5.0)
    check("clamp never below 0.2 s",
          FrameSampler.clampInterval(duration: 0.4) == 0.2)

    check("wanted: 12 s at 5 s -> [0,5,10]",
          FrameSampler.wantedTimes(duration: 12, interval: 5) == [0, 5, 10])
    check("wanted: 3 s at 0.5 s -> 6 entries",
          FrameSampler.wantedTimes(duration: 3, interval: 0.5).count == 6)

    let many = Array(stride(from: 0.0, to: 2000.0, by: 5.0))   // 400 entries
    let capped = FrameSampler.capped(many)
    // Engine arithmetic: step = ceil(400/250) = 2, so indices[::2] -> 200 kept.
    // The cap is a ceiling, not a target — parity with engine.py is the point.
    check("cap: 400 wanted -> 200 kept (engine parity)", capped.count == 200)
    check("cap: first kept", capped.first == many.first)
    check("cap: evenly spaced (step 2)",
          capped[1] == many[2] && capped[2] == many[4])
    check("cap: 251 wanted -> 126 kept (step 2)",
          FrameSampler.capped(Array(stride(from: 0.0, to: 1255.0, by: 5.0))).count == 126)
    check("cap: short list unchanged",
          FrameSampler.capped([1, 2, 3]) == [1, 2, 3])

    // --- 2. real video through FrameSampler --------------------------------------
    print("\nsampling \(URL(fileURLWithPath: videoPath).lastPathComponent) …")
    let frames: [FrameSampler.SampledFrame]
    do {
        frames = try await FrameSampler.sample(url: URL(fileURLWithPath: videoPath))
        print("got \(frames.count) frames")
    } catch {
        print("FAIL sampling threw: \(error)")
        exit(1)
    }
    check("sampler returned frames", !frames.isEmpty)
    check("frame indices are ordered", frames.map(\.index) == frames.map(\.index).sorted())

    let dur = try await AVURLAsset(url: URL(fileURLWithPath: videoPath)).load(.duration).seconds
    let expected = FrameSampler.capped(
        FrameSampler.wantedTimes(duration: dur, interval: FrameSampler.clampInterval(duration: dur))).count
    check("frame count matches the arithmetic (\(expected) wanted)", frames.count == expected)

    // --- 3. model: compile if needed, embed, cache round-trip ---------------------
    guard FileManager.default.fileExists(atPath: modelPath) else {
        print("SKIP model checks — no model at \(modelPath)")
        exit(failures == 0 ? 0 : 1)
    }
    let compiled: URL
    if modelPath.hasSuffix(".mlpackage") {
        compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
    } else {
        compiled = URL(fileURLWithPath: modelPath)
    }

    // Install where VisionEmbedder looks: <support>/tags/siglip2_base.mlmodelc
    let installRoot = support
    let dest = VisionEmbedder.modelURL(root: installRoot)
    try? FileManager.default.createDirectory(atPath: dest.deletingLastPathComponent().path,
                                             withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: compiled, to: dest)

    check("isInstalled sees the model", VisionEmbedder.isInstalled(root: installRoot))

    let embedder = try VisionEmbedder(root: installRoot)
    let t0 = Date()
    let vectors = try await embedder.embed(frames)
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "embedded %d frames in %.3f s (%.1f ms/frame)",
                 vectors.count, dt, dt / Double(max(vectors.count, 1)) * 1000))

    check("one vector per frame", vectors.count == frames.count)
    check("all \(VisionEmbedder.dim)-dim",
          vectors.allSatisfy { $0.vector.count == VisionEmbedder.dim })
    check("unit norm (±1e-4)",
          vectors.allSatisfy { abs(sqrt($0.vector.map { $0 * $0 }.reduce(0, +)) - 1) < 1e-4 })
    check("vectors differ across frames (not a constant output)",
          Set(vectors.map { $0.vector[0..<4].map { String($0) }.joined() }).count > 1)

    // cache round-trip: same frames again must come from disk, byte-identical
    let cache = EmbeddingCache.default()
    check("cache default root is under scratch support",
          cache.root.hasPrefix(support))
    let hashes = frames.map { EmbeddingCache.frameHash(of: $0.image) }
    for (i, h) in hashes.enumerated() { cache.write(h, vectors[i].vector) }
    check("misses() is empty after writing", cache.misses(in: hashes).isEmpty)
    let reread = hashes.map { cache.read($0) }
    check("read-back identical",
          reread.enumerated().allSatisfy { $0.element == vectors[$0.offset].vector })

    // corrupt file behaves as a miss
    let victim = hashes[0]
    let p = cache.path(for: victim)
    try! Data("garbage".utf8).write(to: URL(fileURLWithPath: p))
    check("corrupt file reads as nil", cache.read(victim) == nil)

    // wrong dim behaves as a miss: write a raw 511-float file under the right
    // name, the way a half-finished or foreign write would land.
    do {
        var raw = vectors[1].vector
        raw.removeLast()
        let p2 = cache.path(for: hashes[1])
        try? FileManager.default.createDirectory(atPath: (p2 as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        var fl = raw
        let d = fl.withUnsafeBytes { Data($0) }
        FileManager.default.createFile(atPath: p2, contents: d)
        check("wrong-dim file reads as nil", cache.read(hashes[1]) == nil)
    }

    // slug isolation: the old slug's dir must not exist in this scratch library
    check("old slug never written",
          !FileManager.default.fileExists(atPath: (cache.root as NSString)
              .appendingPathComponent("openai_clip-vit-large-patch14")))

    // --- 5. the classify path, end to end ---------------------------------------
    // Task 2.5's gate: one real video through sample -> embed (cache first) ->
    // score -> verdict, using the same three types the app's Core ML branch
    // calls, with the prompt table installed where the app looks for it.
    print("\nclassifying through Core ML …")
    check("the engine defaults to Core ML when FVP_ENGINE is unset",
          ProcessInfo.processInfo.environment["FVP_ENGINE"] == nil
          && CoreMLClassifier.mode == .coreml)

    let promptDir = args.count > 4 ? args[4]
        : (ProcessInfo.processInfo.environment["FVP_PROMPT_DIR"]
           ?? NSHomeDirectory() + "/fvp-coreml-models")
    check("the prompt table exists to install (\(promptDir))",
          FileManager.default.fileExists(atPath: promptDir + "/siglip2_base_prompts.json"))
    for name in ["siglip2_base_prompts.json", "siglip2_base_prompts.f32"] {
        try? FileManager.default.removeItem(atPath: (support as NSString)
            .appendingPathComponent("tags/\(name)"))
        try? FileManager.default.copyItem(atPath: (promptDir as NSString).appendingPathComponent(name),
                                         toPath: (support as NSString).appendingPathComponent("tags/\(name)"))
    }

    check("classifier.isInstalled sees model + table under one root",
          CoreMLClassifier.isInstalled(root: support))

    // Wipe the cache so the pass below is genuinely cold: section 3 already
    // wrote vectors for these same frames, and a "cold" pass that silently hit
    // the cache would prove nothing about embedding or about the second pass
    // being faster.
    try? FileManager.default.removeItem(atPath: cache.root)

    // The verdict belongs to the Safe/NSFW model, so the classify path needs it
    // installed — through the same `install` the app uses, so a destination the
    // probe would not find fails in this gate rather than in a user's run.
    if !nsfwPath.isEmpty {
        try NSFWClassifier.install(package: URL(fileURLWithPath: nsfwPath), root: support)
    }
    check("the Safe/NSFW model lands under the name the app reads",
          NSFWClassifier.isInstalled(root: support))

    let classifier = CoreMLClassifier(root: support)
    let t1 = Date()
    let verdict: CoreMLVerdict
    do {
        verdict = try await classifier.analyse(path: videoPath)
    } catch {
        print("FAIL classify threw: \(error)")
        exit(1)
    }
    let dt1 = Date().timeIntervalSince(t1)
    print(String(format: "classified in %.3f s -> score %.4f over %d frames",
                 dt1, verdict.prediction.score, verdict.prediction.frames))

    check("one record per scored frame", verdict.frames.count == verdict.prediction.frames)
    check("every sampled frame was scored", verdict.frames.count == frames.count)
    check("score is a probability", verdict.prediction.score >= 0 && verdict.prediction.score <= 1)
    check("threshold is the 0.5 bar the verdict is filed at",
          verdict.prediction.threshold == 0.5)
    check("aggregation is max, named",
          verdict.prediction.aggregation == NSFWClassifier.aggregationID)
    check("the record names the shipped classifier, not the interim preview",
          verdict.prediction.classifier == NSFWClassifier.classifierID
          && verdict.prediction.classifier != CoreMLClassifier.previewClassifierID
          && verdict.prediction.modelID == "siglip2-base"
          && verdict.prediction.modelID != "openai/clip-vit-large-patch14")
    check("framesAbove counts the frames at or above the threshold",
          verdict.prediction.framesAbove
          == verdict.frames.filter { $0.score >= verdict.prediction.threshold }.count)
    check("the video score is the best frame",
          verdict.prediction.score == (verdict.frames.map(\.score).max() ?? 0))
    check("meanFrame is the mean of the frame scores",
          abs(verdict.prediction.meanFrame
              - (verdict.frames.map(\.score).reduce(0, +) / Double(verdict.frames.count))) < 1e-3)
    check("scores are stored to 4 decimals, like the engine's",
          verdict.frames.allSatisfy { abs($0.score * 10000 - ($0.score * 10000).rounded()) < 1e-6 })
    check("every frame names its cached vector",
          verdict.frames.map(\.hash) == frames.prefix(verdict.frames.count).map {
              EmbeddingCache.frameHash(of: $0.image) })
    check("`at` is the frame's own second",
          verdict.frames.map(\.at) == frames.prefix(verdict.frames.count).map(\.time))
    check("every hash just written resolves in the cache",
          cache.misses(in: verdict.frames.map(\.hash)).isEmpty)
    check("the verdict's vectors live under the new slug only, never the old one",
          cache.slug == "siglip2_base"
          && verdict.frames.allSatisfy { FileManager.default.fileExists(atPath: cache.path(for: $0.hash)) })

    // Second pass: the cache must serve every frame and the verdict must not
    // move. (`classifiedAt` is the one field that must differ — a stored
    // verdict records when it was reached — so the comparison is field by
    // field rather than whole-record equality.)
    let t2 = Date()
    let again = try await classifier.analyse(path: videoPath)
    let dt2 = Date().timeIntervalSince(t2)
    print(String(format: "second pass (cache only) %.3f s vs %.3f s cold", dt2, dt1))
    check("second pass reaches the same score", again.prediction.score == verdict.prediction.score)
    check("second pass reaches the same frame statistics",
          again.prediction.maxFrame == verdict.prediction.maxFrame
          && again.prediction.meanFrame == verdict.prediction.meanFrame
          && again.prediction.frames == verdict.prediction.frames
          && again.prediction.framesAbove == verdict.prediction.framesAbove)
    check("second pass frame records identical", again.frames == verdict.frames)
    check("second pass is not slower than the cold one", dt2 <= dt1)

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
    exit(failures == 0 ? 0 : 1)

    }
}
