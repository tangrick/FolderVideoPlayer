import Foundation

/// A saved library question — "unwatched videos of Anna rated 4 stars or more"
/// — that answers itself again whenever the library changes.
///
/// Only the QUESTION is stored. Which videos answer it is computed from the
/// library as it is now (`SmartEvaluator`), so a collection can never hold a
/// stale list, and deleting one deletes nothing but the question.
struct SmartCollection: Codable, Equatable, Identifiable {
    enum Match: String, Codable, CaseIterable, Identifiable {
        case all, any
        var id: String { rawValue }
        var title: String { self == .all ? "All" : "Any" }
    }

    var id = UUID()
    var name: String
    var match: Match = .all
    var rules: [SmartRule] = []
}

/// One condition. Stored flat — a kind and the fields that kind uses — so a
/// file written by a newer build with a kind this one does not know still
/// loads: the unknown rule is kept, shown as not understood, and matches
/// nothing, rather than the whole file failing to read.
struct SmartRule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case tag, person, rating, recorded, added, transcript, playback, analysis, verdict, file
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tag: return "Tag"
            case .person: return "Person"
            case .rating: return "Rating"
            case .recorded: return "Recording date"
            case .added: return "Date added"
            case .transcript: return "Transcript"
            case .playback: return "Playback"
            case .analysis: return "Analysis"
            case .verdict: return "Safe / NSFW"
            case .file: return "File"
            }
        }
    }

    /// How a value is compared. Which apply depends on the kind.
    enum Op: String, Codable, CaseIterable, Identifiable {
        case includes, excludes          // tag, person
        case equals, atLeast, atMost     // rating
        case before, after, between      // dates
        case contains                    // transcript
        case isValue                     // playback, analysis, verdict, file
        var id: String { rawValue }
        var title: String {
            switch self {
            case .includes: return "is"
            case .excludes: return "is not"
            case .equals: return "is exactly"
            case .atLeast: return "is at least"
            case .atMost: return "is at most"
            case .before: return "is before"
            case .after: return "is after"
            case .between: return "is between"
            case .contains: return "contains"
            case .isValue: return "is"
            }
        }
    }

    var id = UUID()
    /// Raw rather than `Kind`, so an unknown kind survives a round trip.
    var type: String
    var op: String
    /// The tag or person name, the transcript words, or the state's raw value.
    var text: String = ""
    /// Star count for a rating (0 = unrated).
    var stars: Int = 0
    /// Seconds since 1970 — the date, or a range's start.
    var from: Double = 0
    /// A range's end, inclusive of that whole day.
    var to: Double = 0

    init(kind: Kind, op: Op, text: String = "", stars: Int = 0, from: Double = 0, to: Double = 0) {
        self.type = kind.rawValue
        self.op = op.rawValue
        self.text = text
        self.stars = stars
        self.from = from
        self.to = to
    }

    var kind: Kind? { Kind(rawValue: type) }
    var comparison: Op? { Op(rawValue: op) }

    /// The comparisons a kind offers, in the order a menu shows them.
    static func ops(for kind: Kind) -> [Op] {
        switch kind {
        case .tag, .person: return [.includes, .excludes]
        case .rating: return [.equals, .atLeast, .atMost]
        case .recorded, .added: return [.before, .after, .between]
        case .transcript: return [.contains]
        case .playback, .analysis, .verdict, .file: return [.isValue]
        }
    }

    /// The values a state-like kind can take: raw value and title.
    static func values(for kind: Kind) -> [(raw: String, title: String)] {
        switch kind {
        case .playback: return WatchLog.State.allCases.map { ($0.rawValue, $0.title) }
        case .analysis: return SmartAnalysis.allCases.map { ($0.rawValue, $0.title) }
        case .verdict: return SmartVerdict.allCases.map { ($0.rawValue, $0.title) }
        case .file: return SmartFileState.allCases.map { ($0.rawValue, $0.title) }
        default: return []
        }
    }

    /// A new rule of this kind with sensible defaults.
    static func fresh(_ kind: Kind) -> SmartRule {
        let op = ops(for: kind)[0]
        let now = Date().timeIntervalSince1970
        switch kind {
        case .rating: return SmartRule(kind: kind, op: .atLeast, stars: 4)
        case .recorded, .added: return SmartRule(kind: kind, op: .after, from: now - 365 * 86_400, to: now)
        case .playback, .analysis, .verdict, .file:
            return SmartRule(kind: kind, op: op, text: values(for: kind).first?.raw ?? "")
        default: return SmartRule(kind: kind, op: op)
        }
    }

    /// Does this rule need a file's stat to answer? Such rules are answered
    /// from values gathered off the main thread, never while a row is drawn.
    var needsDisk: Bool { kind == .added || kind == .file }
}

enum SmartAnalysis: String, CaseIterable {
    case pending, failed, complete
    var title: String {
        switch self {
        case .pending: return "Pending"
        case .failed: return "Failed"
        case .complete: return "Complete"
        }
    }
    static func from(_ bucket: AnalysisBucket) -> SmartAnalysis {
        switch bucket {
        case .unseen, .queued, .working: return .pending
        case .failed: return .failed
        case .needsReview, .safe, .nsfw: return .complete
        }
    }
}

enum SmartVerdict: String, CaseIterable {
    case safe, nsfw, needsReview
    var title: String {
        switch self {
        case .safe: return "Safe"
        case .nsfw: return "NSFW"
        case .needsReview: return "Needs review"
        }
    }
    static func from(_ bucket: AnalysisBucket) -> SmartVerdict? {
        switch bucket {
        case .safe: return .safe
        case .nsfw: return .nsfw
        case .needsReview: return .needsReview
        default: return nil
        }
    }
}

enum SmartFileState: String, CaseIterable {
    case missing, playable, needsConversion
    var title: String {
        switch self {
        case .missing: return "Missing"
        case .playable: return "Playable"
        case .needsConversion: return "Needs conversion"
        }
    }
    /// What AVFoundation plays; anything else needs a converted copy.
    static let playableExtensions: Set<String> = ["mp4", "m4v", "mov"]
    static func of(path: String, exists: Bool) -> SmartFileState {
        guard exists else { return .missing }
        return playableExtensions.contains((path as NSString).pathExtension.lowercased())
            ? .playable : .needsConversion
    }
}

/// Everything a collection's rules are answered from, gathered once per
/// evaluation. Closures over the stores, so the evaluator reads the live
/// library in tests and the app alike; `transcriptHits`, `addedOn` and
/// `fileExists` are filled in advance (the last two off the main thread).
struct SmartContext {
    /// Every video the library knows, as share-relative keys, hidden ones already
    /// removed.
    var universe: [String]
    /// A video's tags and readings.
    var names: (String) -> [String]
    var rating: (String) -> Int
    var watch: (String) -> WatchLog.State
    var analysis: (String) -> AnalysisBucket
    /// A video's recording date (from its Date readings), or nil.
    var recorded: (String) -> Double?
    /// Words → the keys of the videos whose transcript contains them.
    var transcriptHits: [String: Set<String>] = [:]
    var addedOn: [String: Double] = [:]
    var fileExists: [String: Bool] = [:]
}

enum SmartEvaluator {

    /// The keys a collection picks out, in the universe's order. All: every
    /// rule must hold. Any: at least one. No rules: nothing — an empty question
    /// is not "everything".
    static func members(_ collection: SmartCollection, in context: SmartContext) -> [String] {
        guard !collection.rules.isEmpty else { return [] }
        return context.universe.filter { key in
            switch collection.match {
            case .all: return collection.rules.allSatisfy { holds($0, for: key, context) }
            case .any: return collection.rules.contains { holds($0, for: key, context) }
            }
        }
    }

    /// One rule on one video. A value the video does not have (no recording
    /// date, never stat-ed) makes a comparison false rather than guessing.
    static func holds(_ rule: SmartRule, for key: String, _ c: SmartContext) -> Bool {
        guard let kind = rule.kind, let op = rule.comparison else { return false }
        switch kind {
        case .tag, .person:
            let has = c.names(key).contains { $0.caseInsensitiveCompare(rule.text) == .orderedSame }
            return op == .excludes ? !has : has
        case .rating:
            let stars = c.rating(key)
            switch op {
            case .equals: return stars == rule.stars
            case .atLeast: return stars >= rule.stars
            case .atMost: return stars <= rule.stars
            default: return false
            }
        case .recorded:
            guard let when = c.recorded(key) else { return false }
            return compare(when, op, rule)
        case .added:
            guard let when = c.addedOn[key], when > 0 else { return false }
            return compare(when, op, rule)
        case .transcript:
            return c.transcriptHits[normalised(rule.text)]?.contains(key) ?? false
        case .playback:
            return c.watch(key).rawValue == rule.text
        case .analysis:
            return SmartAnalysis.from(c.analysis(key)).rawValue == rule.text
        case .verdict:
            return SmartVerdict.from(c.analysis(key))?.rawValue == rule.text
        case .file:
            guard let exists = c.fileExists[key] else { return false }
            return SmartFileState.of(path: key, exists: exists).rawValue == rule.text
        }
    }

    /// Dates are compared by day: "after 3 May" means from 4 May on, and
    /// "between" includes both end days.
    private static func compare(_ when: Double, _ op: SmartRule.Op, _ rule: SmartRule) -> Bool {
        let day = 86_400.0
        let calendar = Calendar.current
        func startOfDay(_ t: Double) -> Double {
            calendar.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970
        }
        switch op {
        case .before: return when < startOfDay(rule.from)
        case .after: return when >= startOfDay(rule.from) + day
        case .between:
            let lo = startOfDay(min(rule.from, rule.to)), hi = startOfDay(max(rule.from, rule.to)) + day
            return when >= lo && when < hi
        default: return false
        }
    }

    /// Transcript words as looked up: trimmed, lower-cased.
    static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Why a rule cannot be answered as meant, in a sentence — or nil when it
    /// can. A tag or person that no longer exists is the common case: the rule
    /// still runs (and matches nothing, or everything for "is not"), but the
    /// user must be told rather than left wondering why the list is empty.
    static func problem(with rule: SmartRule, knownNames: (String) -> Bool) -> String? {
        guard let kind = rule.kind, let op = rule.comparison else {
            return "This rule was made by a newer version of the app and is not understood here."
        }
        guard SmartRule.ops(for: kind).contains(op) else { return "This rule's comparison does not fit its kind." }
        switch kind {
        case .tag, .person:
            let name = rule.text.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return "Choose a \(kind == .tag ? "tag" : "person")." }
            if !knownNames(name) {
                return "“\(name)” is not on any video any more — it may have been renamed or deleted."
            }
        case .transcript:
            if normalised(rule.text).isEmpty { return "Type the words to look for." }
        case .rating:
            if !(0...5).contains(rule.stars) { return "A rating is 0 to 5 stars." }
        case .playback, .analysis, .verdict, .file:
            if !SmartRule.values(for: kind).contains(where: { $0.raw == rule.text }) {
                return "Choose a value."
            }
        case .recorded, .added:
            break
        }
        return nil
    }
}

/// A profile's collections on disk. Versioned; derived membership is never
/// stored.
struct SmartCollectionFile: Codable, Equatable {
    static let currentVersion = 1
    var version = SmartCollectionFile.currentVersion
    var collections: [SmartCollection] = []

    static func load(at path: String) -> SmartCollectionFile {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(SmartCollectionFile.self, from: data) else {
            return SmartCollectionFile()
        }
        return file
    }

    func save(to path: String) -> Bool {
        var copy = self
        copy.version = max(version, Self.currentVersion)
        return JSONStore.save(path, copy)
    }
}
