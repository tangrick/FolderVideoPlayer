import Foundation
import AVFoundation

/// Making the copies `SharePrep` plans: a video for sharing, and a ZIP package
/// of several files.
///
/// Every write goes to a hidden partial file beside the destination and is
/// renamed into place only when complete, so a cancelled or failed job never
/// leaves something that looks finished; the partial is removed on every way
/// out. The source is only ever read.
enum ShareExport {

    enum Failure: Error, LocalizedError, Equatable {
        case unavailable(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case exportFailed(String)
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            case .notEnoughSpace(let needed, let available):
                let f = ByteCountFormatter()
                return "Not enough free space: about \(f.string(fromByteCount: needed)) is needed and "
                    + "\(f.string(fromByteCount: available)) is free."
            case .exportFailed(let why): return why
            case .destinationExists(let name): return "“\(name)” already exists."
            }
        }
    }

    // MARK: - reading the source

    /// What the plan needs to know about a video. AVFoundation first — it is on
    /// every Mac; FFmpeg's probe for what AVFoundation cannot open, when it is
    /// installed. Never throws: an unreadable file comes back with what is
    /// known (its size) and `avReadable == false`.
    static func inspect(_ path: String, tools: PlayableCopy.Tools? = PlayableCopy.findTools()) async -> ShareSource {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        if let playable = try? await asset.load(.isPlayable), playable,
           let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let shown = size.applying(transform)
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            return ShareSource(codec: codec.map(normalise), height: Int(abs(shown.height).rounded()),
                               duration: duration.isFinite ? duration : 0, bytes: bytes, avReadable: true)
        }
        if let tools,
           let probe = try? await PlayableCopy.run(tools.ffprobe,
                                                   ["-v", "error", "-show_entries",
                                                    "stream=codec_type,codec_name,height,bit_rate:format=duration,bit_rate",
                                                    "-of", "json", path]),
           let parsed = PlayableCopy.parseProbe(probe.output) {
            return ShareSource(codec: parsed.video, height: parsed.height, duration: parsed.duration,
                               bytes: bytes, avReadable: false)
        }
        return ShareSource(codec: nil, height: 0, duration: 0, bytes: bytes, avReadable: false)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// AVFoundation's four-character codes, in FFmpeg's names, so one set of
    /// rules in `SharePrep` covers both.
    private static func normalise(_ code: String) -> String {
        switch code {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        default: return code
        }
    }

    // MARK: - one copy

    /// Hidden, beside the destination, with the destination's extension so
    /// AVFoundation writes the container it is asked for.
    static func partialPath(for output: String) -> String {
        let folder = (output as NSString).deletingLastPathComponent
        let name = (output as NSString).lastPathComponent
        return (folder as NSString).appendingPathComponent(".\(name).partial.\((name as NSString).pathExtension)")
    }

    /// Make one share copy of `source` at `output`.
    ///
    /// `replacing` is true only when the user has confirmed replacing an
    /// existing file (the save panel asks); otherwise an existing destination
    /// is refused. `onProgress` gets 0…1, or nil while the length is unknown.
    static func make(source: String, output: String, preset: SharePreset, engine: ShareEngine,
                     trim: ClosedRange<Double>?, estimate: Int64?, replacing: Bool = false,
                     tools: PlayableCopy.Tools? = PlayableCopy.findTools(),
                     onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        if case .unavailable(let why) = engine { throw Failure.unavailable(why) }
        let fm = FileManager.default
        if !replacing, fm.fileExists(atPath: output) {
            throw Failure.destinationExists((output as NSString).lastPathComponent)
        }
        let folder = (output as NSString).deletingLastPathComponent
        if let estimate, let free = freeSpace(folder), !SharePrep.hasRoom(needed: estimate, available: free) {
            throw Failure.notEnoughSpace(needed: estimate, available: free)
        }

        let partial = partialPath(for: output)
        try? fm.removeItem(atPath: partial)
        do {
            switch engine {
            case .avPassthrough:
                try await exportAV(source: source, to: partial, presetName: AVAssetExportPresetPassthrough,
                                   trim: trim, onProgress: onProgress)
            case .avTranscode(let name):
                try await exportAV(source: source, to: partial, presetName: name,
                                   trim: trim, onProgress: onProgress)
            case .ffmpeg(let remux, let height):
                guard let tools else { throw Failure.unavailable("FFmpeg is not installed.") }
                try await exportFFmpeg(source: source, to: partial, preset: preset, remux: remux,
                                       height: height, trim: trim, tools: tools, onProgress: onProgress)
            case .unavailable:
                return
            }
            try Task.checkCancellation()
            // Published in one step. A replace the user confirmed swaps the
            // old file out atomically rather than deleting it first.
            if fm.fileExists(atPath: output) {
                guard replacing else { throw Failure.destinationExists((output as NSString).lastPathComponent) }
                _ = try fm.replaceItemAt(URL(fileURLWithPath: output), withItemAt: URL(fileURLWithPath: partial))
            } else {
                try fm.moveItem(atPath: partial, toPath: output)
            }
        } catch {
            try? fm.removeItem(atPath: partial)
            throw error
        }
    }

    private static func exportAV(source: String, to partial: String, presetName: String,
                                 trim: ClosedRange<Double>?,
                                 onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: source))
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw Failure.exportFailed("This video cannot be exported at that quality.")
        }
        session.outputURL = URL(fileURLWithPath: partial)
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let trim {
            session.timeRange = CMTimeRange(start: CMTime(seconds: trim.lowerBound, preferredTimescale: 600),
                                            end: CMTime(seconds: trim.upperBound, preferredTimescale: 600))
        }
        let box = SessionBox(session)
        let watcher = Task {
            while !Task.isCancelled {
                onProgress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { done.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        switch session.status {
        case .completed:
            onProgress(1)
        case .cancelled:
            throw CancellationError()
        default:
            throw Failure.exportFailed(session.error?.localizedDescription ?? "The export stopped.")
        }
    }

    /// AVAssetExportSession predates Sendable; it is only touched through this
    /// box, from the export's own completion and the progress poll.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private static func exportFFmpeg(source: String, to partial: String, preset: SharePreset,
                                     remux: Bool, height: Int?, trim: ClosedRange<Double>?,
                                     tools: PlayableCopy.Tools,
                                     onProgress: @escaping @Sendable (Double?) -> Void) async throws {
        let probe = try? await PlayableCopy.run(tools.ffprobe,
                                                ["-v", "error", "-show_entries", "format=duration",
                                                 "-of", "json", source])
        let total = trim.map { $0.upperBound - $0.lowerBound }
            ?? probe.flatMap { PlayableCopy.parseProbe($0.output)?.duration } ?? 0
        onProgress(total > 0 ? 0 : nil)
        let args = SharePrep.ffmpegArguments(source: source, output: partial, preset: preset,
                                             remux: remux, height: height, trim: trim)
        let result = try await PlayableCopy.run(tools.ffmpeg, args) { line in
            guard total > 0, let done = PlayableCopy.progressSeconds(line) else { return }
            onProgress(min(1, max(0, done / total)))
        }
        guard result.status == 0 else {
            let last = String(decoding: result.errors, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "FFmpeg stopped (\(result.status))"
            throw Failure.exportFailed(last)
        }
    }

    // MARK: - a package

    /// A ZIP of several files — videos, and the subtitle files beside them.
    ///
    /// Stored, not compressed: a video is already compressed, and deflating it
    /// again costs minutes to save a percent. The point of a package is ONE
    /// thing to send, not a smaller one. Entry names come from
    /// `SharePrep.packageEntries`, so two files with one name both go in.
    static func zip(_ files: [String], to output: String, replacing: Bool = false) async throws {
        let fm = FileManager.default
        if !replacing, fm.fileExists(atPath: output) {
            throw Failure.destinationExists((output as NSString).lastPathComponent)
        }
        let entries = SharePrep.packageEntries(files)
        let needed = entries.reduce(Int64(0)) { sum, entry in
            sum + (((try? fm.attributesOfItem(atPath: entry.source))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let folder = (output as NSString).deletingLastPathComponent
        if let free = freeSpace(folder), !SharePrep.hasRoom(needed: needed, available: free) {
            throw Failure.notEnoughSpace(needed: needed, available: free)
        }

        // The entries are laid out as links in a scratch folder, named as they
        // will appear; zip follows a link and stores what it points at.
        let staging = NSTemporaryDirectory() + "fvp-package-\(UUID().uuidString)"
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: staging) }
        for entry in entries {
            try fm.createSymbolicLink(atPath: (staging as NSString).appendingPathComponent(entry.name),
                                      withDestinationPath: entry.source)
        }

        let partial = partialPath(for: output)
        try? fm.removeItem(atPath: partial)
        do {
            let result = try await runZip(in: staging, archive: partial, names: entries.map(\.name))
            guard result.status == 0 else {
                throw Failure.exportFailed(String(decoding: result.errors, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try Task.checkCancellation()
            if fm.fileExists(atPath: output) {
                guard replacing else { throw Failure.destinationExists((output as NSString).lastPathComponent) }
                _ = try fm.replaceItemAt(URL(fileURLWithPath: output), withItemAt: URL(fileURLWithPath: partial))
            } else {
                try fm.moveItem(atPath: partial, toPath: output)
            }
        } catch {
            try? fm.removeItem(atPath: partial)
            throw error
        }
    }

    /// `/usr/bin/zip` from inside the staging folder, so entries carry their
    /// bare names. Cancellation terminates it (the same runner FFmpeg uses).
    private static func runZip(in folder: String, archive: String,
                               names: [String]) async throws -> PlayableCopy.RunResult {
        // `-0` store, `-q` quiet, `-X` no Mac extra attributes. Each name goes
        // as `./name`, so one that starts with a dash is still a name; zip
        // drops the `./` from what it stores.
        let script = "cd \"$1\" && shift && exec /usr/bin/zip -0 -q -X \"$@\""
        return try await PlayableCopy.run("/bin/sh", ["-c", script, "sh", folder, archive]
                                             + names.map { "./" + $0 })
    }

    // MARK: - disk

    static func freeSpace(_ folder: String) -> Int64? {
        let url = URL(fileURLWithPath: folder)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: folder))?[.systemFreeSize]
            as? NSNumber)?.int64Value
    }
}
