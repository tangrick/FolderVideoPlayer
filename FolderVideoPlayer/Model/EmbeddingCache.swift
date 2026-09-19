import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// The on-disk embedding cache, in the exact shape the Python engine laid
/// down: `frames/<model_slug>/<xx>/<frame_hash>.f32`, little-endian floats,
/// two-level fan-out.
///
/// Contract kept from engine.py:
///  - keyed on the FRAME's bytes, not the video path — a moved or renamed
///    library keeps every vector it already paid for;
///  - corrupt or wrong-length files are misses, never errors;
///  - writes go to `<path>.tmp` then rename, so a crash cannot leave a
///    half-vector that later reads back as data;
///  - a full disk is best-effort, never a failed analysis.
///
/// The slug differs (`siglip2_base`, and before it `mobileclip_s2` and the
/// engine's `openai_clip-vit-large-patch14`), so old vectors sit untouched and
/// inert — the spaces are incomparable and are never mixed. Changing the tower
/// is therefore a rename of that slug: the old cache is simply never read, and
/// the fitted heads, which are named after the slug too, refuse to load.
///
/// Since 2026-09-16 the namespace is not only that hand-written slug: when a
/// space marker is installed (`ModelSpace`), the tree is keyed by the space's
/// digest instead, so a tower or preprocessing change re-keys the cache on its
/// own — see `cacheKey(root:)` and `namespace`.
struct EmbeddingCache {

    let root: String            // …/frames
    let slug: String            // siglip2_base
    let dim: Int                // 768
    /// The support root the space marker is read from — the marker lives at
    /// `<support>/tags/installed.digest`, one level above this cache's
    /// `frames` directory in every construction site.
    let spaceRoot: String
    private var pinnedNamespace: String? = nil

    /// Inference must keep the namespace of the model it loaded, even if an
    /// installer changes the active marker while an async pass is suspended.
    func pinned(to namespace: String) -> EmbeddingCache {
        var copy = self
        copy.pinnedNamespace = namespace
        return copy
    }

    init(root: String, slug: String = VisionEmbedder.modelSlug, dim: Int = VisionEmbedder.dim,
         spaceRoot: String? = nil) {
        self.root = root
        self.slug = slug
        self.dim = dim
        self.spaceRoot = spaceRoot ?? (root as NSString).deletingLastPathComponent
    }

    /// The namespace an embedding cache keyed to `root`'s installed space
    /// belongs in. `root` is the SUPPORT root (the marker lives under its
    /// `tags/`), not the frames directory.
    ///
    /// With a space marker (an install this build stamped), the cache binds to
    /// the digest itself: a tower or preprocessing change re-stamps, and the
    /// old tree is simply never read again — no human rename required. With no
    /// marker, the hand-written slug — the engine's contract, which is also
    /// what keeps the Python engine and the Swift app sharing one tree today.
    static func cacheKey(root: String) -> String {
        ModelSpace.read(root: root)?.digest ?? VisionEmbedder.modelSlug
    }

    /// Default location, under the app's support dir.
    static func `default`() -> EmbeddingCache {
        EmbeddingCache(root: (Paths.support as NSString).appendingPathComponent("frames"))
    }

    /// Directory this cache reads and writes, under `frames/`.
    ///
    /// Keyed by the INSTALLED space's digest when one is recorded — not by a
    /// name — so a tower or preprocessing change moves every vector out of
    /// reach instead of feeding old vectors into the new space. A cache under
    /// a digest key can only have been written by a build running that exact
    /// tower; a slug-keyed tree is the shared Python/Swift namespace.
    var namespace: String {
        pinnedNamespace ?? ModelSpace.read(root: spaceRoot)?.digest ?? slug
    }

    /// Enumerate the same model space used by `read`. Capture it once so an
    /// installed-marker change cannot redirect part of this directory walk.
    func hashes() -> [String] {
        let directory = (root as NSString).appendingPathComponent(namespace)
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var hashes: [String] = []
        for child in children.sorted() {
            let path = (directory as NSString).appendingPathComponent(child)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            for name in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
                where name.hasSuffix(".f32") {
                hashes.append(String(name.dropLast(4)))
            }
        }
        return hashes
    }

    func path(for hash: String) -> String {
        let sub = (root as NSString).appendingPathComponent(namespace)
        let dir = (sub as NSString).appendingPathComponent(String(hash.prefix(2)))
        return (dir as NSString).appendingPathComponent(hash + ".f32")
    }

    /// SHA-256 of the frame's bytes, truncated to 32 hex chars — the engine's
    /// `_frame_hash` exactly. ffmpeg JPEG bytes and AVFoundation PNG bytes
    /// differ, which only means the two engines do not share cache entries —
    /// precisely the intent, since the two embedding spaces are incomparable.
    nonisolated static func frameHash(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Stable hash of a frame's pixels. PNG encoding is deterministic within
    /// a process; an encoder change across OS versions only costs a re-embed,
    /// never a wrong vector.
    nonisolated static func frameHash(of image: CGImage) -> String {
        frameHash(image.pngData())
    }

    func read(_ hash: String) -> [Float]? {
        let p = path(for: hash)
        guard let raw = FileManager.default.contents(atPath: p),
              !raw.isEmpty, raw.count % 4 == 0 else { return nil }
        let n = raw.count / 4
        if n != dim { return nil }          // a different model wrote this; ignore
        var v = [Float](repeating: 0, count: n)
        _ = v.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
        return v
    }

    func write(_ hash: String, _ vec: [Float]) {
        guard vec.count == dim else { return }
        let p = path(for: hash)
        let dir = (p as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let v = vec                         // copy into one contiguous buffer
        let data = v.withUnsafeBytes { Data($0) }
        let tmp = p + ".tmp"
        guard fm.createFile(atPath: tmp, contents: data) else { return }
        if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        try? fm.moveItem(atPath: tmp, toPath: p)   // rename(2): atomic on APFS and SMB
    }

    /// Indices of frames the cache cannot serve.
    func misses(in hashes: [String]) -> [Int] {
        hashes.enumerated().compactMap { read($0.element) == nil ? $0.offset : nil }
    }
}

// --- little helpers ---------------------------------------------------------

extension CGImage {
    /// PNG bytes of this image, for content hashing. Deterministic within a
    /// process; an encoder change across OS versions only costs a re-embed,
    /// never a wrong vector.
    func pngData() -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, self, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }
}
