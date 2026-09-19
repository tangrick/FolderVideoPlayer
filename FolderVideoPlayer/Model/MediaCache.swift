import AVFoundation
import AppKit
import CryptoKit
import Foundation

/// Durations and poster frames, remembered rather than earned again.
///
/// Frames used to be held in a dictionary and nowhere else, so quitting threw
/// away every one of them and the next launch earned them all again. Durations
/// went the same way, in the same scan. Both are now kept on disk: this Mac's
/// copies under Application Support, and — for videos that live on a share —
/// a bigger frame left on the share itself, because what a video looks like is
/// not anybody's opinion and one frame serves every device that can read it.
@MainActor
final class MediaCache: ObservableObject {

    /// tagKey → [byte count, seconds]. The size guards the entry, so a file
    /// swapped for another of the same name is measured again rather than
    /// wearing the old one's length.
    private var lengths: [String: [Double]] = [:]
    private var lengthsDirty = false
    /// Lengths already resolved this session, by path. `rememberedLength`
    /// costs a stat to check the file has not been swapped; a list redrawing
    /// would otherwise pay that per visible row, per redraw, over the wire.
    private var resolved: [String: Double] = [:]
    private var pendingSave: Task<Void, Never>?
    /// Poster frames, held in a cache that evicts rather than a dictionary
    /// that does not: a session spent browsing icon grids over a few
    /// thousand videos used to accumulate every frame it had ever shown.
    private let memory = NSCache<NSString, NSImage>()
    /// Videos whose frame could not be made, and when the attempt was.
    ///
    /// Without this, a file AVFoundation will not open was asked again every
    /// time its row scrolled into view — which with `.avi` in the list is most
    /// of them. Remembered for a few minutes rather than for good, so a share
    /// that was asleep is not written off for the session.
    private var failures: [String: Double] = [:]
    private let retryFailedAfter: TimeInterval = 300

    /// Bumped when a frame or a length arrives, so lists redraw.
    @Published private(set) var revision = 0

    init() {
        lengths = JSONStore.load(Paths.durationFile, fallback: [:])
        // Roughly a minute of 4K frames' worth of pixels before eviction
        // starts, and half a thousand frames by count — whichever first.
        memory.totalCostLimit = 512 * 1024 * 1024
        memory.countLimit = 500
    }

    // MARK: - durations

    func rememberedLength(_ path: String) -> Double? {
        guard let known = lengths[Paths.tagKey(path)], known.count == 2,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.doubleValue,
              size == known[0] else { return nil }
        return known[1]
    }

    func remember(length seconds: Double, for path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.doubleValue else { return }
        lengths[Paths.tagKey(path)] = [size, seconds]
        lengthsDirty = true
        scheduleSave()
    }

    /// Written once a scan finishes rather than per video: a thousand videos
    /// would otherwise be a thousand rewrites of the same file.
    func saveLengths() {
        guard lengthsDirty else { return }
        lengthsDirty = false
        JSONStore.saveCompact(Paths.durationFile, lengths)
    }

    /// How long this video is, if that is already known — a dictionary lookup,
    /// safe to call from a row being drawn.
    func length(_ path: String) -> Double? {
        if let known = resolved[path] { return known }
        if let known = rememberedLength(path) {
            resolved[path] = known
            return known
        }
        return nil
    }

    /// Written once the measuring has gone quiet rather than per video: a
    /// scrolled list would otherwise rewrite the whole file per row.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveLengths()
        }
    }

    // MARK: - poster frames

    /// A frame for this video, if one is already to hand.
    func cachedPoster(_ path: String, big: Bool) -> NSImage? {
        memory.object(forKey: path + (big ? "|big" : "") as NSString)
    }

    /// A frame for this video: from memory, from either cache on disk, or made
    /// on the spot — whichever is cheapest that answers.
    func poster(_ path: String, big: Bool) async -> NSImage? {
        let slot = path + (big ? "|big" : "")
        if let image = memory.object(forKey: slot as NSString) { return image }
        if let failed = failures[path],
           Date().timeIntervalSince1970 - failed < retryFailedAfter { return nil }
        let image = await Self.fetchPoster(path, big: big)
        if let image {
            // Costed at its pixel count so eviction weighs big gallery frames
            // above small row thumbnails.
            memory.setObject(image, forKey: slot as NSString, cost: Self.pixelCost(image))
            failures.removeValue(forKey: path)
        } else {
            failures[path] = Date().timeIntervalSince1970
        }
        return image
    }

    private nonisolated static func fetchPoster(_ path: String, big: Bool) async -> NSImage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let cache = thumbLocation(path, size: size, big: big)
        if let data = FileManager.default.contents(atPath: cache),
           let image = NSImage(data: data) {
            return image
        }
        // A published frame on the share beats making one: reading a 30 KB
        // JPEG is one round trip, where making a frame means parsing a moov
        // atom that may sit at the far end of the file.
        if let shared = sharedLocation(path, size: size),
           let data = FileManager.default.contents(atPath: shared),
           let image = NSImage(data: data) {
            Self.write(data, to: cache)
            return image
        }
        guard fastExtensions.contains((path as NSString).pathExtension.lowercased())
        else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let seconds = try? await asset.load(.duration).seconds, seconds > 0
        else { return nil }
        let at = CMTime(seconds: min(seconds * 0.1, 30), preferredTimescale: 600)
        let wanted = big ? Tuning.gallerySize : Tuning.thumbSize
        guard let cg = try? await Self.frame(asset, at: at,
                                             size: CGSize(width: wanted.width * 2,
                                                          height: wanted.height * 2))
        else { return nil }
        if let data = Self.jpeg(cg, quality: Tuning.posterQuality) {
            Self.write(data, to: cache)
        }
        // And a bigger one on the share, once, for whatever else reads it.
        if let dest = sharedLocation(path, size: size),
           !FileManager.default.fileExists(atPath: dest),
           let full = try? await Self.frame(asset, at: at, size: Tuning.posterSize),
           let data = Self.jpeg(full, quality: Tuning.posterQuality) {
            Self.write(data, to: dest)
        }
        return NSImage(cgImage: cg, size: wanted)
    }

    /// What a frame weighs, in pixels — a faithful-enough stand-in for its
    /// memory so the cache evicts the big ones before the little ones.
    private nonisolated static func pixelCost(_ image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return rep.pixelsWide * rep.pixelsHigh
        }
        return Int(image.size.width * image.size.height)
    }

    private nonisolated static func thumbLocation(_ path: String, size: Int64, big: Bool) -> String {
        let digest = SHA256.hash(data: Data("\(Paths.tagKey(path))\0\(size)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return (Paths.thumbCache as NSString)
            .appendingPathComponent(hex + (big ? "-big.jpg" : ".jpg"))
    }

    private nonisolated static func sharedLocation(_ path: String, size: Int64) -> String? {
        let key = Paths.tagKey(path)
        guard !key.hasPrefix("/"), let cut = key.firstIndex(of: "/") else { return nil }
        let share = String(key[key.startIndex..<cut])
        let rest = String(key[key.index(after: cut)...])
        guard !rest.isEmpty else { return nil }
        let root = Paths.volumes + share
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        let digest = SHA256.hash(data: Data("\(rest)\0\(size)".utf8))
        let name = String(digest.map { String(format: "%02x", $0) }.joined().prefix(32)) + ".jpg"
        return ((root as NSString).appendingPathComponent(Paths.posterDir) as NSString)
            .appendingPathComponent(name)
    }

    private nonisolated static func frame(_ asset: AVURLAsset, at: CMTime,
                                          size: CGSize) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        return try await generator.image(at: at).image
    }

    private nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: quality])
    }

    /// Written beside and moved into place, so a share that drops out
    /// mid-write leaves no half a picture behind.
    private nonisolated static func write(_ data: Data, to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let scratch = path + ".writing"
        guard (try? data.write(to: URL(fileURLWithPath: scratch))) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                   withItemAt: URL(fileURLWithPath: scratch))
    }
}
