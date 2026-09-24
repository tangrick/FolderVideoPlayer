import Foundation

/// The app's handle on timed evidence: one store per profile, the spans a review
/// row needs, and the ONE place a verdict on a suggested tag is written.
///
/// It exists so nothing else has to know the store exists. A view asks for
/// `spans(for:)`; a suggestion pass hands over what it saw through `record(...)`;
/// a click calls `decide(...)`. Because the same click writes the tag store and
/// the evidence, the two cannot disagree about what was decided — and the tag
/// store goes first, because it is authoritative and the evidence is not.
///
/// Evidence is an ADDITION to a suggestion pass, never a precondition for one.
/// Nothing here throws at a caller: a store that cannot be opened, written or
/// read lands in `problem` and the pass keeps its suggestions. The alternative —
/// failing a pass because an audit trail is unavailable — would turn a
/// non-essential record into a reason the user cannot tag their videos.
final class EvidenceJournal: ObservableObject {

    /// One timed claim, in the shape a review row shows.
    struct Span: Equatable, Identifiable {
        let id: Int64
        let label: String
        let start: Double
        let end: Double
        let reason: String
        let confidence: Double?
        let decision: TimedEvidence.Decision
        /// The file has changed since this claim was made: the times describe
        /// bytes that no longer exist, so a reviewer must be told rather than
        /// shown a time that now seeks somewhere else.
        let isStale: Bool
    }

    /// What a pass saw, per tag: the bar that tag was judged against, and the
    /// frames that cleared it with the margin they cleared it by. Built by
    /// `CoreMLClassifier.sightings(path:tags:)`, the same rule that offered the
    /// chip — a claim justified by a different bar would be about something else.
    typealias Sightings = EvidenceProposal.TagSightings

    /// The last thing that went wrong, in a sentence a person can read. Nil when
    /// nothing has. Cleared by the next successful call.
    @Published private(set) var problem: String?

    /// Bumped whenever this video's spans could have changed, so a view showing
    /// them re-reads rather than guessing.
    @Published private(set) var changeCount = 0

    /// The videos this profile has a transcript for. Held rather than asked,
    /// because the playlist's AI menu reads it on every redraw; refreshed when
    /// the profile changes and after every transcription pass.
    private(set) var transcribedPaths: Set<String> = []

    private let root: String
    private var store: EvidenceStore?
    private var openProfile: String?
    /// Cached spans, keyed by video AND by the file's identity at the time they
    /// were read. Keying on the path alone would freeze the first read's answer:
    /// bytes that change behind the app would keep reporting a currency they no
    /// longer have, and the whole point of the stale flag is that it is decided
    /// against the file as it is now.
    private var cache: [String: (revision: TimedEvidence.SourceRevision?, spans: [Span])] = [:]

    init(root: String = Paths.support) {
        self.root = root
    }

    deinit { store?.close() }

    // MARK: - lifetime

    /// Point the journal at a profile. An empty profile closes the store: with no
    /// profile there is no evidence, which is different from none being found.
    func reload(profile: String) {
        guard profile != openProfile || store == nil else { return }
        store?.close()
        store = nil
        cache = [:]
        transcribedPaths = []
        openProfile = profile
        guard !profile.isEmpty else { return }
        do {
            store = try EvidenceStore(root: root, profile: profile)
            problem = nil
            refreshTranscribed()
        } catch {
            // A store that cannot be opened is reported, not fatal: see the
            // type's comment. The next pass still records its suggestions.
            problem = error.localizedDescription
        }
        changeCount += 1
    }

    /// Transcripts arrived from another Mac through the shares: the same store,
    /// new rows, so the list of transcribed videos is read again.
    func transcriptsArrived() {
        refreshTranscribed()
        changeCount += 1
    }

    // MARK: - writing

    /// Transcribe one video through the store that belongs to the OPEN profile.
    /// The journal hands over the store; the pass does the work and the writing.
    ///
    /// Long-running by nature, so nothing here holds a lock across it: the
    /// store is read once, and the pass owns what happens next.
    func transcribe(path: String,
                    using transcriber: SpeechTranscribing,
                    onProgress: @escaping (SpeechProgress) -> Void) async throws -> SpeechOutcome {
        guard let store else { throw SpeechPassRefusal.failed("no profile is open") }
        defer { refreshTranscribed() }
        return try await SpeechPass(transcriber: transcriber, store: store)
            .run(path: path, onProgress: onProgress)
    }

    private func refreshTranscribed() {
        transcribedPaths = (try? store?.transcribedPaths()) ?? []
    }

    // MARK: - reading (T08 S5 reads these)

    /// Every line this profile holds for one video, in order.
    func transcript(for path: String) -> [TranscriptLine] {
        guard let store else { return [] }
        return (try? store.transcript(for: path)) ?? []
    }

    /// Lines whose words match, anywhere in the profile. A query the store
    /// cannot understand returns nothing rather than everything.
    func transcriptMatches(_ query: String, limit: Int = 50) -> [TranscriptLine] {
        guard let store else { return [] }
        return (try? store.transcriptMatches(query, limit: limit)) ?? []
    }

    /// Record what a suggestion pass saw, as timed claims.
    ///
    /// One pass writes ALL of its tags in one call, because the store's
    /// replacement is scoped to (video, capability, model, space, revision) and
    /// per-tag writes would each withdraw the last one's rows.
    ///
    /// Tags whose source has no per-frame times of its own (a library prototype,
    /// a named face) contribute no rows. That is honest rather than empty: those
    /// chips are still offered and still judgeable, they simply have no WHEN to
    /// show, so the review row shows no times for them.
    func record(path: String,
                capability: TimedEvidence.Capability = .tags,
                model: String,
                space: String,
                _ sightings: Sightings) {
        guard let store else { return }
        guard let revision = Self.evidenceRevision(of: path) else {
            problem = "“\((path as NSString).lastPathComponent)” is no longer on disk, so its evidence was not recorded."
            return
        }
        var rows: [TimedEvidence] = []
        for (label, sighting) in sightings.byTag {
            let readings = EvidenceProposal.readings(label: label,
                                                     sampled: sightings.sampled,
                                                     agreed: sighting.hits)
            var limits = EvidenceProposal.Limits()
            // The bar this tag was actually judged against, so the span's
            // confidence and its "cleared the bar" claim are the chip's own.
            limits.threshold = sighting.bar
            rows += EvidenceProposal.spans(readings: readings,
                                           capability: capability,
                                           path: path,
                                           source: model,
                                           space: space,
                                           revision: revision,
                                           limits: limits)
        }
        do {
            try EvidenceProposal.record(rows, in: store, for: path, capability: capability,
                                        source: model, space: space, revision: revision)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        cache[path] = nil
        changeCount += 1
    }

    /// Record what the user decided about one tag, against every timed claim of
    /// that tag for this video. A nil verdict means the decision was taken back,
    /// so the rows return to unanswered — a row that kept an answer the user has
    /// withdrawn would be a record of something that did not happen.
    ///
    /// The verdict is the tag store's own value, and it is already recorded there
    /// by the time this runs: a failure here costs the evidence, never the
    /// decision. `ignored` is written as `ignored`, which is the store's way of
    /// saying it is not a negative example.
    func decide(_ verdict: SuggestionVerdict?, for path: String, label: String,
                capability: TimedEvidence.Capability = .tags) {
        guard let store else { return }
        let decision: TimedEvidence.Decision
        switch verdict {
        case .accepted?: decision = .accepted
        case .rejected?: decision = .rejected
        case .ignored?:  decision = .ignored
        case nil:        decision = .pending
        }
        guard let rows = try? store.evidence(for: path, capability: capability) else { return }
        var failure: String?
        for row in rows where row.label == label {
            guard let id = row.id else { continue }
            do {
                _ = try store.setDecision(decision, id: id)
            } catch {
                failure = error.localizedDescription
            }
        }
        cache[path] = nil
        problem = failure
        changeCount += 1
    }

    // MARK: - reading

    /// This video's timed claims, oldest first, with staleness decided against
    /// the file as it is NOW rather than as it was when the claim was made.
    func spans(for path: String,
               capability: TimedEvidence.Capability = .tags) -> [Span] {
        let current = Self.evidenceRevision(of: path)
        if let cached = cache[path], cached.revision == current { return cached.spans }
        guard let store else { return [] }
        guard let rows = try? store.evidence(for: path, capability: capability) else {
            problem = "This video's recorded evidence could not be read."
            return []
        }
        let spans = rows.map { row -> Span in
            // A claim with no revision at all cannot be checked, so it is shown
            // as stale: unknown is not the same as unchanged. The comparison is
            // the app's own file-identity rule, timestamp slack included.
            let stillThere = current?.matches(row.sourceRevision) ?? false
            return Span(id: row.id ?? 0,
                        label: row.label,
                        start: row.start,
                        end: row.end,
                        reason: row.reason,
                        confidence: row.confidence,
                        decision: row.decision,
                        isStale: !stillThere)
        }
        cache[path] = (current, spans)
        return spans
    }

    /// One tag's claims for this video, in time order.
    func spans(for path: String, label: String,
               capability: TimedEvidence.Capability = .tags) -> [Span] {
        spans(for: path, capability: capability).filter { $0.label == label }
    }

    /// Has this video been looked at at all? Distinguishes "a pass found nothing"
    /// from "no pass has run", which are different answers to the same question.
    func hasEvidence(for path: String, capability: TimedEvidence.Capability = .tags) -> Bool {
        !spans(for: path, capability: capability).isEmpty
    }

    // MARK: - helpers

    /// The app's file identity, in the evidence store's own shape.
    static func evidenceRevision(of path: String) -> TimedEvidence.SourceRevision? {
        SourceRevision.of(path).map {
            TimedEvidence.SourceRevision(bytes: $0.size, modifiedAt: $0.mtime)
        }
    }
}
