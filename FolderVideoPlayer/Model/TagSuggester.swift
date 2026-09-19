import Foundation

/// engine.py's `suggest_tags` — every source merged into one ranked list.
///
/// Four sources produce candidate tags and each keeps its own provenance, which
/// the UI shows as a different icon per row:
///
/// | source        | icon                                  | what it means                        |
/// |---------------|---------------------------------------|--------------------------------------|
/// | `zeroshot`    | `sparkles`                            | a phrasing in the prompt vocabulary beat the bland pool |
/// | `trained`     | `checkmark.seal`                      | a head fitted from this user's own accept/reject clicks |
/// | `library`     | `books.vertical.fill`                 | the frames look like videos the user tagged with that name |
/// | `face`        | `person.crop.circle.badge.checkmark`  | a named person's face is in the video (**Phase 6**)  |
///
/// **The merge is not a union.** It is the thing that is easiest to get subtly
/// wrong, so it is written here the way engine.py writes it, in the same order:
///
///  1. zero-shot candidates, uncapped, in vocabulary order;
///  2. trained heads, in sorted tag order — a tag not yet offered is appended,
///     and a tag already offered is **replaced only when the head's confidence
///     is higher**, so the stronger evidence wins and the entry's `source`
///     changes with it;
///  3. the paired winner (see `pairedWinner`), one at most, decided pairwise;
///  4. library prototypes, same rule as the heads — higher confidence replaces,
///     otherwise the existing entry keeps its number and its source;
///  5. then sort by confidence, strongest first, and truncate to
///     `SUGGEST_MAX_TAGS` so the user is never buried in chips.
///
/// Order matters twice over: the sort is stable, so equal confidences keep
/// insertion order — and insertion order is steps 1-4. Swift's `sort` is not
/// stable, so the tie-break is written out rather than hoped for.
///
/// The face source is absent on purpose: identity needs a face embedder, and
/// Phase 0 found no clean conversion for one. `AICapability` refuses the
/// feature, so nothing downstream expects a `face` candidate from this path.
enum TagSuggester {

    /// One candidate, in the shape the engine reports and the store persists.
    struct Candidate: Equatable, Codable {
        var tag: String
        var confidence: Double
        var frames: Int
        var source: String
    }

    /// engine.py's `SUGGEST_MAX_TAGS`.
    static let maxTags = 8

    /// The bar a zero-shot frame must clear IN THE APP.
    ///
    /// engine.py's `SUGGEST_MARGIN` is 0.02, and that is still what the parity
    /// gates and the Python engine compare against. The app raises it because
    /// 0.02 is low enough that the tower's phrasing guesses become chips on
    /// footage that does not contain the thing at all.
    ///
    /// **The number is per embedding space, and it moved with the tower.** It
    /// was 0.06 for MobileCLIP-S2 (measured 2026-09-12 over 25 real analysed
    /// videos: 15.3 chips per video at 0.02, 9.5 at 0.04, 2.8 at 0.06). SigLIP 2
    /// B/16 writes much smaller margins for the same phrases — the reason is in
    /// `docs/coreml-spike/table_margin_compare.py`: its normalized cosines are
    /// compressed, a phrasing sits 0.86 from the bland pool where MobileCLIP put
    /// it at 0.92, with roughly a third the spread. So 0.06 in the new space is
    /// not a stricter 0.06, it is silence.
    ///
    /// Re-derived 2026-09-15 with `docs/coreml-spike/swap_quality.py`, the same
    /// 25-video probe run through BOTH towers on identically sampled frames
    /// (`engine.py`'s own fps/scale), chips per video:
    ///
    ///     bar         0.005  0.010  0.015  0.020  0.030  0.040  0.060
    ///     MobileCLIP   29.96  25.20  21.68  17.56  10.56   6.60   1.64
    ///     SigLIP 2      1.92   1.60   1.28   0.76   0.20   0.00   0.00
    ///
    /// ⚠️ The SigLIP 2 row is VOID (found 2026-09-16). The tower those numbers
    /// were read through returned the SAME vector for every frame — a dead fp16
    /// build (see `convert_siglip2_image.py`, which now builds float32). Every
    /// number in that row is the margin of a CONSTANT, so it describes no real
    /// image and no real tower. The MobileCLIP row is unaffected. Re-derive the
    /// SigLIP 2 column on a working tower before trusting the bar; until then
    /// 0.01 is a guess that happens to be no worse than the old tower's 0.06.
    ///
    /// 0.01 is chosen to match the old tower's 1.64 chips per video at 0.06
    /// (1.60 here) — the bar is transplanted by BEHAVIOUR, not by number, which
    /// is the only way to move it between two spaces without inventing a taste.
    /// The chips themselves are also better, on the same probe: SigLIP 2's
    /// best-matching phrases for cat clips are “a cat”, where MobileCLIP's were
    /// rows from the NSFW pool.
    ///
    /// What this CANNOT do is pick the right chip on a given video — raising the
    /// bar is the blunt instrument it looks like, and 25 videos is a probe, not
    /// a library. A full run over the analysed library should refine it.
    ///
    /// Deliberately NOT applied to the paired tags: their decision is a
    /// head-to-head difference between two tags, not a margin over the bland
    /// pool, so it keeps engine.py's number.
    static let vocabularyMargin: Float = 0.01

    /// The whole port: frames in, ranked candidates out.
    ///
    /// Everything it needs is handed in — the prompt table, the fitted heads,
    /// the prototypes and the library baseline — so this is pure arithmetic over
    /// values the analyse pass has already paid for, and so the parity test can
    /// drive it from a fixture without a model, a video or a GPU.
    static func suggest(table: PromptTable,
                        frames: [[Float]],
                        heads: TrainedHeads = TrainedHeads(),
                        paired: Bool = false,
                        margin: Float? = nil,
                        prototypes: [TagPrototypes.Prototype] = [],
                        baseline: [Double]? = nil,
                        faces: [String: Double] = [:],
                        priors: TagPriors = TagPriors(),
                        neighbours: NeighbourPrior = NeighbourPrior(),
                        maxTags: Int = TagSuggester.maxTags) -> [Candidate] {
        guard !frames.isEmpty else { return [] }
        let needed = PromptTable.minFrames(for: frames.count)

        // --- 1. zero-shot, uncapped, in vocabulary order --------------------
        var out: [Candidate] = table.zeroShotCandidates(vectors: frames, margin: margin).map {
            Candidate(tag: $0.tag, confidence: LookAlikes.round4($0.confidence),
                      frames: $0.frames, source: "zeroshot")
        }

        // --- 2. trained per-tag heads ----------------------------------------
        // Paired-tag heads (engine.py's `PAIRED_TAG_NAMES`) are excluded here
        // and handled pairwise below. `names` can be empty while heads exist —
        // a user who has trained ONLY the pair lands exactly here, which is the
        // case that used to crash the Python path on `np.stack([])`.
        let pairedNames = Set(table.pairedTags.map(\.name))
        let names = heads.tags.keys.filter { !pairedNames.contains($0) }.sorted()
        let dim = frames.first?.count ?? 0
        if !names.isEmpty, dim > 0, heads.dim == dim {
            var at: [String: Int] = [:]
            for (i, c) in out.enumerated() where at[c.tag] == nil { at[c.tag] = i }
            for name in names {
                guard let head = heads.tags[name], head.dim == dim else { continue }
                var hits = 0
                var best = -Float.greatestFiniteMagnitude
                for frame in frames {
                    let p = head.score(frame)
                    if p >= HeadTuning.cut { hits += 1 }      // `>=`, like engine.py's
                    if p > best { best = p }
                }
                guard hits >= needed else { continue }
                let confidence = LookAlikes.round4(Double(best))
                if let i = at[name] {
                    // Only a STRONGER claim replaces one already on the list.
                    if confidence > out[i].confidence {
                        out[i].confidence = confidence
                        out[i].frames = hits
                        out[i].source = "trained"
                    }
                } else {
                    at[name] = out.count
                    out.append(Candidate(tag: name, confidence: confidence,
                                         frames: hits, source: "trained"))
                }
            }
        }

        // --- 3. the pair, head to head, one winner at most ------------------
        if paired, let winner = pairedWinner(table: table, frames: frames,
                                             heads: heads, needed: needed) {
            out.append(winner)
        }

        // --- 4. library prototypes ------------------------------------------
        let library = TagPrototypes.score(frames: frames, prototypes: prototypes,
                                         baseline: baseline, minFrames: needed)
        var at: [String: Int] = [:]
        for (i, c) in out.enumerated() where at[c.tag] == nil { at[c.tag] = i }
        for cand in library {
            if let i = at[cand.tag] {
                if cand.confidence > out[i].confidence {
                    out[i].confidence = cand.confidence
                    out[i].frames = cand.frames
                    out[i].source = "library"
                }
            } else {
                at[cand.tag] = out.count
                out.append(Candidate(tag: cand.tag, confidence: cand.confidence,
                                     frames: cand.frames, source: cand.source))
            }
        }

        // --- 4b. face recognition --------------------------------------------
        //
        // A face match is the strongest evidence a PERSON tag can have: CLIP
        // only knows "there is a face", so a name it suggests is a guess about
        // a person, where a registry match is a measurement of one. So a face
        // hit takes the tag over from any other source outright, and only a
        // better face cosine replaces a face cosine.
        //
        // IN PLACE, unlike `engine.py`, which builds a SECOND entry for the tag
        // and leaves the first one in the list — two chips for one person, the
        // weaker one still carrying "library" as its source. Nothing downstream
        // wants that, and the app would have to de-duplicate before drawing.
        // (`faces` is empty unless a name is bound and a face matched, so the
        // parity fixtures, which have no registry, are unaffected.)
        if !faces.isEmpty {
            var byTag: [String: Int] = [:]
            for (i, c) in out.enumerated() where byTag[c.tag] == nil { byTag[c.tag] = i }
            for (name, best) in faces.sorted(by: { $0.key < $1.key }) {
                let confidence = LookAlikes.round4(best)
                if let i = byTag[name] {
                    if out[i].source != "face" {
                        out[i].confidence = confidence
                        out[i].frames = 1
                        out[i].source = "face"
                    } else if confidence > out[i].confidence {
                        out[i].confidence = confidence
                    }
                } else {
                    byTag[name] = out.count
                    out.append(Candidate(tag: name, confidence: confidence,
                                         frames: 1, source: "face"))
                }
            }
        }

        // --- 5. strongest first, ties keep insertion order -------------------
        //
        // With priors supplied, "strongest" means *furthest above that tag's own
        // habit* rather than highest raw margin — a broad tag like Speech beats
        // the background pool on any footage with a person in it and says
        // nothing about this video. Only the ORDER changes: every `confidence`
        // still carries the number the source produced, so the store, the UI and
        // the parity fixtures all keep reading the same quantity. An empty or
        // too-small `priors` scores by the raw margin, which is today's exact
        // behaviour.
        //
        // The cap is applied after this, so reordering also decides WHICH tags
        // survive the top-8 cut. That is the point: on the rig the first tag the
        // user accepted sat at median rank 5.5 of 8.
        // The neighbourhood is the second term: how much the videos shot around
        // this one agree about the tag, worth at most `NeighbourPrior.weight`
        // (0.02) — a third of `vocabularyMargin`, so it lifts a tag a couple of
        // places and can never carry a weak one over a strong one. It moves
        // candidates that already exist and never adds one, because a tag
        // nobody offered, appearing only because yesterday's clip carried it,
        // is a guess about content made from a timestamp.
        //
        // An empty `neighbours` returns 0 for every tag, so the key is exactly
        // the line above and today's behaviour is unchanged — which is what
        // every existing parity fixture relies on.
        let key = { (c: Candidate) in
            priors.rankingKey(tag: c.tag, confidence: c.confidence)
                + neighbours.bonus(tag: c.tag)
        }
        var ranked = out.enumerated().map { ($0.offset, $0.element) }
        ranked.sort { key($0.1) == key($1.1)
            ? $0.0 < $1.0
            : key($0.1) > key($1.1) }
        return Array(ranked.map { $0.1 }.prefix(maxTags))
    }

    // MARK: - the paired tags

    /// Decide between the table's two paired tags for one NSFW video — ONE
    /// winner, or none. engine.py's `_paired_winner`.
    ///
    /// The pair is a forced choice: a video cannot be both, so the two
    /// candidates are scored against EACH OTHER on every frame rather than each
    /// against the bland background pool. Scoring both against the background is
    /// what used to emit BOTH chips: a frame that suits either phrasing
    /// out-scores "a photo" for both.
    ///
    /// The side that wins more frames — and at least `_min_frames_for()` of them
    /// — is the only one offered. When the clip is genuinely ambiguous (no side
    /// wins clearly) no chip appears: the user can tag by hand, and that mark is
    /// what the next head learns from.
    ///
    /// A trained head, once the user has earned one, outranks the prompt guess —
    /// and a single trained head speaks alone, because its rejections have
    /// already taught it the other side.
    static func pairedWinner(table: PromptTable,
                             frames: [[Float]],
                             heads: TrainedHeads = TrainedHeads(),
                             needed: Int) -> Candidate? {
        guard !frames.isEmpty else { return nil }
        // A table without exactly one pair cannot decide it.
        guard table.pairedTags.count == 2 else { return nil }
        let first = table.pairedTags[0].name, second = table.pairedTags[1].name

        // Trained heads first: the user's own evidence outranks a rough guess.
        var trained: [String: [Float]] = [:]
        let dim = frames.first?.count ?? 0
        for name in [first, second] {
            guard let head = heads.tags[name], head.dim == dim else { continue }
            trained[name] = frames.map { head.score($0) }
        }
        if let pa = trained[first], let pb = trained[second] {
            var aWins = 0, bWins = 0
            for i in 0..<frames.count {
                if pa[i] >= pb[i] && pa[i] >= HeadTuning.cut { aWins += 1 }
                else if pb[i] > pa[i] && pb[i] >= HeadTuning.cut { bWins += 1 }
            }
            if aWins != bWins, max(aWins, bWins) >= needed {
                let tag = aWins > bWins ? first : second
                let p = tag == first ? pa : pb
                return Candidate(tag: tag,
                                 confidence: LookAlikes.round4(Double(p.max() ?? 0)),
                                 frames: max(aWins, bWins),
                                 source: "trained")
            }
            return nil
        }
        // One trained head and the other not yet earned: it speaks alone.
        //
        // `next(iter(trained))` in engine.py is insertion order — the pair's
        // first tag first — and a Swift dictionary has no order at all, so the
        // pair is walked explicitly.
        for name in [first, second] {
            guard let p = trained[name] else { continue }
            let hits = p.filter { $0 >= HeadTuning.cut }.count
            guard hits >= needed else { return nil }
            return Candidate(tag: name,
                             confidence: LookAlikes.round4(Double(p.max() ?? 0)),
                             frames: hits, source: "trained")
        }

        // Zero-shot: compare the two candidates on each frame, not the pool.
        let diff = frames.map { frame -> Float in
            let sims = table.vocabSimilarities(vector: frame)
            guard let a = sims.first(where: { $0.tag == first })?.value,
                  let b = sims.first(where: { $0.tag == second })?.value else { return 0 }
            return a - b
        }
        let bar = table.constants.suggestMargin
        let aWins = diff.filter { $0 >= bar }.count
        let bWins = diff.filter { $0 <= -bar }.count
        guard aWins != bWins, max(aWins, bWins) >= needed else { return nil }
        let tag = aWins > bWins ? first : second
        let side = tag == first ? diff : diff.map { -$0 }
        let confidence = (aWins + bWins) > 0
            ? Double(side.max() ?? bar)
            : Double(bar)
        return Candidate(tag: tag, confidence: LookAlikes.round4(confidence),
                         frames: max(aWins, bWins), source: "zeroshot")
    }
}
