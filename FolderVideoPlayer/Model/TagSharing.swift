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
/// Each person gets a folder, and in it one file every device edits:
///
///     .FolderVideoPlayer/quincy/tags.json
///
/// Person, so several people sharing a NAS never overwrite each other. One
/// file, rather than one per device as it used to be, because merging several
/// full lists is how a moved video came back at its old path. Two writers on
/// one file is made safe by a lock held for one save; see `SharedTagFile`.
extension Library {

    var myTagFolder: String { Paths.shareDir + "/" + slug(person) }

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

    /// Bring this profile's tags and each share's `tags.json` into line: send
    /// this Mac's edits, take in everyone else's. Silent by design: a NAS
    /// asleep, unplugged or mounted read-only is a normal Tuesday.
    ///
    /// The shares are read and written off the main thread; what comes back is
    /// applied here. Syncs run one at a time.
    ///
    /// There are seven ways to start one — launch, the hold after tagging,
    /// coming to the front, quitting, the menu, the window button, and adopting
    /// a profile — and two of them landing together is ordinary. Two at once
    /// wrote through one another and the share answered "Resource busy", so
    /// each waits for the one before it.
    typealias PublishOutcome = (written: [(String, Int)], skipped: [(String, String)])
    typealias ShareSyncer = ([ShareSyncInput]) async -> [ShareSyncOutput]

    @discardableResult
    func publishTags(syncer: @escaping ShareSyncer = Library.syncAsync) async -> PublishOutcome {
        await syncTags(syncer: syncer).outcome
    }

    /// The same sync, for the menu that asks what came in: how many videos'
    /// tags changed because another device changed them.
    @discardableResult
    func mergeShared(syncer: @escaping ShareSyncer = Library.syncAsync) async -> Int {
        await syncTags(syncer: syncer).fromOthers
    }

    func syncTags(syncer: @escaping ShareSyncer = Library.syncAsync)
        async -> (outcome: PublishOutcome, fromOthers: Int) {
        guard profileOpen else { return (([], []), 0) }
        let context = profileContext
        let previous = publishQueue
        let work = Task<(outcome: PublishOutcome, fromOthers: Int), Never> { [self] in
            _ = await previous?.value
            // A queued request must not silently become a sync for the next person.
            guard profileOpen, profileContext == context else { return (([], []), 0) }
            isPublishing = true
            defer {
                if profileContext == context { isPublishing = false }
            }
            let profile = person
            let root = Paths.support
            let snapshot = tags
            let inputs = shareSyncInputs()
            let outputs = await syncer(inputs)
            let when = Date().timeIntervalSince1970
            guard profileOpen, profileContext == context else {
                // Another profile is in force now. What came back is not
                // taken in — it would land in the wrong profile — and that
                // profile's base is left as it was, so its next sync simply
                // sends the same edits again. The timestamp still belongs to
                // the profile that wrote, never to the one now open.
                if outputs.contains(where: { $0.status == .inLine && $0.sentSomething }) {
                    ProfileBundle.markPublished(profile: profile, at: when, clean: false, root: root)
                }
                return (([], []), 0)
            }
            let (outcome, fromOthers) = applySync(inputs: inputs, outputs: outputs, sent: snapshot)
            await syncSharedExtras(context: context)
            guard !outcome.written.isEmpty else { return (outcome, fromOthers) }
            let clean = sharedTagsInLine() && outcome.skipped.isEmpty
            ProfileBundle.markPublished(profile: profile, at: when, clean: clean, root: root)
            lastPublishedAt = when
            publishedClean = clean
            return (outcome, fromOthers)
        }
        publishQueue = Task { _ = await work.value }
        return await work.value
    }

    /// The named people and the transcripts, to and from the same shares, right
    /// after the tags — so every way a tag sync starts (adopting a profile on a
    /// new Mac included) carries them too. See `SharedExtras`.
    private func syncSharedExtras(context: UUID) async {
        let profile = slug(person)
        let root = Paths.support
        var folders: [String: String] = [:]
        for share in Set(shareTags().keys).union(Paths.networkShares()) {
            folders[share] = ((Paths.volumes + share) as NSString).appendingPathComponent(myTagFolder)
        }
        let stateFile = SharedExtras.stateFile(profile, root: root)
        let input = SharedExtras.Input(
            root: root, profile: profile, device: slug(device), volumes: Paths.volumes,
            folders: folders,
            state: JSONStore.load(stateFile, fallback: SharedExtras.State()))
        let output = await Task.detached(priority: .utility) {
            SharedExtras.sync(input, lockBudget: 10)
        }.value
        // Written for the profile that synced, even if another is open now:
        // the state describes that profile's files, wherever they went.
        if output.state != input.state { _ = JSONStore.save(stateFile, output.state) }
        guard profileContext == context,
              output.facesChanged || output.transcriptsImported > 0 else { return }
        NotificationCenter.default.post(name: .fvpSharedExtrasArrived, object: profile)
    }

    /// The last push on the way out. Synchronous, with a short wait for the
    /// lock: the app is going and there is no later to retry in.
    func syncOnQuit() {
        guard profileOpen else { return }
        let inputs = shareSyncInputs()
        guard inputs.contains(where: { $0.hasSomethingToSend }) else { return }
        let outputs = inputs.map { Library.syncShare($0, lockBudget: 3) }
        _ = applySync(inputs: inputs, outputs: outputs, sent: tags)
    }

    nonisolated static func syncAsync(_ inputs: [ShareSyncInput]) async -> [ShareSyncOutput] {
        await Task.detached(priority: .utility) {
            inputs.map { Library.syncShare($0, lockBudget: 10) }
        }.value
    }

    /// One input per share this profile has anything to do with: tags on it,
    /// a file seen on it before, edits waiting for it, or any network share —
    /// another device may have started a file there.
    func shareSyncInputs() -> [ShareSyncInput] {
        let state = sharedSyncState()
        let local = shareTags()
        let shares = Set(local.keys).union(state.base.keys).union(state.pending.keys)
            .union(Paths.networkShares())
        let device = slug(self.device)
        return shares.sorted().map { share in
            let mount = Paths.volumes + share
            return ShareSyncInput(
                share: share, mount: mount,
                folder: (mount as NSString).appendingPathComponent(myTagFolder),
                device: device,
                local: local[share] ?? [:],
                base: state.base[share],
                recorded: state.pending[share] ?? [],
                legacySeen: state.legacySeen[share] ?? [:],
                knownMtime: sharedTagMtimes[share],
                mergedUpTo: lastMerge)
        }
    }

    /// Take what came back from the shares into the tags in hand.
    ///
    /// `sent` is the tags as they were when the inputs were made. Anything
    /// edited here since goes on top of the file rather than under it — it has
    /// not been sent yet, and the next sync sends it.
    private func applySync(inputs: [ShareSyncInput], outputs: [ShareSyncOutput],
                           sent: [String: [String]]) -> (PublishOutcome, Int) {
        var state = sharedSyncState()
        var updated = tags
        var written: [(String, Int)] = []
        var skipped: [(String, String)] = []
        var fromOthers = 0
        for (input, output) in zip(inputs, outputs) {
            let share = input.share
            switch output.status {
            case .skipped(let why):
                // Only worth a word where this Mac had something to send.
                if input.hasSomethingToSend { skipped.append((share, why)) }
                continue
            case .nothingHere:
                continue
            case .inLine:
                break
            }
            guard let file = output.file else { continue }
            let prefix = share + "/"
            let sentHere = sent.filter { $0.key.hasPrefix(prefix) }
            let nowHere = updated.filter { $0.key.hasPrefix(prefix) }
            var merged: [String: [String]] = [:]
            for (rest, names) in file.videos { merged[prefix + rest] = names }
            // Edits made here while the share was being written.
            for key in Set(sentHere.keys).union(nowHere.keys)
            where sentHere[key] != nowHere[key] {
                merged[key] = nowHere[key]
            }
            fromOthers += file.videos.filter { input.local[$0.key] != $0.value }.count
                + input.local.keys.filter { file.videos[$0] == nil }.count
            for key in nowHere.keys { updated.removeValue(forKey: key) }
            updated.merge(merged) { _, shared in shared }
            state.base[share] = file.videos
            let left = Array((state.pending[share] ?? []).dropFirst(output.sentRecorded))
            state.pending[share] = left.isEmpty ? nil : left
            state.legacySeen[share] = output.legacySeen
            sharedTagMtimes[share] = output.mtime
            written.append((share, file.videos.count))
        }
        saveSharedSyncState(state)
        if updated != tags { adoptSharedTags(updated) }
        return ((written, skipped), fromOthers)
    }

    /// Whether every share's entries match what was last synced, with nothing
    /// waiting to be sent — what "published" means now.
    func sharedTagsInLine() -> Bool {
        let state = sharedSyncState()
        return shareTags().allSatisfy { share, entries in
            state.base[share] == entries && (state.pending[share] ?? []).isEmpty
        }
    }

    /// The sync state for the profile in force, read from its bundle the
    /// first time it is asked for after a profile change.
    func sharedSyncState() -> SharedSyncState {
        let owner = slug(person)
        if let cache = sharedSyncCache, cache.owner == owner { return cache.state }
        let loaded = JSONStore.load(Paths.sharedSyncFile(person), fallback: SharedSyncState())
        sharedSyncCache = (owner, loaded, [:])
        return loaded
    }

    func saveSharedSyncState(_ state: SharedSyncState) {
        guard profileOpen else { return }
        _ = sharedSyncState()
        sharedSyncCache?.state = state
        JSONStore.save(Paths.sharedSyncFile(person), state)
    }

    /// The file times seen this session, per share: a file whose time has not
    /// moved is not read again.
    var sharedTagMtimes: [String: Double] {
        get { _ = sharedSyncState(); return sharedSyncCache?.mtimes ?? [:] }
        set { _ = sharedSyncState(); sharedSyncCache?.mtimes = newValue }
    }

    /// Note a move or a removal for the shared file. Tagging needs no note —
    /// the next sync works it out by comparing — but a move compared looks
    /// like a removal and an addition, and the file has to know it was a move.
    func recordSharedEdit(moving from: String, to: String?) {
        guard profileOpen else { return }
        func split(_ key: String) -> (share: String, rest: String)? {
            guard !key.hasPrefix("/"), let cut = key.firstIndex(of: "/") else { return nil }
            let rest = String(key[key.index(after: cut)...])
            return rest.isEmpty ? nil : (String(key[..<cut]), rest)
        }
        guard let old = split(from) else { return }
        let edit: SharedTagEdit
        if let to, let new = split(to), new.share == old.share {
            edit = .move(old.rest, new.rest)
        } else {
            // Gone from this share: another share, a local folder, or the bin.
            edit = .remove(old.rest)
        }
        var state = sharedSyncState()
        state.pending[old.share, default: []].append(edit)
        saveSharedSyncState(state)
    }

    // MARK: - one share, off the main thread

    /// Everything one share's sync needs, gathered on the main thread.
    struct ShareSyncInput {
        var share: String
        var mount: String
        var folder: String
        var device: String
        /// This Mac's tags on this share, keyed from the share root.
        var local: [String: [String]]
        /// The file as this Mac last synced it. Nil: never synced here.
        var base: [String: [String]]?
        var recorded: [SharedTagEdit]
        var legacySeen: [String: SharedSyncState.LegacySeen]
        var knownMtime: Double?
        /// Old files no newer than this were merged here before the shared
        /// file existed; see `Library.lastMerge`. Zero takes them all.
        var mergedUpTo: Double = 0

        var hasSomethingToSend: Bool {
            guard let base else { return !local.isEmpty || !recorded.isEmpty }
            return !recorded.isEmpty || base != local
        }
    }

    struct ShareSyncOutput {
        enum Status: Equatable {
            /// The file and this Mac agree now.
            case inLine
            /// No file and nothing to start one with.
            case nothingHere
            case skipped(String)
        }
        var status: Status
        var file: SharedTagFile?
        var mtime: Double?
        /// How many of the recorded edits reached the file.
        var sentRecorded = 0
        var legacySeen: [String: SharedSyncState.LegacySeen] = [:]
        /// Entries left out of a first file because their video is not there.
        var dropped = 0
        /// Whether this sync wrote the file, rather than only reading it.
        var sentSomething = false
    }

    /// Sync one share. Blocking; see `SharedTagDisk`.
    nonisolated static func syncShare(_ input: ShareSyncInput, lockBudget: Double,
                                      now: Double = Date().timeIntervalSince1970) -> ShareSyncOutput {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.mount, isDirectory: &isDir), isDir.boolValue else {
            return ShareSyncOutput(status: .skipped("not mounted"))
        }
        let folder = input.folder
        let me = input.device
        let exists = { (rest: String) in
            fm.fileExists(atPath: (input.mount as NSString).appendingPathComponent(rest))
        }
        let lockPath = (folder as NSString).appendingPathComponent(SharedTagFile.lockName)

        // Look first, without the lock: most syncs have nothing to write.
        var found: SharedTagFile?
        var foundMtime: Double?
        switch SharedTagDisk.read(folder: folder) {
        case .unreadable:
            return ShareSyncOutput(status: .skipped("tags.json could not be read, so it was left alone"))
        case let .file(file, mtime):
            if file.isReadOnlyHere {
                return ShareSyncOutput(status: .skipped("tags.json was written by a newer version of the app"))
            }
            found = file
            foundMtime = mtime
        case .missing:
            break
        }
        let times = SharedTagDisk.legacyTimes(folder: folder)
        if found == nil {
            if times.isEmpty && input.local.isEmpty && input.recorded.isEmpty {
                return ShareSyncOutput(status: .nothingHere, legacySeen: input.legacySeen)
            }
            // Mid-save by someone else: the tvOS app deletes before it renames.
            if fm.fileExists(atPath: lockPath) {
                return ShareSyncOutput(status: .skipped("another device is saving; tried again later"))
            }
        }
        let firstContact = input.base == nil
        let edits = firstContact
            ? input.recorded
            : SharedTagFile.pending(local: input.local, base: input.base ?? [:], recorded: input.recorded)
        let legacyNow = times.map { SharedTagFile.Legacy(name: $0.key, mtime: $0.value, entries: [:]) }

        if let file = found {
            let listed = { (name: String) in
                file.devices[SharedTagFile.slug(ofLegacy: name) ?? ""] != nil
            }
            let legacyChanged = times.contains { name, mtime in
                !listed(name) && input.legacySeen[name]?.mtime != mtime
            }
            let oldActive = file.oldWritersActive(legacyNow, now: now)
            let retireDue = !times.isEmpty && !oldActive
            let quiet = edits.isEmpty && !legacyChanged && !retireDue && file.devices[me] != nil
            if quiet {
                if oldActive, foundMtime != input.knownMtime {
                    SharedTagDisk.writeCompatCopy(file.videos, folder: folder, device: me)
                }
                return ShareSyncOutput(status: .inLine, file: file, mtime: foundMtime,
                                       legacySeen: input.legacySeen)
            }
        }

        // Something to write: take the lock, and read again under it.
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard let token = SharedTagDisk.lock(folder: folder, by: me, budget: lockBudget) else {
            return ShareSyncOutput(status: .skipped("another device is saving; tried again later"))
        }
        defer { SharedTagDisk.unlock(folder: folder, token: token) }

        var current: SharedTagFile?
        switch SharedTagDisk.read(folder: folder) {
        case .unreadable:
            return ShareSyncOutput(status: .skipped("tags.json could not be read, so it was left alone"))
        case let .file(file, _):
            if file.isReadOnlyHere {
                return ShareSyncOutput(status: .skipped("tags.json was written by a newer version of the app"))
            }
            current = file
        case .missing:
            current = SharedTagDisk.unfinishedWrite(folder: folder)
        }

        let legacy = SharedTagDisk.legacy(folder: folder)
        var seen = input.legacySeen
        var file: SharedTagFile
        var dropped = 0
        if var existing = current {
            existing.apply(edits, at: now)
            // What the devices that have not been updated changed since last time.
            for old in legacy where old.slug != me && existing.devices[old.slug] == nil {
                if let before = seen[old.name], before.mtime != old.mtime {
                    existing.apply(existing.editsFromLegacy(current: old.entries,
                                                            previous: before.entries,
                                                            exists: exists), at: now)
                }
                seen[old.name] = SharedSyncState.LegacySeen(mtime: old.mtime, entries: old.entries)
            }
            file = existing
        } else {
            // The first file on this share, from the old ones and this Mac's tags.
            // Only old files with news this Mac never merged: the rest are in
            // its own tags already, removals included.
            let unmerged = legacy.filter { $0.slug != me && $0.mtime > input.mergedUpTo }
            (file, dropped) = SharedTagFile.build(from: unmerged, local: input.local, exists: exists)
            file.apply(input.recorded.filter { if case .set = $0 { return false }; return true },
                       at: now)
            for old in legacy {
                seen[old.name] = SharedSyncState.LegacySeen(mtime: old.mtime, entries: old.entries)
            }
        }
        file.devices[me] = SharedTagFile.Device(format: SharedTagFile.currentFormat, seen: now)
        file.prune(now: now)

        if let why = SharedTagDisk.write(file, folder: folder, device: me) {
            return ShareSyncOutput(status: .skipped(why))
        }
        let mtime = SharedTagDisk.mtime((folder as NSString).appendingPathComponent(SharedTagFile.name))
        retireRootLegacy(input.mount, folder)

        if file.oldWritersActive(legacy, now: now) {
            SharedTagDisk.writeCompatCopy(file.videos, folder: folder, device: me)
        } else if !legacy.isEmpty {
            SharedTagDisk.retire(legacy.map(\.name), folder: folder)
            for old in legacy { seen[old.name] = nil }
        }
        return ShareSyncOutput(status: .inLine, file: file, mtime: mtime,
                               sentRecorded: input.recorded.count, legacySeen: seen,
                               dropped: dropped, sentSomething: true)
    }

    /// Drop the old un-owned tags.json once this person has a file. It has
    /// to go rather than linger: it belongs to nobody, so every person on the
    /// share would keep reading tags that are not theirs. Only ever removed
    /// after its contents have been written into the person's own file.
    private nonisolated static func retireRootLegacy(_ mount: String, _ folder: String) {
        let legacy = (mount as NSString).appendingPathComponent(Paths.legacyTags)
        let mine = (folder as NSString).appendingPathComponent(SharedTagFile.name)
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

    /// The same list, or nil when the shares have not answered in `seconds`.
    ///
    /// For File ▸ Open Profile, which has a person waiting on it: a NAS with
    /// its disks spun down keeps SMB waiting 10–30 s, and a menu item that
    /// shows nothing for that long looks broken. The scan is not cancelled —
    /// a blocked read cannot be — so it finishes in the background and warms
    /// the directory cache for the next time.
    func sharePeople(within seconds: Double) async -> [SharePerson]? {
        let mine = Set(shareTags().keys)
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            Task.detached(priority: .userInitiated) {
                let people = Library.peopleOnShares(extra: mine)
                if once.claim() { continuation.resume(returning: people) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    nonisolated static func peopleOnShares(extra: Set<String> = []) -> [SharePerson] {
        var found: [String: SharePerson] = [:]
        let fm = FileManager.default
        let posterFolder = (Paths.posterDir as NSString).lastPathComponent
        for share in Set(Paths.networkShares()).union(extra).sorted() {
            let root = ((Paths.volumes + share) as NSString)
                .appendingPathComponent(Paths.shareDir)
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            // "thumbs" is skipped by name before it is listed: it holds a
            // poster frame per video — 9,352 files on one share, ~5 s to list
            // over SMB when the directory cache is cold — only to be refused
            // by the check below.
            for name in names.sorted() where !name.hasPrefix(".") && name != posterFolder {
                let folder = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue
                else { continue }
                // A folder is a profile because it holds somebody's tags, not
                // because it sits here. "thumbs" is where poster frames are
                // published, and it was being offered as a person to choose.
                let files = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
                let shared: SharedTagFile?
                if case let .file(file, _) = SharedTagDisk.read(folder: folder) {
                    shared = file
                } else {
                    shared = nil
                }
                guard shared != nil || files.contains(where: {
                    $0.hasPrefix("tags-") && $0.hasSuffix(".json")
                }) else { continue }
                var entry = found[name] ?? SharePerson(name: name)
                entry.shares.append(share)
                // The shared file, once there is one, is the whole answer: the
                // old per-device files are copies of it or retired.
                if let shared {
                    entry.devices += shared.devices.count
                    let path = (folder as NSString).appendingPathComponent(SharedTagFile.name)
                    entry.changed = max(entry.changed, SharedTagDisk.mtime(path) ?? 0)
                    for rest in shared.videos.keys { entry.videos.insert("\(share)/\(rest)") }
                    found[name] = entry
                    continue
                }
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

/// Lets exactly one of two racing tasks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
