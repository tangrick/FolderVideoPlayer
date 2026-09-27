// Share and Prepare Video: the plan (which engine, what name, how big, what a
// package holds) always, and — when FFmpeg is on this Mac to make fixtures —
// real copies: remuxed, trimmed, re-encoded, from a format AVFoundation cannot
// read, cancelled, refused over an existing file, and packaged. Through all of
// it the original must stay byte-for-byte what it was.
//
// Run: Tests/run_share_prep.sh

@testable import FVPModel
import Foundation
import AVFoundation
import CryptoKit

@main
struct SharePrepTest {
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        // --- the plan ----------------------------------------------------------

        let hd = ShareSource(codec: "h264", height: 1080, duration: 100, bytes: 100_000_000, avReadable: true)
        let small = ShareSource(codec: "h264", height: 480, duration: 100, bytes: 20_000_000, avReadable: true)
        let prores = ShareSource(codec: "apch", height: 1080, duration: 100, bytes: 900_000_000, avReadable: true)
        let mkv = ShareSource(codec: "h264", height: 1080, duration: 100, bytes: 100_000_000, avReadable: false)
        let divx = ShareSource(codec: "mpeg4", height: 480, duration: 100, bytes: 50_000_000, avReadable: false)

        check("Original Quality of H.264 is a remux",
              SharePrep.engine(for: .original, source: hd, hasFFmpeg: false) == .avPassthrough)
        check("1080p of a 1080p H.264 is a remux",
              SharePrep.engine(for: .hd1080, source: hd, hasFFmpeg: false) == .avPassthrough)
        check("720p of a 1080p source re-encodes to 720",
              SharePrep.engine(for: .hd720, source: hd, hasFFmpeg: false)
                == .avTranscode(preset: "AVAssetExportPreset1280x720"))
        check("720p of a 480p source is already small enough: a remux",
              SharePrep.engine(for: .hd720, source: small, hasFFmpeg: false) == .avPassthrough)
        check("Smaller File always re-encodes",
              SharePrep.engine(for: .smaller, source: small, hasFFmpeg: true)
                == .avTranscode(preset: "AVAssetExportPreset960x540"))
        check("a codec phones do not play is re-encoded even at Original Quality",
              SharePrep.engine(for: .original, source: prores, hasFFmpeg: false)
                == .avTranscode(preset: "AVAssetExportPresetHighestQuality"))
        check("an MKV of H.264 is remuxed by FFmpeg",
              SharePrep.engine(for: .original, source: mkv, hasFFmpeg: true) == .ffmpeg(remux: true, height: nil))
        check("an MKV asked for 720p is scaled by FFmpeg",
              SharePrep.engine(for: .hd720, source: mkv, hasFFmpeg: true) == .ffmpeg(remux: false, height: 720))
        check("DivX at 480p asked for 720p is re-encoded but not upscaled",
              SharePrep.engine(for: .hd720, source: divx, hasFFmpeg: true) == .ffmpeg(remux: false, height: nil))
        if case .unavailable(let why) = SharePrep.engine(for: .original, source: mkv, hasFFmpeg: false) {
            check("without FFmpeg a foreign format says why", why.contains("FFmpeg"), why)
        } else {
            check("without FFmpeg a foreign format says why", false)
        }
        check("the codec name is compared in any case",
              SharePrep.engine(for: .original, source: ShareSource(codec: "HEVC", height: 2160, duration: 1,
                                                                    bytes: 1, avReadable: true),
                               hasFFmpeg: false) == .avPassthrough)

        let args = SharePrep.ffmpegArguments(source: "/in.mkv", output: "/out.mp4", preset: .hd720,
                                             remux: false, height: 720, trim: 10...25.5)
        check("a trimmed FFmpeg copy seeks before the input and runs for the range",
              args.firstIndex(of: "-ss")! < args.firstIndex(of: "-i")!
                && args[args.firstIndex(of: "-ss")! + 1] == "10.000"
                && args[args.firstIndex(of: "-t")! + 1] == "15.500", args.joined(separator: " "))
        check("a scaled FFmpeg copy keeps the width even", args.contains("scale=-2:720"))
        check("a remux copies both streams",
              SharePrep.ffmpegArguments(source: "/a", output: "/b", preset: .original, remux: true,
                                        height: nil, trim: nil).contains("copy"))

        check("names say what the copy is for",
              SharePrep.suggestedName(for: "/v/Birthday.MOV", preset: .hd720) == "Birthday (720p).mp4"
                && SharePrep.suggestedName(for: "/v/Birthday.mov", preset: .original, trimmed: true)
                    == "Birthday (clip).mp4")
        let taken: Set = ["clip.mp4", "clip 2.mp4"]
        check("a taken name becomes the next free one",
              SharePrep.uniqueName("clip.mp4") { taken.contains($0) } == "clip 3.mp4")
        check("a free name is kept", SharePrep.uniqueName("new.mp4") { taken.contains($0) } == "new.mp4")
        let entries = SharePrep.packageEntries(["/a/clip.mp4", "/b/clip.mp4", "/c/CLIP.mp4", "/a/clip.srt"])
        check("package entries with one name all go in, renamed",
              entries.map(\.name) == ["clip.mp4", "clip 2.mp4", "CLIP 3.mp4", "clip.srt"], "\(entries.map(\.name))")

        let remuxSize = SharePrep.estimatedBytes(engine: .avPassthrough, preset: .original, source: hd, trim: 0...50)
        check("a remux of half the video is about half its size", remuxSize == 50_000_000, "\(remuxSize ?? -1)")
        let smallSize = SharePrep.estimatedBytes(engine: .avTranscode(preset: "x"), preset: .smaller,
                                                 source: hd, trim: nil) ?? 0
        check("a Smaller File estimate is much smaller than the source",
              smallSize > 0 && smallSize < hd.bytes / 3, "\(smallSize)")
        check("no length, no estimate",
              SharePrep.estimatedBytes(engine: .avPassthrough, preset: .original,
                                       source: ShareSource(codec: nil, height: 0, duration: 0, bytes: 5,
                                                           avReadable: true), trim: nil) == nil)
        check("free space is judged with a margin",
              SharePrep.hasRoom(needed: 100_000_000, available: 200_000_000)
                && !SharePrep.hasRoom(needed: 100_000_000, available: 105_000_000))

        // --- real copies ---------------------------------------------------------

        guard let tools = PlayableCopy.findTools() else {
            print("skip real copies: FFmpeg is not installed, so there is nothing to make fixtures with")
            finish(failures)
        }
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "fvp-share-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let mp4 = dir + "/source.mp4", mkvFile = dir + "/source.mkv"
        for (out, extra) in [(mp4, [String]()), (mkvFile, ["-f", "matroska"])] {
            let made = try? await PlayableCopy.run(tools.ffmpeg,
                ["-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc=duration=6:size=1920x1080:rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-c:v", "libx264", "-g", "25",
                 "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"] + extra + [out])
            guard made?.status == 0 else {
                print("FAIL could not make the fixture \(out)")
                finish(failures + 1)
            }
        }
        func digest(_ path: String) -> String {
            SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
                .map { String(format: "%02x", $0) }.joined()
        }
        let before = digest(mp4), beforeMKV = digest(mkvFile)

        let source = await ShareExport.inspect(mp4, tools: tools)
        check("an MP4 is read by AVFoundation with its codec, height and length",
              source.avReadable && source.codec == "h264" && source.height == 1080
                && abs(source.duration - 6) < 0.2, "\(source)")
        let foreign = await ShareExport.inspect(mkvFile, tools: tools)
        check("an MKV is read by FFmpeg instead", !foreign.avReadable && foreign.codec == "h264"
                && foreign.height == 1080, "\(foreign)")

        func lengthOf(_ path: String) async -> Double {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard (try? await asset.load(.isPlayable)) == true else { return -1 }
            return (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? -1
        }
        func leftovers() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains(".partial") }
        }

        // Remux, whole.
        let whole = dir + "/whole.mp4"
        do {
            try await ShareExport.make(source: mp4, output: whole, preset: .original, engine: .avPassthrough,
                                       trim: nil, estimate: source.bytes) { _ in }
            check("a remuxed copy plays on its own", abs(await lengthOf(whole) - 6) < 0.2)
        } catch { check("a remuxed copy is made", false, "\(error)") }

        // Remux, trimmed.
        let clip = dir + "/clip.mp4"
        do {
            try await ShareExport.make(source: mp4, output: clip, preset: .original, engine: .avPassthrough,
                                       trim: 1...3, estimate: nil) { _ in }
            let length = await lengthOf(clip)
            check("a trimmed copy is about the range's length", length > 1.5 && length < 3, "\(length)")
        } catch { check("a trimmed copy is made", false, "\(error)") }

        // Re-encode to 720p, with progress.
        let small720 = dir + "/small.mp4"
        let seen = Seen()
        do {
            let engine = SharePrep.engine(for: .hd720, source: source, hasFFmpeg: true)
            try await ShareExport.make(source: mp4, output: small720, preset: .hd720, engine: engine,
                                       trim: nil, estimate: nil) { seen.add($0) }
            let copy = await ShareExport.inspect(small720, tools: tools)
            check("a 720p copy is 720 lines", copy.height == 720, "\(copy)")
            check("progress reached the end", seen.last == 1, "\(seen.values.suffix(3))")
        } catch { check("a 720p copy is made", false, "\(error)") }

        // FFmpeg, from what AVFoundation cannot read.
        let fromMKV = dir + "/from-mkv.mp4"
        do {
            let engine = SharePrep.engine(for: .original, source: foreign, hasFFmpeg: true)
            try await ShareExport.make(source: mkvFile, output: fromMKV, preset: .original, engine: engine,
                                       trim: nil, estimate: nil, tools: tools) { _ in }
            check("an MKV becomes an MP4 AVFoundation plays", abs(await lengthOf(fromMKV) - 6) < 0.3)
        } catch { check("an MKV copy is made", false, "\(error)") }

        // Collision.
        do {
            try await ShareExport.make(source: mp4, output: whole, preset: .original, engine: .avPassthrough,
                                       trim: nil, estimate: nil) { _ in }
            check("an existing file is not overwritten without asking", false)
        } catch {
            check("an existing file is not overwritten without asking",
                  (error as? ShareExport.Failure) == .destinationExists("whole.mp4"), "\(error)")
        }

        // Cancellation.
        let cancelled = dir + "/cancelled.mp4"
        let job = Task {
            try await ShareExport.make(source: mp4, output: cancelled, preset: .hd720,
                                       engine: .avTranscode(preset: "AVAssetExportPreset1280x720"),
                                       trim: nil, estimate: nil) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(50))
        job.cancel()
        let outcome = await job.result
        if case .failure = outcome {
            check("a cancelled copy leaves no file", !fm.fileExists(atPath: cancelled))
        } else {
            // The export may finish inside 50 ms on a fast Mac; then it must be whole.
            check("a copy that finished before the cancel is whole", abs(await lengthOf(cancelled) - 6) < 0.2)
        }
        check("no partial file is left behind", leftovers().isEmpty, "\(leftovers())")

        // Package.
        let srt = dir + "/source.srt"
        try? "1\n00:00:00,000 --> 00:00:01,000\nhello\n".write(toFile: srt, atomically: true, encoding: .utf8)
        try? fm.createDirectory(atPath: dir + "/other", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: whole, toPath: dir + "/other/whole.mp4")
        let package = dir + "/package.zip"
        do {
            try await ShareExport.zip([whole, dir + "/other/whole.mp4", srt], to: package)
            let listing = try await PlayableCopy.run("/usr/bin/unzip", ["-Z1", package])
            let names = String(decoding: listing.output, as: UTF8.self).split(separator: "\n").map(String.init)
            check("the package holds every file, same-named ones renamed",
                  names.sorted() == ["source.srt", "whole 2.mp4", "whole.mp4"], "\(names)")
            let test = try await PlayableCopy.run("/usr/bin/unzip", ["-tq", package])
            check("the package is a valid ZIP", test.status == 0,
                  String(decoding: test.output + test.errors, as: UTF8.self))
        } catch { check("a package is made", false, "\(error)") }
        do {
            try await ShareExport.zip([srt], to: package)
            check("an existing package is not overwritten without asking", false)
        } catch {
            check("an existing package is not overwritten without asking", error is ShareExport.Failure)
        }
        check("no partial package is left behind", leftovers().isEmpty, "\(leftovers())")

        check("the original MP4 is byte-for-byte unchanged", digest(mp4) == before)
        check("the original MKV is byte-for-byte unchanged", digest(mkvFile) == beforeMKV)

        finish(failures)
    }

    static func finish(_ failures: Int) -> Never {
        print(failures == 0 ? "\nall share checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [Double?] = []
        func add(_ v: Double?) { lock.lock(); values.append(v); lock.unlock() }
        var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last ?? nil }
    }
}
