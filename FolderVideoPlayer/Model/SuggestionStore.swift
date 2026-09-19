import Foundation

/// One tag the engine thinks belongs on a video, and what the user did about it.
///
/// Suggestions are deliberately kept OUTSIDE the tag library until accepted.
/// A suggestion is a machine opinion; a tag is the user's word. Mixing the two
/// would make `tags.json` — which syncs to the Apple TV and to other Macs —
/// carry guesses the user never agreed to.
struct TagSuggestion: Codable, Equatable {
    let tag: String
    /// How far this tag's best phrasing beat a bland background phrase, on its
    /// strongest frame. Small numbers: +0.02 is the bar, +0.06 is emphatic.
    /// (For a trained-head suggestion: the head's strongest frame probability.)
    let confidence: Double
    /// How many sampled frames supported it. One frame on a three-frame clip is
    /// meaningful; one frame out of thirty is usually a fluke.
    let frames: Int
    /// Where the advice came from: "zeroshot" (prompt vocabulary) or "trained"
    /// (a head fitted from this user's own accept/reject decisions). Older
    /// stored suggestions have neither; they decode as nil and read as zeroshot.
    var source: String?
}

/// What the user decided about a suggested tag.
///
/// The distinction between `rejected` and `ignored` matters and is the reason
/// this is not a Bool. If the engine offers "birthday, indoor, cake" and the
/// user accepts only "birthday", that is NOT evidence that "cake" was wrong —
/// it may be perfectly accurate but not worth filing. Treating a silent pass as
/// a hard negative would teach the model that correct answers are mistakes.
enum SuggestionVerdict: String, Codable {
    /// The user explicitly said no. A real negative example.
    case rejected
    /// The user accepted it; it is now a tag in the library.
    case accepted
    /// The user dismissed the batch without ruling on this tag. Weak evidence
    /// at best — recorded so it is not offered again and again, but never fed
    /// to training as a negative.
    case ignored
}

/// Everything known about one video's suggestions.
struct VideoSuggestions: Codable {
    var suggestions: [TagSuggestion] = []
    /// Decisions keyed by tag name. Survives re-suggestion: a tag the user
    /// already rejected is not offered again.
    var verdicts: [String: SuggestionVerdict] = [:]
    /// When the engine last produced suggestions for this video.
    var suggestedAt: Date?
    /// Model that produced them, so a model change can invalidate stale advice.
    var model: String?
    /// Frames the engine actually saw — useful when judging a 1-frame result.
    var framesSeen: Int?
    /// Whether the batch was run with the paired candidates on. A video
    /// suggested while safe, then later marked NSFW, must be re-suggested so
    /// the paired-tag chips can appear at all. Optional because files
    /// written before this field existed decode as nil (unknown coverage,
    /// treated as uncovered).
    var pairedCovered: Bool?

    /// How many distinct faces the engine detected in this video. Used by the
    /// UI to offer "who is this?" when faces exist but no name is bound to
    /// them yet. Nil for suggestions recorded before face recognition shipped.
    var facesDetected: Int?

    /// Was this video suggested by a build that records WHEN each tag was seen?
    ///
    /// Nil in every video suggested before that existed, and that is the whole
    /// reason the field is here: those videos have advice but no moments to show
    /// beside it, so they are asked once more — the pass that answers is also the
    /// pass that records the moments — and then never again. Same rule and same
    /// shape as `facesDetected` above.
    var evidenceCovered: Bool?

    /// Suggestions the user has not ruled on yet, strongest first.
    var pending: [TagSuggestion] {
        suggestions
            .filter { verdicts[$0.tag] == nil }
            .sorted { $0.confidence > $1.confidence }
    }
}

/// Stores tag suggestions and the user's decisions about them.
///
/// Two jobs, kept apart on purpose:
///   1. Remember what was suggested, so a video is not re-analysed on every play.
///   2. Remember every accept and reject as training data for later — the point
///      of the whole feature is that the machine gets better at THIS library.
///
/// Persistence mirrors `AnalysisStore`: a plain JSON file next to the others,
/// written through `JSONStore` for the SMB-safe write path, and debounced so a
/// burst of clicks does not hammer the disk.
@MainActor
final class SuggestionStore: ObservableObject {
    @Published private(set) var byVideo: [String: VideoSuggestions] = [:]

    private var saveTask: Task<Void, Never>?
    private var file: String
    private var profileOpen = true

    /// `file` is an explicit override for the tests and nothing else; the app
    /// leaves it nil and lets the path follow the profile in force.
    init(file: String? = nil, profile: String = Paths.activeProfile) {
        self.file = file ?? Paths.suggestionsFile(in: profile)
        profileOpen = file != nil || !profile.isEmpty
        byVideo = profileOpen ? JSONStore.load(self.file, fallback: [String: VideoSuggestions]()) : [:]
    }

    /// Called after a verdict is recorded, with (path, tag, verdict).
    ///
    /// The app routes this into `EvidenceJournal.decide`, so answering a chip
    /// answers its timed evidence in the same breath. The hook lives HERE rather
    /// than at the panel's call sites because a new call site would otherwise be
    /// free to answer a chip and leave its evidence unanswered — and a chip that
    /// says one thing while its evidence says another is worse than no evidence.
    ///
    /// A nil verdict means the decision was taken back (`undecide`).
    var onVerdict: ((String, String, SuggestionVerdict?) -> Void)?

    /// Move to another profile's file, leaving this one's behind.
    ///
    /// Suggestions and verdicts are not merged across profiles and are not
    /// carried over: a rejected chip is one person's word, a video already
    /// suggested under one model is not therefore suggested for the next
    /// person, and a head fitted from these decisions must never be fed a
    /// verdict somebody else made.
    func reload(profile: String) {
        let target = Paths.suggestionsFile(in: profile)
        guard target != file || profileOpen != !profile.isEmpty else { return }
        let leaving = file
        let hadPendingWrite = saveTask != nil
        saveTask?.cancel()
        saveTask = nil
        let inHand = byVideo
        // A debounced write still on its timer is aimed at the file being left.
        // Where it should land depends on why we are leaving. An ordinary
        // profile switch keeps the old folder, so the verdicts belong to it. A
        // RENAME has already moved the folder to the new name, and writing to
        // the old path would re-create a stale copy behind the old name — so
        // the newest verdicts travel with the profile instead.
        let folderStillThere = FileManager.default.fileExists(
            atPath: (leaving as NSString).deletingLastPathComponent)
        if hadPendingWrite && folderStillThere {
            _ = JSONStore.saveCompact(leaving, inHand)
        }
        file = target
        profileOpen = !profile.isEmpty
        byVideo = profileOpen ? JSONStore.load(file, fallback: [String: VideoSuggestions]()) : [:]
        if profileOpen && hadPendingWrite && !folderStillThere {
            byVideo = inHand
            scheduleSave()
        }
    }

    // MARK: - reading

    func entry(_ path: String) -> VideoSuggestions? { byVideo[Paths.tagKey(path)] }

    /// Suggestions still awaiting the user's decision for this video.
    func pending(_ path: String) -> [TagSuggestion] {
        byVideo[Paths.tagKey(path)]?.pending ?? []
    }

    /// Has this video been through the engine already?
    ///
    /// Used to skip re-suggesting on every play. A video whose suggestions came
    /// from a different model is treated as unvisited, since the old advice was
    /// produced in an embedding space that no longer applies. A video whose
    /// last run disagrees about paired coverage is unvisited too: an NSFW
    /// mark after a safe run must bring the paired-tag chips, and a safe
    /// mark after an NSFW run must drop them (nil coverage from older files
    /// counts as false).
    func hasSuggestions(_ path: String, model: String?,
                        paired: Bool = false) -> Bool {
        guard let e = byVideo[Paths.tagKey(path)], e.suggestedAt != nil else { return false }
        if let model, let stored = e.model, stored != model { return false }
        if (e.pairedCovered ?? false) != paired { return false }
        // Face recognition shipped after suggestions existed: an entry whose
        // faces were never checked (facesDetected nil) must be re-suggested
        // once so the face pass runs. Otherwise every video suggested before
        // this feature never gets its faces looked at.
        if e.facesDetected == nil { return false }
        // The same rule for the moments beside a tag. A video suggested before
        // the app recorded when it saw each tag has advice with nothing to show
        // beside it, so it is asked once more — the pass that answers also
        // records the moments — and never again after that. Without this, every
        // video already in the library would keep its times blank for good.
        if e.evidenceCovered != true { return false }
        return true
    }

    /// Should opening this video start an automatic suggestion pass?
    ///
    /// The rule behind "suggestions appear without pressing anything"
    /// (maintainer's decision, 2026-09-17), kept here rather than in the view
    /// so it can be tested: a view's `onChange` is exactly the kind of code
    /// that compiles and then silently never runs.
    ///
    /// No, when the video already has current suggestions — the same staleness
    /// test the rest of the app uses, so a model change or a paired-tags
    /// change still earns a fresh pass. No, when this launch has already tried
    /// it: a pass that produced nothing must not be retried on every
    /// completion, which would spin on a machine with no models installed.
    /// Otherwise yes.
    func wantsAutoSuggestion(_ path: String, model: String?,
                             paired: Bool, attempted: Set<String>) -> Bool {
        if hasSuggestions(path, model: model, paired: paired) { return false }
        return !attempted.contains(Paths.tagKey(path))
    }

    // MARK: - writing

    /// Record a fresh batch from the engine.
    ///
    /// Existing verdicts are preserved: a tag the user already rejected stays
    /// rejected even if the engine offers it again, so the same argument is not
    /// had twice.
    func record(_ path: String, suggestions: [TagSuggestion],
                model: String?, framesSeen: Int?, paired: Bool = false,
                facesDetected: Int? = nil) {
        guard profileOpen else { return }
        let key = Paths.tagKey(path)
        var e = byVideo[key] ?? VideoSuggestions()
        e.suggestions = suggestions
        e.suggestedAt = Date()
        e.model = model
        e.framesSeen = framesSeen
        e.pairedCovered = paired
        e.facesDetected = facesDetected
        // A pass that stored advice is also the pass that recorded the moments
        // beside it (see `PlayerWindow.suggestTags`), so this is set here rather
        // than by a second call that could drift out of step with the first.
        e.evidenceCovered = true
        byVideo[key] = e
        scheduleSave()
    }

    /// Record what the user decided about one tag.
    ///
    /// This is the training signal. Every call here is a labelled example for
    /// this library specifically, which is what a general-purpose model cannot
    /// give us.
    func decide(_ path: String, tag: String, verdict: SuggestionVerdict) {
        guard profileOpen else { return }
        let key = Paths.tagKey(path)
        var e = byVideo[key] ?? VideoSuggestions()
        e.verdicts[tag] = verdict
        byVideo[key] = e
        scheduleSave()
        onVerdict?(path, tag, verdict)
    }

    /// Take a decision back.
    ///
    /// A rejection is a lasting negative example, so the user must be able to
    /// undo one they made by accident — otherwise a mis-click teaches the
    /// model something wrong forever.
    func undecide(_ path: String, tag: String) {
        let key = Paths.tagKey(path)
        guard var e = byVideo[key] else { return }
        e.verdicts.removeValue(forKey: tag)
        byVideo[key] = e
        scheduleSave()
        // Taking a decision back has to reach the evidence too, or the row would
        // go on showing an answer the user has already withdrawn.
        onVerdict?(path, tag, nil)
    }

    /// Mark every still-pending suggestion for a video as ignored.
    ///
    /// Used when the user dismisses the batch. Deliberately `ignored` and not
    /// `rejected` — walking away is not the same as saying no, and only one of
    /// those is safe to train on.
    func dismissRest(_ path: String) {
        let key = Paths.tagKey(path)
        guard var e = byVideo[key] else { return }
        var dismissed: [String] = []
        for s in e.suggestions where e.verdicts[s.tag] == nil {
            e.verdicts[s.tag] = .ignored
            dismissed.append(s.tag)
        }
        byVideo[key] = e
        scheduleSave()
        // One decision per tag, not one for the batch: "not now" is still a
        // verdict on each claim, and the evidence has to be able to say which
        // tags were left alone rather than answered.
        for tag in dismissed { onVerdict?(path, tag, .ignored) }
    }

    /// Forget everything about a video (used when its file is gone).
    func forget(_ path: String) {
        byVideo.removeValue(forKey: Paths.tagKey(path))
        scheduleSave()
    }

    // MARK: - training data

    /// Every decision the user has made, as (tagKey, tag, verdict) triples.
    ///
    /// `ignored` is excluded: it is not a label, it is an absence of one.
    var labelledExamples: [(key: String, tag: String, accepted: Bool)] {
        var out: [(String, String, Bool)] = []
        for (key, e) in byVideo {
            for (tag, verdict) in e.verdicts {
                switch verdict {
                case .accepted: out.append((key, tag, true))
                case .rejected: out.append((key, tag, false))
                case .ignored: continue
                }
            }
        }
        return out.map { (key: $0.0, tag: $0.1, accepted: $0.2) }
    }

    /// How many usable examples exist per tag, strongest first.
    ///
    /// The gate for "can this tag graduate from prompts to a trained model".
    /// Both classes are counted because a classifier needs negatives too.
    func exampleCounts() -> [(tag: String, accepted: Int, rejected: Int)] {
        var acc: [String: Int] = [:]
        var rej: [String: Int] = [:]
        for (_, e) in byVideo {
            for (tag, verdict) in e.verdicts {
                switch verdict {
                case .accepted: acc[tag, default: 0] += 1
                case .rejected: rej[tag, default: 0] += 1
                case .ignored: continue
                }
            }
        }
        let tags = Set(acc.keys).union(rej.keys)
        return tags
            .map { (tag: $0, accepted: acc[$0] ?? 0, rejected: rej[$0] ?? 0) }
            .sorted { ($0.accepted + $0.rejected) > ($1.accepted + $1.rejected) }
    }

    // MARK: - persistence

    /// Coalesce rapid changes: accepting four chips in a row should be one write.
    private func scheduleSave() {
        guard profileOpen else { return }
        saveTask?.cancel()
        let snapshot = byVideo
        let target = file
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            _ = JSONStore.saveCompact(target, snapshot)
            _ = self
        }
    }

    /// Write immediately, for app termination.
    func flush() {
        guard profileOpen else { return }
        saveTask?.cancel()
        saveTask = nil
        _ = JSONStore.saveCompact(file, byVideo)
    }
}

/// The labels for one training pass — everything the engine needs to fit
/// heads for the tags the user has actually ruled on.
///
/// Built by `TrainingSetBuilder` from three stores that all key on the same
/// share-relative path:
///   • the tag library   — every tag the user typed or accepted is a POSITIVE
///   • chip verdicts     — a rejected chip is a NEGATIVE
///   • analysis records  — the frame hashes that name the cached embeddings
///
/// Scope is whatever the caller passes: a playlist's visible videos (the
/// playlist Train button) or every tagged video (Tag Profiles). One builder,
/// two scopes — so both surfaces agree on what counts as a lesson.
@MainActor
struct TrainingSetBuilder {

    /// Exclusive pairs supply each other's negatives: a video tagged with one
    /// side of a forced choice is, by definition, a negative for the other.
    /// The pair is the prompt table's paired tags, as the installed private
    /// overlay names them — none without one.
    nonisolated static func installedPairs(root: String = Paths.support) -> [(String, String)] {
        let names = PromptTable.installedPairedNames(root: root)
        return names.count == 2 ? [(names[0], names[1])] : []
    }

    struct Result {
        var labels: [String: [String: Bool]] = [:]   // tag -> key -> accepted?
        var frameHashes: [String: [String]] = [:]    // key -> cached frame hashes
        /// Keys that carried a tag but have no embeddings yet — they cannot
        /// teach until Analyse has seen them.
        var unanalysed: [String] = []
        /// How many videos in the scope carried at least one tag.
        var taggedCount = 0
    }

    /// Build the training set from the stores. `scopeKeys` limits which
    /// POSITIVES count (the playlist's or tag's videos); once a tag is being
    /// trained its NEGATIVES are tag-global — a rejection lives on a video
    /// that does NOT carry the tag, so filtering negatives by scope would
    /// silently discard every rejection (the exact bug that made tag training
    /// report '0 rejected' despite saved ⌥click rejections). `analysis`
    /// supplies the frame hashes; `library` the tags.
    static func build(scopeKeys: Set<String>?,
                      library: Library,
                      suggestions: SuggestionStore,
                      analysis: AnalysisStore,
                      exclusivePairs: [(String, String)] = installedPairs()) -> Result {
        var out = Result()
        // Positive: the user's own tag library is their word. A video the
        // user tagged "Beach" is a Beach example whether it came from
        // typing or from an accepted chip. Scope applies HERE — the visible
        // rows decide what counts as a yes.
        // A hidden video is invisible to the app, so it is no part of a
        // lesson either — positive or negative. Decided here, once, so every
        // scope (playlist, tag, folder, Tag Profiles) agrees.
        let hidden = library.hidden
        var taggedInScope = 0
        for (key, names) in library.tags
        where scopeKeys?.contains(key) != false && !hidden.contains(key) {
            guard !names.isEmpty else { continue }
            if scopeKeys != nil { taggedInScope += 1 }
            for name in names where !name.isEmpty {
                out.labels[name, default: [:]][key] = true
            }
        }
        // Every tag this pass will train: the positives found in scope.
        let considered = Set(out.labels.keys)
        // Negative: a rejected chip. Only explicit rejections count — an
        // ignored suggestion is an absence of judgement, not a "no". NOT
        // scoped by video: the rejected video is by definition one the user
        // refused to tag, so it would never sit inside the tag's own scope.
        // Only attached to tags this pass is actually training (they have
        // positives), so a stray rejection elsewhere never pollutes a
        // playlist's report with tags nobody asked about.
        //
        // A rejection NEVER overwrites a positive. The user's own tag is
        // their word and outranks a stale or mis-clicked verdict; without
        // this guard a rejection recorded on a video that also carries the
        // tag silently deleted that positive, and rejecting a whole tag
        // playlist left the tag with nothing to train on at all.
        for (key, tag, accepted) in suggestions.labelledExamples
        where !accepted && considered.contains(tag) && !hidden.contains(key) {
            let carriesTag = (library.tags[key] ?? []).contains {
                $0.caseInsensitiveCompare(tag) == .orderedSame
            }
            guard !carriesTag else { continue }
            out.labels[tag, default: [:]][key] = false
        }
        // Exclusive pairs: tagged with one side implies not the other —
        // for any pair side the pass is training. The counterpart videos sit
        // outside the trained tag's scope by definition, so they are read
        // library-wide.
        for (a, b) in exclusivePairs {
            guard considered.contains(a) || considered.contains(b) else { continue }
            for (key, names) in library.tags where !hidden.contains(key) {
                let hasA = names.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame })
                let hasB = names.contains(where: { $0.caseInsensitiveCompare(b) == .orderedSame })
                if hasA && !hasB { out.labels[b, default: [:]][key] = false }
                if hasB && !hasA { out.labels[a, default: [:]][key] = false }
            }
        }
        // Frame hashes for everything labelled: the engine reads the cached
        // embeddings by these names and never re-watches a video.
        var seen = Set<String>()
        for tagLabels in out.labels.values {
            for key in tagLabels.keys where !seen.contains(key) {
                seen.insert(key)
                let hashes = analysis.analysis(for: key)?.frameScores.map(\.hash) ?? []
                out.frameHashes[key] = hashes
                if hashes.isEmpty { out.unanalysed.append(key) }
            }
        }
        out.taggedCount = taggedInScope
        return out
    }
}
