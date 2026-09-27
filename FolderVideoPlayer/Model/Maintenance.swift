import Foundation

/// Opt-in background upkeep of chosen folders: notice what was added, removed
/// or moved, and do the per-video work the user allowed — poster frames, date
/// readings, and the AI passes that are installed — without anybody having to
/// play each video first.
///
/// Off unless a folder is opted in, one pinned folder at a time. Hidden videos
/// are never scanned, read or queued. Nothing leaves the Mac. The queue is
/// written after every step, so quitting halfway resumes where it stopped
/// rather than starting a folder again.
///
/// This file is the decisions: what changed between two scans, what to queue,
/// when to pause, when to give up on a file. `MaintenanceWorker` does the work.

enum MaintenanceWork: String, Codable, CaseIterable, Identifiable {
    /// A poster frame for the playlist and the Apple TV.
    case posters
    /// The date readings (year, month) off the file.
    case metadata
    /// The Safe/NSFW verdict — and the frame cache the tag passes read.
    case classify
    /// Tag ideas (and faces, when face recognition is on).
    case suggest
    /// A searchable transcript. Minutes per film; off unless chosen.
    case transcribe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posters: return "Poster frames"
        case .metadata: return "Dates from the files"
        case .classify: return "Safe / NSFW verdict"
        case .suggest: return "Tag suggestions and faces"
        case .transcribe: return "Transcripts"
        }
    }

    /// Cheap work: a few reads of the file. The rest runs the AI.
    var isLight: Bool { self == .posters || self == .metadata }

    /// The order a video's work is done in: cheap first, then the passes that
    /// read the frame cache the verdict pass fills.
    static let order: [MaintenanceWork] = [.posters, .metadata, .classify, .suggest, .transcribe]
}

struct MaintenanceSettings: Codable, Equatable {
    enum Schedule: String, Codable, CaseIterable, Identifiable {
        case anytime
        /// 22:00 to 07:00 local time.
        case overnight
        var id: String { rawValue }
        var title: String { self == .anytime ? "Any time" : "Overnight (10 pm – 7 am)" }
    }

    /// The opted-in folders, absolute paths.
    var folders: [String] = []
    var work: Set<MaintenanceWork> = [.posters, .metadata]
    var pauseWhilePlaying = true
    var pauseOnBattery = true
    var schedule: Schedule = .anytime
    /// How many light jobs (posters, dates) read files at once. The AI passes
    /// always take one video at a time. Kept low for network shares.
    var concurrency = 1
    /// Minutes between looks at a folder for changes.
    var rescanMinutes = 30
}

/// One video's outstanding work.
struct MaintenanceItem: Codable, Equatable {
    var path: String
    var remaining: [MaintenanceWork]
    var attempts = 0
    var lastError: String?
    var addedAt: Double
}

/// A profile's upkeep, as stored: the settings, what each folder held at its
/// last scan, and what is left to do.
struct MaintenanceFile: Codable, Equatable {
    static let currentVersion = 1
    var version = MaintenanceFile.currentVersion
    var settings = MaintenanceSettings()
    /// Folder → (path relative to it → size) at the last completed scan.
    var known: [String: [String: Int64]] = [:]
    var lastScan: [String: Double] = [:]
    var queue: [MaintenanceItem] = []
    /// Videos given up on, and why — shown, never retried by themselves.
    var failed: [String: String] = [:]

    static func load(at path: String) -> MaintenanceFile {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(MaintenanceFile.self, from: data) else { return MaintenanceFile() }
        return file
    }

    func save(to path: String) -> Bool {
        var copy = self
        copy.version = max(version, Self.currentVersion)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        return JSONStore.save(path, copy)
    }
}

enum MaintenancePlanner {

    /// Attempts before a video is set aside as failed.
    static let maxAttempts = 3

    struct Changes: Equatable {
        var added: [String] = []
        var removed: [String] = []
        /// Same name and size, gone from one place and new in another, with no
        /// other file sharing both — the only moves safe to act on unasked.
        var moved: [Move] = []

        struct Move: Equatable { let from: String; let to: String }
        var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty }
    }

    /// What changed between two scans of a folder. Keys are paths relative to
    /// the folder; sizes tell a move from a namesake.
    static func diff(old: [String: Int64], new: [String: Int64]) -> Changes {
        let gone = Set(old.keys).subtracting(new.keys)
        let arrived = Set(new.keys).subtracting(old.keys)
        func signature(_ path: String, _ size: Int64) -> String {
            ((path as NSString).lastPathComponent.lowercased()) + "|" + String(size)
        }
        var goneBy: [String: [String]] = [:]
        for path in gone { goneBy[signature(path, old[path] ?? -1), default: []].append(path) }
        var arrivedBy: [String: [String]] = [:]
        for path in arrived { arrivedBy[signature(path, new[path] ?? -1), default: []].append(path) }

        var changes = Changes()
        var movedFrom = Set<String>(), movedTo = Set<String>()
        for (sig, froms) in goneBy {
            guard froms.count == 1, let tos = arrivedBy[sig], tos.count == 1 else { continue }
            changes.moved.append(.init(from: froms[0], to: tos[0]))
            movedFrom.insert(froms[0])
            movedTo.insert(tos[0])
        }
        changes.moved.sort { $0.from < $1.from }
        changes.added = arrived.subtracting(movedTo).sorted { naturalLess($0, $1) }
        changes.removed = gone.subtracting(movedFrom).sorted { naturalLess($0, $1) }
        return changes
    }

    /// Add videos to the queue with the allowed work, skipping hidden ones and
    /// ones already queued (whose work is widened instead).
    static func enqueue(_ paths: [String], work: Set<MaintenanceWork>, into queue: [MaintenanceItem],
                        hidden: Set<String>, now: Double) -> [MaintenanceItem] {
        let wanted = MaintenanceWork.order.filter(work.contains)
        guard !wanted.isEmpty else { return queue }
        var out = queue
        var index = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.path, $0) })
        for path in paths where !hidden.contains(Paths.tagKey(path)) {
            if let i = index[path] {
                let merged = MaintenanceWork.order.filter { wanted.contains($0) || out[i].remaining.contains($0) }
                out[i].remaining = merged
            } else {
                index[path] = out.count
                out.append(MaintenanceItem(path: path, remaining: wanted, addedAt: now))
            }
        }
        return out
    }

    /// Take removed videos out of the queue, so a file that is gone is not
    /// tried again and again.
    static func drop(_ removed: Set<String>, from queue: [MaintenanceItem]) -> [MaintenanceItem] {
        queue.filter { !removed.contains($0.path) }
    }

    /// A moved video's queued work follows it.
    static func move(_ moves: [(from: String, to: String)], in queue: [MaintenanceItem]) -> [MaintenanceItem] {
        let map = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        return queue.map { item in
            var copy = item
            if let to = map[item.path] { copy.path = to }
            return copy
        }
    }

    /// Why work should wait right now, in words for the status line — or nil
    /// to go ahead.
    static func pauseReason(_ settings: MaintenanceSettings, playing: Bool, onBattery: Bool,
                            hour: Int) -> String? {
        if settings.folders.isEmpty { return "No folders are kept up to date." }
        if settings.pauseWhilePlaying && playing { return "Paused while a video plays." }
        if settings.pauseOnBattery && onBattery { return "Paused on battery power." }
        if settings.schedule == .overnight && !(hour >= 22 || hour < 7) {
            return "Waiting for the overnight window (10 pm – 7 am)."
        }
        return nil
    }

    /// After a step failed: try again later, or give up after `maxAttempts`.
    /// Returns the item to keep queued, or nil when it is set aside.
    static func afterFailure(_ item: MaintenanceItem, error: String) -> MaintenanceItem? {
        var copy = item
        copy.attempts += 1
        copy.lastError = error
        return copy.attempts >= maxAttempts ? nil : copy
    }

    /// Is a folder due another look?
    static func isDue(lastScan: Double?, minutes: Int, now: Double) -> Bool {
        guard let lastScan else { return true }
        return now - lastScan >= Double(max(minutes, 1)) * 60
    }

    /// A scan's paths, relative to the folder, with sizes — hidden ones left out
    /// so they are never queued, read or counted.
    static func snapshot(_ scanned: [(path: String, size: Int64)], under folder: String,
                         hidden: Set<String>) -> [String: Int64] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var out: [String: Int64] = [:]
        for (path, size) in scanned where path.hasPrefix(prefix) && !hidden.contains(Paths.tagKey(path)) {
            out[String(path.dropFirst(prefix.count))] = size
        }
        return out
    }
}
