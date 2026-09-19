import Foundation

/// One piece of timed evidence: what a capability saw, WHEN in the video it saw
/// it, why it says so, and what a human decided about it (design §6, §8).
///
/// The design's rules live in this type's shape rather than in a convention:
///
/// - **A time is required, and it must be ordered.** Evidence without a time
///   cannot be reviewed and cannot be seeked to, so a time is not optional here;
///   a range that ends before it starts would put a reviewer in front of the
///   wrong frame, so the store refuses one instead of trusting every caller.
/// - **Confidence belongs to its capability.** A detector's 0.8 and a cosine
///   similarity's 0.8 are not the same claim, and the design forbids averaging
///   them: each number is kept beside the capability that produced it, together
///   with the model that produced it, the embedding space it belongs to and the
///   revision of the file it read.
/// - **`ignored` is not negative training data.** Only a decision a human
///   actually made — accepted or rejected — is a label. `Decision.forTraining`
///   is the one place that rule is written down, so nothing downstream has to
///   remember it.
/// - **Provenance travels with the claim.** The same label from a different
///   model space, or from the same model reading a file that has changed since,
///   is a different claim; it must not be indistinguishable from this one.
struct TimedEvidence: Equatable, Codable {

    /// Which capability produced this. The design's set — a capability that does
    /// not exist yet still has a name here, so its evidence needs no migration
    /// when it arrives.
    enum Capability: String, Codable, CaseIterable {
        case tags       // descriptive tags from the semantic pass
        case scenes     // semantic/scene labels
        case objects    // detector boxes (T09)
        case faces      // people integration (T10)
        case speech     // transcript evidence (T08)
    }

    /// What a human did with a proposed piece of evidence (design §6).
    enum Decision: String, Codable, CaseIterable {
        case pending    // shown, not yet answered
        case accepted   // a human said yes
        case rejected   // a human said no
        case ignored    // seen and passed over — NOT a no

        /// Is this a human label? Deliberately written out rather than
        /// `!= .pending`, because an ignored row is also not pending and must
        /// still never reach training.
        var forTraining: Bool { self == .accepted || self == .rejected }
    }

    /// The identity of the bytes this evidence was read from: the file's size
    /// and its modification date, the same pair the fingerprint index and the
    /// sampling plan use as a source revision. Evidence whose revision no longer
    /// matches the file on disk is evidence about a video the user has since
    /// changed (design §2, T06's stale-verdict rule).
    struct SourceRevision: Equatable, Codable {
        var bytes: Int64
        var modifiedAt: Double

        /// Does this identity describe the same bytes at the same time? The
        /// timestamp comparison allows a sub-millisecond difference, which is the
        /// granularity the filesystem stores — the same convention the app's own
        /// `SourceRevision.matches(_:)` uses, so the two cannot disagree about
        /// whether a video is still the one that was looked at. Comparing the
        /// doubles exactly would call a file changed over a rounding error.
        func matches(_ other: SourceRevision?) -> Bool {
            guard let other else { return false }
            return bytes == other.bytes && abs(modifiedAt - other.modifiedAt) < 0.001
        }
    }

    /// Assigned by the store. `nil` means "not written yet".
    var id: Int64? = nil

    var capability: Capability
    /// The video this is about, as the library keys it.
    var path: String
    /// Start of the evidence in the SOURCE video's time, in seconds.
    var start: Double
    /// End of the evidence. Equal to `start` for a point in time.
    var end: Double
    /// The claim itself — a tag name, a scene label, a detected class, a word.
    var label: String
    /// Why, in words a reviewer can judge. The design requires the reason to be
    /// shown with the evidence, so it is stored with it rather than recomputed.
    var reason: String = ""
    /// Which model or pack produced this — a name a user can read back to us.
    var source: String = ""
    /// The embedding space this belongs to (the digest the model layer pins).
    /// A vector, a head or a threshold from another space says nothing about
    /// this one, so it travels with the evidence.
    var space: String = ""
    /// The capability's own score, on the capability's own scale. Never averaged
    /// across capabilities, and therefore never normalised here either.
    var confidence: Double? = nil
    var proposedAt: Double = Date().timeIntervalSince1970
    var decision: Decision = .pending
    /// The revision of the file this was read from, when the producer knew it.
    var sourceRevision: SourceRevision? = nil
    /// The job that asked for this, when a job did. Empty for evidence from an
    /// interactive pass — the ledger's id, or "". The store keeps it as a string
    /// rather than joining to the ledger: the ledger owns its own lifetime, and
    /// evidence must survive it (job history can be cleared without losing what
    /// was actually observed).
    var jobID: String = ""

    var duration: Double { end - start }
    var isPointInTime: Bool { end == start }
    var isAboutAChangedFile: Bool { sourceRevision != nil }

    /// Everything the store refuses to write, checked before a single row lands
    /// — a batch is one claim, so half of it landing is worse than none of it.
    func validate() throws {
        if path.isEmpty { throw EvidenceError.emptyPath }
        if label.isEmpty { throw EvidenceError.emptyLabel }
        guard start.isFinite, end.isFinite else {
            throw EvidenceError.timeNotFinite("(\(start)…\(end))")
        }
        if start < 0 { throw EvidenceError.negativeStart(start) }
        if end < start { throw EvidenceError.endBeforeStart(start: start, end: end) }
        if let confidence, !confidence.isFinite { throw EvidenceError.confidenceNotFinite }
        if let revision = sourceRevision, revision.bytes < 0 || !revision.modifiedAt.isFinite {
            throw EvidenceError.invalidSourceRevision
        }
    }
}

/// One searchable line of transcript, in the SOURCE video's time. T08 writes
/// these; the store's job is that they are searchable without turning every word
/// into a tag (design §6), and that search works for the languages this library
/// actually holds.
struct TranscriptLine: Equatable, Codable {
    var id: Int64? = nil
    var path: String
    var start: Double
    var end: Double
    var text: String
    var language: String = ""
    /// Which speech model produced it — a transcript from another runtime is a
    /// different claim, so it is stored rather than inferred.
    var source: String = ""

    func validate() throws {
        if path.isEmpty { throw EvidenceError.emptyPath }
        if text.isEmpty { throw EvidenceError.emptyTranscriptLine }
        guard start.isFinite, end.isFinite else {
            throw EvidenceError.timeNotFinite("(\(start)…\(end))")
        }
        if start < 0 { throw EvidenceError.negativeStart(start) }
        if end < start { throw EvidenceError.endBeforeStart(start: start, end: end) }
    }
}

/// How transcript search is served by a store.
///
/// The design asks for FTS5 "where available and verified on the supported
/// runtime". It is verified here at open time rather than assumed: FTS5 is a
/// compile-time option of the SQLite the app happens to link, and a build that
/// lacks it must degrade to a scan instead of failing to open the store.
enum TranscriptSearchMode: String, Equatable {
    case fts5
    case scan
}

enum EvidenceError: Error, Equatable, LocalizedError {
    // A row that cannot be reviewed is not written at all.
    case emptyPath
    case emptyLabel
    case emptyTranscriptLine
    case timeNotFinite(String)
    case negativeStart(Double)
    case endBeforeStart(start: Double, end: Double)
    case confidenceNotFinite
    case invalidSourceRevision

    // The store itself.
    /// The file could not be opened or created, with the reason.
    case storeUnreadable(String)
    /// An SQLite file that this app did not write. Refused, and left untouched:
    /// adopting a foreign file would put our tables inside somebody else's data.
    case unrecognisedStore(String)
    /// Written by a newer build. Refused WITHOUT writing, because the only safe
    /// thing to do with a schema we do not understand is nothing.
    case newerSchema(found: Int, supported: Int)
    case backupFailed(String)
    case migrationFailed(String)
    case statementFailed(String)
    /// The same refusal applies to the two things a producer must never do: mix
    /// two videos' scopes in one replacement, or hand a decided row in as though
    /// it were a proposal.
    case mixedProposalScope
    case proposalMustBePending(TimedEvidence.Decision)
    case noSuchEvidence(Int64)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Evidence without a video cannot be reviewed."
        case .emptyLabel:
            return "Evidence with nothing to say is not evidence."
        case .emptyTranscriptLine:
            return "An empty transcript line is not stored."
        case .timeNotFinite(let times):
            return "Evidence needs a real time in the video, and \(times) is not one."
        case .negativeStart(let start):
            return "Evidence cannot start before the beginning of the video (\(start)s)."
        case .endBeforeStart(let start, let end):
            return "Evidence that ends (\(end)s) before it starts (\(start)s) would seek to the wrong frame."
        case .confidenceNotFinite:
            return "A confidence that is not a number cannot be compared with a threshold."
        case .invalidSourceRevision:
            return "The file revision this evidence came from is not a real one."
        case .storeUnreadable(let why):
            return "The analysis evidence store could not be opened: \(why)"
        case .unrecognisedStore(let path):
            return "There is a database at \(path) that this app did not write. It has been left untouched."
        case .newerSchema(let found, let supported):
            return "The analysis evidence store was written by a newer version of this app (schema \(found); this build understands \(supported)). It has been left untouched."
        case .backupFailed(let why):
            return "The evidence store could not be backed up before a schema upgrade, so nothing was changed: \(why)"
        case .migrationFailed(let why):
            return "The analysis evidence store could not be upgraded: \(why)"
        case .statementFailed(let why):
            return "The evidence store refused a query: \(why)"
        case .mixedProposalScope:
            return "These proposals are about more than one video, capability, model or revision, so nothing was replaced."
        case .proposalMustBePending(let decision):
            return "A proposal is unanswered by definition, so a row already marked \(decision.rawValue) is not one, and nothing was replaced."
        case .noSuchEvidence(let id):
            return "There is no evidence \(id) in this profile's store."
        }
    }
}

/// The repository abstraction the design asks for (§8): the app talks to THIS,
/// and the SQLite file behind it is one implementation. Tests hand an
/// implementation a temporary root; nothing above this line knows where the
/// bytes live, so replacing the storage later does not touch a caller.
protocol EvidenceRepository: AnyObject {
    /// The schema version actually ON DISK, read at open rather than assumed.
    var schemaVersion: Int { get }
    /// How transcript search is served here — verified, not assumed.
    var searchMode: TranscriptSearchMode { get }

    /// Release the file. Called on deinit; explicit so a caller can let go of a
    /// profile's store before moving or deleting it.
    func close()

    /// Write a batch as one unit. Throws without writing anything if any row is
    /// not reviewable.
    @discardableResult func insert(_ items: [TimedEvidence]) throws -> [Int64]

    /// Replace ONE producer's unanswered proposals with a new set, in one
    /// transaction. A pass run twice must not double the review list, and a
    /// crash must leave either the old set or the new one — never both, never
    /// neither. Rows a human ANSWERED are never withdrawn, and neither is
    /// another revision's or another model's evidence: those are other claims.
    ///
    /// The scope comes from the rows themselves, so a batch mixing two scopes is
    /// refused rather than guessed at — and an EMPTY batch is a no-op that
    /// withdraws nothing, because there is no row to read a scope off. A producer
    /// that found nothing this time calls `discardPending` instead.
    @discardableResult
    func replacePending(_ items: [TimedEvidence]) throws -> (withdrawn: Int, written: [Int64])

    /// Take back the unanswered proposals for one scope — for a pass that found
    /// nothing this time, where there are no rows to derive the scope from. A
    /// label the new run cannot see is no longer a claim this producer makes.
    @discardableResult
    func discardPending(for path: String,
                        capability: TimedEvidence.Capability,
                        source: String,
                        space: String,
                        revision: TimedEvidence.SourceRevision?) throws -> Int
    /// One video's evidence, oldest first, optionally only one capability's.
    func evidence(for path: String, capability: TimedEvidence.Capability?) throws -> [TimedEvidence]
    /// Record what a human decided. The evidence is never removed by a decision:
    /// a rejection is exactly what the next reviewer needs to see.
    @discardableResult func setDecision(_ decision: TimedEvidence.Decision, id: Int64) throws -> TimedEvidence
    /// Forget one video's evidence (a deletion, or a re-analysis of a changed
    /// file), returning how many rows went.
    @discardableResult func deleteEvidence(for path: String) throws -> Int
    func count(capability: TimedEvidence.Capability?) throws -> Int
    /// The rows a model may be trained on: a human's yes or a human's no, never
    /// an ignored proposal and never an unanswered one (design §6).
    func trainingEvidence(limit: Int) throws -> [TimedEvidence]

    /// T08's half of the store. Nothing outside tests writes these yet.
    @discardableResult func insertTranscript(_ lines: [TranscriptLine], path: String, language: String) throws -> Int
    func transcriptMatches(_ query: String, limit: Int) throws -> [TranscriptLine]
}

extension EvidenceRepository {
    func evidence(for path: String) throws -> [TimedEvidence] {
        try evidence(for: path, capability: nil)
    }

    /// Every row this profile holds, across capabilities.
    func count() throws -> Int {
        try count(capability: nil)
    }

    func transcriptMatches(_ query: String) throws -> [TranscriptLine] {
        try transcriptMatches(query, limit: 50)
    }
}
