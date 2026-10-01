import Foundation

/// What one decision changed on one video, taken just before it was made, so
/// undo can put all of it back exactly.
///
/// Not `Library.rememberForUndo`: that keeps ONE snapshot of every tag in the
/// library and writes two files each time. A session of a few hundred decisions
/// through it would cost a full rewrite apiece and, worse, spend the one slot
/// on a single video's change and lose whatever the user could really have
/// undone before.
struct TriageStep: Equatable {
    let path: String
    let tagsBefore: [String]
    let verdictsBefore: [String: SuggestionVerdict]
    let triagedBefore: Date?
}

/// A review session: the queue, the strip for the video in view, and what each
/// answer does to the tags and to the suggestion verdicts.
///
/// **What each answer records** is the part that must not drift, because the
/// verdicts are training data (see `SuggestionVerdict`):
///   - accepting a suggestion records `accepted`; so does a tag typed by hand
///     that happens to be a pending suggestion, once the video is finished with;
///   - only `reject` and `rejectAll` record `rejected`, a real negative;
///   - finishing a video records `ignored` for the suggestions it leaves, as
///     Dismiss All does: walking away is not saying no;
///   - skipping, going back and moving past a video record nothing.
@MainActor
final class TriageSession: ObservableObject {
    private let library: Library
    private let suggestions: SuggestionStore
    private let unavailable: (String) -> Bool

    @Published private(set) var queue: TriageQueue
    @Published private(set) var strip = TriageStrip()
    /// The strip each video had when it was last in view, so coming back to
    /// one (Back, or an undo) shows the same chips under the same numbers.
    /// Without it a finished video came back bare: its suggestions are no
    /// longer pending, and the tags it was given are left out of a new strip.
    private var strips: [String: TriageStrip] = [:]
    /// The decisions made so far, newest last. In memory: it ends with the
    /// session, and what was already written stays written.
    @Published private(set) var steps: [TriageStep] = []

    /// The tags offered on every video, fixed for the session.
    let quick: [String]

    /// `unavailable` answers for a video that would not open; the playback
    /// controller keeps that list.
    init(library: Library, suggestions: SuggestionStore, playlist: [String],
         filter: TriageFilter = .needsTags, unavailable: @escaping (String) -> Bool = { _ in false }) {
        self.library = library
        self.suggestions = suggestions
        self.unavailable = unavailable
        let popular = library.tagCounts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.lowercased() < $1.key.lowercased() }
            .map(\.key)
        quick = TriageStrip.quickTags(scope: playlist.map { library.tagsFor($0) }, popular: popular)
        queue = TriageQueue(playlist: playlist, filter: filter,
                            reader: Self.reader(library, suggestions, unavailable))
        openCurrent()
    }

    /// The library as triage's queue asks about it. Also what the Library
    /// Overview's Needs Tags section asks, so the two share one definition.
    static func reader(_ library: Library, _ suggestions: SuggestionStore,
                       _ unavailable: @escaping (String) -> Bool = { _ in false }) -> TriageReader {
        TriageReader(
            tags: { library.tagsFor($0) },
            hasPendingSuggestions: { path in
                let carried = Set(library.tagsFor(path).map { $0.lowercased() })
                return suggestions.pending(path).contains { !carried.contains($0.tag.lowercased()) }
            },
            isReviewed: { suggestions.triagedAt($0) != nil },
            isHidden: { library.isHidden($0) },
            isUnavailable: unavailable)
    }

    private var reader: TriageReader { Self.reader(library, suggestions, unavailable) }

    var current: String? { queue.current }
    var canUndo: Bool { !steps.isEmpty }
    /// The number on the bar. Counting it reads every video not yet reached
    /// (20 ms over eleven thousand), so it is counted when the cursor moves
    /// and kept, not counted again each time the bar is drawn.
    @Published private(set) var left = 0

    // MARK: - what the strip shows

    /// Whether the tag is on the video in view.
    func isApplied(_ entry: TriageStrip.Entry) -> Bool {
        guard let path = queue.current else { return false }
        return library.hasTag(path, entry.tag)
    }

    /// Whether the suggestion was answered no, and the tag is not on the video.
    func isRejected(_ entry: TriageStrip.Entry) -> Bool {
        guard let path = queue.current, entry.kind == .suggestion else { return false }
        return verdict(path, entry.tag) == .rejected && !library.hasTag(path, entry.tag)
    }

    /// Suggestions can land after a video opened. They join the strip on the
    /// end, with the next numbers; none already there moves.
    func refreshSuggestions() {
        guard let path = queue.current else { return }
        strip.appendLate(suggestions.pending(path), carried: carried(path))
        strips[path] = strip
    }

    // MARK: - answers

    /// Keys `1` to `9`: put the tag on the video, or take it off again.
    func toggle(key number: Int) {
        guard let entry = strip.entry(forKey: number) else { return }
        toggle(entry)
    }

    /// Taking a suggestion off again withdraws the answer it was given: it is
    /// pending once more. That is the user changing their mind, not a no.
    func toggle(_ entry: TriageStrip.Entry) {
        guard library.profileOpen, let path = queue.current else { return }
        record(path)
        if library.hasTag(path, entry.tag) {
            remove(entry.tag, from: path)
            if entry.kind == .suggestion, verdict(path, entry.tag) == .accepted {
                suggestions.undecide(path, tag: entry.tag)
            }
        } else {
            add([entry.tag], to: path)
            if entry.kind == .suggestion {
                suggestions.decide(path, tag: entry.tag, verdict: .accepted)
            }
        }
        library.saveTagsSoon()
    }

    /// `⌥1` to `⌥9`: the suggestion is wrong. Takes the tag off if it is on,
    /// and records a real negative. Does nothing to a quick tag, which is not
    /// a claim the engine made.
    func reject(key number: Int) {
        guard let entry = strip.entry(forKey: number) else { return }
        reject(entry)
    }

    func reject(_ entry: TriageStrip.Entry) {
        guard library.profileOpen, entry.kind == .suggestion, let path = queue.current else { return }
        guard library.hasTag(path, entry.tag) || verdict(path, entry.tag) != .rejected else { return }
        record(path)
        if library.hasTag(path, entry.tag) {
            remove(entry.tag, from: path)
            library.saveTagsSoon()
        }
        suggestions.decide(path, tag: entry.tag, verdict: .rejected)
    }

    /// The suggestions shown that `rejectAll` would answer no: not on the video,
    /// and not refused already.
    private var rejectable: [TriageStrip.Entry] {
        guard let path = queue.current else { return [] }
        return strip.entries.filter {
            $0.kind == .suggestion && !library.hasTag(path, $0.tag) && verdict(path, $0.tag) != .rejected
        }
    }

    var canRejectAll: Bool { !rejectable.isEmpty }

    /// `X`: every suggestion shown that was not taken is wrong. One step, so
    /// one undo. It stays on the video: wrong guesses do not mean there is
    /// nothing to tag. A suggestion already put on the video is left alone.
    func rejectAll() {
        let wrong = rejectable
        guard library.profileOpen, let path = queue.current, !wrong.isEmpty else { return }
        record(path)
        for entry in wrong {
            suggestions.decide(path, tag: entry.tag, verdict: .rejected)
        }
    }

    /// Tags typed by hand, comma separated as in the tag panel.
    func addTyped(_ text: String) {
        let names = parseTags(text)
        guard library.profileOpen, !names.isEmpty, let path = queue.current else { return }
        record(path)
        add(names, to: path)
        library.saveTagsSoon()
    }

    /// Whether there is a suggestion `acceptAll` would take or keep: one that
    /// was not answered no.
    var canAcceptAll: Bool {
        guard let path = queue.current else { return false }
        return strip.entries.contains {
            $0.kind == .suggestion && (verdict(path, $0.tag) != .rejected || library.hasTag(path, $0.tag))
        }
    }

    /// `A`: accept every suggestion shown, then move on. With none to accept
    /// it does nothing, so it cannot be mistaken for Done. A suggestion
    /// answered no is not brought back.
    func acceptAll() {
        guard library.profileOpen, let path = queue.current, canAcceptAll else { return }
        record(path)
        for entry in strip.entries where entry.kind == .suggestion {
            if verdict(path, entry.tag) == .rejected, !library.hasTag(path, entry.tag) { continue }
            add([entry.tag], to: path)
            suggestions.decide(path, tag: entry.tag, verdict: .accepted)
        }
        library.saveTagsSoon()
        finish(path)
    }

    /// `Return`: finished with this video, whatever state it is in.
    ///
    /// Suggestions it carries by now count as accepted, since the user put the
    /// tag there; the rest are ignored. A video that still has no tag is put
    /// aside as "nothing to tag", so it does not come round again.
    func done() {
        guard library.profileOpen, let path = queue.current else { return }
        record(path)
        finish(path)
    }

    /// Leave it for later this pass. Records nothing.
    func skip() {
        queue.skip(reader)
        openCurrent()
    }

    @discardableResult
    func back() -> Bool {
        guard queue.back() else { return false }
        openCurrent()
        return true
    }

    func revisitSkipped() {
        queue.revisitSkipped(reader)
        openCurrent()
    }

    /// Take back the last answer exactly — tags, verdicts and the "nothing to
    /// tag" mark — and return to that video.
    @discardableResult
    func undo() -> Bool {
        guard library.profileOpen, let step = steps.popLast() else { return false }
        library.setTags(step.tagsBefore, for: step.path)
        library.saveTagsSoon()
        let now = suggestions.entry(step.path)?.verdicts ?? [:]
        for tag in now.keys where step.verdictsBefore[tag] == nil {
            suggestions.undecide(step.path, tag: tag)
        }
        for (tag, before) in step.verdictsBefore where now[tag] != before {
            suggestions.decide(step.path, tag: tag, verdict: before)
        }
        if suggestions.triagedAt(step.path) != step.triagedBefore {
            suggestions.setTriaged(step.path, to: step.triagedBefore)
        }
        queue.focus(step.path)
        openCurrent()
        return true
    }

    // MARK: - internals

    private func finish(_ path: String) {
        let carriedNow = carried(path)
        for s in suggestions.pending(path) where carriedNow.contains(s.tag.lowercased()) {
            suggestions.decide(path, tag: s.tag, verdict: .accepted)
        }
        suggestions.dismissRest(path)
        if !library.tagsFor(path).contains(where: { !isStarTag($0) }) {
            suggestions.setTriaged(path, to: Date())
        }
        queue.done(reader)
        openCurrent()
    }

    private func openCurrent() {
        left = queue.left(reader)
        guard let path = queue.current else { strip = TriageStrip(); return }
        if var seen = strips[path] {
            seen.appendLate(suggestions.pending(path), carried: carried(path))
            strip = seen
        } else {
            strip = TriageStrip.open(suggestions: suggestions.pending(path),
                                     carried: carried(path), quick: quick)
        }
        strips[path] = strip
    }

    private func record(_ path: String) {
        steps.append(TriageStep(path: path,
                                tagsBefore: library.tagsFor(path),
                                verdictsBefore: suggestions.entry(path)?.verdicts ?? [:],
                                triagedBefore: suggestions.triagedAt(path)))
    }

    private func carried(_ path: String) -> Set<String> {
        Set(library.tagsFor(path).map { $0.lowercased() })
    }

    private func verdict(_ path: String, _ tag: String) -> SuggestionVerdict? {
        suggestions.entry(path)?.verdicts[tag]
    }

    /// Append names the video does not carry. Not `Library.addTag`, which is
    /// right for a batch but writes the file itself; the caller saves once.
    private func add(_ names: [String], to path: String) {
        var have = library.tagsFor(path)
        for name in names where !have.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            have.append(name)
        }
        library.setTags(have, for: path)
    }

    /// Not `Library.removeTag`: that spends the single undo slot on every call.
    private func remove(_ name: String, from path: String) {
        library.setTags(library.tagsFor(path).filter { $0.caseInsensitiveCompare(name) != .orderedSame },
                        for: path)
    }
}
