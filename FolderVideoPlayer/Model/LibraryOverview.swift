import Foundation

/// The library at a glance: what is new, what is unfinished, what is done, and
/// what is waiting on the user — each a list that opens as an ordinary
/// playlist, or a door into the window that already handles it.
///
/// Built from memory only (the stores, the warm stat cache), so opening the
/// overview asks no share anything. Recently Added is the one section that
/// needs dates; the caller warms them off the main thread first, and a video
/// whose date is not known yet is simply not in it.
struct LibraryOverview: Equatable {

    enum Kind: String, CaseIterable, Identifiable {
        case continueWatching, recentlyAdded, recentlyWatched, unwatched, awaitingReview, analysisTrouble
        var id: String { rawValue }

        var title: String {
            switch self {
            case .continueWatching: return "Continue Watching"
            case .recentlyAdded: return "Recently Added"
            case .recentlyWatched: return "Recently Watched"
            case .unwatched: return "Unwatched"
            case .awaitingReview: return "Tag Suggestions to Review"
            case .analysisTrouble: return "Analysis Not Finished"
            }
        }

        /// What an empty section says: how it comes to have something in it.
        var emptyNote: String {
            switch self {
            case .continueWatching: return "Videos you stop part-way through appear here."
            case .recentlyAdded: return "Videos added in the last 30 days appear here once their folder has been opened."
            case .recentlyWatched: return "Videos you play appear here."
            case .unwatched: return "Videos the library knows but you have not played appear here."
            case .awaitingReview: return "When the AI suggests tags, the videos waiting for your answer appear here."
            case .analysisTrouble: return "Videos whose analysis failed or is still queued appear here."
            }
        }

        var icon: String {
            switch self {
            case .continueWatching: return "play.circle"
            case .recentlyAdded: return "sparkles"
            case .recentlyWatched: return "clock.arrow.circlepath"
            case .unwatched: return "circle.fill"
            case .awaitingReview: return "tag"
            case .analysisTrouble: return "exclamationmark.triangle"
            }
        }
    }

    /// Absolute paths per section, most relevant first.
    var sections: [Kind: [String]] = [:]

    func paths(_ kind: Kind) -> [String] { sections[kind] ?? [] }

    static let recentDays = 30.0
    static let listLimit = 200

    /// Everything the overview reads, as plain values — so it is built and
    /// tested without a window, and the rules for each section live here.
    struct Input {
        /// Known videos (share-relative keys), hidden already removed.
        var known: [String]
        var hidden: Set<String>
        var watch: (String) -> WatchLog.State
        var lastPlayed: (String) -> Double?
        /// Resume position stamps, by absolute path.
        var progressSeen: [String: Double]
        /// Date added, by absolute path; missing when not yet known.
        var addedOn: [String: Double]
        var hasPendingSuggestions: (String) -> Bool
        var analysis: (String) -> AnalysisBucket
        var now: Double = Date().timeIntervalSince1970
    }

    static func build(_ input: Input) -> LibraryOverview {
        let known = input.known.filter { !input.hidden.contains($0) }
        var out = LibraryOverview()

        // Unfinished, the one touched most recently first.
        out.sections[.continueWatching] = input.progressSeen
            .filter { path, _ in
                let key = Paths.tagKey(path)
                return !input.hidden.contains(key) && input.watch(key) == .inProgress
            }
            .sorted { $0.value > $1.value }
            .map(\.key)
            .prefix(listLimit).map { $0 }

        let cutoff = input.now - recentDays * 86_400
        out.sections[.recentlyAdded] = known
            .compactMap { key -> (String, Double)? in
                let path = Paths.tagPath(key)
                guard let when = input.addedOn[path], when >= cutoff else { return nil }
                return (path, when)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(listLimit).map(\.0)

        out.sections[.recentlyWatched] = known
            .compactMap { key -> (String, Double)? in
                input.lastPlayed(key).map { (Paths.tagPath(key), $0) }
            }
            .sorted { $0.1 > $1.1 }
            .prefix(listLimit).map(\.0)

        out.sections[.unwatched] = known
            .filter { input.watch($0) == .unwatched }
            .map { Paths.tagPath($0) }

        out.sections[.awaitingReview] = known
            .filter(input.hasPendingSuggestions)
            .map { Paths.tagPath($0) }

        out.sections[.analysisTrouble] = known
            .filter {
                switch input.analysis($0) {
                case .failed, .queued, .working: return true
                default: return false
                }
            }
            .map { Paths.tagPath($0) }
        return out
    }
}
