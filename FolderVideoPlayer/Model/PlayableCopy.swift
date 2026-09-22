import Foundation

/// A copy of a video that AVFoundation can play, made with FFmpeg when the
/// original cannot be.
///
/// Two ways, chosen per file from what ffprobe reports:
///   - REMUX: the video is already H.264 or HEVC, only the container (MKV, TS,
///     FLV, WebM…) is foreign. The streams are copied into an MP4 untouched —
///     seconds, not minutes, and no loss.
///   - TRANSCODE: the codec itself is foreign (DivX/Xvid, WMV, VP8/VP9,
///     RealVideo…). Re-encoded to H.264 on the hardware encoder.
/// Audio is copied when AVFoundation reads it and turned into AAC when not.
///
/// Only ever run after the user said yes (see `PlaybackController`). The copy
/// is written beside the original under a hidden temporary name, renamed only
/// when complete, and given the original's dates; replacing the original with
/// it — tags carried over, original to the Trash — is `FileOps.replace`.
enum PlayableCopy {

    // MARK: - the tool

    struct Tools: Equatable {
        let ffmpeg: String
        let ffprobe: String
    }

    /// A copy bundled inside the app wins; otherwise Homebrew's, on either
    /// architecture. Nil when there is no FFmpeg at all.
    static func findTools(bundle: Bundle = .main,
                          fallbacks: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> Tools? {
        var dirs: [String] = []
        if let resources = bundle.resourcePath { dirs.append(resources) }
        dirs += fallbacks
        let fm = FileManager.default
        for dir in dirs {
            let ffmpeg = (dir as NSString).appendingPathComponent("ffmpeg")
            let ffprobe = (dir as NSString).appendingPathComponent("ffprobe")
            if fm.isExecutableFile(atPath: ffmpeg), fm.isExecutableFile(atPath: ffprobe) {
                return Tools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }

    // MARK: - what the file holds

    struct Probe: Equatable {
        var video: String?
        var audio: String?
        var duration: Double
        var height: Int
        /// Bits per second of the source — the video stream's own figure when
        /// the container states one (MKV and WebM usually do not), otherwise
        /// the whole file's. 0 when neither is known.
        var bitrate: Int = 0
    }

    /// ffprobe's `-of json` reply, reduced to the first video and audio stream.
    static func parseProbe(_ data: Data) -> Probe? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let format = root["format"] as? [String: Any]
        let duration = Double(format?["duration"] as? String ?? "") ?? 0
        let bitrate = Int(video?["bit_rate"] as? String ?? "") ?? Int(format?["bit_rate"] as? String ?? "") ?? 0
        return Probe(video: video?["codec_name"] as? String,
                     audio: audio?["codec_name"] as? String,
                     duration: duration,
                     height: video?["height"] as? Int ?? 0,
                     bitrate: bitrate)
    }

    static let copyableVideo: Set<String> = ["h264", "hevc"]
    static let copyableAudio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]

    struct Plan: Equatable {
        var copyVideo: Bool
        var copyAudio: Bool
        /// A remux: nothing is re-encoded that the picture depends on.
        var isRemux: Bool { copyVideo }
    }

    static func plan(for probe: Probe) -> Plan {
        Plan(copyVideo: probe.video.map(copyableVideo.contains) ?? false,
             copyAudio: probe.audio.map(copyableAudio.contains) ?? true)
    }

    /// Enough bits that a re-encode does not look worse than the source did,
    /// and no more: the per-height ceiling, capped at 1.5× what the source
    /// itself spends (H.264 needs somewhat more than VP9 or HEVC for the same
    /// picture, not three times more). Measured 2026-09-22 on a 25-minute 720p
    /// VP9 WebM of 1.9 Mbps: the 5 Mbps ceiling made 987 MB, the 2.8 Mbps cap
    /// 567 MB, with the same SSIM against the source (0.893 vs 0.894) and 20%
    /// less time.
    static func bitrate(forHeight height: Int, source: Int = 0) -> String {
        let ceiling: Int
        switch height {
        case ..<1: ceiling = 8_000_000          // unknown: assume HD
        case ...480: ceiling = 2_500_000
        case ...720: ceiling = 5_000_000
        case ...1080: ceiling = 8_000_000
        default: ceiling = 16_000_000
        }
        // A floor, so a tiny or mis-stated source figure cannot starve it.
        let wanted = source > 0 ? max(source * 3 / 2, 500_000) : ceiling
        return "\(min(ceiling, wanted) / 1000)k"
    }

    static func arguments(source: String, output: String, plan: Plan, probe: Probe) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-i", source,
                    "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        if plan.copyVideo {
            args += ["-c:v", "copy"]
            // QuickTime only plays HEVC in MP4 under the hvc1 tag.
            if probe.video == "hevc" { args += ["-tag:v", "hvc1"] }
        } else {
            args += ["-c:v", "h264_videotoolbox", "-allow_sw", "1",
                     "-b:v", bitrate(forHeight: probe.height, source: probe.bitrate),
                     // H.264 wants even dimensions; odd-sized old clips exist.
                     "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p"]
        }
        args += plan.copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "160k"]
        // The capture date and the rest of the container's tags travel.
        args += ["-map_metadata", "0",
                 "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", "-f", "mp4", output]
        return args
    }

    /// Seconds of output written, from one line of `-progress` output.
    static func progressSeconds(_ line: String) -> Double? {
        for prefix in ["out_time_us=", "out_time_ms="] where line.hasPrefix(prefix) {
            // Both are microseconds, whatever the second one's name says.
            return Double(line.dropFirst(prefix.count)).map { $0 / 1_000_000 }
        }
        return nil
    }

    // MARK: - doing it

    enum Failure: Error, LocalizedError {
        case unreadable
        case notAVideo
        case ffmpeg(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "FFmpeg could not read it either"
            case .notAVideo: return "it has no video stream"
            case .ffmpeg(let why): return why
            }
        }
    }

    struct Progress: Equatable {
        var remux: Bool
        /// 0…1, nil until the length is known.
        var fraction: Double?
    }

    /// Where a copy is written while it is being made: hidden, beside the
    /// finished name, so a half-made file is never mistaken for a video.
    static func partialPath(for output: String) -> String {
        let folder = (output as NSString).deletingLastPathComponent
        return (folder as NSString).appendingPathComponent("." + (output as NSString).lastPathComponent + ".partial")
    }

    /// Write a playable copy of `source` at `output`. Cancelling the task stops
    /// FFmpeg and leaves nothing behind; `output` exists only once complete.
    static func make(from source: String, to output: String, tools: Tools,
                     onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        let probeData = try await run(tools.ffprobe,
                                      ["-v", "error", "-show_entries",
                                       "stream=codec_type,codec_name,height,bit_rate:format=duration,bit_rate",
                                       "-of", "json", source])
        guard let probe = parseProbe(probeData.output) else { throw Failure.unreadable }
        guard probe.video != nil else { throw Failure.notAVideo }
        let plan = plan(for: probe)
        onProgress(Progress(remux: plan.isRemux, fraction: probe.duration > 0 ? 0 : nil))

        let fm = FileManager.default
        let partial = partialPath(for: output)
        try? fm.removeItem(atPath: partial)
        do {
            let result = try await run(tools.ffmpeg,
                                       arguments(source: source, output: partial, plan: plan, probe: probe)) { line in
                guard probe.duration > 0, let done = progressSeconds(line) else { return }
                onProgress(Progress(remux: plan.isRemux, fraction: min(1, max(0, done / probe.duration))))
            }
            guard result.status == 0 else {
                let last = String(decoding: result.errors, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init) ?? "FFmpeg stopped (\(result.status))"
                throw Failure.ffmpeg(last)
            }
            guard !fm.fileExists(atPath: output) else {
                throw Failure.ffmpeg("“\((output as NSString).lastPathComponent)” appeared while converting")
            }
            try fm.moveItem(atPath: partial, toPath: output)
        } catch {
            try? fm.removeItem(atPath: partial)
            throw error
        }
        // The file's own dates too: the library sorts and dates by them.
        if let original = try? fm.attributesOfItem(atPath: source) {
            var dates: [FileAttributeKey: Any] = [:]
            dates[.creationDate] = original[.creationDate]
            dates[.modificationDate] = original[.modificationDate]
            try? fm.setAttributes(dates, ofItemAtPath: output)
        }
    }

    struct RunResult {
        var status: Int32
        var output: Data
        var errors: Data
    }

    /// Run a tool to the end, handing each stdout line to `onLine`. Task
    /// cancellation terminates the process.
    static func run(_ tool: String, _ args: [String],
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collected.appendOut(chunk)
            if let onLine {
                for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                    onLine(String(line))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.appendErr(chunk) }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Whatever arrived after the last handler call.
        collected.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        collected.appendErr(err.fileHandleForReading.readDataToEndOfFile())
        if Task.isCancelled { throw CancellationError() }
        return RunResult(status: status, output: collected.out, errors: collected.err)
    }

    /// The two pipes' bytes, gathered from their handler threads.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var o = Data(), e = Data()
        var out: Data { lock.lock(); defer { lock.unlock() }; return o }
        var err: Data { lock.lock(); defer { lock.unlock() }; return e }
        func appendOut(_ d: Data) { lock.lock(); o.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); e.append(d); lock.unlock() }
    }
}
