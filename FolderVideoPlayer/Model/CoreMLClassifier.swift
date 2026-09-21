import Foundation
import AVFoundation

/// One video's Core ML verdict, in the same shape the store already stores.
struct CoreMLVerdict {
    let prediction: NsfwPrediction
    let frames: [FrameScore]
}

/// Classify, the Core ML way — the Swift half of `analyse_video`.
///
/// Same pipeline, same record: sample frames (`FrameSampler`, engine parity),
/// score each one for NSFW with the shipped Falconsai model (`NSFWClassifier`,
/// 224×224), embed each one with SigLIP 2 B/16 (`VisionEmbedder`, 768-dim) so the
/// vectors land in the cache under `frames/siglip2_base/`, and hand the store an
/// `NsfwPrediction` + `[FrameScore]` it cannot tell from the Python engine's.
/// The frame hash it records is the cache key under `frames/siglip2_base/`, so
/// a later pass (a retrained head, a retuned prompt set, the look-alike search)
/// reuses the vector instead of paying for the GPU again — the reason hashes are
/// stored at all.
///
/// **Two models, two jobs, one record.** Falconsai decides Safe/NSFW. The vision
/// tower still embeds every frame, because its vectors are what every later pass
/// reads — the four suggestion sources, the look-alike search, the library
/// prototypes — so most of a pass is still spent on it even though the verdict
/// no longer needs it. The record names both: `modelID` is the EMBEDDING space
/// (the namespace a frame's vector file lives in), and `classifier` is the model
/// that produced the score (`falconsai-nsfw-v1`).
///
/// **The zero-shot margin is no longer the verdict.** `PromptTable.nsfwScore`
/// (AUC 0.669 on the MobileCLIP predecessor in Phase 0) was the interim answer
/// while the port was under way; now nothing stores it. The table keeps its NSFW
/// columns and `Tests/run_prompt_table.sh` still checks them against numpy — that
/// is the table's own gate — but Classify asks Falconsai.
///
/// This is the engine a downloaded DMG runs (see `Mode`); the Python child is
/// reached only by asking for it. Three embedding spaces now exist on disk
/// (768-dim ViT-L/14, 512-dim MobileCLIP-S2, 768-dim SigLIP 2) and they are
/// mutually incomparable, so they must never mix verdicts in one library — the
/// slug in the cache path is what keeps them apart.
actor CoreMLClassifier {

    /// Which engine this process runs.
    enum Mode: String {
        case python      // the child process: engine.py + torch + ffmpeg
        case coreml      // in-process: no python, no ffmpeg, no subprocess
    }

    /// Core ML is the DEFAULT, because it is what ships. A DMG lands on a Mac
    /// with no Python, no torch and no ffmpeg, so a stranger has to get the
    /// in-process engine without configuring anything — the Python path is a
    /// development tool now, not the fallback. `mode=python` in
    /// `~/.fvp-engine` (or `FVP_ENGINE=python` for one launch) selects it.
    nonisolated static var mode: Mode {
        mode(environment: ProcessInfo.processInfo.environment["FVP_ENGINE"],
             override: DevOverride.values)
    }

    /// The decision as a pure function, so the gate can drive every combination
    /// without needing a file on disk or an environment it cannot unset.
    ///
    /// Precedence, and the reason for each rung:
    ///
    /// 1. **`FVP_ENGINE`, when it says something.** The harnesses `setenv` it,
    ///    and it is the only way to choose an engine for a single launch.
    ///    `python` selects the child; everything else — `coreml`, a misspelling,
    ///    whitespace — falls to the default rather than quietly changing engine.
    /// 2. **`mode=python` in the dev override file**, which is how the Python
    ///    path stays available day to day without touching the project.
    /// 3. **Core ML.** This is not a migration switch that has been left off; it
    ///    is the engine a downloaded DMG runs.
    ///
    /// The old rule required `mode=coreml` to arrive WITH a `support` directory,
    /// so Core ML could not be pointed at the real library by accident. The
    /// guard is gone because the situation inverted: Core ML against the default
    /// library is now the shipped arrangement, so the accident to prevent is a
    /// Core ML-space library being opened by the Python engine instead. That
    /// takes a deliberate `mode=python`, which names itself.
    nonisolated static func mode(environment: String?, override: [String: String]) -> Mode {
        if let raw = environment?.trimmingCharacters(in: .whitespaces).lowercased(),
           !raw.isEmpty {
            return raw == Mode.python.rawValue ? .python : .coreml
        }
        let wantsPython = (override["mode"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased() == Mode.python.rawValue
        return wantsPython ? .python : .coreml
    }

    /// The provenance names. `modelID` is the EMBEDDING space: what the Info
    /// sheet shows, and the namespace a frame's vector file lives in. It is
    /// deliberately NOT the verdict model's id — that is recorded as the
    /// classifier (`NSFWClassifier.classifierID`), because a frame hash resolves
    /// against this string and nothing else.
    static let modelID = "siglip2-base"

    /// The interim verdict's provenance. Nothing produces a verdict like this
    /// any more; the names stay because a record an earlier build stored still
    /// says so, and a name is cheaper than a mystery.
    static let previewClassifierID = "zeroshot-margin-v1"
    static let previewAggregationID = "max-margin-v1"

    /// How many frames one pass over a video may decode.
    ///
    /// `FrameSampler` samples every 5 seconds and used to keep up to its own
    /// 250; decoding was measured as the dominant cost of a pass (1.97s of a
    /// 5.14s cold run on a 6-minute video, against 0.34s of Safe/NSFW
    /// scoring), so this is the number that moves it. The sample stays evenly
    /// spaced across the whole video — it is a thinner comb, not a prefix — so
    /// a loud moment late in a clip is still seen.
    ///
    /// 40 was measured, not guessed. Across 28 videos from the maintainer's
    /// library — 14 of the highest-frame-count files and all 14 reachable
    /// cases where a cap could plausibly change the answer (more than 40
    /// frames, and either a verdict carried by under 10% of them or a score
    /// between 0.2 and 0.8) — capping at 60, 40 and 20 produced **zero
    /// verdict flips**, while cutting decode+score time by 42-77% on the
    /// videos long enough to be affected. 40 was chosen over 20 because the
    /// stored scores drift less (largest movement at 40 was 0.056 to 0.042;
    /// at 20 one safe video went 0.313 to 0.255), and the scores are kept and
    /// shown, not just compared against the threshold.
    ///
    /// Only videos longer than about 3.5 minutes are affected at all: a
    /// shorter clip yields fewer than 40 frames and is sampled exactly as
    /// before. In this library that was 81 of 1,974 analysed videos.
    ///
    /// NOTE: these frames are also what the memo hands the suggestion pass, so
    /// a long video now offers tags from 40 frames rather than up to 250. The
    /// verdict effect is measured above; the TAG effect is not, and cannot be
    /// until T01's annotated corpus exists.
    static let maxAnalysisFrames = 40

    private let root: String           // the support dir: models and cache live under it
    private let cache: EmbeddingCache
    private var loadedSpaceKey: String?
    private var table: PromptTable?
    private var embedder: VisionEmbedder?
    private var nsfw: NSFWClassifier?
    /// The face engine, built on first use and only in builds where the face
    /// bundle is installed. It lives here rather than in `FaceStore` because
    /// the suggestion pass needs the frames it already sampled.
    private var faceRegistry: FaceRegistry?
    /// The LAST video's decoded frames, within a byte budget, so the next
    /// pass over the SAME video (classify → suggest) does not decode it
    /// again. At most one video is held; a clip that does not fit the budget
    /// memoizes nothing. See `SamplingPlan.FrameMemo`.
    private var frameMemo = SamplingPlan.FrameMemo<FrameSampler.SampledFrame>()
    private var memoHashes: [String] = []

    init(root: String) {
        self.root = root
        self.cache = EmbeddingCache(root: (root as NSString).appendingPathComponent("frames"))
    }

    /// Everything a Core ML classify needs on disk. Cheap: three directory
    /// checks, no model load, no 346 KB of floats read — so the capability layer
    /// can ask on a machine that has none of it.
    nonisolated static func isInstalled(root: String) -> Bool {
        VisionEmbedder.isInstalled(root: root) && PromptTable.isInstalled(root: root)
    }

    /// Load the models and the table now, so the first Classify press is not
    /// also a cold model load. Idempotent, and each load names what is missing
    /// rather than failing later with a number that makes no sense.
    ///
    /// The table is also checked against the INSTALLED space: a table computed
    /// for a different tower is refused here, so no classify or suggestion
    /// pass can ever score vectors against text embeddings from another space.
    @discardableResult
    func warm(loadClassifier: Bool = true) throws -> Bool {
        let installedSpace = try ModelSpace.readForInference(root: root)
        let key = installedSpace?.digest ?? cache.slug
        if let loadedSpaceKey, loadedSpaceKey != key {
            throw ClassifierError.spaceMismatch("The installed model changed. Restart the app before analysing with the replacement.")
        }
        // Keep preparation local: a failed dependency must not leave half of
        // an installation retained for a later retry under another identity.
        let preparedTable: PromptTable
        if let table {
            preparedTable = table
        } else {
            if let why = PromptTable.spaceBindingError(root: root) {
                throw ClassifierError.spaceMismatch(why)
            }
            preparedTable = try PromptTable(root: root)
        }
        let preparedEmbedder: VisionEmbedder
        if let embedder {
            preparedEmbedder = embedder
        } else {
            if let installed = installedSpace,
               !installed.matchesInstalledBytes(root: root) {
                throw ClassifierError.spaceMismatch(
                    "The installed model files do not match the model the app recorded. "
                  + "Reinstall the model pack in Settings before analysing.")
            }
            preparedEmbedder = try VisionEmbedder(root: root)
        }
        let preparedNSFW: NSFWClassifier?
        if let nsfw { preparedNSFW = nsfw }
        else if loadClassifier { preparedNSFW = try NSFWClassifier(root: root) }
        else { preparedNSFW = nil }
        try requireSpace(key)
        table = preparedTable
        embedder = preparedEmbedder
        nsfw = preparedNSFW
        loadedSpaceKey = key
        return true
    }

    private func requireSpace(_ key: String) throws {
        guard (try ModelSpace.readForInference(root: root)?.digest ?? cache.slug) == key else {
            throw ClassifierError.spaceMismatch("The installed model changed during analysis. Restart the app and retry.")
        }
    }

    /// Sample → embed (cache first) for one video, handing back the frames
    /// themselves so the caller can score them with whichever model it needs.
    ///
    /// Extracted so every pass over a video shares it: a video just analysed and
    /// then asked about its tags pays for nothing twice, and both passes agree on
    /// exactly which frames and which hashes they are talking about.
    ///
    /// Cancellation is checked between frames, and a frame that cannot be read or
    /// embedded comes back `nil` rather than failing the video — the same
    /// discipline as the engine's ("one unreadable stretch drops one frame").
    private func framesAndVectors(path: String) async throws
        -> (frames: [FrameSampler.SampledFrame], hashes: [String], vectors: [[Float]?]) {
        guard let embedder, let loadedSpaceKey else { throw ClassifierError.notLoaded }
        let cache = self.cache.pinned(to: loadedSpaceKey)
        try requireSpace(loadedSpaceKey)
        // The SHARED plan decides which frames this pass wants — the same
        // arithmetic FrameSampler has always used (uniform strategy), so the
        // frames are identical; what is new is that the plan is bound to the
        // file's revision, checked before any decode is paid for, and
        // counted.
        let url = URL(fileURLWithPath: path)
        guard let source = SourceRevision.of(path) else { throw ClassifierError.noScores(path) }
        var frames: [FrameSampler.SampledFrame]
        let hashes: [String]
        var counters = SamplingPlan.Counters()
        if let memoized = frameMemo.frames(for: path), memoHashes.count == memoized.count {
            frames = memoized
            hashes = memoHashes
            counters.memoHits = frames.count
        } else {
            frameMemo.evict()
            memoHashes = []
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard let plan = SamplingPlan.build(path: path, duration: duration, strategy: .uniform),
                  plan.sourceRevision == source, source.matches(path) else {
                throw ClassifierError.noScores(path)
            }
            frames = try await FrameSampler.sample(url: url, duration: duration,
                                                  maxFrames: Self.maxAnalysisFrames)
            counters.framesDecoded = frames.count
            guard source.matches(path) else { throw ClassifierError.noScores(path) }
            hashes = frames.map { EmbeddingCache.frameHash(of: $0.image) }
            counters.framesHashed = hashes.count
            let bytes = frames.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
            frameMemo.store(path: path, revision: source, frames: frames, bytes: bytes)
            memoHashes = hashes
        }
        defer { SamplingPlan.record(counters) }

        // The cache is keyed on the frame's bytes, so a video already analysed
        // costs no embedding at all — 0.19 s of a 0.96 s pass.
        var vectors = [[Float]?](repeating: nil, count: frames.count)
        var pending: [Int] = []
        for (i, hash) in hashes.enumerated() {
            if let cached = cache.read(hash) {
                vectors[i] = cached
                counters.cacheHits += 1
            } else { pending.append(i) }
        }
        if !pending.isEmpty {
            let embedded = try await embedder.embed(pending.map { frames[$0] })
            counters.framesEmbedded += embedded.count
            var byFrameIndex: [Int: [Float]] = [:]
            for e in embedded { byFrameIndex[e.index] = e.vector }
            for i in pending {
                guard let vector = byFrameIndex[frames[i].index] else { continue }
                vectors[i] = vector
                cache.write(hashes[i], vector)   // best-effort: a full disk is not a failed verdict
            }
        }
        guard source.matches(path) else {
            frameMemo.evict()
            memoHashes = []
            throw ClassifierError.noScores(path)
        }
        try requireSpace(loadedSpaceKey)
        return (frames, hashes, vectors)
    }

    /// Score → aggregate, for one video.
    ///
    /// Aggregation is max across frames, as it has always been: one loud frame
    /// is a verdict, and averaging would hide it. `framesAbove` counts against
    /// the same 0.5 the review window files Safe/NSFW at, so the stored numbers
    /// and the badge cannot disagree.
    func analyse(path: String) async throws -> CoreMLVerdict {
        try warm()
        guard let nsfw, let loadedSpaceKey else { throw ClassifierError.notLoaded }

        let sample = try await framesAndVectors(path: path)
        guard !sample.frames.isEmpty else { throw ClassifierError.noScores(path) }

        // Falconsai resizes the SAME decoded frame the embedding used to its own
        // 224×224 constraint, so no video is ever decoded twice for two models.
        let probabilities = try await nsfw.scores(sample.frames)
        try requireSpace(loadedSpaceKey)

        var scored: [Double] = []
        var recorded: [FrameScore] = []
        recorded.reserveCapacity(sample.frames.count)
        for (i, frame) in sample.frames.enumerated() {
            try Task.checkCancellation()
            guard let p = probabilities[frame.index] else { continue }
            scored.append(p)
            // `at` is the second this frame actually came from: FrameSampler
            // knows the real time, where the engine's `index × 5 s` only
            // approximates it on a clamped short clip.
            recorded.append(FrameScore(at: frame.time, score: Self.round4(p),
                                       hash: sample.hashes[i]))
        }
        guard !scored.isEmpty else { throw ClassifierError.noScores(path) }

        let threshold = NSFWClassifier.threshold
        let video = scored.max() ?? 0
        let mean = scored.reduce(0, +) / Double(scored.count)
        let prediction = NsfwPrediction(
            score: Self.round4(video),
            maxFrame: Self.round4(video),
            meanFrame: Self.round4(mean),
            frames: scored.count,
            framesAbove: scored.filter { $0 >= threshold }.count,
            threshold: threshold,
            aggregation: NSFWClassifier.aggregationID,
            modelID: Self.modelID,
            classifier: NSFWClassifier.classifierID,
            classifiedAt: Date().timeIntervalSince1970)
        return CoreMLVerdict(prediction: prediction, frames: recorded)
    }

    /// engine.py's `suggest_tags`, in-process: sample → embed (cache first) →
    /// merge the four sources → rank → cap at `TagSuggester.maxTags`.
    ///
    /// `framesSeen` is how many frames actually carried a vector — the same
    /// number engine.py reports and the suggestion store shows.
    ///
    /// The heads and the library baseline are read out of THIS space (the slug
    /// is the cache namespace), so a head fitted on the old 768-dim vectors can
    /// never be applied to a 512-dim frame: that would be silent nonsense, not
    /// an error.
    func suggest(path: String, paired: Bool,
                 tagged: TagPrototypes.TaggedVideos = [],
                 faces: Bool = true,
                 neighbours: NeighbourPrior = NeighbourPrior())
        async throws -> (candidates: [TagSuggester.Candidate], framesSeen: Int,
                         facesDetected: Int, faceHashes: [String]) {
        try warm(loadClassifier: false)
        guard let table else { throw ClassifierError.notLoaded }
        let sample = try await framesAndVectors(path: path)
        let frames = sample.vectors.compactMap { $0 }
        guard !frames.isEmpty else { return ([], 0, 0, []) }

        // A copy, so the read closure carries the cache rather than the actor.
        let store = cache.pinned(to: loadedSpaceKey ?? cache.namespace)
        let read: (String) -> [Float]? = { store.read($0) }
        let heads = TrainedHeads.load(root: root, slug: store.slug)
        let prototypes = TagPrototypes.prototypes(
            tagged, excluding: Set(table.pairedTags.map(\.name)), read: read)
        let cached = store.hashes()
        let baseline = TagPrototypes.baseline(
            hashes: cached, dim: table.dim, read: read)

        // --- faces, over the frames that are already decoded ----------------
        //
        // engine.py does this in the same function for the same reason: the
        // frames exist, and re-sampling a video to look for faces would double
        // the decode cost of every video the user watches. It degrades to
        // nothing rather than failing — a Mac without the face bundle, or with
        // nobody named yet, just gets no face candidates.
        //
        // The switch is honoured HERE and not downstream: when faces are off, no
        // face is detected, embedded, hashed or stored for this video at all,
        // rather than being computed and then hidden.
        var faceHits: [String: Double] = [:]
        var detected: [FoundFace] = []
        if faces, FaceRegistry.isInstalled(root: root) {
            let faces = faceEngine()
            detected = (try? await faces.faces(inFrames: sample.frames)) ?? []
            if !detected.isEmpty {
                // The video-level bar, not the engine's one-to-one one: this
                // compares against every face the video yielded, so the weaker
                // threshold offered a fifth of the library for anybody with a
                // face bound to them. See `SFaceEmbedder.videoMatchCosine`.
                faceHits = faces.matches(vectors: detected.map(\.vector),
                                         in: faces.registry(),
                                         threshold: SFaceEmbedder.videoMatchCosine)
            }
        }

        return (TagSuggester.suggest(table: table, frames: frames, heads: heads,
                                     paired: paired,
                                     margin: TagSuggester.vocabularyMargin,
                                     prototypes: prototypes, baseline: baseline,
                                     faces: faceHits,
                                     priors: priors(table: table, hashes: cached,
                                                    read: read),
                                     neighbours: neighbours),
                frames.count, detected.count, detected.map(\.hash))
    }

    /// The face engine for this process, built on first use and REBUILT when
    /// the active profile moves. Constructing it loads no model — the detector
    /// and the embedder are loaded by the first scan — so a video with no
    /// faces does not pay for one, and a rebuild costs nothing until the next
    /// scan reloads them.
    ///
    /// The profile is fixed inside `FaceRegistry` at construction, and this
    /// one outlives any single run: `AnalysisEngine` holds the classifier for
    /// the life of the app. Caching it across a profile switch would answer
    /// the new profile's suggestions out of the old profile's `faces.json` —
    /// which name belongs to which face is one person's judgement, and
    /// `FaceStore.reload(profile:)` drops its own registry for exactly this
    /// reason. This is the same rule on the classifier's copy.
    /// Not private: the profile-lifetime gate in `test_face_registry.swift`
    /// asks which profile the cached engine is bound to.
    func faceEngine() -> FaceRegistry {
        let profile = Paths.activeProfile
        if let faceRegistry, faceRegistry.profile == profile { return faceRegistry }
        let made = FaceRegistry(root: root, profile: profile)
        faceRegistry = made
        return made
    }

    /// The per-tag priors, measured once per library and then reused.
    ///
    /// Off unless `FVP_SUGGEST_RANK=normalized`, in which case an empty
    /// `TagPriors` is returned and `TagSuggester` sorts by the raw margin
    /// exactly as it does today.
    ///
    /// Measuring walks every cached vector, so it is cached on disk and redone
    /// only when the library has grown enough to move the averages. A stale
    /// prior is not a correctness problem — it reorders suggestions — so this
    /// deliberately does not invalidate on every new frame.
    private func priors(table: PromptTable,
                        hashes: [String],
                        read: (String) -> [Float]?) -> TagPriors {
        guard TagPriors.enabled else { return TagPriors() }
        let cachedPriors = TagPriors.load(root: root, slug: cache.slug)
        // Re-measure when the cache has grown by half again, so a library that
        // is filling up does not keep ranking against its first few videos.
        if cachedPriors.isUsable, hashes.count < cachedPriors.frames * 3 / 2 {
            return cachedPriors
        }
        let measured = TagPriors.measure(table: table, hashes: hashes, read: read)
        guard measured.isUsable else { return cachedPriors }
        try? measured.save(root: root, slug: cache.slug)
        return measured
    }

    /// engine.py's `tag_candidates`, answered in-process from the cache.
    ///
    /// No `warm()` and no model load: `LookAlikes.rank` is arithmetic over
    /// vectors already on disk, which is what lets the look-alike search work
    /// under the Core ML engine, where the Python child does not exist at all.
    /// The vectors live in the same cache the suggestion pass writes, so the
    /// two agree on what a video looks like.
    ///
    /// The two lists are built here, SORTED. A dictionary has no order of its
    /// own, and `LookAlikes.rank` takes its baseline mean and its tie-breaks
    /// from the order it is handed — an answer that could differ between two
    /// runs of the same search would be indefensible.
    ///
    /// `nonisolated` on purpose: reading the cache must not queue behind an
    /// analyse that is already running inside this actor.
    nonisolated func tagCandidates(tag: String,
                                   tagged: [String: [String]],
                                   pool: [String: [String]],
                                   limit: Int) -> LookAlikes.Result {
        let store = cache
        return LookAlikes.rank(tag: tag,
                               tagged: tagged.keys.sorted().map { ($0, tagged[$0] ?? []) },
                               pool: pool.keys.sorted().map { ($0, pool[$0] ?? []) },
                               read: { store.read($0) },
                               limit: limit)
    }

    /// The evidence behind one suggestion, recomputed from the cached vectors.
    ///
    /// Deliberately NOT stored alongside the suggestion: 8 chips × 556 videos of
    /// explanation would be a lot of JSON for something looked at now and then,
    /// and a stored explanation can go stale where a recomputed one cannot.
    ///
    /// Returns nil when there is nothing honest to show — no cached frames, or a
    /// table without phrase texts.
    func explain(tag: String, source: String, path: String,
                 learnedFrom: [String] = [], person: String? = nil)
        async throws -> SuggestionExplanation? {
        try warm(loadClassifier: false)
        guard let table else { throw ClassifierError.notLoaded }
        let sample = try await framesAndVectors(path: path)
        let frames: [SuggestionWhy.Frame] = zip(sample.frames, sample.hashes)
            .enumerated()
            .compactMap { i, pair in
                guard let vector = sample.vectors[i] else { return nil }
                return SuggestionWhy.Frame(vector: vector, hash: pair.1, at: pair.0.time)
            }
        guard !frames.isEmpty else { return nil }
        let head = source == "trained"
            ? TrainedHeads.load(root: root, slug: cache.slug).tags[tag]
            : nil
        return SuggestionWhy.explain(table: table, tag: tag, source: source,
                                     frames: frames, learnedFrom: learnedFrom,
                                     head: head, margin: TagSuggester.vocabularyMargin,
                                     person: person)
    }

    /// Every proposed tag's agreeing frames and the bar it was judged against,
    /// from ONE read of the cached vectors.
    ///
    /// The rule that decides "agreed" is `SuggestionWhy.explain`'s: the same
    /// function, the same bar and the same head that offered the chip. A timed
    /// claim justified by a different rule than the one that made it would be a
    /// claim about something else, and the review row would defend a tag with
    /// evidence the app never used.
    ///
    /// A tag whose source owns no per-frame times of its own — a library
    /// prototype, a named face — comes back with no hits. Those chips are still
    /// offered and still judgeable; they simply have no WHEN to show.
    ///
    /// `learnedFrom` and `person` are not needed: they are read only by the two
    /// branches that return no hits.
    func sightings(path: String, tags: [TagSuggestion]) async throws -> EvidenceProposal.TagSightings {
        try warm(loadClassifier: false)
        guard let table else { throw ClassifierError.notLoaded }
        let sample = try await framesAndVectors(path: path)
        let frames: [SuggestionWhy.Frame] = zip(sample.frames, sample.hashes)
            .enumerated()
            .compactMap { i, pair in
                guard let vector = sample.vectors[i] else { return nil }
                return SuggestionWhy.Frame(vector: vector, hash: pair.1, at: pair.0.time)
            }
        var answer = EvidenceProposal.TagSightings(sampled: frames.map(\.at))
        guard !frames.isEmpty else { return answer }
        let heads = TrainedHeads.load(root: root, slug: cache.slug).tags
        for tag in tags {
            let source = tag.source ?? "zeroshot"
            guard let explanation = SuggestionWhy.explain(
                table: table, tag: tag.tag, source: source, frames: frames,
                head: source == "trained" ? heads[tag.tag] : nil,
                margin: TagSuggester.vocabularyMargin
            ) else { continue }
            answer.byTag[tag.tag] = EvidenceProposal.TagSighting(
                bar: explanation.bar,
                hits: explanation.hits.map { ($0.at, $0.margin) }
            )
        }
        return answer
    }

    /// The engine rounds every stored score to 4 decimals; a record that says
    /// 0.50004 where Python says 0.5 is a record that invites a false diff.
    nonisolated static func round4(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }

    // MARK: - training, in-process

    /// Fit one head per tag from the user's own judgements — engine.py's
    /// `train`, answered in-process.
    ///
    /// Reads the embedding cache and nothing else: no model, no ffmpeg, no
    /// child process, and no need to queue behind an analyse already running
    /// inside this actor. The videos are ordered by key before the fit because
    /// the hold-out rule is positional — a dictionary has no order of its own,
    /// and a fit that could come out differently on two runs over the same
    /// library would be indefensible.
    ///
    /// The heads are MERGED into the file the classifier reads back, which is
    /// what makes a tag start being offered at all; training one tag never
    /// erases another.
    nonisolated func trainHeads(labels: [String: [String: Bool]],
                                frameHashes: [String: [String]]) throws -> [HeadFit] {
        let store = cache
        let dataset = HeadDataset.build(
            frames: frameHashes.keys.sorted().map {
                (key: $0, hashes: frameHashes[$0] ?? [])
            },
            read: { store.read($0) })
        let tags = labels.keys.sorted().map { (tag: $0, labels: labels[$0] ?? [:]) }
        let (heads, fits) = LogisticTrainer.fitTags(tags, dataset: dataset)
        if !heads.isEmpty {
            try TrainedHeads(slug: store.slug, dim: dataset.dim, tags: heads)
                .save(root: root, merging: true)
        }
        return fits
    }

    /// Fit the single Safe/NSFW correction head — engine.py's `train_nsfw`.
    ///
    /// The same shape as `trainHeads` and deliberately separate: no tag filter,
    /// and the split runs over the marked videos alone, so this head and the
    /// per-tag heads can disagree about which videos are held out. They always
    /// have — which is why the two fits are two functions.
    nonisolated func trainNsfw(labels: [String: Bool],
                               frameHashes: [String: [String]]) throws -> HeadFit {
        let store = cache
        let dataset = HeadDataset.build(
            frames: frameHashes.keys.sorted().map {
                (key: $0, hashes: frameHashes[$0] ?? [])
            },
            read: { store.read($0) })
        let (head, fit) = LogisticTrainer.fitNSFW(labels: labels, dataset: dataset)
        if let head {
            try TrainedHeads(slug: store.slug, dim: dataset.dim, nsfw: head)
                .save(root: root, merging: true)
        }
        return fit
    }

    enum ClassifierError: Error, LocalizedError, CustomStringConvertible {
        case notLoaded
        case noScores(String)
        case notInstalled(String)
        case spaceMismatch(String)

        var description: String {
            switch self {
            case .notLoaded:
                return "the Core ML classifier is not loaded"
            case .noScores(let p):
                return "no frame of \((p as NSString).lastPathComponent) could be scored"
            case .notInstalled(let what):
                return "\(what) is not installed — the Core ML engine needs both the "
                    + "image model and the prompt table"
            case .spaceMismatch(let why):
                return why
            }
        }

        var errorDescription: String? { description }
    }
}
