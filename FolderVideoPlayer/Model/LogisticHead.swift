import Foundation
import Accelerate

/// Fitted logistic heads: one linear model per tag, plus the single
/// Safe/NSFW correction head.
///
/// This is the maths half of engine.py's `train` / `train_nsfw` — the fit and
/// the score. Nothing here touches a model, a frame, or the network: heads are
/// fitted over vectors the analyse pass already paid for, which is what makes
/// this phase possible while the model work is blocked.
///
/// Contract kept from engine.py, deliberately and exactly:
///  - a video is represented by the **mean of its cached frame vectors**,
///    L2-normalised — the same vector a whole-video comparison uses;
///  - the split is **every 5th video held out**, over the index positions of
///    the videos the engine actually has vectors for, so frames of one video
///    never straddle the split (a caller that drops a video changes who is
///    held out — that is the Python behaviour, not a bug to fix here);
///  - a tag needs **4 accepted and 4 rejected** videos, and **4 train / 1 test**
///    after the split; below either, it refuses and says so in the same words
///    the engine used, because that string is what the UI shows;
///  - a zero-norm mean (a video whose frames cancel out) divides by 1, not 0.
///
/// What this file does NOT do: decide a tag. A tag fires when enough frames
/// clear `HeadTuning.cut` and that count clears `_min_frames_for()`, which
/// lives with the suggester — `hits(_:)` is here so that rule has a number to
/// compare, not to make the call itself.
enum HeadTuning {
    static let minPos = 4           // TRAINED_HEADS_MIN_POS
    static let minRej = 4           // TRAINED_HEADS_MIN_REJ
    static let cut: Float = 0.5     // TRAINED_HEADS_CUT
    static let learningRate = 0.5
    static let epochs = 300
    static let lambda = 1e-3
    static let holdEvery = 5        // every 5th video is held out
    static let minTrain = 4
    static let minTest = 1
}

/// One linear head: `sigmoid(w · v + b)`.
///
/// `w` and `b` are stored in float32 because that is what engine.py writes to
/// the npz, and a head that round-trips through a different precision would
/// score differently from the Python path for no reason. The fit itself runs in
/// float64, as numpy's does.
struct LogisticHead: Equatable, Codable {
    var w: [Float]
    var b: Float
    /// How many videos the head was fitted from — engine.py's `head/<tag>/n`.
    var n: Float

    var dim: Int { w.count }

    /// Per-frame probability, in float32: the Python path scores a float32
    /// tensor, so a decision near the cut lands the same way on both sides.
    func score(_ v: [Float]) -> Float {
        guard v.count == w.count, !w.isEmpty else { return .nan }
        var dot: Float = 0
        vDSP_dotpr(w, 1, v, 1, &dot, vDSP_Length(w.count))
        return 1 / (1 + expf(-(dot + b)))
    }

    /// Frames at or above the logistic cut. Boundary rule: `>=`, matching
    /// `p >= TRAINED_HEADS_CUT` — a frame exactly on the cut *is* a vote.
    func hits(_ frames: [[Float]]) -> Int {
        frames.reduce(0) { $0 + (score($1) >= HeadTuning.cut ? 1 : 0) }
    }

    /// Vectors of the wrong width are a different embedding space; scoring them
    /// would be arithmetic on nothing. The caller checks `dim` once instead.
    func matches(dim other: Int) -> Bool { w.count == other }
}

/// The fitted heads on disk, as JSON.
///
/// engine.py kept these in an `.npz`. Swift has no npz reader and the file was
/// only ever ours, so the format is ours too — but the *shape* is kept, because
/// two things about it are load-bearing:
///  - every tag gets its own `w`/`b`/`n` triple, and the Safe/NSFW correction
///    head gets its own separate one, so a user tag named "nsfw" cannot collide
///    with the correction head (pitfall 22);
///  - writes **merge**. Two training scopes exist — a playlist's Train button
///    and Tag Profiles' whole-library pass — and each must update only its own
///    tags, leaving the other's heads untouched.
///
/// Weights travel as base64 float32 rather than as decimal numbers: a head is
/// scored in float32, and text that only *round-trips through* the right
/// precision is a way to be subtly wrong for no gain. A corrupt file, a newer
/// version, or a truncated vector is IGNORED and reported in `problem` — an
/// unfitted head must never be mistaken for a fitted one.
struct TrainedHeads: Equatable {
    /// The same string `VisionEmbedder.modelSlug` holds; the Core ML runner
    /// compiles both files and asserts they agree.
    static let defaultSlug = "siglip2_base"
    static let currentVersion = 1

    var slug: String = TrainedHeads.defaultSlug
    var dim: Int = 0
    /// The exact installed space these heads were fitted against — the digest
    /// of the artifact bytes, not a name. Written on save; a load bound to a
    /// different space refuses entirely. Nil on files written before spaces
    /// existed, which keeps every existing head working.
    var spaceDigest: String? = nil
    var tags: [String: LogisticHead] = [:]
    var nsfw: LogisticHead?

    /// Why a file on disk was ignored, if one was. Shown, not swallowed: an
    /// app that silently trains nothing is the bug this app already fixed once.
    var problem: String? = nil

    enum StoreError: LocalizedError {
        case emptyHead(String)
        case mkdirFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyHead(let what): return "refusing to write an empty head: \(what)"
            case .mkdirFailed(let dir): return "could not create \(dir)"
            }
        }
    }

    var isEmpty: Bool { tags.isEmpty && nsfw == nil }

    /// Where a profile's heads for one encoder live. Per profile: a head is
    /// fitted from one person's own accept/reject decisions, so it belongs to
    /// them and to no one else. Two profiles training the same tag name fit
    /// two different heads, and neither ever sees the other's.
    static func file(root: String = Paths.support, slug: String = TrainedHeads.defaultSlug,
                     profile: String = Paths.activeProfile) -> String {
        ProfileBundle.file(in: profile,
                           ProfileBundle.headsRelative(slug, "_trained_heads.json"),                           root: root)
    }

    // --- reading -----------------------------------------------------------

    private struct Wire: Codable {
        struct Head: Codable { var w: String; var b: Float; var n: Float }
        var version: Int
        var slug: String?
        var dim: Int?
        /// Absent on files written before spaces existed — optional so those
        /// files still decode and their heads keep working (Codable new-field
        /// trap: a required field would break every existing profile).
        var spaceDigest: String?
        var tags: [String: Head]?
        var nsfw: Head?

        enum CodingKeys: String, CodingKey {
            case version, slug, dim, tags, nsfw
            case spaceDigest = "space_digest"
        }
    }

    /// Read the heads for this slug. Never throws: an unreadable, truncated,
    /// newer or mismatched file yields no heads plus a `problem` saying why.
    static func load(root: String = Paths.support, slug: String = TrainedHeads.defaultSlug,
                     profile: String = Paths.activeProfile) -> TrainedHeads {
        var out = TrainedHeads(slug: slug)
        let path = file(root: root, slug: slug, profile: profile)
        guard let data = FileManager.default.contents(atPath: path) else { return out }

        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            out.problem = "the fitted heads file could not be read (\(path)) — nothing is being suggested from it"
            return out
        }
        guard wire.version <= currentVersion else {
            out.problem = "the fitted heads file was written by a newer version (\(wire.version)) — ignoring it rather than guessing"
            return out
        }
        let dim = wire.dim ?? 0
        guard dim > 0 else {
            out.problem = "the fitted heads file has no width — ignoring it"
            return out
        }
        out.dim = dim

        // Space binding: heads are fitted to ONE embedding space. Equal widths
        // never imply equal spaces, so a file bound to a different installed
        // artifact is refused wholesale — the space marker is the arbiter, and
        // a missing marker (artifacts installed before spaces existed, or a
        // support root without the tower at all) keeps legacy heads working.
        if let installed = ModelSpace.read(root: root) {
            if let bound = wire.spaceDigest {
                if bound != installed.digest {
                    out.problem = "these heads were fitted in another embedding space — train them again after switching models "
                                + "(bound \(bound.prefix(12))…, installed \(installed.digest.prefix(12))…)"
                    out.dim = 0
                    return out
                }
            }
            // Else: a pre-binding file loads against the current space. The
            // next save binds it — see below.
        }

        func unpack(_ name: String, _ head: Wire.Head) -> LogisticHead? {
            guard let raw = Data(base64Encoded: head.w), raw.count == dim * 4 else {
                out.problem = "the fitted head for \(name) is \(Data(base64Encoded: head.w)?.count ?? 0) bytes, "
                            + "expected \(dim * 4) — ignoring it"
                return nil
            }
            var w = [Float](repeating: 0, count: dim)
            _ = w.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
            return LogisticHead(w: w, b: head.b, n: head.n)
        }

        for (tag, head) in wire.tags ?? [:] {
            if let h = unpack(tag, head) { out.tags[tag] = h }
        }
        if let head = wire.nsfw, let h = unpack("nsfw", head) { out.nsfw = h }
        return out
    }

    // --- writing -----------------------------------------------------------

    /// Write this instance's heads over whatever is on disk, keeping every head
    /// it does not mention. The file appears whole or not at all (write to
    /// `.tmp`, then rename), so a crash cannot leave a half-written head that
    /// later reads back as a shorter, wrong one.
    func save(root: String = Paths.support, merging: Bool = true,
              profile: String = Paths.activeProfile) throws {
        var merged = merging ? TrainedHeads.load(root: root, slug: slug, profile: profile)
                             : TrainedHeads(slug: slug)
        merged.problem = nil
        let dim = dim > 0 ? dim : merged.dim
        guard dim > 0 else { throw StoreError.emptyHead("no width") }
        // A width change means a different encoder, which means a different
        // slug and a different file. Merging across widths would produce a file
        // that declares one width and holds another.
        guard merged.dim == 0 || merged.dim == dim else {
            throw StoreError.emptyHead("the file holds \(merged.dim)-wide heads, not \(dim)")
        }

        for (tag, head) in tags {
            guard head.w.count == dim else { throw StoreError.emptyHead("\(tag) is \(head.w.count) wide, expected \(dim)") }
            merged.tags[tag] = head
        }
        if let head = nsfw {
            guard head.w.count == dim else { throw StoreError.emptyHead("nsfw is \(head.w.count) wide, expected \(dim)") }
            merged.nsfw = head
        }
        merged.slug = slug
        merged.dim = dim
        // Bind whatever this save produces to the space installed right now —
        // including a pre-binding legacy file, whose heads are thereby adopted
        // by the space they are actually being used against. With no marker
        // (no tower installed) the digest stays nil, which loads anywhere.
        merged.spaceDigest = ModelSpace.read(root: root)?.digest

        let path = Self.file(root: root, slug: slug, profile: profile)
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw StoreError.mkdirFailed(dir)
        }

        let wire = Wire(version: TrainedHeads.currentVersion, slug: slug, dim: dim,
                        spaceDigest: merged.spaceDigest,
                        tags: merged.tags.mapValues { head in
                            Wire.Head(w: head.w.withUnsafeBytes { Data($0) }.base64EncodedString(),
                                      b: head.b, n: head.n)
                        },
                        nsfw: merged.nsfw.map { head in
                            Wire.Head(w: head.w.withUnsafeBytes { Data($0) }.base64EncodedString(),
                                      b: head.b, n: head.n)
                        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(wire)
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
        try fm.moveItem(atPath: tmp, toPath: path)     // rename(2): atomic on APFS and SMB
    }
}

/// What a fit attempt produced, in the engine's own vocabulary — including the
/// refusal text, which is user-facing copy and is compared verbatim by the
/// parity test.
struct HeadFit: Equatable, Codable {
    var tag: String
    var fitted: Bool
    var reason: String?
    var videos: Int?
    var heldOut: Int?
    var precision: Double?
    var recall: Double?

    enum CodingKeys: String, CodingKey {
        case tag, fitted, reason, videos, precision, recall
        case heldOut = "held_out"
    }

    static func refused(_ tag: String, _ reason: String) -> HeadFit {
        HeadFit(tag: tag, fitted: false, reason: reason)
    }
}

/// The videos a fit runs over, in the order the caller sent them.
///
/// Order is not cosmetic: the hold-out rule is positional, so a dictionary's
/// iteration order would silently change which videos are scored on. Callers
/// pass an ordered list, exactly as the app sends one to the engine.
struct HeadDataset {
    var keys: [String]
    var vectors: [[Double]]      // unit-norm, one row per key

    var dim: Int { vectors.first?.count ?? 0 }

    /// Collect one mean vector per video from the embedding cache.
    ///
    /// A video with no cached frames is **dropped, not zero-filled** — and that
    /// shifts the split for everyone else, which is what engine.py does, so the
    /// Python and Swift paths hold out the same videos.
    static func build(frames: [(key: String, hashes: [String])],
                      read: (String) -> [Float]?) -> HeadDataset {
        var keys: [String] = []
        var rows: [[Double]] = []
        for entry in frames {
            var acc: [Double]? = nil
            var count = 0
            for h in entry.hashes {
                guard let vec = read(h) else { continue }
                if acc == nil { acc = [Double](repeating: 0, count: vec.count) }
                guard var a = acc, a.count == vec.count else { continue }
                for i in 0..<vec.count { a[i] += Double(vec[i]) }   // float32 widened, summed in float64
                acc = a
                count += 1
            }
            guard let a = acc, count > 0 else { continue }
            keys.append(entry.key)
            rows.append(a.map { $0 / Double(count) })
        }
        for i in 0..<rows.count {
            var sum = 0.0
            for x in rows[i] { sum += x * x }
            let norm = sum.squareRoot()
            if norm != 0 { for j in 0..<rows[i].count { rows[i][j] /= norm } }
        }
        return HeadDataset(keys: keys, vectors: rows)
    }
}

enum LogisticTrainer {

    /// engine.py's `train`: one head per tag.
    ///
    /// `tags` is ordered (the app's order), and each label map holds only the
    /// videos the user actually judged — an unjudged video is neither positive
    /// nor negative, and must not be invented as one.
    static func fitTags(_ tags: [(tag: String, labels: [String: Bool])],
                        dataset: HeadDataset) -> (heads: [String: LogisticHead], fits: [HeadFit]) {
        var heads: [String: LogisticHead] = [:]
        var fits: [HeadFit] = []
        let n = dataset.keys.count
        guard n > 0 else { return (heads, fits) }

        let heldOut = (0..<n).map { $0 % HeadTuning.holdEvery == 0 }

        for entry in tags {
            let known = (0..<n).filter { entry.labels[dataset.keys[$0]] != nil }
            let pos = known.filter { entry.labels[dataset.keys[$0]] == true }
            let neg = known.filter { entry.labels[dataset.keys[$0]] == false }

            guard pos.count >= HeadTuning.minPos, neg.count >= HeadTuning.minRej else {
                fits.append(.refused(entry.tag,
                    "need \(HeadTuning.minPos)+ accepted and \(HeadTuning.minRej)+ rejected videos "
                    + "(have \(pos.count)/\(neg.count))"))
                continue
            }

            let tr = known.filter { !heldOut[$0] }
            let te = known.filter { heldOut[$0] }
            guard tr.count >= HeadTuning.minTrain, te.count >= HeadTuning.minTest else {
                fits.append(.refused(entry.tag, "not enough held-out videos"))
                continue
            }

            let (w, b) = fit(X: tr.map { dataset.vectors[$0] },
                             y: tr.map { entry.labels[dataset.keys[$0]] == true ? 1.0 : 0.0 })
            let metrics = heldOutMetrics(X: te.map { dataset.vectors[$0] },
                                         y: te.map { entry.labels[dataset.keys[$0]] == true ? 1.0 : 0.0 },
                                         w: w, b: b)

            heads[entry.tag] = LogisticHead(w: w.map { Float($0) }, b: Float(b),
                                            n: Float(known.count))
            fits.append(HeadFit(tag: entry.tag, fitted: true, reason: nil,
                                videos: known.count, heldOut: te.count,
                                precision: metrics.precision, recall: metrics.recall))
        }
        return (heads, fits)
    }

    /// engine.py's `train_nsfw`: the single Safe/NSFW correction head.
    ///
    /// No tag filter — every video the user marked is either positive (NSFW) or
    /// negative (Safe) — and the split runs over exactly those videos, so this
    /// head and the per-tag heads can disagree about who is held out. They
    /// always have, which is why the two fit functions are separate.
    static func fitNSFW(labels: [String: Bool], dataset: HeadDataset) -> (head: LogisticHead?, fit: HeadFit) {
        let tag = "nsfw"
        guard !dataset.keys.isEmpty else {
            return (nil, .refused(tag, "no cached embeddings for the marked videos -- analyse them first"))
        }
        let y = dataset.keys.map { labels[$0] == true ? 1.0 : 0.0 }
        let pos = y.filter { $0 == 1 }.count
        let neg = y.filter { $0 == 0 }.count
        guard pos >= HeadTuning.minPos, neg >= HeadTuning.minRej else {
            return (nil, .refused(tag, "need \(HeadTuning.minPos)+ NSFW and \(HeadTuning.minRej)+ Safe marks "
                                 + "(have \(pos)/\(neg))"))
        }
        let n = dataset.keys.count
        let heldOut = (0..<n).map { $0 % HeadTuning.holdEvery == 0 }
        let tr = (0..<n).filter { !heldOut[$0] }
        let te = (0..<n).filter { heldOut[$0] }
        guard tr.count >= HeadTuning.minTrain, te.count >= HeadTuning.minTest else {
            return (nil, .refused(tag, "not enough held-out videos"))
        }
        let (w, b) = fit(X: tr.map { dataset.vectors[$0] }, y: tr.map { y[$0] })
        let metrics = heldOutMetrics(X: te.map { dataset.vectors[$0] },
                                    y: te.map { y[$0] }, w: w, b: b)
        let head = LogisticHead(w: w.map { Float($0) }, b: Float(b), n: Float(n))
        return (head, HeadFit(tag: tag, fitted: true, reason: nil, videos: n,
                              heldOut: te.count, precision: metrics.precision, recall: metrics.recall))
    }

    // --- the fit itself ----------------------------------------------------

    /// Logistic regression by gradient descent — numpy's arithmetic, not a
    /// SIMD-flavoured rewrite of it. The matrix products go through BLAS
    /// (`cblas_dgemv`, the same call numpy makes) so the accumulation order
    /// matches; `w` and `b` stay float64 throughout and are narrowed to float32
    /// only where engine.py narrows them, at the store.
    static func fit(X: [[Double]], y: [Double]) -> ([Double], Double) {
        let m = X.count
        guard m > 0, let d = X.first?.count, d > 0 else { return ([], 0) }
        var flat = [Double](repeating: 0, count: m * d)
        for i in 0..<m { for j in 0..<d { flat[i * d + j] = X[i][j] } }

        var w = [Double](repeating: 0, count: d)
        var b = 0.0
        var z = [Double](repeating: 0, count: m)
        var r = [Double](repeating: 0, count: m)
        var grad = [Double](repeating: 0, count: d)
        let lr = HeadTuning.learningRate

        for _ in 0..<HeadTuning.epochs {
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(m), Int32(d), 1.0,
                        flat, Int32(d), w, 1, 0.0, &z, 1)
            var rsum = 0.0
            for i in 0..<m {
                r[i] = 1 / (1 + exp(-(z[i] + b))) - y[i]
                rsum += r[i]
            }
            cblas_dgemv(CblasRowMajor, CblasTrans, Int32(m), Int32(d), 1.0 / Double(m),
                        flat, Int32(d), r, 1, 0.0, &grad, 1)
            for j in 0..<d { w[j] -= lr * (grad[j] + HeadTuning.lambda * w[j]) }
            b -= lr * (rsum / Double(m))
        }
        return (w, b)
    }

    /// Precision and recall on videos the fit never saw. `>=` the cut counts as
    /// a hit, as in engine.py; no positives predicted means precision 0, not
    /// a division by zero.
    static func heldOutMetrics(X: [[Double]], y: [Double], w: [Double], b: Double)
        -> (precision: Double, recall: Double) {
        guard !X.isEmpty, w.count == X[0].count else { return (0, 0) }
        var tp = 0.0, fp = 0.0, fn = 0.0
        for i in 0..<X.count {
            var z = b
            for j in 0..<w.count { z += X[i][j] * w[j] }
            let hit = (1 / (1 + exp(-z))) >= Double(HeadTuning.cut)
            if hit && y[i] == 1 { tp += 1 }
            if hit && y[i] == 0 { fp += 1 }
            if !hit && y[i] == 1 { fn += 1 }
        }
        let precision = (tp + fp) > 0 ? tp / (tp + fp) : 0
        let recall = (tp + fn) > 0 ? tp / (tp + fn) : 0
        return (precision, recall)
    }
}
