import Foundation
import CryptoKit

/// The identity of the installed embedding space — the thing equal dimensions
/// can never prove.
///
/// A 768-wide vector from one tower and a 768-wide vector from another are
/// both "768-wide" and completely incomparable; scoring one against the other
/// is arithmetic on nothing. So the identity recorded here is not a name or a
/// dimension count but a digest of the exact installed artifact bytes: two
/// installs that differ in anything digest differently, and consumers (fitted
/// heads, the prompt table) bind to the digest they were built against.
///
/// What this deliberately is NOT: a signed statement of provenance. The
/// catalog's checksum proves what was DOWNLOADED; this proves what is
/// INSTALLED right now, so stale consumers can be refused. Authentication of
/// the catalog itself remains T03's separate release gate.
struct ModelSpace: Codable, Equatable {

    /// The catalog-declared adapter that produced the space.
    var adapter: String
    /// Digest of the installed artifact directory (see `digestOfDirectory`).
    var digest: String
    /// The space's vector width, for the record and for cheap refusal.
    var dim: Int
    /// The declared frame preprocessing this space was computed under (pixel
    /// format, resize, interpolation). Absent on markers written before this
    /// existed. It is folded into `digest`, so a preprocessing change moves
    /// the identity even when the tower bytes did not.
    var preprocess: String?

    /// This space's identity in one line, as an evidence row records it.
    ///
    /// The digest is the part that means anything — two towers are both
    /// "768-wide" — so it is carried in the line rather than left to the reader
    /// to infer from the name.
    var identityLabel: String { "\(adapter)-\(dim)@\(String(digest.prefix(12)))" }

    /// The model that produced a claim, in the same shape. Distinct from
    /// `identityLabel` because a store scopes evidence by BOTH: the model that
    /// said it, and the vector space it said it in.
    var sourceLabel: String { "\(adapter)@\(String(digest.prefix(12)))" }

    /// Adapters this build understands. From the pack descriptor contract;
    /// anything else cannot be a space this build can consume.
    static let knownAdapters = ["siglip2-base-v1", "falconsai-v1", "yunet-sface-v1"]

    /// The frame preprocessing this build declares for the siglip2 space:
    /// what `VisionEmbedder.pixelBuffer(from:)` does to every frame before the
    /// tower sees it. It is part of the space's identity — folded into the
    /// digest on write — so a resize, pixel-format or interpolation change
    /// invalidates vectors, prompts and heads even when the tower bytes did
    /// not. Bump it when that pipeline changes.
    static let declaredPreprocess = "siglip2-v1: bgra-premultiplied-first, constraint-resize, medium-interpolation"

    /// Where the identity of the currently-installed space is recorded.
    /// Beside the artifacts it identifies, and reserved from catalogs like
    /// the receipts are — a catalog asset must never sit where this is
    /// written, or a catalog could forge the identity of its own space.
    static func digestFile(root: String) -> String {
        (root as NSString).appendingPathComponent("tags/installed.digest")
    }

    /// Content digest of every file in the directory, sorted by relative path:
    /// `"model-space-v1:<path>:<size>\n"` lines followed by each file's bytes.
    ///
    /// Sizes are hashed alongside contents because a model directory's files
    /// are large and their NAMES are load-bearing (Core ML reads a manifest
    /// that names them); a same-bytes-different-names tree is a different
    /// artifact as far as Core ML is concerned. Nil for a missing or empty
    /// directory — there is nothing installed there to identify.
    ///
    /// With `preprocess`, the declared preprocessing is folded in after the
    /// directory: the identity is of the SPACE — what the tower does to a
    /// frame — not merely of the bytes. A resize or pixel-format change with
    /// unchanged weights is a different space for anything that scores
    /// against it, and must invalidate like one.
    static func digestOfDirectory(at url: URL, preprocess: String? = nil) -> String? {
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: url.path) else { return nil }
        var entries: [(rel: String, size: Int64)] = []
        for item in walk {
            let name = item as! String
            let path = (url.path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            entries.append((name, size))
        }
        guard !entries.isEmpty else { return nil }
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.rel < $1.rel }) {
            let line = "model-space-v1:\(entry.rel):\(entry.size)\n"
            hasher.update(data: Data(line.utf8))
            // Weight files can be hundreds of MB. Hash a bounded chunk and
            // refuse read failures instead of silently hashing empty bytes.
            do {
                let handle = try FileHandle(forReadingFrom: url.appendingPathComponent(entry.rel))
                defer { try? handle.close() }
                var readBytes: Int64 = 0
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                    readBytes += Int64(bytes.count)
                    guard readBytes <= entry.size else { return nil }
                    hasher.update(data: bytes)
                }
                guard readBytes == entry.size else { return nil }
            } catch {
                return nil
            }
        }
        if let preprocess, !preprocess.isEmpty {
            hasher.update(data: Data("model-space-v1:preprocess:\(preprocess)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The recorded identity of what is installed now, if any. Nil means no
    /// marker was ever written (artifacts installed before spaces existed) —
    /// every consumer treats that as the legacy case and keeps working.
    static func read(root: String) -> ModelSpace? {
        guard let data = FileManager.default.contents(atPath: digestFile(root: root)) else { return nil }
        return try? JSONDecoder().decode(ModelSpace.self, from: data)
    }

    enum MarkerError: Error, LocalizedError {
        case invalid
        var errorDescription: String? {
            "The installed model identity is unreadable or incompatible. Reinstall the model pack in Settings before analysing."
        }
    }

    /// Only an absent marker is a legacy installation. A present but damaged
    /// marker must never downgrade inference to the legacy cache namespace.
    /// This contract describes the visual adapter implemented by this build.
    static func readForInference(root: String) throws -> ModelSpace? {
        let path = digestFile(root: root)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw MarkerError.invalid
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= 65_536,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 65_536,
              let space = try? JSONDecoder().decode(ModelSpace.self, from: data),
              space.adapter == "siglip2-base-v1", space.dim == 768,
              space.digest.utf8.count == 64,
              space.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              space.preprocess == nil || space.preprocess == declaredPreprocess else {
            throw MarkerError.invalid
        }
        return space
    }

    /// The tower whose bytes this identity is OF. One place, so the write
    /// path and the re-check path can never disagree about what is being
    /// identified.
    static func towerDirectory(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString)
            .appendingPathComponent("tags/siglip2_base.mlmodelc"))
    }

    /// Does this marker still describe the bytes that are on disk NOW?
    ///
    /// Everything else in this file compares one marker against another
    /// marker, which only proves the RECORD changed. It cannot notice a tower
    /// swapped underneath a marker that stayed put — a restore from backup, a
    /// hand-copied model directory, a reinstall that died after placing files
    /// and before re-stamping. In that state the digest is a statement about
    /// bytes that are gone: vectors from the new tower are written under the
    /// old space's namespace and scored against the old space's prompts and
    /// heads, which is the exact arithmetic-on-nothing this type exists to
    /// prevent.
    ///
    /// So this re-derives the digest from the directory, folding in the
    /// preprocessing THIS marker recorded (a marker written before
    /// `preprocess` existed is re-checked without it, as it was written).
    /// False also covers a missing or empty tower: a marker for artifacts that
    /// are not there describes nothing.
    ///
    /// Cost, measured on the development machine's 352 MB SigLIP 2 tower:
    /// 0.15-0.19s per call. Callers pay it once, on a cold load, where the
    /// same bytes are about to be read anyway. It is NOT for a hot path, and
    /// `read` deliberately stays cheap.
    ///
    /// What it does not prove: that the bytes are trustworthy. An edit that
    /// re-stamps the marker to match is indistinguishable from an install.
    /// That is authentication — T03's separate release gate.
    func matchesInstalledBytes(root: String) -> Bool {
        guard let onDisk = Self.digestOfDirectory(at: Self.towerDirectory(root: root),
                                                  preprocess: preprocess)
        else { return false }
        return onDisk == digest
    }

    /// Record the identity of what an install just put in place. The digest is
    /// recomputed from disk rather than trusted from the caller, and the
    /// declared preprocessing is part of it — see `digestOfDirectory`.
    static func write(adapter: String, dim: Int, root: String,
                      preprocess: String? = nil) throws {
        let tower = towerDirectory(root: root)
        guard let digest = digestOfDirectory(at: tower, preprocess: preprocess) else { return }
        let space = ModelSpace(adapter: adapter, digest: digest, dim: dim, preprocess: preprocess)
        let data = try JSONEncoder().encode(space)
        try data.write(to: URL(fileURLWithPath: digestFile(root: root)), options: .atomic)
    }
}
