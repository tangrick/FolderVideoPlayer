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
    /// The tower builds accepted as this space: tower directory → digest of
    /// its bytes. Absent on markers written before the 16-bit tower existed,
    /// where the one accepted build is `digest` at the float32 tower's path
    /// (see `accepted`).
    ///
    /// Two entries only ever arise one way: a float16 build installed while
    /// the float32 build this marker identifies is on disk and unchanged, or
    /// the other way round (see `write`). They are the same weights at two
    /// precisions — measured on 400 real frames, trained-head decisions
    /// flipped 1 in 800 — so they share this space's cached vectors, heads and
    /// prompt table instead of stranding them. `digest` stays the space's
    /// name throughout, so nothing keyed by it moves.
    var members: [String: String]? = nil

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
              space.preprocess == nil || space.preprocess == declaredPreprocess,
              (space.members ?? [:]).allSatisfy({ entry in
                  towers.contains { $0.directory == entry.key } && isDigest(entry.value)
              }) else {
            throw MarkerError.invalid
        }
        return space
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }

    /// One build of the image tower this app can load, and the prompt table
    /// that ships beside it.
    struct Tower: Equatable {
        /// The catalogue bundle that installs it — what the Tags row's pack
        /// picker records as the choice.
        let bundleID: String
        let directory: String
        /// The prompt table's file stem under tags/. Both bundles ship the
        /// same public table under their own names, because the catalogue
        /// refuses two bundles that install to the same path.
        let prompts: String
    }

    /// The same SigLIP 2 weights at two precisions. float32 first: it is the
    /// build every installation before this had, so with nothing chosen it
    /// stays the one used.
    static let towers: [Tower] = [
        Tower(bundleID: "tags", directory: "tags/siglip2_base.mlmodelc",
              prompts: "siglip2_base_prompts"),
        Tower(bundleID: "tags-fp16", directory: "tags/siglip2_base_fp16.mlmodelc",
              prompts: "siglip2_base_fp16_prompts"),
    ]

    static func isInstalled(_ tower: Tower, root: String) -> Bool {
        var isDir: ObjCBool = false
        let path = (root as NSString).appendingPathComponent(tower.directory)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The tower to load: the one chosen in Settings when it is installed,
    /// otherwise the first installed. The float32 tower when none is, so a
    /// "not installed" message names the path an install would fill.
    static func activeTower(root: String) -> Tower {
        let installed = towers.filter { isInstalled($0, root: root) }
        let chosen = ModelRegistry.read(root: root).selection(for: .tags)?.bundleID
        return installed.first { $0.bundleID == chosen } ?? installed.first ?? towers[0]
    }

    /// The tower whose bytes this identity is OF. One place, so the write
    /// path and the re-check path can never disagree about what is being
    /// identified.
    static func towerDirectory(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent(activeTower(root: root).directory))
    }

    /// Every build this marker accepts, by tower directory. A marker written
    /// before `members` existed identified the float32 tower alone.
    var accepted: [String: String] {
        members ?? [Self.towers[0].directory: digest]
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
        let tower = Self.activeTower(root: root)
        guard let expected = accepted[tower.directory],
              let onDisk = Self.digestOfDirectory(
                  at: URL(fileURLWithPath: (root as NSString).appendingPathComponent(tower.directory)),
                  preprocess: preprocess)
        else { return false }
        return onDisk == expected
    }

    /// Record the identity of what an install just put in place. The digest is
    /// recomputed from disk rather than trusted from the caller, and the
    /// declared preprocessing is part of it — see `digestOfDirectory`.
    ///
    /// A build of the OTHER precision joins the recorded space instead of
    /// replacing it, but only when that space's own build is still on disk
    /// with the bytes it recorded — the proof that these are the two
    /// precisions of one install, not a stale marker. A tower reinstalled with
    /// different bytes at a path the marker already knows still mints a new
    /// space, exactly as before.
    ///
    /// `joinOnly` is for a bundle with no pack descriptor: it may add its
    /// build to an intact space, and do nothing else — an undescribed install
    /// is never a space change.
    static func write(adapter: String, dim: Int, root: String,
                      preprocess: String? = nil, tower: Tower = towers[0],
                      joinOnly: Bool = false) throws {
        let directory = URL(fileURLWithPath: (root as NSString).appendingPathComponent(tower.directory))
        guard let digest = digestOfDirectory(at: directory, preprocess: preprocess) else { return }
        var space = ModelSpace(adapter: adapter, digest: digest, dim: dim, preprocess: preprocess,
                               members: [tower.directory: digest])
        if let existing = try? readForInference(root: root),
           existing.adapter == adapter, existing.dim == dim, existing.preprocess == preprocess {
            var accepted = existing.accepted
            // The same bytes again: the identity already says so.
            if accepted[tower.directory] == digest { return }
            let siblingIntact = accepted.contains { path, recorded in
                path != tower.directory
                    && digestOfDirectory(at: URL(fileURLWithPath: (root as NSString)
                                            .appendingPathComponent(path)),
                                         preprocess: preprocess) == recorded
            }
            if accepted[tower.directory] == nil, siblingIntact {
                accepted[tower.directory] = digest
                space = existing
                space.members = accepted
            } else if joinOnly {
                return
            }
        } else if joinOnly {
            return
        }
        let data = try JSONEncoder().encode(space)
        try data.write(to: URL(fileURLWithPath: digestFile(root: root)), options: .atomic)
    }

    /// A tower build was removed. The marker loses that build; it is deleted
    /// only when no build it accepts is still on disk — removing one precision
    /// must not unbind every consumer from the other, which is still installed.
    static func forget(_ tower: Tower, root: String) {
        let file = digestFile(root: root)
        guard let existing = read(root: root) else { return }
        var remaining = existing.accepted
        remaining[tower.directory] = nil
        let intact = remaining.contains { path, recorded in
            digestOfDirectory(at: URL(fileURLWithPath: (root as NSString).appendingPathComponent(path)),
                              preprocess: existing.preprocess) == recorded
        }
        guard intact else {
            try? FileManager.default.removeItem(atPath: file)
            return
        }
        var space = existing
        space.members = remaining
        if let data = try? JSONEncoder().encode(space) {
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
    }
}
