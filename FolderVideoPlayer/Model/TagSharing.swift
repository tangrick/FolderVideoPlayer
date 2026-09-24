import Foundation

/// One name published on the mounted shares, and what stands behind it.
struct SharePerson: Identifiable {
    var name: String
    var shares: [String] = []
    var devices = 0
    var videos = Set<String>()
    var changed: Double = 0
    var id: String { name }
}

/// Tags on the network.
///
/// Each person gets a folder and each of their devices a file inside it:
///
///     .FolderVideoPlayer/quincy/tags-macbook.json
///                               /tags-appletv.json
///
/// Person, so several people sharing a NAS never overwrite each other.
/// Device, because one person with two machines is still two writers, and two
/// writers on one file is how tags get quietly lost.
extension Library {

    var myTagFolder: String { Paths.shareDir + "/" + slug(person) }
    var myTagFile: String {
        myTagFolder + "/" + String(format: Paths.deviceTags, slug(device))
    }

    /// The tags split by the share they live on, keyed from the share root. A
    /// device talking SMB has no idea what some Mac called the mount point, so
    /// the share's own copy drops the share name; local paths are left out
    /// entirely, since they mean nothing anywhere else.
    func shareTags() -> [String: [String: [String]]] {
        var byShare: [String: [String: [String]]] = [:]
        for (key, names) in tags where !key.hasPrefix("/") {
            guard let cut = key.firstIndex(of: "/") else { continue }
            let share = String(key[key.startIndex..<cut])
            let rest = String(key[key.index(after: cut)...])
            if !rest.isEmpty { byShare[share, default: [:]][rest] = names }
        }
        return byShare
    }

    /// Leave this device's tags on each share. Silent by design: a NAS asleep,
    /// unplugged or mounted read-only is a normal Tuesday.
    ///
    /// The tags are gathered here and written off the main thread: a share
    /// that has gone to sleep answers its first write in seconds, and doing
    /// that on the main thread is a spinning wheel at every launch.
    /// Publishes are run one at a time.
    ///
    /// There are seven ways to start one — launch, the eight-second hold after
    /// tagging, coming to the front, quitting, the menu, the window button, and
    /// adopting a profile — and two of them landing together is ordinary. Two
    /// at once wrote through one another and the share answered "Resource
    /// busy", so each waits for the one before it.
    typealias PublishOutcome = (written: [(String, Int)], skipped: [(String, String)])
    typealias ShareTags = [String: [String: [String]]]

    @discardableResult
    func publishTags(writer: @escaping (ShareTags, String) async -> PublishOutcome = Library.writeAsync)
        async -> PublishOutcome {
        guard profileOpen else { return ([], []) }
        let context = profileContext
        let previous = publishQueue
        let work = Task<PublishOutcome, Never> { [self] in
            _ = await previous?.value
            // A queued request must not silently become a publish for the next person.
            guard profileOpen, profileContext == context else { return ([], []) }
            isPublishing = true
            defer {
                if profileContext == context { isPublishing = false }
            }
            let profile = person
            let root = Paths.support
            let snapshot = tags
            let file = myTagFile
            let outcome = await writer(shareTags(), file)
            guard !outcome.written.isEmpty else { return outcome }
            let when = Date().timeIntervalSince1970
            let current = profileOpen && profileContext == context
            let clean = current && tags == snapshot && myTagFile == file && outcome.skipped.isEmpty
            // The timestamp belongs to the writer, even if another document is now open.
            ProfileBundle.markPublished(profile: profile, at: when, clean: clean, root: root)
            if current {
                lastPublishedAt = when
                publishedClean = clean
            }
            return outcome
        }
        publishQueue = Task { _ = await work.value }
        return await work.value
    }

    nonisolated static func writeAsync(_ entries: ShareTags, _ file: String) async -> PublishOutcome {
        await Task.detached(priority: .utility) { Library.write(entries, as: file) }.value
    }

    nonisolated static func write(_ byShare: [String: [String: [String]]], as myTagFile: String)
        -> (written: [(String, Int)], skipped: [(String, String)]) {
        var written: [(String, Int)] = []
        var skipped: [(String, String)] = []
        for (share, entries) in byShare.sorted(by: { $0.key < $1.key }) {
            let root = Paths.volumes + share
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
                  isDir.boolValue else {
                skipped.append((share, "not mounted"))
                continue
            }
            let target = (root as NSString).appendingPathComponent(myTagFile)
            // Never quietly empty a file that has something in it. The only
            // way this device holds no tags for a share it has published to is
            // that something went wrong — a profile half-loaded, a store that
            // failed to read — and overwriting is not recoverable.
            if entries.isEmpty {
                let existing: [String: [String]] = JSONStore.load(target, fallback: [:])
                if !existing.isEmpty {
                    skipped.append((share, "left alone — this device has no tags for it, "
                                    + "and the share holds \(existing.count)"))
                    continue
                }
            }
            if let why = JSONStore.write(target, entries) {
                // The path as well as the reason: "could not be written" on
                // its own left nothing to act on, and the answer is usually
                // which file it was and what the system said about it.
                skipped.append((share, "\(why) — \(target)"))
            } else {
                written.append((share, entries.count))
                retireLegacy(root, myTagFile)
            }
        }
        return (written, skipped)
    }

    /// Drop the old un-owned tags.json once this person has a folder. It has
    /// to go rather than linger: it belongs to nobody, so every person on the
    /// share would keep reading tags that are not theirs. Only ever removed
    /// after its contents have been written into the person's own file.
    private nonisolated static func retireLegacy(_ root: String, _ myTagFile: String) {
        let legacy = (root as NSString).appendingPathComponent(Paths.legacyTags)
        let mine = (root as NSString).appendingPathComponent(myTagFile)
        if FileManager.default.fileExists(atPath: legacy),
           FileManager.default.fileExists(atPath: mine) {
            try? FileManager.default.removeItem(atPath: legacy)
        }
    }

    /// Make this person's folder exist on every mounted share. Without it a
    /// name is invisible to your other devices until tags happen to flow,
    /// because the folder is otherwise only created as a side effect of
    /// publishing — and an empty list points at nothing.
    @discardableResult
    func claimName() async -> [String] {
        guard profileOpen else { return [] }
        let mine = myTagFolder
        return await Task.detached(priority: .utility) { () -> [String] in
            var claimed: [String] = []
            // Network shares only. This used to run over every mounted volume
            // and leave an empty profile folder on each — external disks and
            // disk images included, which have no other device reading them.
            for share in Paths.networkShares() {
                let folder = ((Paths.volumes + share) as NSString)
                    .appendingPathComponent(mine)
                if (try? FileManager.default.createDirectory(
                    atPath: folder, withIntermediateDirectories: true)) != nil {
                    claimed.append(share)
                }
            }
            return claimed
        }.value
    }

    /// Take in tags this person made on their other devices.
    ///
    /// Only this person's files are read — another person's tags are none of
    /// our business. A file newer than our last merge wins for the videos it
    /// names: coarse, per video rather than per tag, but it is a rule you can
    /// hold in your head.
    ///
    /// The shares are read off the main thread and the result applied here:
    /// listing a sleeping NAS and reading a file per device is not something
    /// to do while the window is trying to draw.
    @discardableResult
    func mergeShared() async -> Int {
        guard profileOpen else { return 0 }
        let context = profileContext
        let mine = (myTagFile as NSString).lastPathComponent
        let shares = shareTags().keys.sorted()
        let folder = myTagFolder
        let since = lastMerge
        let harvest = await Task.detached(priority: .utility) {
            Library.readShared(shares: shares, folder: folder, mine: mine, since: since)
        }.value
        guard profileOpen, profileContext == context, !harvest.entries.isEmpty else { return 0 }
        // Another device publishes ALL its tags, including paths this Mac has
        // since moved or renamed the file away from — it was never told. Taking
        // those in brought the old path back beside the new one: the same
        // video twice, once as a missing file. So a path this Mac has no entry
        // for is only taken in if its file is there. Stat'ed off the main
        // thread; only such new paths are asked about, not every entry.
        let known = Set(tags.keys)
        let fresh = harvest.entries.map(\.0).filter { !known.contains($0) }
        let present = await Task.detached(priority: .utility) {
            Set(fresh.filter { FileManager.default.fileExists(atPath: Paths.tagPath($0)) })
        }.value
        guard profileOpen, profileContext == context else { return 0 }
        let taken = Self.mergeable(harvest.entries, known: known, present: present)
        for (key, names) in taken {
            // An empty list is a real statement — "that device says no tags" —
            // so it removes rather than being ignored.
            setTags(names, for: Paths.tagPath(key))
        }
        lastMerge = max(lastMerge, harvest.newest)
        saveTags()
        save()
        return taken.count
    }

    /// Which of another device's entries to take in.
    ///
    /// A path this Mac already files tags under is always taken — that is an
    /// ordinary edit from elsewhere. A path it does not know is taken only if
    /// the file exists: a path whose file is gone is one this Mac moved or
    /// removed, and the other device is replaying its old copy. Nothing is
    /// lost by skipping it — the file is not there to carry tags.
    nonisolated static func mergeable(_ entries: [(String, [String])],
                                      known: Set<String>,
                                      present: Set<String>) -> [(String, [String])] {
        entries.filter { key, _ in known.contains(key) || present.contains(key) }
    }

    nonisolated static func readShared(shares: [String], folder: String, mine: String,
                                       since: Double)
        -> (entries: [(String, [String])], newest: Double) {
        var newest = since
        var found: [(String, [String])] = []
        for share in (shares.isEmpty ? Paths.networkShares() : shares) {
            let dir = ((Paths.volumes + share) as NSString).appendingPathComponent(folder)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
            else { continue }
            for name in names.sorted() where name != mine {
                guard name.hasPrefix("tags-"), name.hasSuffix(".json") else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let changed = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      changed > since else { continue }
                newest = max(newest, changed)
                let entries: [String: [String]] = JSONStore.load(path, fallback: [:])
                for (rest, names) in entries {
                    found.append(("\(share)/\(rest)", parseTags(names.joined(separator: ","))))
                }
            }
        }
        return (found, newest)
    }

    /// Every name published on the mounted shares. Read from the shares rather
    /// than remembered, because the point of the list is to show what other
    /// devices are actually filing under — including names this Mac has never
    /// used, and names left behind by a device since renamed.
    func sharePeople() async -> [SharePerson] {
        let mine = Set(shareTags().keys)
        return await Task.detached(priority: .utility) {
            Library.peopleOnShares(extra: mine)
        }.value
    }

    nonisolated static func peopleOnShares(extra: Set<String> = []) -> [SharePerson] {
        var found: [String: SharePerson] = [:]
        let fm = FileManager.default
        for share in Set(Paths.networkShares()).union(extra).sorted() {
            let root = ((Paths.volumes + share) as NSString)
                .appendingPathComponent(Paths.shareDir)
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let folder = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue
                else { continue }
                // A folder is a profile because it holds somebody's tags, not
                // because it sits here. "thumbs" is where poster frames are
                // published, and it was being offered as a person to choose.
                let files = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
                guard files.contains(where: {
                    $0.hasPrefix("tags-") && $0.hasSuffix(".json")
                }) else { continue }
                var entry = found[name] ?? SharePerson(name: name)
                entry.shares.append(share)
                for leaf in files.sorted()
                where leaf.hasPrefix("tags-") && leaf.hasSuffix(".json") {
                    entry.devices += 1
                    let path = (folder as NSString).appendingPathComponent(leaf)
                    if let attrs = try? fm.attributesOfItem(atPath: path),
                       let when = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 {
                        entry.changed = max(entry.changed, when)
                    }
                    let tagged: [String: [String]] = JSONStore.load(path, fallback: [:])
                    for rest in tagged.keys { entry.videos.insert("\(share)/\(rest)") }
                }
                found[name] = entry
            }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }

    func isMyName(_ name: String) -> Bool { slug(name) == slug(person) }
}
