// Verifies PlayableCopy: the remux/transcode decision, the FFmpeg arguments,
// progress parsing, and — when FFmpeg is installed — a real remux of an H.264
// MKV and a real transcode of an MPEG-4 Part 2 AVI written beside the source,
// each checked playable by AVFoundation and dated like its source, plus a
// cancelled run leaving nothing behind. (Replacing the original — details
// moved, original to the Trash — is FileOps.replace, which reuses the move
// bookkeeping main.swift covers; its Trash half is not run here, because it
// would put test files in the real Trash.)

@testable import FVPModel
import AVFoundation
import Foundation

func check(_ name: String, _ cond: Bool) {
    print(cond ? "ok   \(name)" : "FAIL \(name)")
    if !cond { exit(1) }
}

// --- probe parsing ---------------------------------------------------------
let reply = """
{"streams":[{"codec_type":"video","codec_name":"mpeg4","height":480},
            {"codec_type":"audio","codec_name":"mp3"}],
 "format":{"duration":"12.500000"}}
""".data(using: .utf8)!
let probe = PlayableCopy.parseProbe(reply)
check("probe reads the video codec", probe?.video == "mpeg4")
check("probe reads the audio codec", probe?.audio == "mp3")
check("probe reads the duration", probe?.duration == 12.5)
check("probe reads the height", probe?.height == 480)
check("garbage is not a probe", PlayableCopy.parseProbe(Data("nope".utf8)) == nil)

// --- the plan ----------------------------------------------------------------
func p(_ v: String?, _ a: String?) -> PlayableCopy.Probe {
    .init(video: v, audio: a, duration: 10, height: 1080)
}
check("h264 + aac is a remux of both", PlayableCopy.plan(for: p("h264", "aac")) == .init(copyVideo: true, copyAudio: true))
check("hevc is a remux", PlayableCopy.plan(for: p("hevc", "eac3")).isRemux)
check("mpeg4 is a transcode", !PlayableCopy.plan(for: p("mpeg4", "mp3")).isRemux)
check("mp3 audio is copied", PlayableCopy.plan(for: p("mpeg4", "mp3")).copyAudio)
check("opus audio is converted", !PlayableCopy.plan(for: p("vp9", "opus")).copyAudio)
check("no audio needs no conversion", PlayableCopy.plan(for: p("wmv3", nil)).copyAudio)

let hevcArgs = PlayableCopy.arguments(source: "/in.mkv", output: "/out.mp4",
                                      plan: .init(copyVideo: true, copyAudio: true), probe: p("hevc", "aac"))
check("hevc is tagged hvc1", hevcArgs.contains("hvc1"))
check("a remux copies the video", hevcArgs.contains("copy") && !hevcArgs.contains("h264_videotoolbox"))
let encArgs = PlayableCopy.arguments(source: "/in.avi", output: "/out.mp4",
                                     plan: .init(copyVideo: false, copyAudio: false), probe: p("mpeg4", "wmav2"))
check("a transcode uses the hardware encoder", encArgs.contains("h264_videotoolbox"))
check("a transcode converts audio to aac", encArgs.contains("aac"))
check("the output is last", encArgs.last == "/out.mp4")
check("with no source figure, bitrate follows height",
      PlayableCopy.bitrate(forHeight: 480) == "2500k" && PlayableCopy.bitrate(forHeight: 2160) == "16000k")
check("a lean source is capped at 1.5x its own rate",
      PlayableCopy.bitrate(forHeight: 720, source: 1_880_332) == "2820k")
check("a rich source never exceeds the height's ceiling",
      PlayableCopy.bitrate(forHeight: 720, source: 20_000_000) == "5000k")
check("a tiny source figure keeps a floor",
      PlayableCopy.bitrate(forHeight: 1080, source: 50_000) == "500k")
let webmReply = """
{"streams":[{"codec_type":"video","codec_name":"vp9","height":720},{"codec_type":"audio","codec_name":"opus"}],
 "format":{"duration":"1530.173000","bit_rate":"1880332"}}
""".data(using: .utf8)!
check("a container without a stream rate falls back to the file's",
      PlayableCopy.parseProbe(webmReply)?.bitrate == 1_880_332)
let mp4Reply = """
{"streams":[{"codec_type":"video","codec_name":"mpeg4","height":480,"bit_rate":"900000"}],
 "format":{"duration":"10","bit_rate":"1100000"}}
""".data(using: .utf8)!
check("the video stream's own rate is preferred", PlayableCopy.parseProbe(mp4Reply)?.bitrate == 900_000)

// --- progress ----------------------------------------------------------------
check("out_time_us is microseconds", PlayableCopy.progressSeconds("out_time_us=2500000") == 2.5)
check("out_time_ms is microseconds too", PlayableCopy.progressSeconds("out_time_ms=1000000") == 1)
check("other lines are not progress", PlayableCopy.progressSeconds("frame=12") == nil)

// --- the partial file ---------------------------------------------------------
check("the partial is hidden beside the output",
      PlayableCopy.partialPath(for: "/v/clip.mp4") == "/v/.clip.mp4.partial")
check("the copy keeps the capture date", encArgs.contains("-map_metadata"))

let fm = FileManager.default
let scratch = NSTemporaryDirectory() + "fvp-playable-\(UUID().uuidString)"
try! fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: scratch) }

// --- the real thing ----------------------------------------------------------
guard let tools = PlayableCopy.findTools(bundle: Bundle(path: scratch)!) else {
    print("skip  no FFmpeg on this Mac — the real remux and transcode were not run")
    print("playable copy: all passed")
    exit(0)
}

func sh(_ args: [String]) async -> Int32 {
    (try? await PlayableCopy.run(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + args).status) ?? -1
}
func playable(_ url: URL) async -> (Bool, Double) {
    let asset = AVURLAsset(url: url)
    let ok = (try? await asset.load(.isPlayable)) ?? false
    let seconds = (try? await asset.load(.duration))?.seconds ?? 0
    return (ok, seconds)
}

let done = DispatchSemaphore(value: 0)
Task {
    let mkv = scratch + "/clip.mkv", avi = scratch + "/clip.avi", long = scratch + "/long.avi"
    let src = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25", "-f", "lavfi", "-i", "sine=frequency=440"]
    check("fixture: an H.264 MKV", await sh(src + ["-t", "2", "-c:v", "h264_videotoolbox", "-c:a", "aac", mkv]) == 0)
    check("fixture: an MPEG-4 AVI", await sh(src + ["-t", "2", "-c:v", "mpeg4", "-c:a", "mp2", avi]) == 0)
    check("fixture: a long AVI", await sh(src + ["-t", "600", "-c:v", "mpeg4", "-c:a", "mp2", long]) == 0)

    // Old dates on the sources, so "the copy keeps the file's dates" is a real test.
    let old = Date(timeIntervalSince1970: 1_500_000_000)
    for f in [mkv, avi] { try! fm.setAttributes([.modificationDate: old], ofItemAtPath: f) }

    let sawRemux = Flag(), sawTranscode = Flag()
    let mkvOut = scratch + "/clip-from-mkv.mp4", aviOut = scratch + "/clip-from-avi.mp4"
    try! await PlayableCopy.make(from: mkv, to: mkvOut, tools: tools) { if $0.remux { sawRemux.set() } }
    let (ok1, len1) = await playable(URL(fileURLWithPath: mkvOut))
    check("the MKV was remuxed, not re-encoded", sawRemux.value)
    check("the remuxed copy plays in AVFoundation", ok1)
    check("the remuxed copy is the full length", abs(len1 - 2) < 0.2)
    let mkvDate = (try? fm.attributesOfItem(atPath: mkvOut))?[.modificationDate] as? Date
    check("the copy keeps the source's file date", mkvDate.map { abs($0.timeIntervalSince(old)) < 2 } ?? false)
    check("the source is left where it was", fm.fileExists(atPath: mkv))

    try! await PlayableCopy.make(from: avi, to: aviOut, tools: tools) { if !$0.remux { sawTranscode.set() } }
    let (ok2, len2) = await playable(URL(fileURLWithPath: aviOut))
    check("the AVI was transcoded", sawTranscode.value)
    check("the transcoded copy plays in AVFoundation", ok2)
    check("the transcoded copy is the full length", abs(len2 - 2) < 0.2)

    var refused = false
    do { try await PlayableCopy.make(from: mkv, to: mkvOut, tools: tools) { _ in } } catch { refused = true }
    check("an existing file is never overwritten", refused)
    check("...and the refused run leaves no partial", !fm.fileExists(atPath: PlayableCopy.partialPath(for: mkvOut)))

    let longOut = scratch + "/long.mp4"
    let job = Task { try await PlayableCopy.make(from: long, to: longOut, tools: tools) { _ in } }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    job.cancel()
    let outcome = await job.result
    if case .failure = outcome { check("a cancelled run throws", true) } else { check("a cancelled run throws", false) }
    check("a cancelled run leaves no partial file", !fm.fileExists(atPath: PlayableCopy.partialPath(for: longOut)))
    check("a cancelled run writes no output", !fm.fileExists(atPath: longOut))
    done.signal()
}
done.wait()
print("playable copy: all passed")

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
