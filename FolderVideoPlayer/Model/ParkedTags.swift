import Foundation

/// Tags of videos in the Trash, kept for Put Back.
///
/// Deleting a video used to delete its tags with it — so the Finder's Put Back
/// returned an untagged video, and everybody else's tags on it were left
/// counting a file that would not play. Now a trashed video's tags are taken
/// out of every tag list, on this Mac and on the share, and kept here: the
/// profile in force's, every other profile's on this Mac, and every person's
/// on the share. When the file is back at its old path they go back where they
/// came from (`restore`).
///
/// **The order is the safety.** A holder's tags are written here before they
/// are removed from that holder, so a crash at any point loses nothing.
///
///     support/trashed-tags.json
///     { "format": 1,
///       "videos": { "<tag key>": { "when": …, "where": "<file in the Trash>",
///                                  "profiles": { "<slug>": [tags] },
///                                  "people":   { "<person folder on the share>": [tags] } } } }
///
/// Global rather than per profile: it holds everyone's.
struct ParkedTags: Codable, Equatable {
    static let currentFormat = 1

    struct Entry: Codable, Equatable {
        var when: Double
        /// Where the file went — the Trash, or the discard folder. Nil until known.
        var location: String?
        /// Profile slug → its tags, for the profiles on this Mac.
        var profiles: [String: [String]] = [:]
        /// Person folder on the share → their tags.
        var people: [String: [String]] = [:]

        var isEmpty: Bool { profiles.isEmpty && people.isEmpty }

        private enum CodingKeys: String, CodingKey { case when, location = "where", profiles, people }

        init(when: Double, location: String?) {
            self.when = when
            self.location = location
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            when = try c.decodeIfPresent(Double.self, forKey: .when) ?? 0
            location = try c.decodeIfPresent(String.self, forKey: .location)
            profiles = try c.decodeIfPresent([String: [String]].self, forKey: .profiles) ?? [:]
            people = try c.decodeIfPresent([String: [String]].self, forKey: .people) ?? [:]
        }
    }

    var format = ParkedTags.currentFormat
    /// Tag key at the original path → what was kept.
    var videos: [String: Entry] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? ParkedTags.currentFormat
        videos = try c.decodeIfPresent([String: Entry].self, forKey: .videos) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case format, videos }

    // MARK: - the file

    /// The file is read, changed and written back from the main actor and from
    /// the share work off it; one at a time.
    private static let lock = NSRecursiveLock()

    /// A missing or unreadable file is an empty store, never a crash.
    static func load() -> ParkedTags {
        JSONStore.load(Paths.parkedTagsFile, fallback: ParkedTags())
    }

    /// Change the file under the lock. Returns whether it was written — a
    /// caller about to remove somebody's tags must know they are kept first.
    @discardableResult
    static func update(_ change: (inout ParkedTags) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var parked = load()
        // A file from a later version is left alone rather than half-understood.
        guard parked.format <= currentFormat else { return false }
        let before = parked
        change(&parked)
        guard parked != before else { return true }
        if parked.videos.isEmpty {
            try? FileManager.default.removeItem(atPath: Paths.parkedTagsFile)
            return true
        }
        return JSONStore.save(Paths.parkedTagsFile, parked)
    }

    /// Keep one holder's tags for a video. Tags already kept for that holder
    /// are joined, not replaced.
    @discardableResult
    static func keep(_ key: String, profile: String? = nil, person: String? = nil,
                     names: [String], location: String? = nil,
                     now: Double = Date().timeIntervalSince1970) -> Bool {
        update { parked in
            var entry = parked.videos[key] ?? Entry(when: now, location: location)
            if let location { entry.location = location }
            if !names.isEmpty {
                if let profile { entry.profiles[profile] = union(entry.profiles[profile] ?? [], names) }
                if let person { entry.people[person] = union(entry.people[person] ?? [], names) }
            }
            parked.videos[key] = entry
        }
    }

    // MARK: - what the Trash has lost for good

    /// Kept videos that cannot come back: gone from the Trash (or the discard
    /// folder) and not at their old path either. Find Missing Files offers to
    /// forget these.
    func forgettable(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        videos.filter { key, entry in
            !exists(Paths.tagPath(key)) && !(entry.location.map(exists) ?? false)
        }.keys.sorted()
    }

    mutating func forget(_ key: String) { videos.removeValue(forKey: key) }

    static func forget(_ keys: [String]) {
        update { parked in for key in keys { parked.forget(key) } }
    }

    // MARK: - putting a video in the Trash

    /// The other profiles on this Mac: keep each one's tags on these videos,
    /// then take them out of its `tags.json` and queue the removal for its own
    /// sync — exactly what `forgetPath` does for the profile in force.
    static func parkAndRemoveFromBundles(_ keys: [String], except active: String,
                                         root: String = Paths.support) {
        for slug in ProfileBundle.slugs(root: root) where slug != active {
            func file(_ name: String) -> String { ProfileBundle.file(in: slug, name, root: root) }
            var tags: [String: [String]] = JSONStore.load(file(ProfileBundle.tagsName), fallback: [:])
            var sync = JSONStore.load(file("shared-sync.json"), fallback: SharedSyncState())
            var removed = false
            for key in keys {
                guard let names = tags[key], !names.isEmpty else { continue }
                // Kept before it is removed; if keeping fails, nothing is removed.
                guard keep(key, profile: slug, names: names) else { continue }
                tags.removeValue(forKey: key)
                if let edit = SharedTagEdit.forMove(from: key, to: nil) {
                    sync.pending[edit.share, default: []].append(edit.edit)
                }
                removed = true
            }
            if removed {
                JSONStore.save(file(ProfileBundle.tagsName), tags)
                JSONStore.save(file("shared-sync.json"), sync)
            }
        }
    }

    // MARK: - Put Back

    /// Put the tags back on every kept video found at its old path again.
    ///
    /// `present` is paths somebody has just SEEN exist — a folder scan, the
    /// Organize tree, the check at launch — so this does no looking of its own.
    /// The profile in force takes them through the library, and its sync sends
    /// them (a tag on a path in `gone` brings that path back); the other
    /// profiles' files are written and their syncs send them the same way; the
    /// people on the share get them under their own lock, unless they have
    /// tagged the video themselves since. Returns how many videos came back.
    @MainActor
    @discardableResult
    static func restore(present paths: [String], library: Library) async -> Int {
        let parked = load()
        let keys = Set(paths.map(Paths.tagKey)).intersection(parked.videos.keys).sorted()
        guard !keys.isEmpty else { return 0 }
        let active = library.profileOpen ? slug(library.person) : ""
        var done: [String: Entry] = [:]            // what came back, to strike off
        for key in keys {
            guard let entry = parked.videos[key] else { continue }
            var back = Entry(when: entry.when, location: entry.location)
            if !active.isEmpty, let names = entry.profiles[active] {
                let path = Paths.tagPath(key)
                library.setTags(union(library.tagsFor(path), names), for: path)
                back.profiles[active] = names
            }
            done[key] = back
        }
        library.saveTags()

        let device = slug(library.device)
        let root = Paths.support
        let elsewhere = await Task.detached(priority: .utility) {
            restoreElsewhere(keys.compactMap { key in parked.videos[key].map { (key, $0) } },
                             active: active, device: device, root: root)
        }.value
        for (key, back) in elsewhere {
            var merged = done[key] ?? Entry(when: back.when, location: back.location)
            merged.profiles.merge(back.profiles) { a, _ in a }
            merged.people.merge(back.people) { a, _ in a }
            done[key] = merged
        }
        var restored = 0
        update { parked in
            for (key, back) in done {
                guard var entry = parked.videos[key] else { continue }
                for slug in back.profiles.keys { entry.profiles.removeValue(forKey: slug) }
                for folder in back.people.keys { entry.people.removeValue(forKey: folder) }
                if entry.isEmpty { parked.videos.removeValue(forKey: key); restored += 1 }
                else { parked.videos[key] = entry }
            }
        }
        return restored
    }

    /// The other profiles' files and the people on the share. Returns, per
    /// video, which of them took their tags back; a person whose lock was held
    /// stays kept for the next time the video is seen.
    private static func restoreElsewhere(_ entries: [(String, Entry)], active: String,
                                         device: String, root: String) -> [String: Entry] {
        var back: [String: Entry] = [:]
        var bundles: [String: [String: [String]]] = [:]
        for (key, entry) in entries {
            var got = Entry(when: entry.when, location: entry.location)
            for (slug, names) in entry.profiles where slug != active {
                bundles[slug, default: [:]][key] = names
                got.profiles[slug] = names
            }
            for (folder, names) in entry.people {
                guard let cut = key.firstIndex(of: "/") else { continue }
                let rest = String(key[key.index(after: cut)...])
                if ProfileRelocation.restore(rest, names: names, inPersonFolder: folder, device: device) {
                    got.people[folder] = names
                }
            }
            back[key] = got
        }
        for (slug, videos) in bundles {
            let file = ProfileBundle.file(in: slug, ProfileBundle.tagsName, root: root)
            var tags: [String: [String]] = JSONStore.load(file, fallback: [:])
            for (key, names) in videos { tags[key] = union(tags[key] ?? [], names) }
            JSONStore.save(file, tags)
        }
        return back
    }

    /// The videos kept here, at their old paths — what the launch check looks for.
    static func originals() -> [String] { load().videos.keys.sorted().map(Paths.tagPath) }

    /// `existing`'s names first, then the kept ones not already there —
    /// case-insensitively, the rule `moveTags` keeps.
    static func union(_ existing: [String], _ adding: [String]) -> [String] {
        var out = existing
        for name in adding where !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            out.append(name)
        }
        return out
    }
}
