import Foundation

/// The cheap identity of one media file: its size and its modification time —
/// the same two facts the duplicate-sieving fingerprint index already trusts.
///
/// A stored machine verdict is a claim ABOUT THIS FILE. When the file changes
/// (a re-encode, a re-save, a different video moved over the path), the claim
/// no longer describes anything real — and every other consumer of the
/// fingerprint index already treats changed identity as a different source.
/// This is what the analysis store records beside each verdict so the claim
/// can be checked instead of assumed.
struct SourceRevision: Codable, Equatable {
    var size: Int64
    var mtime: Double

    /// Read the current identity of a file. Nil when there is no file —
    /// which is not the same as "unchanged".
    static func of(_ path: String) -> SourceRevision? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              let modified = attrs[.modificationDate] as? Date else {
            return nil
        }
        return SourceRevision(size: size, mtime: modified.timeIntervalSince1970)
    }

    /// Does the file at `path` still have this identity? A missing file is a
    /// mismatch: nothing is served from a verdict about a file that is gone.
    func matches(_ path: String) -> Bool {
        guard let now = Self.of(path) else { return false }
        return now.size == size && abs(now.mtime - mtime) < 0.001
    }
}

/// How far through the analysis pipeline a video has come.
///
/// The store keeps the whole queue on disk, so an interrupted run — the app
/// quitting, a NAS going to sleep — resumes from where it stopped instead of
/// redoing every video. `done` only means the engine has spoken; whether a
/// human has looked is `reviewed`, a separate flag, because a video can carry
/// a machine verdict nobody has seen yet.
enum AnalysisPhase: String, Codable {
    case queued          // asked for, not yet touched
    case analyzing       // sampling, embedding or classifying in progress
    case done            // the engine's verdict is in
    case failed          // the engine gave up (bad file, unmounted share)
}

/// The two labels the first review pass works with. Deliberately not a
/// hard-coded taxonomy: the spec's richer multi-level ladder arrives as
/// user-defined categories once the custom classifier
/// does, so nothing here pretends these two are the whole story.
enum NsfwLabel: String, Codable, CaseIterable {
    case safe
    case nsfw

    /// What a button or badge says. `capitalized` would render "Nsfw", so the
    /// acronym spells itself out here.
    var title: String {
        switch self {
        case .safe: return "Safe"
        case .nsfw: return "NSFW"
        }
    }
}

/// The engine's verdict on one video.
///
/// Every field that decides the result is recorded beside it — which embedding
/// model, which sampling, which aggregation, which classifier version — so a
/// stored verdict can always be reproduced or re-derived, and so embeddings
/// from two different models are never mistaken for each other (the spec's
/// model registry requirement, §22 and §24).
struct NsfwPrediction: Codable, Equatable {
    var score: Double          // the aggregated video score, 0...1
    var maxFrame: Double       // the loudest single frame
    var meanFrame: Double      // the average across analysed frames
    var frames: Int            // how many frames the model looked at
    var framesAbove: Int       // how many of those crossed the threshold
    var threshold: Double      // the per-frame bar the engine used
    var aggregation: String    // strategy id, e.g. "weighted_max_frac"
    var modelID: String        // e.g. "clip-vit-l14" — the embedding space
    var classifier: String     // e.g. "zeroshot-nsfw-v1"
    var classifiedAt: Double   // epoch seconds
}

/// One frame the engine actually scored: where in the video it came from and
/// what it was given.
///
/// Raw frame scores are kept (§8 of the spec) so the video-level aggregation
/// can be changed later without re-embedding anything. `hash` names both the
/// sampled frame and its embedding file under `frames/<modelID>/`.
struct FrameScore: Codable, Equatable {
    var at: Double      // seconds into the video
    var score: Double   // this frame's own score, 0...1
    var hash: String
}

/// One human correction, appended rather than overwriting.
///
/// The training set needs to know who said what and what it overruled, and a
/// correction outranks any automatic prediction (§18): `previous` records the
/// state the human overturned ("automatic 0.940", "user:safe" or "none"), so
/// the record always shows the machine's last word even when the human's word
/// is the one the UI acts on.
struct Correction: Codable, Equatable {
    var previous: String
    var label: NsfwLabel
    var at: Double             // epoch seconds
    var source: String         // "user_correction" today; other sources later
}

/// Everything the app knows about one video's analysis, keyed on the same
/// share-relative path key the tags use — so "this video" means the same
/// thing here and on any other device reaching the same NAS.
struct VideoAnalysis: Codable, Equatable {
    var phase: AnalysisPhase = .queued
    var prediction: NsfwPrediction?
    var userLabel: NsfwLabel?
    var reviewed = false
    var frameScores: [FrameScore] = []
    var history: [Correction] = []
    /// The identity of the file this verdict described, recorded when the
    /// verdict landed. Absent on records written before revisions existed —
    /// those stay governed by the embedding-space check below, and a new
    /// verdict always records one going forward.
    var sourceRevision: SourceRevision? = nil

    /// Is the machine's verdict about bytes that no longer exist?
    ///
    /// True only when a revision was recorded AND the file at hand no longer
    /// matches it: a re-encode, a re-save, a different video moved over the
    /// path, or the file gone entirely. The machine's answer is then about
    /// something that is not what you are looking at, and callers counting
    /// verdicts as current should refuse it. A record with no revision (a
    /// legacy record) is never called stale by THIS check — the embedding-
    /// space check governs those.
    func isStale(forPath path: String) -> Bool {
        guard let revision = sourceRevision else { return false }
        return !revision.matches(path)
    }

    /// Can the engine running RIGHT NOW read this record's vectors back?
    ///
    /// `frameScores[].hash` names a file under `frames/<space>/`, so the answer
    /// is only yes when the record was written by the same embedding space the
    /// app is writing into today. Swap the vision tower and the space changes
    /// (`mobileclip_s2` → `siglip2_base`, or the Python engine's
    /// `openai_clip-vit-large-patch14`), leaving every earlier hash pointing at
    /// a file the new engine never looks at.
    ///
    /// The record still LOOKS analysed — `frameScores` is full, the phase says
    /// done — which is exactly how a tag holding 36 tagged videos reported
    /// "have 2": two were re-analysed after the swap and 34 were counted from a
    /// space nothing can read. Counting them is worse than ignoring them,
    /// because it answers a confident "not enough tagged videos" to someone who
    /// tagged plenty, and never triggers the re-analysis that would fix it.
    ///
    /// `prediction == nil` means never analysed, which is the same answer for
    /// the same reason: nothing to read.
    var isInCurrentSpace: Bool {
        prediction?.modelID == EmbeddingSpace.current
    }
}

/// Which embedding space the app is analysing into at this moment.
///
/// One place, because the two engines name their space differently and a
/// record written under one is unreadable by the other: Core ML reports
/// `siglip2-base` (the tower's own id) while `engine.py` reports the Hugging
/// Face repo it loads. Comparing a record against the wrong one of these would
/// mark a whole library stale, or a whole library current, either way silently.
enum EmbeddingSpace {
    /// `engine.py`'s MODEL_ID. Kept as the repo name it loads, matching what
    /// the Python engine writes into `provenance.embeddingModel`.
    static let python = "openai/clip-vit-large-patch14"

    static var current: String {
        CoreMLClassifier.mode == .coreml ? CoreMLClassifier.modelID : python
    }
}

/// What a human decided about one video — the per-profile half of a record.
///
/// Kept apart from `VideoAnalysis` because the two answer to different owners.
/// The frame scores and the machine's verdict are a reading of the video: the
/// same for every profile, and the expensive part to derive. A Safe/NSFW mark
/// is one person's judgement, so it lives in that profile's own file — a mark
/// made under one profile is never shown, nor trained on, under another.
struct VideoMark: Codable, Equatable {
    var label: NsfwLabel
    var history: [Correction] = []
}

/// Where a video stands for the review UI: one of a handful of buckets the
/// window groups rows into. Derived from the record by `bucket(record:)`; the
/// store never stores a bucket, because the same record can belong to
/// different groups depending on what the user is looking at.
enum AnalysisBucket: Equatable {
    case unseen        // never asked about
    case queued        // asked for, waiting
    case working       // being analysed right now
    case failed        // the engine gave up
    case needsReview   // the engine has spoken, no human has looked
    case safe          // a human marked it Safe
    case nsfw          // a human marked it NSFW
}
