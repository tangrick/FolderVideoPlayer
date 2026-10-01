import Foundation

/// What this profile has watched: when each video was last played, and whether
/// it was finished — so a library can say what is new, what is unfinished and
/// what is done.
///
/// The resume position (`state.json`'s `progress`) already says where a video
/// got to, but it is deliberately forgotten at both ends: a video barely begun
/// or all but finished starts from the top next time. That is right for resuming
/// and wrong for remembering, so completion is written down here instead.
///
/// Keyed share-relative (`Paths.tagKey`) like tags, so a video watched on one
/// Mac through a share is the same video to another. One file per profile —
/// what somebody has watched is theirs, not the Mac's.
struct WatchLog: Codable, Equatable {

    enum State: String, CaseIterable, Identifiable {
        /// No meaningful playback.
        case unwatched
        /// Past the opening, short of the end.
        case inProgress
        /// Played to the end, or marked watched.
        case watched

        var id: String { rawValue }
        var title: String {
            switch self {
            case .unwatched: return "Unwatched"
            case .inProgress: return "In Progress"
            case .watched: return "Watched"
            }
        }
    }

    struct Entry: Codable, Equatable {
        /// The last time it was played past its opening. Nil when never.
        var lastPlayedAt: Double?
        /// When it was finished (or marked watched). Nil when it has not been.
        var completedAt: Double?
    }

    static let currentVersion = 1

    var version = WatchLog.currentVersion
    private(set) var entries: [String: Entry] = [:]

    init() {}

    // MARK: - thresholds

    /// Past this, a play counts: the opening seconds of a video are sampling,
    /// not watching. Thirty seconds — the resume rule's own — or a quarter of a
    /// short clip, whichever comes first.
    static func opening(total: Double) -> Double {
        total > 0 ? min(Tuning.resumeMin, total * 0.25) : Tuning.resumeMin
    }

    /// At or past this, the video is finished: the last thirty seconds (the
    /// resume rule's tail, where credits live) or the last tenth of a short
    /// clip — never the whole of one, so a 20-second clip is not finished the
    /// moment it starts.
    static func isCompletion(position: Double, total: Double) -> Bool {
        guard total > 0, position.isFinite else { return false }
        return position >= total - min(Tuning.resumeTail, total * 0.1)
    }

    // MARK: - reading

    func entry(_ key: String) -> Entry? { entries[key] }

    /// Where a video stands. `resume` is its remembered position, if any — the
    /// in-progress half of the answer lives with resuming.
    func state(_ key: String, resume: Double?) -> State {
        if entries[key]?.completedAt != nil { return .watched }
        if let resume, resume > 0 { return .inProgress }
        return .unwatched
    }

    var keys: Dictionary<String, Entry>.Keys { entries.keys }

    // MARK: - writing

    /// What a playback sample means. Returns what changed, so the caller can
    /// tell a new fact (first play, finished) from a routine refresh of the
    /// last-played time, which is written but not announced.
    enum Change { case none, refreshed, stateChanged }

    @discardableResult
    mutating func notePlayback(_ key: String, position: Double, total: Double,
                               now: Double = Date().timeIntervalSince1970) -> Change {
        guard !key.isEmpty, position.isFinite, position >= Self.opening(total: total) else { return .none }
        var entry = entries[key] ?? Entry()
        var change = Change.none
        if Self.isCompletion(position: position, total: total), entry.completedAt == nil {
            entry.completedAt = now
            change = .stateChanged
        }
        if entry.lastPlayedAt == nil {
            change = .stateChanged
        }
        // Refreshed at most once a minute: a sample arrives every few seconds,
        // and "last played" is not a question asked to the second.
        if entry.lastPlayedAt == nil || now - (entry.lastPlayedAt ?? 0) >= 60 {
            entry.lastPlayedAt = now
            if change == .none { change = .refreshed }
        }
        guard change != .none else { return .none }
        entries[key] = entry
        return change
    }

    /// Mark videos watched or unwatched by hand. Unwatched forgets both the
    /// completion and the last play, so the video reads as new again.
    mutating func mark(_ keys: [String], watched: Bool, now: Double = Date().timeIntervalSince1970) {
        for key in keys where !key.isEmpty {
            if watched {
                var entry = entries[key] ?? Entry()
                if entry.completedAt == nil { entry.completedAt = now }
                entries[key] = entry
            } else {
                entries.removeValue(forKey: key)
            }
        }
    }

    /// A file moved: its history goes with it. A destination with history of
    /// its own keeps the more watched of the two.
    mutating func move(from old: String, to new: String) {
        guard old != new, let moving = entries.removeValue(forKey: old) else { return }
        let there = entries[new]
        entries[new] = Entry(lastPlayedAt: [moving.lastPlayedAt, there?.lastPlayedAt].compactMap { $0 }.max(),
                             completedAt: [moving.completedAt, there?.completedAt].compactMap { $0 }.min())
    }

    mutating func forget(_ key: String) { entries.removeValue(forKey: key) }

    /// Put entries back that were forgotten — the undo of removing a folder.
    mutating func restore(_ saved: [String: Entry]) {
        for (key, entry) in saved { entries[key] = entry }
    }

    // MARK: - disk

    /// An absent or unreadable file is an empty log; a file from a NEWER build
    /// is read for what this one understands (the entry shape is additive).
    static func load(at path: String) -> WatchLog {
        guard let data = FileManager.default.contents(atPath: path),
              let log = try? JSONDecoder().decode(WatchLog.self, from: data) else { return WatchLog() }
        return log
    }

    func save(to path: String) {
        var copy = self
        copy.version = max(version, Self.currentVersion)
        _ = JSONStore.save(path, copy)
    }
}
