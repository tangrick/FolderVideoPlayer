import Foundation

/// The SigLIP 2 B/16 prompt table — the text encoder's answers, precomputed.
///
/// The text half never ships: it is a multilingual 256k-vocabulary tower, larger
/// than the image model it scores against. It is only ever asked about a fixed
/// vocabulary, so its answers are baked by
/// `docs/coreml-spike/precompute_text_siglip2.py` into two files that sit beside
/// the image model:
///
///     <root>/tags/siglip2_base_prompts.f32   rows x 768 float32, unit-normalised
///     <root>/tags/siglip2_base_prompts.json  the row layout, the tag → rows map,
///                                            the constants, and the engine.py
///                                            hash they were read from
///
/// **The private overlay.** The published table carries only the general
/// vocabulary. The zero-shot NSFW pool and the paired tags are explicit by
/// nature and kept out of the public repo and its downloads; a user who has
/// them installs a second pair of files beside the first,
///
///     <root>/tags/siglip2_base_prompts.private.json / .private.f32
///
/// in the same format, and `init(root:)` appends its rows after the public
/// ones. Everything downstream sees one table. Without the overlay the NSFW
/// section is empty (`nsfwScore` returns nil — the shipped verdict is
/// Falconsai's anyway) and no paired tags exist.
///
/// Every number in a Swift verdict therefore comes from the same prompts the
/// Python engine scores with, addressed by row instead of by string. The rows
/// and their layout are built by the SAME code the MobileCLIP table used
/// (`precompute_text.build_rows`), so only the encoder changed.
///
/// **The margins in this space are not the old margins.** SigLIP 2's normalized
/// cosines are compressed relative to MobileCLIP-S2's (bland-pool cosine 0.86 vs
/// 0.92, spread roughly a third as wide), so `SUGGEST_MARGIN` and
/// `TagSuggester.vocabularyMargin` have to be re-derived here rather than
/// transplanted — measured in `table_margin_compare.py`.
///
/// **This is the preview classifier, not the shipped one.** Zero-shot NSFW on
/// the MobileCLIP predecessor measured AUC 0.669 in Phase 0, and Falconsai
/// (Phase 4) is what ships in either case. The table exists so the Core ML path
/// has an honest verdict to store, and so tag suggestions have their phrase
/// columns ready.
struct PromptTable {

    /// The tunables, read from engine.py rather than restated here. A verdict
    /// is only reproducible if the numbers that produced it are named.
    struct Constants: Equatable {
        let marginBias: Float              // MARGIN_BIAS
        let marginTemperature: Float       // MARGIN_TEMPERATURE
        let nsfwThreshold: Double          // NSFW_THRESHOLD
        let suggestMargin: Float           // SUGGEST_MARGIN
        let suggestMaxTags: Int            // SUGGEST_MAX_TAGS
        let sampleIntervalS: Double        // SAMPLE_INTERVAL_S
        let maxFrames: Int                 // MAX_FRAMES
        let sampleShortSide: Double        // SAMPLE_SHORT_SIDE
    }

    /// One suggestion candidate: its tag, and the rows of the table holding
    /// its phrasings (several per tag — CLIP is wording-sensitive, and the
    /// best phrasing is what counts).
    struct Tag: Equatable {
        let name: String
        let rows: Range<Int>
    }

    /// A tag that cleared the background pool on enough frames.
    struct Suggestion: Equatable {
        let tag: String
        let confidence: Double      // the best per-frame margin
        let frames: Int             // how many frames cleared SUGGEST_MARGIN
        let source: String          // "zeroshot" (trained heads are Phase D)
    }

    let version: Int
    let dim: Int
    let rowCount: Int
    /// rowCount × dim, row-major, unit-normalised — so a dot product with a
    /// unit frame vector IS the cosine similarity, as in the Python spike.
    let matrix: [Float]
    /// Empty when neither table carries the NSFW pool.
    let nSFW: Range<Int>
    let neutral: Range<Int>
    let background: Range<Int>
    let tags: [Tag]
    /// The mutually exclusive pair offered only on NSFW videos (see
    /// `TagSuggester.pairedWinner`). Empty unless the overlay supplies it.
    let pairedTags: [Tag]
    let constants: Constants
    /// The engine.py these rows were read from. Recorded, not enforced: a
    /// mismatch means the table is older than the engine, which is worth
    /// being able to see in a diagnostic rather than guessing at.
    let engineSHA: String
    let promptSHA: String

    /// The phrases themselves, one per row — empty on a table built before
    /// 2026-09-12, which is why every reader must tolerate an empty list.
    ///
    /// They exist so the app can answer "why did you suggest this?" with the
    /// actual sentence that won. Row numbers alone cannot: the app ships no
    /// engine.py, and a suggestion nobody can interrogate is one the user has
    /// to take on faith.
    let phrases: [String]

    static let slug = "siglip2_base_prompts"
    static let minimumVersion = 1
    /// A table NEWER than this app understands is refused rather than guessed
    /// at: a future version may reorder rows, and reading it with today's
    /// offsets would produce confident nonsense.
    static let currentVersion = 1

    // MARK: - where it lives

    /// Same directory as the image model it belongs to, because Phase 5's
    /// ModelDownloader ships them together.
    static func jsonURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/\(slug).json"))
    }

    static func binURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/\(slug).f32"))
    }

    /// The paired tags' names as the installed overlay declares them, in
    /// table order — for callers that have no table loaded (training). Empty
    /// without an overlay.
    static func installedPairedNames(root: String) -> [String] {
        struct Names: Decodable {
            struct Entry: Decodable { let tag: String }
            let pairedTags: [Entry]?
            enum CodingKeys: String, CodingKey { case pairedTags = "paired_tags" }
        }
        guard let data = FileManager.default.contents(atPath: overlayJSONURL(root: root).path),
              let names = try? JSONDecoder().decode(Names.self, from: data) else { return [] }
        return (names.pairedTags ?? []).map(\.tag)
    }

    /// The optional private overlay — see the type's comment.
    static func overlayJSONURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/\(slug).private.json"))
    }

    static func overlayBinURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/\(slug).private.f32"))
    }

    /// Both files present. Cheap, so the capability layer can ask without
    /// loading 346 KB of floats.
    nonisolated static func isInstalled(root: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: jsonURL(root: root).path),
              let size = (try? fm.attributesOfItem(atPath: binURL(root: root).path)[.size]) as? Int
        else { return false }
        return size > 0
    }

    // MARK: - loading

    /// The embedding space this table's rows were computed in. A table and an
    /// image tower from different spaces produce confident nonsense when
    /// scored against each other, so the pairing is checked at load — equal
    /// dimensions never imply equal spaces.
    ///
    /// Three states, deliberately distinct:
    ///  - bound and matching → normal operation;
    ///  - bound and DIFFERENT → `load` throws, the feature reports broken
    ///    rather than scoring vectors in a foreign space;
    ///  - absent on the table (pre-2026-09-16) or no space marker installed
    ///    → the legacy case: the table loads, nothing is refused. The next
    ///    installer run binds both sides going forward.
    static func spaceBindingError(root: String) -> String? {
        guard let installed = ModelSpace.read(root: root) else { return nil }
        guard let data = FileManager.default.contents(atPath: jsonURL(root: root).path),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              let bound = meta.spaceDigest else { return nil }
        if bound != installed.digest {
            return "the prompt table was computed for another embedding space — reinstall the matching model pack "
                 + "(table \(bound.prefix(12))…, installed \(installed.digest.prefix(12))…)"
        }
        return nil
    }

    init(root: String) throws {
        let json = Self.jsonURL(root: root)
        let bin = Self.binURL(root: root)
        guard let meta = FileManager.default.contents(atPath: json.path),
              let rows = FileManager.default.contents(atPath: bin.path) else {
            throw TableError.notInstalled(json.path)
        }
        let fm = FileManager.default
        var overlay: (json: Data, bin: Data)?
        if let oj = fm.contents(atPath: Self.overlayJSONURL(root: root).path),
           let ob = fm.contents(atPath: Self.overlayBinURL(root: root).path) {
            overlay = (oj, ob)
        }
        try self.init(json: meta, bin: rows, overlay: overlay,
                      installedSpace: ModelSpace.read(root: root))
    }

    /// The real work, split out so it is testable without a support dir.
    /// `installedSpace` is the identity recorded beside the artifacts, passed
    /// by the file-based init so the binding can be checked without reaching
    /// the disk from here.
    init(json: Data, bin: Data, overlay: (json: Data, bin: Data)? = nil,
         installedSpace: ModelSpace? = nil) throws {
        let meta: Meta
        do { meta = try JSONDecoder().decode(Meta.self, from: json) }
        catch { throw TableError.unreadable("prompts json: \(error)") }
        let base = try Self.validated(meta, bin: bin, installedSpace: installedSpace, what: "prompt table")

        // The overlay, if any, is appended after the public rows: same format,
        // same space, same width. Its sections and tags are offset to match.
        var flat = base
        var rowCount = meta.rows
        var nsfw = try Self.optionalRange(meta.layout["nsfw"], limit: meta.rows, key: "nsfw")
        var paired = try (meta.pairedTags ?? []).map {
            try Tag(name: $0.tag, rows: Self.range(of: $0, limit: meta.rows))
        }
        var phrases = meta.texts ?? []
        if let overlay {
            let extra: Meta
            do { extra = try JSONDecoder().decode(Meta.self, from: overlay.json) }
            catch { throw TableError.unreadable("private overlay json: \(error)") }
            guard extra.dim == meta.dim else {
                throw TableError.unreadable("the private overlay is \(extra.dim)-dim, the table \(meta.dim)")
            }
            if let a = extra.spaceDigest, let b = meta.spaceDigest, a != b {
                throw TableError.unreadable("the private overlay was computed for another embedding space")
            }
            let rows = try Self.validated(extra, bin: overlay.bin, installedSpace: installedSpace,
                                          what: "private overlay")
            let offset = meta.rows
            if let r = try Self.optionalRange(extra.layout["nsfw"], limit: extra.rows, key: "nsfw"),
               !r.isEmpty {
                nsfw = (r.lowerBound + offset)..<(r.upperBound + offset)
            }
            let extraPaired = try (extra.pairedTags ?? []).map {
                try Tag(name: $0.tag, rows: Self.range(of: $0, limit: extra.rows))
            }
            if !extraPaired.isEmpty {
                paired = extraPaired.map {
                    Tag(name: $0.name,
                        rows: ($0.rows.lowerBound + offset)..<($0.rows.upperBound + offset))
                }
            }
            // Phrase texts stay aligned with rows only if both sides carry them.
            phrases = (phrases.count == meta.rows && (extra.texts?.count ?? 0) == extra.rows)
                ? phrases + (extra.texts ?? []) : []
            flat += rows
            rowCount += extra.rows
        }

        func range(_ key: String) throws -> Range<Int> {
            guard let r = try Self.optionalRange(meta.layout[key], limit: meta.rows, key: key),
                  !r.isEmpty else {
                throw TableError.unreadable("prompt table layout has no usable '\(key)'")
            }
            return r
        }

        self.version = meta.version
        self.dim = meta.dim
        self.rowCount = rowCount
        self.matrix = flat
        self.nSFW = nsfw ?? 0..<0
        self.neutral = try range("neutral")
        self.background = try range("background")
        self.tags = try meta.tags.map { try Tag(name: $0.tag, rows: Self.range(of: $0, limit: meta.rows)) }
        self.pairedTags = paired
        self.engineSHA = meta.engineSha256
        self.promptSHA = meta.promptSha256
        self.phrases = phrases
        self.constants = Constants(
            marginBias: meta.constants.marginBias,
            marginTemperature: meta.constants.marginTemperature,
            nsfwThreshold: meta.constants.nsfwThreshold,
            suggestMargin: meta.constants.suggestMargin,
            suggestMaxTags: meta.constants.suggestMaxTags,
            sampleIntervalS: meta.constants.sampleIntervalS,
            maxFrames: meta.constants.maxFrames,
            sampleShortSide: meta.constants.sampleShortSide)
    }

    /// Version, emptiness, space binding and byte count — the checks both the
    /// table and its overlay must pass — then the rows as floats.
    private static func validated(_ meta: Meta, bin: Data, installedSpace: ModelSpace?,
                                  what: String) throws -> [Float] {
        guard meta.version >= Self.minimumVersion else {
            throw TableError.unreadable("\(what) version \(meta.version) is older than this app understands")
        }
        guard meta.version <= Self.currentVersion else {
            throw TableError.unreadable("\(what) version \(meta.version) is newer than this app understands")
        }
        guard meta.dim > 0, meta.rows > 0 else {
            throw TableError.unreadable("\(what) is empty")
        }
        // A table claiming a different space than the one installed is not
        // loadable. A table with no binding at all (legacy) loads anywhere.
        if let bound = meta.spaceDigest, let installed = installedSpace,
           bound != installed.digest {
            throw TableError.unreadable(
                "the \(what) was computed for another embedding space "
              + "(table \(bound.prefix(12))…, installed \(installed.digest.prefix(12))…) — reinstall the matching model pack")
        }
        let expected = meta.rows * meta.dim * MemoryLayout<Float>.size
        guard bin.count == expected else {
            throw TableError.unreadable(
                "\(what) is \(bin.count) bytes, expected \(expected) "
                + "(\(meta.rows) rows x \(meta.dim) floats) — truncated download?")
        }
        var flat = [Float](repeating: 0, count: meta.rows * meta.dim)
        _ = flat.withUnsafeMutableBytes { bin.copyBytes(to: $0) }
        return flat
    }

    /// A layout section, or nil when the table does not have one. An empty
    /// pair ([n, n]) is allowed and means "none"; anything out of bounds is not.
    private static func optionalRange(_ pair: [Int]?, limit: Int, key: String) throws -> Range<Int>? {
        guard let pair else { return nil }
        guard pair.count == 2, pair[0] >= 0, pair[1] <= limit, pair[0] <= pair[1] else {
            throw TableError.unreadable("prompt table layout has no usable '\(key)'")
        }
        return pair[0]..<pair[1]
    }

    private static func range(of tag: Meta.TagMeta, limit: Int) throws -> Range<Int> {
        guard tag.rows.count == 2, tag.rows[0] >= 0, tag.rows[1] <= limit,
              tag.rows[0] < tag.rows[1] else {
            throw TableError.unreadable("tag '\(tag.tag)' has no usable rows")
        }
        return tag.rows[0]..<tag.rows[1]
    }

    // MARK: - scoring

    /// Cosine similarity of one frame vector against one table row.
    /// Both sides are unit-normalised, so this is a plain dot product.
    func similarity(_ row: Int, _ vector: [Float]) -> Float {
        let base = row * dim
        var sum: Float = 0
        for i in 0..<min(dim, vector.count) { sum += matrix[base + i] * vector[i] }
        return sum
    }

    /// The zero-shot NSFW score for one frame — engine.py's formula, and the
    /// one `compare_accuracy.py` measured AUC 0.669 with:
    ///
    ///     margin = max(sim(NSFW pool)) - max(sim(neutral pool)) - MARGIN_BIAS
    ///     score  = sigmoid(MARGIN_TEMPERATURE * margin)
    ///
    /// Aggregation across frames is the caller's business (the engine takes
    /// the max), because one video's frames are not one video's verdict.
    /// Nil when no NSFW pool is installed (see the private overlay).
    func nsfwScore(vector: [Float]) -> Double? {
        guard !nSFW.isEmpty else { return nil }
        var nsfwMax = -Float.greatestFiniteMagnitude
        var neutralMax = -Float.greatestFiniteMagnitude
        for r in nSFW { nsfwMax = max(nsfwMax, similarity(r, vector)) }
        for r in neutral { neutralMax = max(neutralMax, similarity(r, vector)) }
        let margin = Double(nsfwMax - neutralMax) - Double(constants.marginBias)
        return 1.0 / (1.0 + exp(-Double(constants.marginTemperature) * margin))
    }

    /// The best background phrase for one frame — the bland pool every
    /// candidate has to beat, and the same quantity the tag margins subtract.
    func backgroundBest(vector: [Float]) -> Float {
        var best = -Float.greatestFiniteMagnitude
        for r in background { best = max(best, similarity(r, vector)) }
        return best
    }

    /// Which phrase scored best for one tag on one frame, with its numbers.
    ///
    /// This is the evidence behind a chip. Without the phrase texts (a table
    /// built before 2026-09-12) it returns nil and the UI omits the line rather
    /// than inventing one.
    func bestPhrasing(for tag: Tag, vector: [Float]) -> (phrase: String, row: Int, sim: Float)? {
        guard !phrases.isEmpty else { return nil }
        var best: (row: Int, sim: Float)?
        for r in tag.rows where r < phrases.count {
            let s = similarity(r, vector)
            if best == nil || s > best!.sim { best = (r, s) }
        }
        guard let b = best else { return nil }
        return (phrases[b.row], b.row, b.sim)
    }

    /// The bland phrase the tag had to beat, and by how much. `a photo` beating
    /// nothing is the whole reason a bar exists.
    func bestBackgroundPhrasing(vector: [Float]) -> (phrase: String, row: Int, sim: Float)? {
        guard !phrases.isEmpty else { return nil }
        var best: (row: Int, sim: Float)?
        for r in background where r < phrases.count {
            let s = similarity(r, vector)
            if best == nil || s > best!.sim { best = (r, s) }
        }
        guard let b = best else { return nil }
        return (phrases[b.row], b.row, b.sim)
    }

    /// The per-frame margin for every suggestion tag: best phrasing of the tag
    /// against the best background phrase. Deliberately NOT a softmax across
    /// tags — "none of these" has to stay reachable (see engine.py's note on
    /// the Sep 2026 probe, where a forced choice fired "wedding" on living
    /// rooms).
    ///
    /// Returns the tags in table order; the paired tags are excluded,
    /// because they are decided head-to-head and only ever for NSFW videos.
    func tagMargins(vector: [Float]) -> [(tag: String, margin: Float)] {
        let backgroundBest = self.backgroundBest(vector: vector)
        return tags.map { tag in
            var best = -Float.greatestFiniteMagnitude
            for r in tag.rows { best = max(best, similarity(r, vector)) }
            return (tag.name, best - backgroundBest)
        }
    }

    /// Best-phrase similarity for EVERY vocabulary entry, the pair included,
    /// in engine.py's `vocab` order — the suggestion tags first, then the
    /// paired tags (`SUGGEST_VOCAB + PAIRED_VOCAB`).
    ///
    /// These are raw cosines, not margins: the pair decision compares one tag
    /// against the other on the same frame, and only then against a bar — a
    /// difference of two margins would cancel the background term out anyway,
    /// but engine.py takes the difference of the raw values and the port
    /// follows it to the digit.
    func vocabSimilarities(vector: [Float]) -> [(tag: String, value: Float)] {
        (tags + pairedTags).map { tag in
            var best = -Float.greatestFiniteMagnitude
            for r in tag.rows { best = max(best, similarity(r, vector)) }
            return (tag.name, best)
        }
    }

    /// How many frames must support a tag, given how many frames exist —
    /// engine.py's `_min_frames_for`. Short clips get one frame's benefit of
    /// the doubt; longer ones must show the subject persisting.
    static func minFrames(for frames: Int) -> Int {
        if frames <= 3 { return 1 }
        if frames <= 10 { return 2 }
        return 3
    }

    /// The zero-shot pass over one video's frames, in engine.py's order and
    /// with its bar: a tag needs `minFrames(for:)` frames at or above
    /// SUGGEST_MARGIN. **Uncapped and unsorted** — vocabulary order, exactly
    /// the list engine.py builds before it merges the trained heads, the
    /// paired winner and the library prototypes, and only then sorts and
    /// truncates. Truncating here would silently drop a tag that a later source
    /// was about to promote.
    ///
    /// `margin` overrides the table's SUGGEST_MARGIN. The default is the
    /// engine's own number so the parity gates keep comparing against Python;
    /// the app passes `TagSuggester.vocabularyMargin`, which is higher.
    func zeroShotCandidates(vectors: [[Float]], margin: Float? = nil) -> [Suggestion] {
        guard !vectors.isEmpty else { return [] }
        let needed = Self.minFrames(for: vectors.count)
        let bar = margin ?? constants.suggestMargin
        var hits = [Int](repeating: 0, count: tags.count)
        var strength = [Float](repeating: -Float.greatestFiniteMagnitude, count: tags.count)
        for vector in vectors {
            for (i, m) in tagMargins(vector: vector).enumerated() {
                if m.margin >= bar { hits[i] += 1 }
                strength[i] = max(strength[i], m.margin)
            }
        }
        var out: [Suggestion] = []
        for (i, tag) in tags.enumerated() where hits[i] >= needed {
            out.append(Suggestion(tag: tag.name,
                                  confidence: Double(strength[i]),
                                  frames: hits[i],
                                  source: "zeroshot"))
        }
        return out
    }

    /// The zero-shot pass, ranked and capped — what a caller wants when there is
    /// nothing to merge with, so "the top 8 tags" is the whole answer.
    ///
    /// Strongest first, and equal confidences keep vocabulary order: engine.py's
    /// sort is stable and Swift's is not, so the tie-break is written out.
    func suggestions(vectors: [[Float]], margin: Float? = nil) -> [Suggestion] {
        var ranked = zeroShotCandidates(vectors: vectors, margin: margin)
            .enumerated().map { ($0.offset, $0.element) }
        ranked.sort { $0.1.confidence == $1.1.confidence
            ? $0.0 < $1.0
            : $0.1.confidence > $1.1.confidence }
        return Array(ranked.map { $0.1 }.prefix(constants.suggestMaxTags))
    }

    // MARK: - the declared format

    private struct Meta: Decodable {
        struct ConstMeta: Decodable {
            let marginBias: Float
            let marginTemperature: Float
            let nsfwThreshold: Double
            let suggestMargin: Float
            let suggestMaxTags: Int
            let sampleIntervalS: Double
            let maxFrames: Int
            let sampleShortSide: Double

            enum CodingKeys: String, CodingKey {
                case marginBias = "MARGIN_BIAS"
                case marginTemperature = "MARGIN_TEMPERATURE"
                case nsfwThreshold = "NSFW_THRESHOLD"
                case suggestMargin = "SUGGEST_MARGIN"
                case suggestMaxTags = "SUGGEST_MAX_TAGS"
                case sampleIntervalS = "SAMPLE_INTERVAL_S"
                case maxFrames = "MAX_FRAMES"
                case sampleShortSide = "SAMPLE_SHORT_SIDE"
            }
        }
        struct TagMeta: Decodable {
            let tag: String
            let rows: [Int]
        }

        let version: Int
        let dim: Int
        let rows: Int
        let layout: [String: [Int]]
        let tags: [TagMeta]
        /// Only the private overlay carries these; absent on the public table.
        let pairedTags: [TagMeta]?
        let constants: ConstMeta
        let engineSha256: String
        let promptSha256: String
        /// Absent on tables built before 2026-09-12 — optional on purpose, so an
        /// older table still loads and the UI degrades to "no phrase detail"
        /// rather than failing to open. See `PromptTable.phrases`.
        let texts: [String]?
        /// The space this table was computed in. Absent on legacy tables;
        /// optional so they still decode (Codable new-field trap).
        let spaceDigest: String?

        enum CodingKeys: String, CodingKey {
            case version, dim, rows, layout, tags, constants, texts
            case pairedTags = "paired_tags"
            case engineSha256 = "engine_py_sha256"
            case promptSha256 = "prompt_sha256"
            case spaceDigest = "space_digest"
        }
    }

    enum TableError: Error, LocalizedError, CustomStringConvertible {
        case notInstalled(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .notInstalled(let p): return "the prompt table is not installed at \(p)"
            case .unreadable(let why): return "the prompt table could not be read — \(why)"
            }
        }

        /// So the Analysis window's broken-state text is this sentence rather
        /// than "the operation couldn't be completed (…error 0)".
        var errorDescription: String? { description }
    }
}
