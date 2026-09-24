// The sampling plan: source-revision binding, bounded streaming, counters,
// and the adaptive-vs-uniform comparison's honesty rules.
//
// The properties that matter:
//  - a plan is bound to the file it was built from: changed size or mtime
//    invalidates it, so cached vectors can never be served for a video that
//    is no longer the same bytes;
//  - the adaptive layout holds the SAME frame budget as uniform — a plan
//    that looks faster by holding fewer frames is not faster, it is
//    thinner — and falls back to the uniform layout when no cuts are found;
//  - the comparison never reports a saving by dropping coverage;
//  - counters do the ≥25% arithmetic honestly, including the probe cost.
//
// `@main` rather than top-level code: this file compiles alongside the
// app's model layer, and only a file literally named main.swift may carry
// top-level statements.
//
// Run: Tests/run_sampling_plan.sh

@testable import FVPModel
import Foundation
import CoreGraphics

@main
struct SamplingPlanTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-plan-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        // --- 1. source revision validation -----------------------------------
        let file = scratch + "/clip.mp4"
        try? Data("frame bytes would be here".utf8).write(to: URL(fileURLWithPath: file))
        guard let revision = SamplingPlan.revision(of: file) else {
            print("FAIL the revision of a real file could be read")
            exit(1)
        }
        check("a file's revision reads size and mtime", revision.size > 0)
        check("an unchanged file still matches its revision",
              revision.matches(file))
        // Change the bytes (and therefore the mtime): no longer the source.
        Thread.sleep(forTimeInterval: 0.01)
        try? Data("different bytes now".utf8).write(to: URL(fileURLWithPath: file))
        check("a changed file is refused by its old revision",
              !revision.matches(file))
        check("a missing file is refused by any revision",
              !revision.matches(scratch + "/absent.mp4"))

        // --- 2. plan building over the real arithmetic -----------------------
        // No video needed: the pure-arithmetic path (FrameSampler's functions)
        // decides the wanted list; the revision check needs only a real file.
        guard let uniform = SamplingPlan.build(path: file, duration: 120,
                                               strategy: .uniform) else {
            print("FAIL a uniform plan built over a real file")
            exit(1)
        }
        check("the uniform plan matches FrameSampler's own arithmetic",
              uniform.wanted == FrameSampler.capped(
                FrameSampler.wantedTimes(duration: 120,
                                         interval: FrameSampler.clampInterval(duration: 120)),
                maxFrames: FrameSampler.maxFrames))
        check("a plan carries the revision it was built from",
              uniform.sourceRevision == SamplingPlan.revision(of: file))
        check("an unreadable duration plans nothing",
              SamplingPlan.build(path: file, duration: 0) == nil
                && SamplingPlan.build(path: file, duration: .nan) == nil)
        check("a missing file plans nothing",
              SamplingPlan.build(path: scratch + "/absent.mp4", duration: 60) == nil)

        // --- 3. the adaptive layout keeps the budget and its fallback --------
        // Without a probe source, adaptive falls back to uniform — stated,
        // not faked: no cuts found means no reason to move anything.
        let adaptive = SamplingPlan.build(path: file, duration: 120, strategy: .adaptive)
        check("with no probe source the adaptive layout falls back to uniform",
              adaptive?.wanted == uniform.wanted)

        // The pure arithmetic, driven directly: same budget, cut-directed
        // middle, head/tail grid kept.
        let long = SamplingPlan.adaptiveWanted(duration: 600, interval: 5.0,
                                               maxFrames: 250)
        let uniformLong = FrameSampler.capped(
            FrameSampler.wantedTimes(duration: 600, interval: 5.0), maxFrames: 250)
        check("the adaptive layout holds the SAME frame budget as uniform (no probe source)",
              long.count == uniformLong.count)
        check("the head and tail of the grid survive the release",
              long.prefix(uniformLong.count / 4) == uniformLong.prefix(uniformLong.count / 4)
                && long.suffix(uniformLong.count / 4) == uniformLong.suffix(uniformLong.count / 4))
        // Deterministic: same inputs, same plan.
        check("the adaptive layout is deterministic",
              long == SamplingPlan.adaptiveWanted(duration: 600, interval: 5.0, maxFrames: 250))

        // Cut threshold: survives one outlier flash.
        let plain = Array(repeating: 0.1, count: 50)
        let withFlash = plain + [0.9]
        check("a single outlier does not move the cut threshold",
              SamplingPlan.cutThreshold(plain) == SamplingPlan.cutThreshold(withFlash))
        check("a series too short to read declares no cuts",
              SamplingPlan.cutThreshold([0.1, 0.2]) == .infinity)

        // --- 4. counters and the savings arithmetic --------------------------
        var shared = SamplingPlan.Counters()
        shared.framesDecoded = 100            // one shared pass over 100 frames
        var separate = SamplingPlan.Counters()
        separate.framesDecoded = 300          // three passes over the same 100
        check("the shared saving is measured against the separate total",
              SamplingPlan.Counters.sharedSaving(shared: shared, separate: separate)
                == 66.66666666666666 as Double? || abs((SamplingPlan.Counters.sharedSaving(
                    shared: shared, separate: separate) ?? 0) - 200.0 / 3.0) < 0.01)
        // The probe cost counts: adaptive's scan is decode work too.
        var adaptiveCounters = SamplingPlan.Counters()
        adaptiveCounters.framesDecoded = 100
        adaptiveCounters.probesDecoded = 96
        check("probes count as decode work in the denominator",
              adaptiveCounters.decodedTotal == 196)
        check("no separate work measured means no saving claimed",
              SamplingPlan.Counters.sharedSaving(shared: shared,
                                                 separate: SamplingPlan.Counters()) == nil)

        // --- 5. the comparison harness on a real clip, when one exists -------
        // Locate a real video the way run_coreml.sh does; none here, the
        // harness's honesty rules are still checked on its arithmetic guard.
        var clip: String?
        for candidate in [ProcessInfo.processInfo.environment["FVP_TEST_VIDEO"],
                          "\(NSHomeDirectory())/Downloads/X Videos/GjgTjtwGsxRqq0_J.mp4"] {
            if let c = candidate, fm.isReadableFile(atPath: c) { clip = c; break }
        }
        if let clip, let duration = try? await AVURLAsset(url: URL(fileURLWithPath: clip))
            .load(.duration).seconds, duration > 0 {
            // With a probe source, adaptive really scans and really picks.
            SamplingPlan.probeURL = URL(fileURLWithPath: clip)
            defer { SamplingPlan.probeURL = nil }
            guard let result = SamplingComparison.run(path: clip, duration: duration) else {
                print("FAIL the comparison ran over a real clip")
                exit(1)
            }
            check("the comparison holds both plans to the same frame budget",
                  result.adaptiveFrames == result.uniformFrames)
            check("a comparison that drops coverage is not reported as a saving",
                  result.coverageOfUniform > 0.99 || (result.savings ?? 0) <= 0)
            print("· measured on \(result.uniformFrames) frames: adaptive decodes \(result.adaptiveDecodes), uniform \(result.uniformDecodes), coverage \(String(format: "%.2f", result.coverageOfUniform))")
        } else {
            check("the comparison needs a real clip and refuses otherwise",
                  SamplingComparison.run(path: scratch + "/absent.mp4", duration: 60) == nil)
        }

        // --- 6. the bounded frame memo ---------------------------------------
        // Self-contained: its own file, its own revision reads. A stand-in
        // frame type, because the memo is generic and only tracks bytes.
        struct StubFrame { let width: Int; let height: Int; let tag: Int }
        let memoFile = scratch + "/memo.mp4"
        try? Data("memo source bytes".utf8).write(to: URL(fileURLWithPath: memoFile))
        guard let memoRevision = SamplingPlan.revision(of: memoFile) else {
            print("FAIL the memo fixture's revision could be read")
            exit(1)
        }
        var memo = SamplingPlan.FrameMemo<StubFrame>(budgetBytes: 4096)
        let framesA = (0..<4).map { StubFrame(width: 16, height: 16, tag: $0) }
        let bytesA = SamplingPlan.FrameMemo<StubFrame>.bytes(in: framesA.map { ($0.width, $0.height) })
        // Entries are keyed by the REAL file path — the hit re-validates
        // against the disk, exactly as the classifier's memo does.
        memo.store(path: memoFile, revision: memoRevision, frames: framesA, bytes: bytesA)
        check("a memoized video is served while its bytes match",
              memo.frames(for: memoFile)?.count == 4)
        // The file changed: the hit re-validates and refuses to serve.
        Thread.sleep(forTimeInterval: 0.02)
        try? Data("changed bytes".utf8).write(to: URL(fileURLWithPath: memoFile))
        check("a memo hit re-validates the file's identity",
              memo.frames(for: memoFile) == nil)
        // A fresh identity, then prove the bound: a clip too big to fit
        // memoizes NOTHING rather than growing the bound.
        Thread.sleep(forTimeInterval: 0.02)
        try? Data("third content".utf8).write(to: URL(fileURLWithPath: memoFile))
        let bigRevision = SamplingPlan.revision(of: memoFile)!
        let big = (0..<400).map { StubFrame(width: 32, height: 32, tag: $0) }   // 400*32*32*4 > 4096
        let bytesBig = SamplingPlan.FrameMemo<StubFrame>.bytes(in: big.map { ($0.width, $0.height) })
        memo.store(path: "/v/two.mp4", revision: bigRevision, frames: big, bytes: bytesBig)
        check("a clip over the budget memoizes nothing (the bound wins)",
              memo.frames(for: "/v/two.mp4") == nil)
        check("...and evicts what was held for it",
              memo.entry == nil)
        // The next video replaces the previous one: one video's frames, ever.
        let framesB = (0..<2).map { StubFrame(width: 16, height: 16, tag: 100 + $0) }
        memo.store(path: memoFile, revision: bigRevision, frames: framesB,
                   bytes: SamplingPlan.FrameMemo<StubFrame>.bytes(in: framesB.map { ($0.width, $0.height) }))
        check("the next store replaces the memoized frames",
              memo.frames(for: memoFile)?.count == 2
                && memo.frames(for: memoFile)?.first?.tag == 100)
        check("a different path is a miss, not a serve",
              memo.frames(for: scratch + "/other.mp4") == nil)

        print(failures == 0 ? "\nALL PASS sampling plan" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}

import AVFoundation
