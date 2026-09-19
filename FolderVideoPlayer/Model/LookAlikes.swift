import Foundation

/// engine.py's `tag_candidates` — "which videos, anywhere, look like the ones I
/// tagged Kite?"
///
/// A user tag like "Kite" or "Bench" is not in the CLIP phrase vocabulary, so the
/// zero-shot pass can never offer it — and a tag the machine can never offer can
/// never be rejected either, which is why this exists. The tag is prototyped
/// from the videos already carrying it, then the whole analysed library is
/// ranked against that prototype. Pure arithmetic over vectors already cached:
/// no model, no ffmpeg, no GPU, so it is cheap enough to re-run on every toggle.
///
/// **Everything is a MARGIN, never an absolute similarity.** In a personal
/// library every video is close to every other one — measured, untagged videos
/// average +0.60 cosine to a Kite prototype — so a raw score cannot discriminate.
/// What discriminates is how far a video sits above the library's own average
/// video: tagged videos sit +0.10..+0.22 above it, untagged ones below. Hence
/// `margin`, and hence a candidate is offered only when it clears it.
///
/// Contract kept from engine.py, deliberately:
///  - a video is its frames' mean vector, L2-normalised, and a video with no
///    usable vectors is skipped — never zero-filled, which would score 0 against
///    everything and read as "not a look-alike" instead of "not looked at";
///  - the baseline is the mean of the per-video means of tagged ∪ pool — the
///    same corpus the +0.10 margin was calibrated against. A raw frame-mean
///    would let long videos dominate it;
///  - fewer than 2 tagged videos, or fewer than 3 videos for the baseline, is a
///    refusal with a reason, not a guess — but a tagged video with nothing
///    cached is not counted, so the app analyses that tag's unanalysed videos
///    before it searches, rather than telling someone who HAS two tagged videos
///    to go and run something;
///  - ties are broken by library order, and the limit truncates the ranking, not
///    the search (`unseenPool` still counts the whole pool).
struct LookAlikes {

    static let margin = 0.10            // LIBRARY_TAG_MARGIN
    static let minVideos = 2            // LIBRARY_TAG_MIN_VIDEOS
    static let minBaseline = 3
    static let defaultLimit = 25

    /// Split ranked candidates into the ones whose file is still where it was
    /// cached, and how many are not.
    ///
    /// The store can hold vectors for a path that has since moved — a renamed
    /// or re-nested folder leaves the old key behind, and the cache keeps
    /// ranking it. Such a row is worse than useless: it carries the SAME file
    /// name as the video the user just rejected, so it reads as "my rejection
    /// did not take", and it cannot be played or accepted either. Only the
    /// shortlist is checked (one `stat` per offered row), never the whole pool,
    /// so a search over thousands of videos still costs a few milliseconds.
    ///
    /// Order is preserved: this filters the answer, it does not re-rank it.
    static func live(_ candidates: [Candidate],
                     exists: (String) -> Bool) -> (live: [Candidate], gone: Int) {
        var live: [Candidate] = []
        var gone = 0
        for candidate in candidates {
            if exists(candidate.key) { live.append(candidate) } else { gone += 1 }
        }
        return (live, gone)
    }

    /// One ranked video. `score` is the margin over the library baseline at four
    /// decimals — the same number engine.py reports.
    struct Candidate: Equatable, Codable {
        var key: String
        var score: Double
    }

    struct Result: Equatable {
        var tag: String
        var candidates: [Candidate] = []
        /// Pool videos with no usable vectors — not yet analysed, or analysed
        /// before this encoder existed. Counted, then shown: "N more videos not
        /// yet classified".
        var unseenPool: Int = 0
        /// The SAME rows, named. `unseenPool` is what the engine reports and
        /// what every parity fixture compares; the keys are what the app needs
        /// to do something about it, because the only thing that makes such a
        /// video visible to the search is analysing it — see `widening`.
        var unseen: [String] = []
        /// Why there are no candidates, in the engine's own words. That string
        /// is user-facing copy, so it is reproduced exactly.
        var reason: String?
    }

    /// Rank `pool` against a prototype built from `tagged`.
    ///
    /// Both lists are ORDERED and the caller is expected to keep them stable:
    /// the baseline is a mean over them, and ties in the ranking are broken by
    /// that order. `library.tags` alone is not a valid pool — it holds only the
    /// videos that carry a tag, and the whole point is to search the ones that
    /// do not (that mix-up once made every tag report "no candidates").
    static func rank(tag: String,
                     tagged: [(key: String, hashes: [String])],
                     pool: [(key: String, hashes: [String])],
                     read: (String) -> [Float]?,
                     limit: Int = defaultLimit) -> Result {
        let proto = videoMeans(tagged, read: read)
        guard proto.count >= minVideos else {
            var out = Result(tag: tag)
            out.reason = "need \(minVideos)+ tagged videos to form a prototype (have \(proto.count))"
            return out
        }
        guard let prot = unit(mean(proto)) else {
            var out = Result(tag: tag)
            out.reason = "empty prototype"
            return out
        }

        // The baseline is measured over tagged ∪ pool, with pool winning any
        // key both lists mention — engine.py merges the two maps that way, and
        // the corpus decides the baseline.
        let poolValues = Dictionary(pool.map { ($0.key, $0.hashes) }, uniquingKeysWith: { _, last in last })
        var corpus: [(key: String, hashes: [String])] = tagged.map {
            ($0.key, poolValues[$0.key] ?? $0.hashes)
        }
        var seen = Set(tagged.map { $0.key })
        for entry in pool where !seen.contains(entry.key) {
            corpus.append(entry)
            seen.insert(entry.key)
        }

        let library = videoMeans(corpus, read: read)
        guard library.count >= minBaseline, let base = unit(mean(library)) else {
            var out = Result(tag: tag)
            out.reason = "no library baseline"
            return out
        }

        let delta = zip(prot, base).map { $0 - $1 }
        var scored: [(index: Int, candidate: Candidate)] = []
        var unseen: [String] = []
        for (index, entry) in pool.enumerated() {
            guard !entry.hashes.isEmpty, let vec = meanVector(entry.hashes, read: read) else {
                unseen.append(entry.key)        // nothing cached, or frames that cancel out
                continue
            }
            let value = dot(delta, vec)
            // `>=`: a video exactly on the margin is offered, as in engine.py.
            if value >= margin {
                scored.append((index, Candidate(key: entry.key, score: round4(value))))
            }
        }
        // Highest first; equal scores keep library order (Python's sort is
        // stable, Swift's is not — so the tie-break is explicit).
        scored.sort { $0.candidate.score == $1.candidate.score
            ? $0.index < $1.index
            : $0.candidate.score > $1.candidate.score }

        var out = Result(tag: tag)
        out.candidates = scored.prefix(max(0, limit)).map { $0.candidate }
        out.unseenPool = unseen.count
        out.unseen = unseen
        return out
    }

    /// How many videos one search pass will analyse to widen itself.
    ///
    /// Bounded per pass, not per press: the search re-runs when the analysis
    /// finishes — the same `.onChange` that re-asks it after a tag's own videos
    /// are analysed — so a library bigger than this is worked through in
    /// instalments the user can see (the footer names the job; Stop ends it)
    /// instead of one press silently starting a forty-minute library sweep.
    static let wideningBatch = 250

    /// What one widening pass would do — and what it cannot do.
    ///
    /// Returned in parts rather than as one list because the app has to SAY
    /// which is which: "N more videos the search cannot read" means two
    /// different things to the user depending on whether the app has already
    /// tried them, and a count the app cannot explain is the note this replaced.
    struct Widening: Equatable {
        /// What this pass should analyse, in library order, capped at the limit.
        var batch: [String] = []
        /// Everything it could analyse, before the cap — so the note can say
        /// "150 of 400" instead of pretending one batch is the whole library.
        var offered: Int = 0
        /// Refused by the caller: a file that has moved, a video a human has
        /// settled, a row the engine has already given up on.
        var refused: Int = 0
        /// Already re-analysed once this session and still unreadable. Never
        /// offered again — that is the loop guard, and the honest answer for
        /// these videos is the count, not another pass.
        var alreadyTried: Int = 0

        /// Nothing this pass can do.
        var isEmpty: Bool { batch.isEmpty }
    }

    /// Which videos the search must analyse before it can see more of the
    /// library.
    ///
    /// Two kinds, and they are the same problem: a video whose vectors the
    /// ranking cannot read is a video the search cannot see, so it can neither
    /// be offered nor be dismissed. That is the one state a tag cannot recover
    /// from on its own.
    ///
    ///  - `unreadable` — the rows `rank` counted as unseen: the record names
    ///    frame hashes whose `.f32` files are gone (a run that was interrupted,
    ///    or a cache write that failed on a full disk), so every read comes back
    ///    nil and the video scores as nothing;
    ///  - `unscored` — records from another embedding space, or with no frames
    ///    at all: never analysed, or analysed by an earlier vision tower, whose
    ///    vectors the engine running now will never open.
    ///
    /// `skip` is the caller's own CHEAP refusal, asked once per key: a video a
    /// human has settled, a row the engine has already given up on, a hidden
    /// video. It must not touch the disk — see `existing` for why, and for what
    /// happens to a key whose file has moved.
    ///
    /// `tried` is what this session has already re-analysed, and it is what
    /// keeps this from becoming a loop: a cache write is best-effort, so a video
    /// that comes back from a run with nothing on disk (a full disk, a share
    /// that went away) would otherwise be handed to the engine again by the very
    /// next search, for as long as the app is open. Once tried, "still
    /// unreadable" is the honest answer — not another pass over the same file.
    ///
    /// Sorted and deduplicated (a key can be both unreadable and unscored, and
    /// the two lists are built from different places), then capped at `limit`.
    static func widening(unreadable: [String],
                         unscored: [String],
                         tried: Set<String>,
                         skip: (String) -> Bool,
                         limit: Int = wideningBatch) -> Widening {
        var out = Widening()
        var seen = Set<String>()
        var offered: [String] = []
        for key in unreadable + unscored {
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            if tried.contains(key) { out.alreadyTried += 1; continue }
            if skip(key) { out.refused += 1; continue }
            offered.append(key)
        }
        out.offered = offered.count
        out.batch = Array(offered.sorted().prefix(max(0, limit)))
        return out
    }

    // --- what is still on disk ---------------------------------------------

    /// Which of these ABSOLUTE PATHS still name a file, checked off the main
    /// actor.
    ///
    /// **A `stat` is not free and this library is on a share.** Measured on the
    /// live store: ~1.9 ms per path against `/Volumes/media`, so asking about
    /// every candidate (2,933 of them, which is one real toggle's worth) is
    /// **5.6 seconds of blocked main thread** — the spinning ball, not a
    /// hiccup. The caller therefore checks only the BATCH it is about to run
    /// (≤ `wideningBatch`) and checks it here, where the UI keeps drawing.
    ///
    /// Takes absolute paths rather than keys deliberately: turning a key into a
    /// path reads `Paths`, which a test redirects, so that crossing gets done
    /// once on the caller's side rather than from another thread.
    nonisolated static func existing(_ paths: [String]) async -> (live: [String], gone: Int) {
        await Task.detached(priority: .userInitiated) {
            let live = paths.filter { FileManager.default.fileExists(atPath: $0) }
            return (live, paths.count - live.count)
        }.value
    }

    // --- the arithmetic ----------------------------------------------------

    /// One unit mean vector per video, skipping videos with nothing usable.
    static func videoMeans(_ videos: [(key: String, hashes: [String])],
                           read: (String) -> [Float]?) -> [[Double]] {
        videos.compactMap { meanVector($0.hashes, read: read) }
    }

    /// A video's mean frame vector, unit-normalised. Nil when no frame is cached
    /// or the frames cancel to a zero vector — both mean "cannot be compared",
    /// which is a different thing from "compared and found unlike".
    static func meanVector(_ hashes: [String], read: (String) -> [Float]?) -> [Double]? {
        var acc: [Double]?
        var n = 0
        for h in hashes {
            guard let vec = read(h) else { continue }
            if acc == nil { acc = [Double](repeating: 0, count: vec.count) }
            guard var a = acc, a.count == vec.count else { continue }
            for i in 0..<vec.count { a[i] += Double(vec[i]) }   // widened to float64, as engine.py's is
            acc = a
            n += 1
        }
        guard let a = acc, n > 0 else { return nil }
        return unit(a.map { $0 / Double(n) })
    }

    /// Elementwise mean, or nil for an empty list.
    static func mean(_ vectors: [[Double]]) -> [Double]? {
        guard let first = vectors.first else { return nil }
        var out = [Double](repeating: 0, count: first.count)
        for v in vectors {
            guard v.count == out.count else { continue }
            for i in 0..<out.count { out[i] += v[i] }
        }
        let n = Double(vectors.count)
        for i in 0..<out.count { out[i] /= n }
        return out
    }

    /// Unit vector, or nil when there is no direction to keep. Takes an optional
    /// so a missing mean and a directionless one are the same answer.
    static func unit(_ input: [Double]?) -> [Double]? {
        guard let v = input, !v.isEmpty else { return nil }
        var sum = 0.0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var out = 0.0
        for i in 0..<min(a.count, b.count) { out += a[i] * b[i] }
        return out
    }

    /// Four decimals, the way engine.py's `round(x, 4)` reports it.
    static func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
}
