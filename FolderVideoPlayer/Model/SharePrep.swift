import Foundation

/// Deciding how to make a copy of a video for sharing — which engine, which
/// size, what it is called, roughly how big it will be — without touching a
/// file. The doing is `ShareExport`; keeping the decisions pure is what lets
/// every preset, name and package be tested without encoding anything.
///
/// The rule the whole feature keeps: **the original is never altered.** Every
/// copy is a new file, and every decision here is about that new file.

/// What the copy is for.
enum SharePreset: String, CaseIterable, Identifiable {
    /// Same picture, a container everything opens — remuxed when the streams
    /// allow it, so nothing is re-encoded.
    case original
    case hd1080
    case hd720
    /// Small enough to send: 540 lines, a modest bitrate.
    case smaller

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original Quality"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .smaller: return "Smaller File"
        }
    }

    var detail: String {
        switch self {
        case .original: return "The same picture in an MP4 that most apps and phones open."
        case .hd1080: return "Full HD. Larger videos are scaled down; smaller ones are left as they are."
        case .hd720: return "HD, about half the size of 1080p."
        case .smaller: return "540 lines at a modest bitrate — for messages and email."
        }
    }

    /// The tallest picture this preset makes. Nil keeps the source's.
    var maxHeight: Int? {
        switch self {
        case .original: return nil
        case .hd1080: return 1080
        case .hd720: return 720
        case .smaller: return 540
        }
    }

    /// What goes in the file name, so several copies of one video can sit in
    /// one folder and be told apart.
    var nameSuffix: String {
        switch self {
        case .original: return ""
        case .hd1080: return " (1080p)"
        case .hd720: return " (720p)"
        case .smaller: return " (small)"
        }
    }

    /// Video bits per second a re-encode at this preset spends — used for the
    /// estimate and for FFmpeg; AVFoundation's presets choose their own.
    var videoBitrate: Int {
        switch self {
        case .original: return 10_000_000
        case .hd1080: return 8_000_000
        case .hd720: return 5_000_000
        case .smaller: return 1_500_000
        }
    }
}

/// What the source is, as far as the plan needs to know. Filled by
/// `ShareExport.inspect` (AVFoundation, and FFmpeg's probe when AVFoundation
/// cannot read the file).
struct ShareSource: Equatable {
    var codec: String?
    var height: Int
    var duration: Double
    var bytes: Int64
    /// AVFoundation can open it — `.mp4`, `.mov`, `.m4v` and what they hold.
    var avReadable: Bool
}

/// How one copy will be made.
enum ShareEngine: Equatable {
    /// AVFoundation copies the streams into a new MP4: seconds, no loss.
    case avPassthrough
    /// AVFoundation re-encodes with one of its export presets.
    case avTranscode(preset: String)
    /// FFmpeg, for what AVFoundation cannot read. `height` is the scale target
    /// when the picture must shrink; nil keeps it.
    case ffmpeg(remux: Bool, height: Int?)
    /// No way to make this copy on this Mac, and why.
    case unavailable(String)

    var isRemux: Bool {
        switch self {
        case .avPassthrough: return true
        case .ffmpeg(let remux, _): return remux
        default: return false
        }
    }

    /// A sentence for the window: what will happen, in plain words.
    var summary: String {
        switch self {
        case .avPassthrough, .ffmpeg(true, _):
            return "Copied without re-encoding — fast, and the picture is untouched."
        case .avTranscode, .ffmpeg(false, _):
            return "Re-encoded as H.264. This takes a while for a long video."
        case .unavailable(let why):
            return why
        }
    }
}

enum SharePrep {

    static let copyableCodecs: Set<String> = ["h264", "avc1", "hevc", "hvc1", "hev1"]

    /// Which engine makes `preset` from `source`.
    ///
    /// Remuxing wins whenever it satisfies the preset: the codec is one every
    /// device plays and the picture is no taller than the preset allows (a
    /// 720p source asked for 1080p is already 1080p-or-smaller). "Smaller File"
    /// always re-encodes — its point is fewer bytes, which a remux never makes.
    static func engine(for preset: SharePreset, source: ShareSource, hasFFmpeg: Bool) -> ShareEngine {
        let copyable = source.codec.map { copyableCodecs.contains($0.lowercased()) } ?? false
        let fits: Bool
        if let limit = preset.maxHeight {
            fits = source.height > 0 && source.height <= limit
        } else {
            fits = true
        }
        let remux = copyable && fits && preset != .smaller
        let shrinkTo = preset.maxHeight.flatMap { limit in source.height == 0 || source.height > limit ? limit : nil }

        if source.avReadable {
            if remux { return .avPassthrough }
            switch preset {
            case .original: return .avTranscode(preset: "AVAssetExportPresetHighestQuality")
            case .hd1080: return .avTranscode(preset: "AVAssetExportPreset1920x1080")
            case .hd720: return .avTranscode(preset: "AVAssetExportPreset1280x720")
            case .smaller: return .avTranscode(preset: "AVAssetExportPreset960x540")
            }
        }
        guard hasFFmpeg else {
            return .unavailable("This file's format needs FFmpeg to make a copy, and it is not installed "
                                + "(Homebrew: brew install ffmpeg). Share Original still works.")
        }
        return .ffmpeg(remux: remux, height: remux ? nil : shrinkTo)
    }

    /// FFmpeg's arguments for a share copy — the FFmpeg half of `engine`.
    /// `-ss` before the input seeks fast; a remuxed cut therefore starts at the
    /// keyframe before the chosen time, which the window says.
    static func ffmpegArguments(source: String, output: String, preset: SharePreset,
                                remux: Bool, height: Int?, trim: ClosedRange<Double>?) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y"]
        if let trim {
            args += ["-ss", seconds(trim.lowerBound)]
        }
        args += ["-i", source]
        if let trim {
            args += ["-t", seconds(trim.upperBound - trim.lowerBound)]
        }
        args += ["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        if remux {
            args += ["-c:v", "copy", "-c:a", "copy"]
        } else {
            let scale = height.map { "scale=-2:\($0)" } ?? "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            args += ["-c:v", "h264_videotoolbox", "-allow_sw", "1",
                     "-b:v", "\(preset.videoBitrate / 1000)k", "-vf", scale, "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", preset == .smaller ? "96k" : "160k"]
        }
        args += ["-map_metadata", "0", "-movflags", "+faststart",
                 "-progress", "pipe:1", "-nostats", "-f", "mp4", output]
        return args
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", max(0, value)) }

    // MARK: - names

    /// The name offered for a copy: the video's own, what it is for, and
    /// " (clip)" when it is a trimmed range. Always `.mp4`: every engine here
    /// writes MP4.
    static func suggestedName(for source: String, preset: SharePreset, trimmed: Bool = false) -> String {
        let base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        return (base.isEmpty ? "Video" : base) + preset.nameSuffix + (trimmed ? " (clip)" : "") + ".mp4"
    }

    /// `name` if nothing in the folder is called that, otherwise "name 2",
    /// "name 3"… — the way Finder names a copy. Never overwrites, because it
    /// never returns a name `exists` says is taken.
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// The files of a ZIP package and the name each has inside it. Two videos
    /// called `clip.mp4` from different folders become `clip.mp4` and
    /// `clip 2.mp4`; names are compared case-insensitively, because a Mac's
    /// disk (and most unzippers) would put them in the same place.
    static func packageEntries(_ files: [String]) -> [(source: String, name: String)] {
        var taken = Set<String>()
        return files.map { file in
            let name = uniqueName((file as NSString).lastPathComponent) { taken.contains($0.lowercased()) }
            taken.insert(name.lowercased())
            return (file, name)
        }
    }

    // MARK: - estimates

    /// Roughly how many bytes the copy will be — shown as an estimate, never as
    /// a promise. A remux is the source's share of its own size; a re-encode is
    /// the preset's bitrate over the length.
    static func estimatedBytes(engine: ShareEngine, preset: SharePreset, source: ShareSource,
                               trim: ClosedRange<Double>?) -> Int64? {
        guard source.duration > 0 else { return nil }
        let length = trim.map { max(0, min($0.upperBound, source.duration) - $0.lowerBound) } ?? source.duration
        let fraction = length / source.duration
        switch engine {
        case .unavailable:
            return nil
        case .avPassthrough, .ffmpeg(true, _):
            return Int64(Double(source.bytes) * fraction)
        case .avTranscode, .ffmpeg(false, _):
            let audio = preset == .smaller ? 96_000 : 160_000
            let sourceRate = Double(source.bytes) * 8 / source.duration
            // A re-encode does not usefully spend more than the source did.
            let video = min(Double(preset.videoBitrate), max(sourceRate, 500_000))
            return Int64((video + Double(audio)) / 8 * length)
        }
    }

    /// Enough free space for `needed`, with a margin — a disk filled to the
    /// last byte fails the export and everything else on the Mac with it.
    static func hasRoom(needed: Int64, available: Int64) -> Bool {
        available >= needed + needed / 10 + 50_000_000
    }
}
