import Foundation

/// Why a suggestion appeared — the evidence behind one chip.
///
/// ## Why this exists
///
/// A chip says "Sightseeing" and nothing else. The user's reasonable question is
/// "says who?", and until now the app had no answer: `SuggestionStore` keeps only
/// a confidence and a frame count. The maintainer asked for exactly this ("is there a
/// way to select a tag that it suggest and see why it suggest?"), and it is the
/// difference between a list you can audit and one you have to take on faith.
///
/// ## Recomputed, never stored
///
/// The frame vectors are already cached, so the explanation is recomputed when
/// asked rather than written into `suggestions.json` — 8 chips × 556 videos of
/// evidence would be a lot of JSON for something looked at occasionally, and a
/// stored explanation can go stale in a way that a recomputed one cannot.
struct SuggestionExplanation: Equatable {

    /// One frame that agreed with the tag.
    struct Hit: Equatable {
        let hash: String
        let at: Double          // seconds into the video
        let margin: Double      // how far it cleared the bar
    }

    /// How the rest of the vocabulary did on this video.
    ///
    /// Without this the panel could only ever DEFEND a chip — its winning
    /// phrase, its best frames — and never let the user check it. "Cruise Ship
    /// beat 'an ordinary moment' by 0.0508" reads like evidence; "34 of 52 tags
    /// cleared the same bar here" is the fact that settles whether it is.
    struct Vocabulary: Equatable {
        let cleared: Int
        let total: Int
    }

    let tag: String
    let source: String
    /// The strongest per-frame margin, i.e. the number the chip shows.
    let confidence: Double
    let framesSeen: Int
    let framesAgreed: Int
    /// Nil for the sources where how the vocabulary scored says nothing.
    let vocabulary: Vocabulary?
    /// `SUGGEST_MARGIN` — the bar each frame had to clear.
    let bar: Double

    /// The phrase that actually won, for a zero-shot chip. Nil when the table
    /// has no phrase texts (an older table) — the UI then omits the line rather
    /// than inventing one.
    let winningPhrase: String?
    /// The bland phrase it had to beat, and that phrase's similarity.
    let poolPhrase: String?
    let poolBest: Double?
    /// The frames that agreed, strongest first.
    let hits: [Hit]

    /// A library chip: the user's own videos this was learned from.
    let learnedFrom: [String]
    /// A trained chip: how many frames cleared the head's cut.
    let headAgreed: Int?
    /// A face chip: the person matched.
    let person: String?

    /// The one-line summary the panel leads with.
    var headline: String {
        switch source {
        case "library":
            return learnedFrom.isEmpty
                ? "Looks like your other videos for this tag."
                : "Learned from \(learnedFrom.count) of your videos tagged “\(tag)”."
        case "trained":
            if let n = headAgreed { return "Your own trained head for “\(tag)”: \(n) of \(framesSeen) frames." }
            return "From the head you trained for “\(tag)”."
        case "face":
            if let p = person { return "The face you named “\(p)” appears in this video." }
            return "A face you named appears in this video."
        default:
            var line = "\(framesAgreed) of \(framesSeen) frames cleared the bar for “\(tag)” "
                     + "— a wording match, not a detection."
            if let v = vocabulary {
                line += v.cleared <= 1
                    ? " It was the only tag above the bar here."
                    : " \(v.cleared) of \(v.total) tags cleared the same bar here."
            }
            return line
        }
    }
}

/// Builds a `SuggestionExplanation` from the same inputs the suggester used.
///
/// Pure arithmetic over cached vectors — no model, no video decode — so the
/// gate can drive it from a fixture and the UI can call it without a stall.
enum SuggestionWhy {

    /// One frame as the explanation sees it.
    struct Frame {
        let vector: [Float]
        let hash: String
        let at: Double
    }

    /// - Parameters:
    ///   - source: which source offered the chip; zero-shot is explained in
    ///     full, the other three report the evidence they own.
    ///   - learnedFrom: for `library`, the video keys that fed the prototype.
    ///   - head: for `trained`, the fitted head so its hits can be counted.
    static func explain(table: PromptTable,
                        tag: String,
                        source: String,
                        frames: [Frame],
                        learnedFrom: [String] = [],
                        head: LogisticHead? = nil,
                        margin: Float? = nil,
                        person: String? = nil) -> SuggestionExplanation? {
        guard !frames.isEmpty else { return nil }
        // The bar the chip was actually offered against — the caller passes the
        // one it used, so the panel cannot explain a chip with a bar the app
        // never applied. The table's own constant is only the fallback, and it
        // is engine.py's (SUGGEST_MARGIN), which is a DIFFERENT bar from
        // `TagSuggester.vocabularyMargin` in a different space.
        let bar = Double(margin ?? table.constants.suggestMargin)

        // --- trained: the head's own count --------------------------------
        if source == "trained", let head {
            let scores = frames.map { Double(head.score($0.vector)) }
            let agreed = scores.filter { $0 >= Double(HeadTuning.cut) }.count
            let hits = zip(frames, scores)
                .filter { $0.1 >= Double(HeadTuning.cut) }
                .map { SuggestionExplanation.Hit(hash: $0.0.hash, at: $0.0.at,
                                                margin: LookAlikes.round4($0.1)) }
                .sorted { $0.margin > $1.margin }
            return SuggestionExplanation(
                tag: tag, source: source,
                confidence: LookAlikes.round4(scores.max() ?? 0),
                framesSeen: frames.count, framesAgreed: agreed, vocabulary: nil,
                bar: Double(HeadTuning.cut),
                winningPhrase: nil, poolPhrase: nil, poolBest: nil, hits: hits,
                learnedFrom: [], headAgreed: agreed, person: person)
        }

        // --- library: the user's own tagged videos ARE the evidence -------
        if source == "library" {
            return SuggestionExplanation(
                tag: tag, source: source, confidence: 0,
                framesSeen: frames.count, framesAgreed: 0, vocabulary: nil, bar: 0,
                winningPhrase: nil, poolPhrase: nil, poolBest: nil, hits: [],
                learnedFrom: learnedFrom, headAgreed: nil, person: person)
        }

        // --- face -----------------------------------------------------------
        if source == "face" {
            return SuggestionExplanation(
                tag: tag, source: source, confidence: 0,
                framesSeen: frames.count, framesAgreed: 0, vocabulary: nil, bar: 0,
                winningPhrase: nil, poolPhrase: nil, poolBest: nil, hits: [],
                learnedFrom: [], headAgreed: nil, person: person ?? tag)
        }

        // --- zero-shot: the phrase, the pool, and the frames that agreed ----
        guard let tagRow = (table.tags + table.pairedTags).first(where: { $0.name == tag })
        else { return nil }

        var hits: [SuggestionExplanation.Hit] = []
        var best: (phrase: String, row: Int, sim: Float)?
        var pool: (phrase: String, row: Int, sim: Float)?
        var strongest = -Double.greatestFiniteMagnitude
        var agreed = 0

        for frame in frames {
            let top = table.bestPhrasing(for: tagRow, vector: frame.vector)
            let bg = table.bestBackgroundPhrasing(vector: frame.vector)
            guard let top, let bg else { continue }
            let margin = Double(top.sim - bg.sim)
            if margin > strongest {
                strongest = margin
                best = top
                pool = bg
            }
            if margin >= bar {
                agreed += 1
                hits.append(SuggestionExplanation.Hit(hash: frame.hash, at: frame.at,
                                                      margin: LookAlikes.round4(margin)))
            }
        }
        guard strongest > -Double.greatestFiniteMagnitude else { return nil }
        hits.sort { $0.margin > $1.margin }

        // How the whole vocabulary did on this video, at the SAME bar this chip
        // was offered against. Asked of the suggester rather than recounted, so
        // the panel cannot disagree with the reason the chip exists.
        let cleared = table.zeroShotCandidates(vectors: frames.map(\.vector), margin: margin).count

        return SuggestionExplanation(
            tag: tag, source: "zeroshot",
            confidence: LookAlikes.round4(strongest),
            framesSeen: frames.count, framesAgreed: agreed,
            vocabulary: SuggestionExplanation.Vocabulary(cleared: cleared,
                                                         total: table.tags.count),
            bar: bar,
            winningPhrase: best?.phrase, poolPhrase: pool?.phrase,
            poolBest: pool.map { LookAlikes.round4(Double($0.sim)) },
            hits: hits, learnedFrom: [], headAgreed: nil, person: person)
    }
}
