# The Model-layer files the standalone test harnesses compile, and the
# frameworks they need — in ONE place.
#
# Tests/run.sh and Tests/run_coreml.sh both source this. Two hand-kept lists
# drift: a file missing from one makes a test fail to compile, which reads as a
# broken test rather than a broken list (the second trap this skill records).
#
# Callers must set `model` to the Model directory first.

MODEL_SOURCES=(
    "$model/Paths.swift" "$model/Formatting.swift" "$model/JSONStore.swift"
    "$model/Scanner.swift" "$model/Fingerprints.swift" "$model/AppState.swift"
    "$model/Library.swift" "$model/TagKinds.swift" "$model/TagSharing.swift"
    # Where a tag came from (added Sep'26). A new Model/ file lands HERE or the
    # whole suite stops compiling with `cannot find 'TagProvenance' in scope`.
    "$model/TagProvenance.swift"
    # The facts READ off the files — dates, resolutions, cameras, GPS places —
    # in a store of their own, kept out of the tags (added Sep'26). Same rule:
    # a new Model/ file lands here or nothing compiles.
    "$model/MetadataFacts.swift"
    "$model/FileOps.swift" "$model/AutoTagCore.swift" "$model/MetadataTagger.swift"
    "$model/MovedScan.swift" "$model/NameIndex.swift" "$model/AnalysisModels.swift"
    "$model/AnalysisStore.swift" "$model/AnalysisEngine.swift"
    "$model/AICapability.swift" "$model/FaceStore.swift" "$model/SuggestionStore.swift"
    # Phase 2's Core ML path — the app's classify branch lives in these.
    "$model/FrameSampler.swift" "$model/VisionEmbedder.swift" "$model/ModelSpace.swift"
    "$model/EmbeddingCache.swift" "$model/PromptTable.swift"
    "$model/CoreMLClassifier.swift"
    # Phase 3's maths — no model, no frames, just the vectors already cached.
    "$model/LogisticHead.swift" "$model/LookAlikes.swift" "$model/TagPrototypes.swift"
    # Phase 4: the shipped Safe/NSFW verdict, and the suggester that merges
    # every source into one ranked list. `TagPriors` is the optional re-ranking
    # (FVP_SUGGEST_RANK=normalized) the suggester sorts by.
    "$model/NSFWClassifier.swift" "$model/TagSuggester.swift"
    "$model/TagPriors.swift" "$model/PlayerWindowTitle.swift"
    # The neighbour prior: the same kind of optional re-ranking as TagPriors,
    # asking what the videos shot AROUND this one say about a tag.
    "$model/NeighbourPrior.swift"
    "$model/LibraryTagPayload.swift" "$model/SuggestionWhy.swift"
    # T01's evaluation corpus: the frozen manifest, rubric, deterministic
    # splits, video-level metrics and the real benchmark runner. Pure model
    # code — a new Model/ file lands HERE or the whole suite stops compiling.
    "$model/EvalCorpus.swift"
    # T05's job ledger and explicit runner: what was asked for, what finished,
    # checkpoints, cancellation, profile isolation. Same rule as ever.
    "$model/JobLedger.swift"
    # T06's shared sampling plan: source-revision-bound plans, bounded
    # streams, counters, adaptive-vs-uniform comparison. Same rule.
    "$model/SamplingPlan.swift"
    # T05's other half: the typed, timed payload every remaining capability
    # writes (tags, scenes, objects, faces, speech) and the repository the app
    # talks to. Same rule as ever: a new Model/ file lands HERE.
    "$model/TimedEvidence.swift"
    # ...and the versioned SQLite store behind that repository: schema version
    # on disk, backup before migration, refuse a newer schema without writing,
    # profile isolation, and transcript search with FTS5 where the runtime has
    # it. Same rule.
    "$model/EvidenceStore.swift"
    # T07's producer half: per-frame prompt-table scores become reviewable timed
    # evidence, and a re-run replaces its own unanswered proposals instead of
    # doubling the review list. Same rule.
    "$model/EvidenceProposal.swift"
    # ...and the journal the app talks to: one store per profile, the spans a
    # review row shows, and the one place a verdict on a suggested tag is
    # written, so the tag store and its evidence cannot disagree. Same rule.
    "$model/EvidenceJournal.swift"
    # T08's first slice: the sound a speech pass needs — 16 kHz mono floats out of
    # any video, using only what macOS ships (no ffmpeg, no Python). Same rule.
    "$model/AudioExtraction.swift"
    # Speech: the logic half. WhisperKitTranscriber.swift is deliberately NOT
    # listed: it imports WhisperKit, which the swiftc suite cannot see, so it is
    # verified by the real app build and by Tests/check_speech_runtime.sh.
    "$model/Speech.swift"
    "$model/SpeechPass.swift"
    # The hidden-videos credential and filter: no model, no frames, but the
    # library keys its hidden set by the same share-relative rule as tags.
    "$model/HiddenVideos.swift"
    # Phase 5: the download experience. A new Model/ file must be added HERE or
    # the whole suite stops compiling.
    "$model/ModelDownloader.swift" "$model/ModelPack.swift"
    # Which pack each capability uses (added Sep'26). Same rule: a new Model/
    # file lands here or the whole suite stops compiling.
    "$model/ModelRegistry.swift"
    # Kept versions of an installed pack: every install keeps a copy, so an
    # older revision can be switched back to without a download. Same rule.
    "$model/ModelStore.swift"
    # Phase 6.2: the face models as the app runs them. `FaceDetector` is the
    # ported YuNet (decode + NMS + the /32 padding), `FaceAlignment` is the
    # Umeyama transform onto the ArcFace template, `SFaceEmbedder` is the
    # 18 MB identity model. The crop geometry is what `FACE_MATCH_COSINE =
    # 0.30` is calibrated on, so these three are parity-gated, not eyeballed.
    "$model/FaceDetector.swift" "$model/FaceAlignment.swift"
    "$model/SFaceEmbedder.swift"
    # 6.3: the half of face recognition that is not a model — the crop-keyed
    # cache, the per-profile registry, the matcher and the prominence clustering.
    "$model/FaceRegistry.swift"
    # A profile as one document: its bundle layout, manifest and the one-time
    # migration of the legacy files into it. `Paths` builds every per-profile
    # path from this, so the whole suite stops compiling without it.
    "$model/ProfileBundle.swift"
)

MODEL_FRAMEWORKS=(
    -framework CoreML -framework AVFoundation -framework CoreGraphics
    -framework ImageIO -framework UniformTypeIdentifiers -framework CryptoKit
    -framework Accelerate
)
