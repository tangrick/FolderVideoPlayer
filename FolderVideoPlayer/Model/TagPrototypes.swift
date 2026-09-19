import Foundation

/// engine.py's Phase D tag maths: the prototypes built from the videos the user
/// has already tagged, and the margin rule that turns a video's frames into
/// suggestions. Pure arithmetic over the embedding cache — no model, no ffmpeg,
/// no GPU — so it is cheap enough to run whenever a video is analysed.
///
/// Ported from `_library_prototypes`, `_library_baseline` and
/// `_score_library_tags`. The arithmetic itself (`mean`, `unit`, `dot`,
/// `round4`) lives in `LookAlikes` — the same sums, so a fix lands in one place.
///
/// Two things here are deliberately NOT the same as `LookAlikes`:
///   - the baseline walks the whole cache directory, where `tag_candidates`
///     builds its own baseline from the request;
///   - a video's frames are averaged and used RAW, where `TagCandidates`'
///     per-video means are unit-normalised first. Two videos of different
///     lengths therefore weigh differently. That is engine.py's behaviour.
enum TagPrototypes {

    /// engine.py `LIBRARY_TAG_MARGIN` — what a frame must clear to count.
    static let margin = 0.10

    /// engine.py `LIBRARY_TAG_MIN_VIDEOS` — fewer, and the "prototype" is one
    /// video's noise rather than a tag.
    static let minVideos = 2

    /// The shape the app sends: {tag: {videoKey: [frameHash]}}.
    typealias TaggedVideos = [(tag: String, videos: [(key: String, hashes: [String])])]

    /// The payload the app already builds for the Python engine, turned into the
    /// list this type works with.
    ///
    /// Sorted by tag and then by video key, because a Swift `Dictionary` has no
    /// order at all and prototype order decides the merge's tie-breaks — an
    /// answer that could change between two runs over the same library would be
    /// indefensible. (The Python path hands engine.py whatever order its
    /// dictionary happens to have; that is engine.py's behaviour and is left
    /// exactly as it is.)
    static func taggedVideos(_ payload: [String: [String: [String]]]) -> TaggedVideos {
        payload.keys.sorted().map { tag in
            let videos = payload[tag] ?? [:]
            return (tag: tag,
                    videos: videos.keys.sorted().map { (key: $0, hashes: videos[$0] ?? []) })
        }
    }

    /// What the suggester merges with its zero-shot and trained candidates.
    struct Candidate: Equatable, Codable {
        var tag: String
        var confidence: Double
        var frames: Int
        var source: String = "library"
    }

    struct Prototype: Equatable {
        var tag: String
        var vector: [Double]
    }

    // MARK: - the library baseline

    /// Every frame hash in the cache: engine.py lists `<cache>/<slug>/<xx>/*.f32`
    /// and keeps the two levels. Sorted, so the answer does not depend on the
    /// order the filesystem happens to hand the names over.
    static func hashes(inCache root: String, slug: String) -> [String] {
        let dir = (root as NSString).appendingPathComponent(slug)
        let fm = FileManager.default
        guard let subs = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [String] = []
        for sub in subs.sorted() {
            let d = (dir as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue else { continue }
            for name in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).sorted()
            where name.hasSuffix(".f32") {
                out.append(String(name.dropLast(4)))
            }
        }
        return out
    }

    /// The mean of every cached vector, unit-normalised: "the typical video in
    /// this library". Margins are measured against this rather than against
    /// zero, where everything scores 0.6+ and nothing separates.
    ///
    /// Nil where the cache holds nothing usable — engine.py returns a 1-wide
    /// zero vector there, and every caller treats it as a refusal. A vector of
    /// the wrong width is skipped: engine.py's guard lives in `_cache_read`
    /// (`_embed_dim`), and it has to live somewhere on this side too, or a
    /// vector from another model quietly joins the mean.
    ///
    /// engine.py memoises this in `_library_mean`, which is easy to be bitten
    /// by: a second call answers from the *first* call's tree, however much the
    /// cache has moved on. This port is pure — the caller caches it if it wants
    /// to (the suggester runs it once per video, so it should).
    static func baseline(hashes: [String], dim: Int,
                         read: (String) -> [Float]?) -> [Double]? {
        var acc: [Double]?
        var n = 0
        for h in hashes {
            guard let vec = read(h), vec.count == dim else { continue }
            if acc == nil { acc = [Double](repeating: 0, count: dim) }
            guard var a = acc else { continue }
            for i in 0..<dim { a[i] += Double(vec[i]) }
            acc = a
            n += 1
        }
        guard let a = acc, n > 0 else { return nil }
        return LookAlikes.unit(a.map { $0 / Double(n) })
    }

    // MARK: - the prototypes

    /// One unit vector per user tag, from the videos already carrying that tag.
    ///
    /// The tag's map is measured BEFORE any frame is read, exactly as engine.py
    /// does: two tagged videos that were never analysed are a tag with no
    /// prototype, not a tag with a prototype built from whatever was cached.
    ///
    /// `excluding` is engine.py's `PAIRED_TAG_NAMES` — the table's paired
    /// tags, which have their own head-to-head machinery and never become
    /// library prototypes. Compared case-sensitively, as engine.py does.
    static func prototypes(_ tagged: TaggedVideos,
                           excluding: Set<String> = [],
                           read: (String) -> [Float]?) -> [Prototype] {
        var out: [Prototype] = []
        for (tag, videos) in tagged {
            if excluding.contains(tag) { continue }
            if videos.count < minVideos { continue }
            let perVideo = videos
                .filter { !$0.hashes.isEmpty }
                .compactMap { rawMeanVector($0.hashes, read: read) }
            if perVideo.count < minVideos { continue }
            guard let m = LookAlikes.mean(perVideo),
                  let u = LookAlikes.unit(m) else { continue }
            out.append(Prototype(tag: tag, vector: u))
        }
        return out
    }

    /// A video's frames averaged — NOT unit-normalised, unlike `LookAlikes`.
    /// This is what `_library_prototypes` feeds into the tag mean, and the
    /// difference is measurable: normalising here changes which tags fire.
    static func rawMeanVector(_ hashes: [String],
                              read: (String) -> [Float]?) -> [Double]? {
        var acc: [Double]?
        var n = 0
        for h in hashes {
            guard let vec = read(h) else { continue }
            if acc == nil { acc = [Double](repeating: 0, count: vec.count) }
            guard var a = acc, a.count == vec.count else { continue }
            for i in 0..<vec.count { a[i] += Double(vec[i]) }   // float32 widened, as engine.py's is
            acc = a
            n += 1
        }
        guard let a = acc, n > 0 else { return nil }
        return a.map { $0 / Double(n) }
    }

    // MARK: - the suggestion

    /// The tags whose prototype these frames clear the library baseline by at
    /// least `margin`, on at least `minFrames` frames.
    ///
    /// The margin is `(prototype − baseline) · frame`: how far this frame sits
    /// above the library's average video in the direction that tag points, not
    /// how similar it is to the tag. Absolute similarity is useless here —
    /// every video resembles every tag — and the existing UserTagSuggester
    /// margins are measured the same way, so the numbers are comparable.
    ///
    /// `confidence` is the best margin of any frame, `frames` the number of
    /// frames that cleared the line; the caller merges on `confidence`.
    static func score(frames: [[Float]],
                      prototypes: [Prototype],
                      baseline: [Double]?,
                      minFrames: Int) -> [Candidate] {
        guard !prototypes.isEmpty, let first = frames.first else { return [] }
        guard let base = baseline, base.count == first.count else { return [] }
        var ranked: [(index: Int, candidate: Candidate)] = []
        for (index, p) in prototypes.enumerated() {
            guard p.vector.count == base.count else { continue }
            let delta = (0..<base.count).map { p.vector[$0] - base[$0] }
            var hits = 0
            var best = -Double.infinity
            for frame in frames {
                guard frame.count == base.count else { continue }
                var m = 0.0
                for i in 0..<base.count { m += Double(frame[i]) * delta[i] }
                if m >= margin { hits += 1 }      // >= , like engine.py's
                if m > best { best = m }
            }
            guard hits >= minFrames, best > -Double.infinity else { continue }
            ranked.append((index, Candidate(tag: p.tag,
                                            confidence: LookAlikes.round4(best),
                                            frames: hits,
                                            source: "library")))
        }
        // engine.py's sort is stable, so equal confidences keep prototype order.
        ranked.sort { $0.candidate.confidence == $1.candidate.confidence
                      ? $0.index < $1.index
                      : $0.candidate.confidence > $1.candidate.confidence }
        return ranked.map { $0.candidate }
    }
}
