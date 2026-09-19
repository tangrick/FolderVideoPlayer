import Foundation
import Combine

/// The analysis store: what the engine has said about each video, and what the
/// humans have said back.
///
/// One JSON file (`analysis.json`, keyed on the same share-relative path keys
/// the tags use), written compact — the file grows with raw frame scores, so
/// pretty printing would be pretty megabytes. The engine and the review UI
/// both read and write through this store; nothing else in the app needs to
/// know where a verdict came from.
///
/// This is deliberately the same shape as the tags side of `Library`: a plain
/// observed object owning a path-keyed dictionary, derived views reading it,
/// and every mutation saved. The heavy passes (sampling, embedding) live in
/// the engine, which reports back through `begin`/`finish`/`fail` — so the
/// store itself never touches a video file, and stays pure model code the
/// test harness can run.
@MainActor
final class AnalysisStore: ObservableObject {

    private(set) var contextID = UUID()

    @Published private(set) var records: [String: VideoAnalysis] = [:]

    /// What a human decided, per profile. The machine's half of a record lives
    /// in `analysis.json` and is shared by every profile (it is arithmetic on
    /// the video, and re-deriving it per profile would mean re-classifying the
    /// library for each one); this half is one person's judgement and is kept
    /// under their own name.
    private var marks: [String: VideoMark] = [:]
    /// The shared machine file. A computed property, so a test that redirects
    /// `Paths.support` after the store exists still reads the right place.
    private var machineFile: String { Paths.analysisFile }
    private var marksFile: String
    private var profileOpen = true

    /// Posted whenever a human mark lands, with the absolute path as object.
    /// The player listens so a video marked NSFW *while playing* re-suggests
    /// immediately — the paired-tag chips would otherwise wait until the
    /// video is left and revisited.
    static let markedNotification = Notification.Name("AnalysisStore.marked")

    init(profile: String = Paths.activeProfile) {
        profileOpen = !profile.isEmpty
        marksFile = Paths.marksFile(in: profile)
        load()
    }

    /// Move to another profile's marks, leaving this one's behind.
    ///
    /// The machine records do not move — they are the same file every profile
    /// reads — so this is only about whose Safe/NSFW word is in force. Nothing
    /// is written here: the marks in hand were already saved when they were
    /// made, and a write now would go to the file this profile is leaving.
    func reload(profile: String) {
        contextID = UUID()
        profileOpen = !profile.isEmpty
        marksFile = Paths.marksFile(in: profile)
        load()
    }

    // MARK: - loading and saving

    func load() {
        let stored: [String: VideoAnalysis] = JSONStore.load(machineFile, fallback: [:])
        // An empty key (or one that is only slashes) names no video; dropping
        // it keeps a hand-edited file from offering a row that can never play.
        var machine: [String: VideoAnalysis] = [:]
        for (key, record) in stored where !key.isEmpty && key != "/" && !key.hasSuffix("/") {
            machine[key] = Self.machineOnly(record)
        }
        // Then the humans' half, laid back over it. A mark on a video the
        // machine has never seen still makes a record: the user's word is
        // enough to put a row in the review window.
        marks = profileOpen ? JSONStore.load(marksFile, fallback: [:]) : [:]
        for (key, mark) in marks {
            var record = machine[key] ?? VideoAnalysis()
            record.userLabel = mark.label
            record.history = mark.history
            record.reviewed = true
            // A mark settles a video — the same thing `mark()` writes — so a
            // mark-only row comes back Done rather than Queued.
            record.phase = .done
            machine[key] = record
        }
        records = machine
    }

    /// Strip what a human owns, leaving the machine's half.
    ///
    /// A file written before marks moved into a profile still carries a label
    /// inside the record. It is dropped rather than trusted: that label
    /// belonged to whoever was in force when it was written, and the profile
    /// now in force is not necessarily them.
    private static func machineOnly(_ record: VideoAnalysis) -> VideoAnalysis {
        var out = record
        out.userLabel = nil
        out.reviewed = false
        out.history = []
        return out
    }

    /// Two files, because they have two owners: the machine's reading of the
    /// videos, and this profile's judgement about them.
    private func save() {
        JSONStore.saveCompact(machineFile, records.mapValues(Self.machineOnly))
        if profileOpen { JSONStore.saveCompact(marksFile, marks) }
    }

    /// What the store knows about one video, by its path. Takes either form —
    /// the tag-keyed share-relative form or an absolute path — because the
    /// playlist rows speak absolute paths while the stored records are keyed
    /// share-relative.
    func analysis(for path: String) -> VideoAnalysis? {
        records[Paths.tagKey(path)]
    }

    // MARK: - the queue
    //
    // The window offers a scan of whatever scope the player is showing; the
    // queue is that ask, held on disk so a quit or a sleeping NAS costs a
    // resume rather than a restart. Only videos nobody has a verdict on yet
    // are queued: a done or reviewed video is not re-asked unless the engine
    // later reports its file changed (the mtime gate, when the engine lands).

    /// Does this video still want the machine's verdict?
    ///
    /// The play-time path asks this before it does anything, so it is what
    /// decides whether watching a folder fills the library in. The answer is
    /// about the QUESTION, not the queue: a video nobody has ever seen wants
    /// one just as much as a row a scan already queued, and that is the point —
    /// a video only becomes queued by somebody asking, and the person watching
    /// it is asking.
    ///
    /// Three things are NOT asked again:
    ///   - a filed verdict (`.done`), which is an answer;
    ///   - a human's mark, whoever filed it — their word outranks the machine
    ///     and no background pass may reopen it;
    ///   - and, deliberately, nothing else. A `.failed` row is worth a retry on
    ///     a different day, and a `.analyzing` row that is genuinely in flight
    ///     cannot reach here (the engine is busy, which the caller checks
    ///     first) — so one that does is stale, left by a quit, and the run
    ///     `rescueStaleAnalyses()` performs at its start picks it back up.
    func needsClassification(_ path: String) -> Bool {
        guard let record = analysis(for: path) else { return true }
        guard record.userLabel == nil else { return false }
        return record.phase != .done
    }

    /// Should playing this video start an automatic classification?
    ///
    /// `needsClassification` answers whether the video wants a verdict at all;
    /// this adds the one rule automation needs on top — a video already tried
    /// this launch is not tried again. Without it, a video the engine cannot
    /// get through would be re-run every time playback returned to it, and on
    /// a machine with no models that is every video, forever.
    ///
    /// The explicit right-click Classify does not come through here and is
    /// never blocked by it: asking again on purpose is always allowed.
    ///
    /// Kept beside the gate rather than in the view, so the rule is reachable
    /// by the test harness — a view's `onChange` is not.
    func wantsAutoClassification(_ path: String, attempted: Set<String>) -> Bool {
        needsClassification(path) && !attempted.contains(Paths.tagKey(path))
    }

    /// Ask for these videos. Unseen ones are queued; failed ones are queued
    /// again (a retry) *in place* — nothing already known about a video is
    /// thrown away to re-ask it. Videos a human has settled, or the engine
    /// has finished, are left alone.
    func enqueue(_ paths: [String]) {
        var changed = false
        for path in paths {
            let key = Paths.tagKey(path)
            var record = records[key]
            // A human's word is terminal — no scan may re-ask a settled
            // video, whatever state its machine pass is in. This guard also
            // covers a hand-edited file that paired a label with .failed.
            if record?.userLabel != nil { continue }
            switch record?.phase {
            case nil:
                records[key] = VideoAnalysis()
                changed = true
            case .failed:
                // The retry re-queues the row itself rather than replacing
                // the record, so anything the failed run left behind (frame
                // scores, a partial verdict) survives to be finished or
                // failed again.
                record?.phase = .queued
                records[key] = record
                changed = true
            default:
                break
            }
        }
        if changed { save() }
    }

    /// Drop a queued row the user no longer wants. Only rows that have not
    /// been touched are droppable — a video mid-analysis belongs to the engine
    /// until it reports back.
    @discardableResult
    func dequeue(_ path: String) -> Bool {
        let key = Paths.tagKey(path)
        guard records[key]?.phase == .queued, records[key]?.userLabel == nil else { return false }
        records.removeValue(forKey: key)
        save()
        return true
    }

    /// Drop every queued row — the window's "cancel the waiting work". Rows
    /// the engine is actively holding are not the queue's to cancel.
    func clearQueue() {
        let before = records.count
        records = records.filter { _, record in
            !(record.phase == .queued && record.userLabel == nil)
        }
        if records.count != before { save() }
    }

    /// Ask the engine again for videos that already have an answer, because
    /// the answer is unusable.
    ///
    /// `enqueue` is about videos with no verdict; this is about videos whose
    /// verdict the app cannot act on. A record can say Done and still be
    /// invisible to everything that reads vectors: `frameScores[].hash` names a
    /// file under `frames/<space>/`, and a run that was interrupted, a cache
    /// write that failed on a full disk, or a vision tower that has since
    /// changed leaves that file missing or in a directory the engine running
    /// now never opens. Such a video cannot be offered by the look-alike search
    /// and cannot be rejected either — the one state a tag never recovers from,
    /// because nothing in the app ever asks about it again.
    ///
    /// Deliberately unlike `enqueue`, this RE-OPENS a Done row: that is the
    /// whole point, and it is the recovery path for a completed record whose
    /// vectors are gone. What it does not do:
    ///
    ///  - a human's mark still wins. A settled video is never re-asked, exactly
    ///    as no scan may re-ask one, and its own label is never overwritten;
    ///  - a row the engine is holding right now is left alone (`analyzing`),
    ///    because it belongs to the run in flight — stealing it would make two
    ///    writers of one record;
    ///  - a row already waiting is not counted again;
    ///  - nothing is cleared. The old verdict and frame scores stay until the
    ///    re-run replaces them, so a run that fails leaves the video with the
    ///    answer it had rather than blanking its only one — and `finish` puts
    ///    the fresh frames in beside the fresh verdict.
    ///
    /// Returns how many rows it re-queued, so a caller can report what it did.
    @discardableResult
    func requeue(_ paths: [String]) -> Int {
        var changed = 0
        for path in paths {
            let key = Paths.tagKey(path)
            guard var record = records[key],
                  record.userLabel == nil,
                  record.phase != .analyzing,
                  record.phase != .queued else { continue }
            record.phase = .queued
            records[key] = record
            changed += 1
        }
        if changed > 0 { save() }
        return changed
    }

    /// The engine picked a queued video up.
    func begin(_ path: String) {
        let key = Paths.tagKey(path)
        guard records[key]?.phase == .queued else { return }
        records[key]?.phase = .analyzing
        save()
    }

    /// Anything still marked analyzing when a run starts is stale: only one
    /// engine pass runs at a time, so a row in flight when the app quit (or a
    /// run was stopped) was never answered. Rescuing it back to queued lets
    /// the next run pick it up where it left off. Human-marked rows are never
    /// touched — a verdict settles a video whatever its pipeline state.
    func rescueStaleAnalyses() {
        var changed = false
        for (key, var record) in records
        where record.phase == .analyzing && record.userLabel == nil {
            record.phase = .queued
            records[key] = record
            changed = true
        }
        if changed { save() }
    }

    /// The engine finished: store its verdict and the raw frame scores.
    ///
    /// A video a human has already reviewed stays reviewed — the correction is
    /// the final word, and a machine re-run must not fling it back into the
    /// review queue. The fresh prediction is still kept, under the human's
    /// label, so the two can be compared later.
    @discardableResult
    func finish(_ path: String, prediction: NsfwPrediction, frames: [FrameScore],
                expectedRevision: SourceRevision? = nil) -> Bool {
        if let expectedRevision, !expectedRevision.matches(path) { return false }
        let key = Paths.tagKey(path)
        var record = records[key] ?? VideoAnalysis()
        let humanHasSpoken = record.userLabel != nil
        record.phase = .done
        record.prediction = prediction
        record.frameScores = frames
        // Record what the verdict is a claim ABOUT: the file's identity now.
        // `isStale(forPath:)` later refuses to count this verdict as current
        // when the file no longer matches — a re-encode or a moved-over video
        // cannot keep serving an answer about its predecessor.
        record.sourceRevision = expectedRevision ?? SourceRevision.of(path)
        record.reviewed = humanHasSpoken ? record.reviewed : false
        records[key] = record
        save()
        return true
    }

    /// The engine gave up on this one. Whatever it managed to say before
    /// failing is kept; the row surfaces under Failed so the user can retry.
    ///
    /// A video a human has already settled is not failed: the engine losing a
    /// race it only entered because it was still working is noise against a
    /// human's verdict, so the record stays Done and the failure is dropped.
    func fail(_ path: String) {
        let key = Paths.tagKey(path)
        guard var record = records[key], record.userLabel == nil else { return }
        record.phase = .failed
        records[key] = record
        save()
    }

    // MARK: - human review

    /// A human decides this video is Safe or NSFW.
    ///
    /// The previous state is written into the record's history before the new
    /// label lands — what the human overruled (the machine's score, or an
    /// earlier human label) — so the training set knows who said what and
    /// what it overturned. Marking the same label twice is a no-op: a second
    /// click on the button you already pressed should not manufacture history.
    ///
    /// The record is settled: its phase becomes Done, so the queue and the
    /// engine stand down. A human verdict is final — no scan re-asks a video
    /// a human has judged, and no failure can reopen it. (An engine run that
    /// was already in flight still lands its verdict beside the human's via
    /// `finish`, which keeps `reviewed` true.)
    func mark(_ label: NsfwLabel, on paths: [String]) {
        guard profileOpen else { return }
        var changed = false
        for path in paths {
            let key = Paths.tagKey(path)
            var record = records[key] ?? VideoAnalysis()
            if record.userLabel == label { continue }
            let previous: String
            if let user = record.userLabel {
                previous = "user:\(user.rawValue)"
            } else if let prediction = record.prediction {
                previous = String(format: "automatic %.3f", prediction.score)
            } else {
                previous = "none"
            }
            record.history.append(Correction(previous: previous, label: label,
                                             at: Date().timeIntervalSince1970,
                                             source: "user_correction"))
            record.userLabel = label
            record.reviewed = true
            record.phase = .done
            records[key] = record
            // The profile's own file is where the word is kept; the machine
            // file never carries it.
            marks[key] = VideoMark(label: label, history: record.history)
            changed = true
        }
        if changed {
            save()
            // A fresh human verdict can change which suggestions belong on the
            // video: NSFW wants the paired-tag candidates, Safe must drop
            // them. The player refreshes its chips for the path now playing.
            for path in paths {
                NotificationCenter.default.post(name: Self.markedNotification, object: path)
            }
        }
    }

    /// Where each video in a scope stands, for the review window's groups.
    ///
    /// A human label always wins the bucket over the pipeline state: a video
    /// the engine has not finished with but a human has already marked stays
    /// in the Safe or NSFW group, because that word is the one the app acts
    /// on — the machine is catching up with the user, not the other way round.
    static func bucket(record: VideoAnalysis?) -> AnalysisBucket {
        guard let record else { return .unseen }
        if let label = record.userLabel {
            return label == .safe ? .safe : .nsfw
        }
        switch record.phase {
        case .queued: return .queued
        case .analyzing: return .working
        case .failed: return .failed
        case .done:
            // A confident machine verdict files itself. Only the uncertain
            // band is handed to a human, which is the whole point of the
            // active-learning queue (spec §17): reviewing calls the machine
            // was never in doubt about teaches nothing and costs the user
            // the entire library by hand.
            if let auto = machineVerdict(record) {
                return auto == .safe ? .safe : .nsfw
            }
            return .needsReview
        }
    }

    // MARK: - the confidence band

    /// Below this the machine's "safe" is trusted without asking.
    ///
    /// Originally set wider (0.35 / 0.65, 2026-09-08) so unfamiliar content
    /// landed in review rather than being filed wrongly. The user's call
    /// (2026-09-09): every verdict files itself at the engine's own 0.5 cut —
    /// a wrong auto-file is one Mark press to overturn, which beats working
    /// the queue by hand. Both constants kept so the band can be reopened by
    /// retuning here, without rewriting a single record.
    static let confidentSafeBelow = 0.5
    /// At or above this the machine's "NSFW" is trusted without asking.
    static let confidentNsfwAbove = 0.5

    /// The machine's own filing for a record, or nil when it is not confident
    /// enough to file (the review band) or has nothing to say yet.
    ///
    /// This never overrules a human — callers check `userLabel` first — and it
    /// stores nothing: the band is a reading of the score, so retuning it
    /// re-files every video without rewriting a single record.
    static func machineVerdict(_ record: VideoAnalysis) -> NsfwLabel? {
        guard record.phase == .done, let score = record.prediction?.score else { return nil }
        if score < confidentSafeBelow { return .safe }
        if score >= confidentNsfwAbove { return .nsfw }
        return nil
    }

    /// The order the review window should offer the undecided rows in: the
    /// machine's most uncertain verdicts first — the score closest to the
    /// 0.5 knife edge — because those are the ones a human look teaches the
    /// most (the spec's active-learning priority, §17). A done row with no
    /// score (nothing to be uncertain about) leads; ties break by name.
    static func reviewOrder<S: Sequence>(_ items: S) -> [String]
    where S.Element == (key: String, record: VideoAnalysis) {
        items
            .filter { bucket(record: $0.record) == .needsReview }
            .sorted { a, b in
                let da = Self.uncertainty(a.record)
                let db = Self.uncertainty(b.record)
                return da == db ? naturalLess(a.key, b.key) : da < db
            }
            .map(\.key)
    }

    /// How close a verdict is to the undecided middle, where a wrong guess
    /// costs the most. A missing score is treated as fully undecided.
    private static func uncertainty(_ record: VideoAnalysis) -> Double {
        guard let score = record.prediction?.score else { return 0 }
        return abs(score - 0.5)
    }
}
