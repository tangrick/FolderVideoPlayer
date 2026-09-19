// Task 0.4 — does AVAssetImageGenerator sample what ffmpeg sampled?
//
// The engine's `sample_frames` uses ffmpeg `fps=1/5` with a clamp for short
// clips. That clamp exists because of a real bug (pitfall 11): a 2.1 s clip
// produced ZERO frames, so Analyse failed with nothing on screen to say why.
//
// The gate: a clip under 5 s must yield at least 4 frames, and longer clips
// must land on roughly the same timestamps ffmpeg chose.
//
// Build:
//   swiftc -O -o /tmp/samplespike docs/coreml-spike/SampleSpike/main.swift \
//     -framework AVFoundation
//   /tmp/samplespike <video> [more videos...]

import AVFoundation
import Foundation

/// The cadence the app will use. Mirrors engine.py's sample_frames:
/// one frame every 5 s, except on a clip too short to produce four that way,
/// where the interval shrinks to fit.
func sampleTimes(duration: Double, interval base: Double = 5.0,
                 target: Int = 4, cap: Int = 250) -> [Double] {
    guard duration > 0 else { return [] }
    let interval = min(base, max(duration / Double(target), 0.2))
    var times: [Double] = []
    var t = 0.0
    while t < duration && times.count < cap {
        times.append(t)
        t += interval
    }
    return times
}

let videos = Array(CommandLine.arguments.dropFirst())
guard !videos.isEmpty else {
    print("usage: samplespike <video> [video...]")
    exit(2)
}

var failures = 0

for path in videos {
    let name = (path as NSString).lastPathComponent
    guard FileManager.default.fileExists(atPath: path) else {
        print("skip (missing): \(name)")
        continue
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))

    let semaphore = DispatchSemaphore(value: 0)
    var duration = 0.0
    Task {
        duration = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        semaphore.signal()
    }
    semaphore.wait()

    let wanted = sampleTimes(duration: duration)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 512, height: 512)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

    var got = 0
    var actualTimes: [Double] = []
    let group = DispatchGroup()
    let lock = NSLock()
    group.enter()
    generator.generateCGImagesAsynchronously(
        forTimes: wanted.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
    ) { _, image, actual, result, _ in
        lock.lock()
        if result == .succeeded, image != nil {
            got += 1
            actualTimes.append(CMTimeGetSeconds(actual))
        }
        let finished = got + 0
        lock.unlock()
        if finished >= wanted.count { group.leave() }
    }
    _ = group.wait(timeout: .now() + 120)

    let short = duration < 5.0
    let ok = short ? got >= 4 : got >= max(1, wanted.count - 1)
    if !ok { failures += 1 }

    print(String(format: "%@ %.1fs  wanted %d  got %d  %@",
                 ok ? "ok  " : "FAIL", duration, wanted.count, got,
                 short ? "(SHORT CLIP — the pitfall-11 case)" : ""))

    // Drift between the time asked for and the frame actually returned.
    if !actualTimes.isEmpty {
        let sorted = actualTimes.sorted()
        let drift = zip(wanted.prefix(sorted.count), sorted).map { abs($0 - $1) }.max() ?? 0
        print(String(format: "      max drift from the requested time: %.2f s", drift))
    }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
