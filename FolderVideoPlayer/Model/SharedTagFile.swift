import Foundation

/// One person's tags on one share, in the one file every device edits.
///
///     .FolderVideoPlayer/<person>/tags.json
///     .FolderVideoPlayer/<person>/tags.lock      only while someone is saving
///
/// This replaced a file per device that every device merged. Each of those was
/// a full list, so a video one device had moved came back at its old path from
/// another device's list, and every device had its own idea of which list won.
/// Now there is one copy: a device takes a short lock, re-reads the file,
/// applies only its own edits, writes, and lets go. Nobody merges, and nobody
/// is locked out while another device is open — the lock lasts one save.
///
/// The design, the switch-over from the old files and what was decided:
/// docs/shared-tags-design.md. The tvOS app implements the same rules.
struct SharedTagFile: Codable, Equatable {
    static let currentFormat = 1
    static let name = "tags.json"
    static let lockName = "tags.lock"
    static let retiredDir = "retired"
    /// How long a move or removal is remembered, and how long the old per-device
    /// files are kept alive after the last old-format device wrote one. One
    /// number for both, as decided.
    static let keepFor: Double = 60 * 24 * 3600

    /// A path moved (`to` set) or removed (no `to`), and when.
    struct Gone: Codable, Equatable {
        var to: String?
        var at: Double
    }

    /// A device that speaks this format. Its old `tags-<slug>.json`, if it
    /// still writes one, is a copy for old readers and never read back as edits.
    struct Device: Codable, Equatable {
        var format: Int
        var seen: Double
    }

    var format = SharedTagFile.currentFormat
    /// Share-relative path → tags. A video with no tags has no entry.
    var videos: [String: [String]] = [:]
    var gone: [String: Gone] = [:]
    var devices: [String: Device] = [:]

    init(videos: [String: [String]] = [:]) {
        self.videos = videos.filter { !$0.value.isEmpty }
    }

    // Every field optional on the way in: a file written by a later version, or
    // by the tvOS app, may leave out what it does not use.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? SharedTagFile.currentFormat
        videos = try c.decodeIfPresent([String: [String]].self, forKey: .videos) ?? [:]
        gone = try c.decodeIfPresent([String: Gone].self, forKey: .gone) ?? [:]
        devices = try c.decodeIfPresent([String: Device].self, forKey: .devices) ?? [:]
    }

    /// A file from a later version is shown but never written: rewriting it
    /// with this version's idea of the format would drop whatever it added.
    var isReadOnlyHere: Bool { format > SharedTagFile.currentFormat }

    // MARK: - edits

    mutating func apply(_ edit: SharedTagEdit, at now: Double) {
        switch edit {
        case let .set(path, names):
            if names.isEmpty {
                // An empty list on a moved path is the move's own leftover —
                // the old key emptied on the way out — so the record stays.
                videos[path] = nil
            } else {
                videos[path] = names
                // Tags on a path bring it back: this device is looking at it.
                // That is also what an Undo of a move sends.
                gone[path] = nil
            }
        case let .move(from, to):
            guard from != to, let moving = videos[from], !moving.isEmpty else { return }
            // The destination's own tags lead and a tag already there is not
            // added twice — the rule `Library.moveTags` has always kept.
            var kept = videos[to] ?? []
            for name in moving
            where !kept.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                kept.append(name)
            }
            videos[to] = kept
            videos[from] = nil
            gone[from] = Gone(to: to, at: now)
            gone[to] = nil
        case let .remove(path):
            videos[path] = nil
            gone[path] = Gone(to: nil, at: now)
        }
    }

    mutating func apply(_ edits: [SharedTagEdit], at now: Double) {
        for edit in edits { apply(edit, at: now) }
    }

    /// Forget moves and removals older than `keepFor`.
    mutating func prune(now: Double) {
        gone = gone.filter { now - $0.value.at < SharedTagFile.keepFor }
    }

    /// Where a path's video went, following one move after another. Nil for a
    /// removed video, or a chain that loops.
    func destination(of path: String) -> String? {
        var at = path
        var hops = 0
        while let went = gone[at] {
            guard let next = went.to, hops < 32 else { return nil }
            at = next
            hops += 1
        }
        return at
    }

    // MARK: - what this device has to say

    /// This device's edits since `base`, the file as it last saw it.
    ///
    /// Moves and removals are recorded as they happen, because a comparison
    /// cannot tell a move from a removal and an addition. Everything else —
    /// tagging, bulk edits, Undo — is worked out here by comparing, against
    /// the base with those recorded edits already applied, so a move is not
    /// also sent as its two halves.
    static func pending(local: [String: [String]], base: [String: [String]],
                        recorded: [SharedTagEdit]) -> [SharedTagEdit] {
        var expected = SharedTagFile(videos: base)
        expected.apply(recorded, at: 0)
        let local = local.filter { !$0.value.isEmpty }
        let keys = Set(local.keys).union(expected.videos.keys).sorted()
        let sets = keys.compactMap { key -> SharedTagEdit? in
            local[key] == expected.videos[key] ? nil : .set(key, local[key] ?? [])
        }
        return recorded + sets
    }

    // MARK: - the switch-over from one file per device

    /// A `tags-<slug>.json` from before this format.
    struct Legacy: Equatable {
        var name: String
        var mtime: Double
        var entries: [String: [String]]

        var slug: String { SharedTagFile.slug(ofLegacy: name) ?? "" }
    }

    /// `tags-macbook.json` → `macbook`; nil for anything else.
    static func slug(ofLegacy name: String) -> String? {
        guard name.hasPrefix("tags-"), name.hasSuffix(".json"),
              name.count > "tags-.json".count else { return nil }
        return String(name.dropFirst(5).dropLast(5))
    }

    /// The first file on a share, built from the old ones.
    ///
    /// Oldest file first, so a newer file wins a video, then this Mac's own
    /// tags on top. A path from the old files whose video is not there is
    /// dropped — the one place the file-exists rule is still used, because the
    /// old files carry every path any device ever had, moved or not — and the
    /// count is reported. This Mac's own paths are all kept, missing or not:
    /// they are what Find Missing Files repairs, and a repair needs the tags.
    static func build(from legacy: [Legacy], local: [String: [String]],
                      exists: (String) -> Bool) -> (file: SharedTagFile, dropped: Int) {
        var merged: [String: [String]] = [:]
        for file in legacy.sorted(by: { ($0.mtime, $0.name) < ($1.mtime, $1.name) }) {
            merged.merge(file.entries) { _, newer in newer }
        }
        var kept: [String: [String]] = [:]
        var dropped = 0
        for (path, names) in merged where !names.isEmpty && local[path] == nil {
            if exists(path) { kept[path] = names } else { dropped += 1 }
        }
        kept.merge(local.filter { !$0.value.isEmpty }) { _, mine in mine }
        return (SharedTagFile(videos: kept), dropped)
    }

    /// What an old-format device changed since this Mac last read its file.
    ///
    /// The old files are full lists written over and over, so only the
    /// difference from the previous read is news — taking the whole list each
    /// time would put back every tag the old device had not heard was changed.
    /// A changed path that was moved follows the move; one that was removed,
    /// or whose file is not here, is skipped.
    func editsFromLegacy(current: [String: [String]], previous: [String: [String]],
                         exists: (String) -> Bool) -> [SharedTagEdit] {
        let keys = Set(current.keys).union(previous.keys).sorted()
        return keys.compactMap { key -> SharedTagEdit? in
            let names = current[key] ?? []
            guard names != (previous[key] ?? []) else { return nil }
            guard let target = destination(of: key) else { return nil }
            if !names.isEmpty, !exists(target) { return nil }
            guard videos[target] ?? [] != names else { return nil }
            return .set(target, names)
        }
    }

    /// Whether any device still writes the old format: a `tags-*.json` whose
    /// device is not listed here, changed in the last `keepFor`.
    func oldWritersActive(_ legacy: [Legacy], now: Double) -> Bool {
        legacy.contains { devices[$0.slug] == nil && now - $0.mtime < SharedTagFile.keepFor }
    }
}

/// One change, as sent to the shared file. Never a whole list.
enum SharedTagEdit: Codable, Equatable {
    case set(String, [String])
    case move(String, String)
    case remove(String)
}

// MARK: - the lock and the file on disk

/// Reading and writing one person's folder on a mounted share.
///
/// Synchronous on purpose: it runs on a background task during a normal sync
/// and on the main thread on the way out at quit, where there is no later.
enum SharedTagDisk {

    /// Locks this Mac has found held, and since when by its own clock. A lock
    /// still holding the same content 30 s later is one a device left behind
    /// when it crashed — comparing against this Mac's clock only, so neither
    /// the NAS's clock nor another device's has to be right.
    private static var seenLocks: [String: (content: Data, since: Double)] = [:]
    private static let seenLocksGuard = NSLock()
    static let staleAfter: Double = 30

    /// Take the lock, waiting up to `budget` seconds. Returns the token to
    /// release with, or nil if it could not be had.
    static func lock(folder: String, by device: String, budget: Double,
                     now: () -> Double = { Date().timeIntervalSince1970 }) -> String? {
        let path = (folder as NSString).appendingPathComponent(SharedTagFile.lockName)
        let token = UUID().uuidString
        let body = Data("{\"by\":\"\(device)\",\"token\":\"\(token)\"}".utf8)
        let started = now()
        var wait = 0.2
        while true {
            let fd = Darwin.open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                _ = body.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                Darwin.close(fd)
                return token
            }
            guard errno == EEXIST else { return nil }
            let held = FileManager.default.contents(atPath: path) ?? Data()
            seenLocksGuard.lock()
            let seen = seenLocks[path]
            if seen == nil || seen!.content != held { seenLocks[path] = (held, now()) }
            let stale = seen.map { $0.content == held && now() - $0.since >= staleAfter } ?? false
            if stale { seenLocks[path] = nil }
            seenLocksGuard.unlock()
            if stale {
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            guard now() - started + wait <= budget else { return nil }
            Thread.sleep(forTimeInterval: wait)
            wait = min(wait * 2, 2)
        }
    }

    static func unlock(folder: String, token: String) {
        let path = (folder as NSString).appendingPathComponent(SharedTagFile.lockName)
        guard let held = FileManager.default.contents(atPath: path),
              String(decoding: held, as: UTF8.self).contains(token) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    enum ReadResult {
        case missing
        case file(SharedTagFile, mtime: Double)
        /// There, but not something this version can read. Never written over.
        case unreadable
    }

    static func read(folder: String) -> ReadResult {
        let path = (folder as NSString).appendingPathComponent(SharedTagFile.name)
        guard let data = FileManager.default.contents(atPath: path) else { return .missing }
        guard let file = try? JSONDecoder().decode(SharedTagFile.self, from: data) else {
            return .unreadable
        }
        return .file(file, mtime: mtime(path) ?? 0)
    }

    /// A save the tvOS app did not finish: it has to delete before it renames,
    /// and a dropped connection in between leaves only the scratch file. Only
    /// asked while holding the lock.
    static func unfinishedWrite(folder: String) -> SharedTagFile? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let scratch = names
            .filter { $0.hasPrefix(SharedTagFile.name + ".") && $0.hasSuffix(".writing") }
            .map { (folder as NSString).appendingPathComponent($0) }
            .max { (mtime($0) ?? 0) < (mtime($1) ?? 0) }
        guard let scratch, let data = FileManager.default.contents(atPath: scratch) else { return nil }
        return try? JSONDecoder().decode(SharedTagFile.self, from: data)
    }

    /// Write via a scratch file renamed into place, so a reader never sees half
    /// a file. Returns why not, or nil.
    static func write(_ file: SharedTagFile, folder: String, device: String) -> String? {
        let path = (folder as NSString).appendingPathComponent(SharedTagFile.name)
        let scratch = "\(path).\(device).writing"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(file).write(to: URL(fileURLWithPath: scratch))
        } catch {
            return "could not be written (\(error.localizedDescription)) — \(scratch)"
        }
        guard Darwin.rename(scratch, path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: scratch)
            return "could not be replaced (\(why)) — \(path)"
        }
        return nil
    }

    /// The old per-device files in a person's folder.
    static func legacy(folder: String) -> [SharedTagFile.Legacy] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.sorted().compactMap { name in
            guard SharedTagFile.slug(ofLegacy: name) != nil else { return nil }
            let path = (folder as NSString).appendingPathComponent(name)
            let entries: [String: [String]] = JSONStore.load(path, fallback: [:])
            return SharedTagFile.Legacy(name: name, mtime: mtime(path) ?? 0, entries: entries)
        }
    }

    /// Only the names and times — enough to tell whether anything needs reading.
    static func legacyTimes(folder: String) -> [String: Double] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var times: [String: Double] = [:]
        for name in names where SharedTagFile.slug(ofLegacy: name) != nil {
            times[name] = mtime((folder as NSString).appendingPathComponent(name)) ?? 0
        }
        return times
    }

    /// A copy in the old format, for devices that have not been updated yet.
    static func writeCompatCopy(_ videos: [String: [String]], folder: String, device: String) {
        let path = (folder as NSString).appendingPathComponent(String(format: Paths.deviceTags, device))
        _ = JSONStore.write(path, videos)
    }

    /// Move the old files into `retired/`. Moved, not deleted: everything in
    /// them is in `tags.json` by now, but they stay if anything needs checking.
    static func retire(_ names: [String], folder: String) {
        let fm = FileManager.default
        let dir = (folder as NSString).appendingPathComponent(SharedTagFile.retiredDir)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in names {
            let from = (folder as NSString).appendingPathComponent(name)
            var to = (dir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: to) {
                to += ".\(Int(Date().timeIntervalSince1970))"
            }
            try? fm.moveItem(atPath: from, toPath: to)
        }
    }

    static func mtime(_ path: String) -> Double? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970
    }
}

/// What this Mac remembers about the shared files, per profile: the file as it
/// last synced each share (what its own edits are worked out against), the
/// moves and removals waiting to be sent, and the old per-device files as last
/// read. Kept in the profile bundle so a quit or a crash loses none of it.
struct SharedSyncState: Codable, Equatable {
    struct LegacySeen: Codable, Equatable {
        var mtime: Double
        var entries: [String: [String]]
    }
    /// Share → the file's videos at the last sync.
    var base: [String: [String: [String]]] = [:]
    /// Share → moves and removals not yet in the file.
    var pending: [String: [SharedTagEdit]] = [:]
    /// Share → old file name → what it held when last read.
    var legacySeen: [String: [String: LegacySeen]] = [:]
}
