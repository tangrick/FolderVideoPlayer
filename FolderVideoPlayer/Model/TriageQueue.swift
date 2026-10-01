import Foundation

/// Which videos a triage session puts in front of the user.
enum TriageFilter: String, CaseIterable, Identifiable {
    /// Carries no tag but a star rating, and has not been put aside as
    /// "nothing to tag". The default: what is left to do.
    case needsTags
    /// Has a machine suggestion nobody has answered, whatever it carries.
    case hasSuggestions
    /// Has no star rating.
    case unrated
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsTags: return "Needs tags"
        case .hasSuggestions: return "Has suggestions to review"
        case .unrated: return "Unrated"
        case .everything: return "Everything"
        }
    }
}

/// What the queue asks of the library, as plain values — the same shape as
/// `LibraryOverview.Input`, so the rules are tested without a library, a
/// window or a disk.
///
/// Every answer comes from memory. Nothing here stats a file: a share that has
/// gone to sleep answers its first stat in seconds, and the queue is asked about
/// a video on every key.
struct TriageReader {
    /// The video's tags as the profile holds them: ordinary tags, people and
    /// star ratings, which are tags too. Readings (date, camera, place) are not
    /// among them and never count: they are read off the file, not judged.
    var tags: (String) -> [String]
    /// A suggestion nobody has answered, for a tag the video does not already
    /// carry — what the strip would offer.
    var hasPendingSuggestions: (String) -> Bool
    /// Triage already finished with this video and left it untagged on purpose.
    var isReviewed: (String) -> Bool
    var isHidden: (String) -> Bool = { _ in false }
    /// A video that would not open. The playback controller already records
    /// these; the queue just does not keep showing them.
    var isUnavailable: (String) -> Bool = { _ in false }

    /// A video needs tags when it carries nothing but a star rating. A person's
    /// name is a tag; so is anything typed.
    func needsTags(_ path: String) -> Bool {
        !tags(path).contains { !isStarTag($0) }
    }

    func isRated(_ path: String) -> Bool {
        tags(path).contains { isStarTag($0) }
    }

    /// Whether the queue should show this video now. Asked when the cursor
    /// reaches it, not once at the start, so a video another device tagged
    /// in the meantime simply drops out.
    func matches(_ path: String, _ filter: TriageFilter) -> Bool {
        if isHidden(path) || isUnavailable(path) { return false }
        switch filter {
        case .needsTags: return needsTags(path) && !isReviewed(path)
        case .hasSuggestions: return hasPendingSuggestions(path)
        case .unrated: return !isRated(path)
        case .everything: return true
        }
    }
}

/// The order triage walks the videos in, and where it has got to.
///
/// A snapshot of the playlist the user had on screen, in that order: the app
/// has no list of every file on every share, and the playlist already is one
/// folder, tag, smart collection or Overview section. Folder order keeps clips
/// shot together next to each other.
///
/// This holds navigation only. What a decision does to tags and verdicts, and
/// how it is undone, is `TriageSession`.
struct TriageQueue: Equatable {
    let filter: TriageFilter
    /// How many videos the playlist held when the session began.
    let total: Int
    private(set) var current: String?
    /// Seen and left for later this pass. Nothing is recorded about them.
    private(set) var skipped: [String] = []
    /// Finished this session, by Done or by accepting everything.
    private(set) var finished: Set<String> = []

    private var order: [String]
    private var next = 0
    /// Videos put back in front of the cursor by Back, most recent last.
    private var returned: [String] = []
    /// Where the cursor has been, so Back can retrace it.
    private var history: [String] = []

    init(playlist: [String], filter: TriageFilter, reader: TriageReader) {
        var seen = Set<String>()
        order = playlist.filter { seen.insert($0).inserted }
        total = order.count
        self.filter = filter
        current = pullNext(reader)
    }

    /// Nothing left to show now, but some videos were skipped: the moment to
    /// ask whether to go through those again.
    var onlySkippedLeft: Bool { current == nil && !skipped.isEmpty }

    /// Everything has been answered, or was never in need of an answer.
    var isFinished: Bool { current == nil && skipped.isEmpty }

    var canGoBack: Bool { !history.isEmpty }

    /// How many are still to be shown, the one in view included — the number
    /// on the bar. Asks the reader about every video not yet reached, so it is
    /// linear in the queue; the bar asks once per change, not once per frame.
    func left(_ reader: TriageReader) -> Int {
        var count = current == nil ? 0 : 1
        for path in returned where reader.matches(path, filter) { count += 1 }
        for path in order[next...] where reader.matches(path, filter) { count += 1 }
        return count
    }

    // MARK: - moving

    /// The video in view is dealt with; move on.
    mutating func done(_ reader: TriageReader) {
        guard let path = current else { return }
        finished.insert(path)
        advance(reader)
    }

    /// Leave the video in view for later this pass. Nothing is written about it.
    mutating func skip(_ reader: TriageReader) {
        guard let path = current else { return }
        skipped.append(path)
        advance(reader)
    }

    /// Return to the video before this one, to judge it again. It stops being
    /// finished or skipped, and the video being left comes back in its turn.
    @discardableResult
    mutating func back() -> Bool {
        guard let previous = history.popLast() else { return false }
        if let path = current { returned.append(path) }
        finished.remove(previous)
        skipped.removeAll { $0 == previous }
        current = previous
        return true
    }

    /// Make a video the one in view — what an undo does for the decision it
    /// takes back. The video being left is not lost: it comes back in turn.
    mutating func focus(_ path: String) {
        finished.remove(path)
        skipped.removeAll { $0 == path }
        returned.removeAll { $0 == path }
        history.removeAll { $0 == path }
        guard current != path else { return }
        if let leaving = current { returned.append(leaving) }
        current = path
    }

    /// Go through the skipped videos again, once the rest are done.
    mutating func revisitSkipped(_ reader: TriageReader) {
        guard current == nil, !skipped.isEmpty else { return }
        order = skipped
        next = 0
        returned = []
        skipped = []
        current = pullNext(reader)
    }

    private mutating func advance(_ reader: TriageReader) {
        if let path = current { history.append(path) }
        current = pullNext(reader)
    }

    /// The next video that still belongs in the queue. One that no longer does
    /// — tagged on another device, hidden, or one that would not open — is
    /// passed over without a word: it is not an answer anybody owes.
    private mutating func pullNext(_ reader: TriageReader) -> String? {
        while true {
            let candidate: String
            if let back = returned.popLast() {
                candidate = back
            } else if next < order.count {
                candidate = order[next]
                next += 1
            } else {
                return nil
            }
            if reader.matches(candidate, filter) { return candidate }
        }
    }
}

/// The numbered row under the picture: what keys `1` to `9` do for one video.
///
/// **The numbers never move.** The strip is built when a video opens and is
/// only ever added to. Suggestions arrive seconds after a video opens, one pass
/// at a time; if they pushed the chips along, `2` would mean something else
/// between the moment it was read and the moment it was pressed, and a tag
/// would land on the wrong word.
struct TriageStrip: Equatable {
    struct Entry: Equatable {
        enum Kind: Equatable { case suggestion, quick }
        let tag: String
        let kind: Kind
        /// For a suggestion, how sure the engine was; nil for a quick tag.
        let confidence: Double?
    }

    /// Keys `1` to `9`.
    static let keyed = 9

    private(set) var entries: [Entry] = []

    /// Build the strip for a video that has just opened.
    ///
    /// Every pending suggestion first, strongest first, then the session's
    /// quick tags. All of them are shown, because finishing a video dismisses
    /// the suggestions it leaves and none should go unseen; the first nine
    /// chips have keys and the rest are for the mouse. A tag the video already
    /// carries is left out — the engine is right, and saying so wastes a key —
    /// and a tag is never listed twice, case aside.
    static func open(suggestions: [TagSuggestion], carried: Set<String>, quick: [String]) -> TriageStrip {
        var strip = TriageStrip()
        var seen = carried
        for s in strongestFirst(suggestions) {
            guard seen.insert(s.tag.lowercased()).inserted else { continue }
            strip.entries.append(Entry(tag: s.tag, kind: .suggestion, confidence: s.confidence))
        }
        for tag in quick {
            guard seen.insert(tag.lowercased()).inserted else { continue }
            strip.entries.append(Entry(tag: tag, kind: .quick, confidence: nil))
        }
        return strip
    }

    /// Suggestions that arrived after the strip was built go on the end, with
    /// the next numbers. Past the ninth there is no key, only the mouse.
    mutating func appendLate(_ suggestions: [TagSuggestion], carried: Set<String>) {
        var seen = carried.union(entries.map { $0.tag.lowercased() })
        for s in Self.strongestFirst(suggestions) {
            guard seen.insert(s.tag.lowercased()).inserted else { continue }
            entries.append(Entry(tag: s.tag, kind: .suggestion, confidence: s.confidence))
        }
    }

    /// Strongest first; equal strengths keep the order they arrived in, so the
    /// same suggestions always give the same numbers.
    private static func strongestFirst(_ suggestions: [TagSuggestion]) -> [TagSuggestion] {
        suggestions.enumerated()
            .sorted { $0.element.confidence != $1.element.confidence
                      ? $0.element.confidence > $1.element.confidence : $0.offset < $1.offset }
            .map(\.element)
    }

    /// What key `number` (1 to 9) stands for, if anything.
    func entry(forKey number: Int) -> Entry? {
        guard (1...Self.keyed).contains(number), number <= entries.count else { return nil }
        return entries[number - 1]
    }

    /// The key an entry answers to, or nil when it sits past the ninth.
    func key(at index: Int) -> Int? {
        entries.indices.contains(index) && index < Self.keyed ? index + 1 : nil
    }

    /// The tags a session offers on every video: the most used in the scope it
    /// walks, then the most used in the library, up to `limit`.
    ///
    /// Chosen once and left alone for the session, so a key keeps meaning the
    /// same tag. Star ratings are not offered — they have their own control.
    /// Ties fall alphabetically, so the same library gives the same keys.
    static func quickTags(scope: [[String]], popular: [String], limit: Int = keyed) -> [String] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for names in scope {
            for name in names where !isStarTag(name) {
                let key = name.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = name }
            }
        }
        var out = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { display[$0.key] }
        var taken = Set(out.map { $0.lowercased() })
        for name in popular where out.count < limit && !isStarTag(name) {
            if taken.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }
}
