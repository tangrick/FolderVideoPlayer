import Foundation

/// A relocation carried past the profile in force.
///
/// `Library.moveTags` carries a move through everything the profile in force
/// knows, and that used to be the whole of it. It was not enough: tags belong
/// to a person, several people tag the same videos, and when one of them
/// renamed a video the others' tags were left pointing at a path that no
/// longer existed — opening their profile afterwards showed their videos as
/// missing. So a move goes two rings further:
///
///  - every OTHER profile on this Mac, opened this session or not
///    (`carryIntoBundles`);
///  - every person's folder on the share the video moved within
///    (`carryOnShares`): their `tags.json` gets the `.move` edit their own
///    devices would send, under the lock those devices take, and their
///    `facts.json` and `transcripts.json` are re-keyed.
///
/// Only where things are changes, never what: no tag, reading or transcript
/// line is added, removed or reworded, in anybody's file.
///
/// The Apple TV reads a person's files fresh from the share, so it follows
/// with no change of its own. Another Mac takes the file in at its next sync,
/// and replays its `gone` records to carry what lives only on that Mac — see
/// `SharedTagFile.unseenMoves` and `Library.applySync`.
///
/// Design: `features/FOLDER_MANAGEMENT.md`, rings 2 and 3.
enum ProfileRelocation {

    /// How long to wait for another person's lock before leaving their folder
    /// for later. The tests shorten it.
    static var lockBudget: Double = 10

    // MARK: - after a move, from the app

    /// Carry file moves to the other profiles and the other people, off the
    /// main thread, and have another go at anything owed from before.
    @MainActor
    static func spread(_ moves: [PathMap], library: Library) async {
        let active = library.profileOpen ? slug(library.person) : ""
        let device = slug(library.device)
        let root = Paths.support
        await Task.detached(priority: .utility) {
            retryOwed(device: device)
            guard !moves.isEmpty else { return }
            carryIntoBundles(moves, except: active, root: root)
            owe(carryOnShares(moves, skip: active, device: device))
        }.value
    }

    // MARK: - ring 2: the other profiles on this Mac

    /// Carry file moves into every profile bundle on this Mac except `active`,
    /// whose stores `moveTags` has carried already. Returns the slugs changed.
    @discardableResult
    static func carryIntoBundles(_ moves: [PathMap], except active: String,
                                 root: String = Paths.support) -> [String] {
        ProfileBundle.slugs(root: root)
            .filter { $0 != active && carry(moves, intoBundle: $0, root: root) }
    }

    /// One bundle's per-video files, each read, re-keyed and written back only
    /// when something of it actually moved.
    private static func carry(_ moves: [PathMap], intoBundle slug: String, root: String) -> Bool {
        func file(_ name: String) -> String { ProfileBundle.file(in: slug, name, root: root) }
        let keyed = moves.map { (from: Paths.tagKey($0.from), to: Paths.tagKey($0.to)) }
        var touched = false

        // Tags, by the rule `moveTags` keeps: a same-named file's own tags
        // lead and the movers join. The move is also queued for this profile's
        // own sync, exactly as `recordSharedEdit` queues one for the profile
        // in force — so its share file hears of it even if ring 3 could not
        // get the lock, and a sync does not mistake it for a removal and an
        // addition.
        var tags: [String: [String]] = JSONStore.load(file(ProfileBundle.tagsName), fallback: [:])
        var sync = JSONStore.load(file("shared-sync.json"), fallback: SharedSyncState())
        var tagsMoved = false
        var edited = false
        for (move, key) in zip(moves, keyed) {
            // A bundle never opened since may still key a share by /Volumes.
            let held = tags[key.from] != nil ? key.from : move.from
            guard let moving = tags.removeValue(forKey: held), !moving.isEmpty else { continue }
            var kept = tags[key.to] ?? []
            for name in moving
            where !kept.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                kept.append(name)
            }
            tags[key.to] = kept
            tagsMoved = true
            if let edit = SharedTagEdit.forMove(from: key.from, to: key.to) {
                sync.pending[edit.share, default: []].append(edit.edit)
                edited = true
            }
        }
        if tagsMoved { JSONStore.save(file(ProfileBundle.tagsName), tags) }
        if edited { JSONStore.save(file("shared-sync.json"), sync) }
        touched = touched || tagsMoved

        var facts = MetadataFacts.load(at: file(ProfileBundle.readingsName))
        let factsBefore = facts
        for key in keyed { facts.move(from: key.from, to: key.to) }
        if facts != factsBefore { facts.save(to: file(ProfileBundle.readingsName)); touched = true }

        var watch = WatchLog.load(at: file("watch.json"))
        let watched = keyed.filter { watch.entry($0.from) != nil }
        for key in watched { watch.move(from: key.from, to: key.to) }
        if !watched.isEmpty { watch.save(to: file("watch.json")); touched = true }

        var moments = MomentBook.load(at: file("moments.json"))
        let momentsMoved = keyed.reduce(0) { $0 + moments.move(from: $1.from, to: $1.to) }
        if momentsMoved > 0 { _ = moments.save(to: file("moments.json")); touched = true }

        touched = rekey([String: VideoSuggestions].self, file("suggestions.json"), keyed) || touched
        touched = rekey([String: VideoMark].self, file("marks.json"), keyed) || touched

        // Transcripts are keyed by the absolute path, in the profile's SQLite
        // store. Opened only when there is one: a profile that never
        // transcribed anything must not be given an empty database.
        if FileManager.default.fileExists(atPath: Paths.evidenceFile(in: slug, root: root)),
           let store = try? EvidenceStore(root: root, profile: slug) {
            for move in moves where (try? store.moveTranscript(from: move.from, to: move.to)) == true {
                touched = true
            }
            store.close()
        }
        return touched
    }

    /// A plain per-video JSON file, re-keyed. A key already taken keeps what
    /// is there: that is the same rule the live stores' `move` follows for a
    /// destination that already had its own entry.
    private static func rekey<V: Codable>(_ type: [String: V].Type, _ path: String,
                                          _ keyed: [(from: String, to: String)]) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var dict: [String: V] = JSONStore.load(path, fallback: [:])
        var moved = false
        for key in keyed where key.from != key.to {
            guard let value = dict.removeValue(forKey: key.from) else { continue }
            if dict[key.to] == nil { dict[key.to] = value }
            moved = true
        }
        if moved { JSONStore.saveCompact(path, dict) }
        return moved
    }

    // MARK: - ring 3: every person on the share

    /// Moves a person's folder on a share still has to hear about.
    struct Owed: Codable, Equatable {
        /// The person's folder: `/Volumes/<share>/.FolderVideoPlayer/<person>`.
        var folder: String
        /// `[from, to]`, keyed from the share root, in the order they happened.
        var moves: [[String]]
        /// Any other edits owed — a video sent to the Trash is a `.remove`.
        /// Optional, so an owed file written before this existed still loads.
        var edits: [SharedTagEdit]? = nil
        /// Share-relative path → tag key, for each `.remove` whose tags must be
        /// kept for Put Back before they are taken out (`ParkedTags`).
        var parks: [String: String]? = nil

        /// Everything owed, in order: the moves, then the other edits.
        var allEdits: [SharedTagEdit] { moves.map { .move($0[0], $0[1]) } + (edits ?? []) }
    }

    /// Carry moves that stayed within one share into every person's folder on
    /// it except `skip` — the profile in force, whose own sync sends its moves
    /// (`recordSharedEdit`). A move to another share or to a local disk is not
    /// carried: those people cannot see where the video went, so their tags
    /// stay where they are, and come back if the video does.
    ///
    /// Returns what could not be written now.
    static func carryOnShares(_ moves: [PathMap], skip: String, device: String) -> [Owed] {
        var byShare: [String: [[String]]] = [:]
        for move in moves {
            guard let edit = SharedTagEdit.forMove(from: Paths.tagKey(move.from), to: Paths.tagKey(move.to)),
                  case let .move(from, to) = edit.edit else { continue }
            byShare[edit.share, default: []].append([from, to])
        }
        var owed: [Owed] = []
        for (share, pairs) in byShare.sorted(by: { $0.key < $1.key }) {
            for folder in personFolders(on: share) where (folder as NSString).lastPathComponent != skip {
                if !apply(pairs, inPersonFolder: folder, device: device) {
                    owed.append(Owed(folder: folder, moves: pairs))
                }
            }
        }
        return owed
    }

    /// Every person's folder on a share that holds a shared `tags.json`.
    ///
    /// A folder holding only the old per-device files is left alone: its
    /// devices have not moved to the shared file yet, and the switch-over
    /// follows `gone` records when it reads them (`editsFromLegacy`).
    static func personFolders(on share: String) -> [String] {
        let fm = FileManager.default
        let root = ((Paths.volumes + share) as NSString).appendingPathComponent(Paths.shareDir)
        let posters = (Paths.posterDir as NSString).lastPathComponent
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted()
            .filter { !$0.hasPrefix(".") && $0 != posters }
            .map { (root as NSString).appendingPathComponent($0) }
            .filter { ProfileBundle.isDirectory($0)
                && fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(SharedTagFile.name)) }
    }

    /// One person's folder: lock, read again under it, apply, write, unlock.
    /// True when done — including when none of those videos were theirs.
    /// False when the lock could not be had or a write failed.
    static func apply(_ pairs: [[String]], inPersonFolder folder: String, device: String,
                      now: Double = Date().timeIntervalSince1970) -> Bool {
        apply(edits: pairs.map { .move($0[0], $0[1]) }, inPersonFolder: folder, device: device, now: now)
    }

    /// The same, for any edits. A `.remove` named in `parks` has the person's
    /// tags on that video kept first (`ParkedTags.keep`) — and if they cannot
    /// be kept, nothing of theirs is removed and the folder is owed instead.
    /// Only a `.move` re-keys facts and transcripts: a trashed video's stay
    /// where they are, to come back with it.
    static func apply(edits: [SharedTagEdit], parks: [String: String] = [:],
                      inPersonFolder folder: String, device: String,
                      now: Double = Date().timeIntervalSince1970) -> Bool {
        let pairs: [[String]] = edits.compactMap {
            if case let .move(from, to) = $0 { return [from, to] } else { return nil }
        }
        guard let token = SharedTagDisk.lock(folder: folder, by: device, budget: lockBudget)
        else { return false }
        defer { SharedTagDisk.unlock(folder: folder, token: token) }
        var done = true

        var current: SharedTagFile?
        switch SharedTagDisk.read(folder: folder) {
        case let .file(file, _): current = file
        case .missing: current = SharedTagDisk.unfinishedWrite(folder: folder)
        case .unreadable: current = nil
        }
        // A file from a later version is never written over: this version's
        // idea of the format would drop whatever that one added.
        if var file = current, !file.isReadOnlyHere {
            let before = file
            for case let .remove(rest) in edits {
                guard let key = parks[rest], let names = file.videos[rest], !names.isEmpty else { continue }
                if !ParkedTags.keep(key, person: folder, names: names, now: now) { return false }
            }
            file.apply(edits, at: now)
            if file != before {
                file.prune(now: now)
                if SharedTagDisk.write(file, folder: folder, device: device) != nil { done = false }
            }
        }

        let factsPath = (folder as NSString).appendingPathComponent(SharedExtras.factsName)
        if var facts = SharedExtras.readJSON(SharedExtras.Facts.self, factsPath),
           facts.format <= SharedExtras.currentFormat,
           rekey(&facts.videos, pairs) {
            done = SharedExtras.write(facts, factsPath, device: device) && done
        }
        let linesPath = (folder as NSString).appendingPathComponent(SharedExtras.transcriptsName)
        if var lines = SharedExtras.readJSON(SharedExtras.Transcripts.self, linesPath),
           lines.format <= SharedExtras.currentFormat,
           rekey(&lines.videos, pairs) {
            done = SharedExtras.write(lines, linesPath, device: device) && done
        }
        return done
    }

    /// Re-key a share file's videos. A video already at the new path keeps
    /// what it has.
    private static func rekey<V>(_ videos: inout [String: V], _ pairs: [[String]]) -> Bool {
        var moved = false
        for pair in pairs where pair[0] != pair[1] {
            guard let value = videos.removeValue(forKey: pair[0]) else { continue }
            if videos[pair[1]] == nil { videos[pair[1]] = value }
            moved = true
        }
        return moved
    }

    // MARK: - a folder, not a file

    /// A folder renamed or moved, for what names FOLDERS rather than videos,
    /// past the profile in force: every other bundle's background upkeep
    /// (`maintenance.json`) and pin merge base (`shared-extras.json`), and
    /// every other person's `pins.json` on the share — so a folder somebody
    /// pinned on their Apple TV's Home screen is still pinned.
    static func carryFolder(_ map: PathMap, except active: String, device: String,
                            root: String = Paths.support) {
        changeFolders(except: active, device: device, root: root, share: share(of: map.from),
                      maintenance: { $0.relocate(map) },
                      pins: { $0.map { restOf(map.map(absolute($0, map.from)) ?? absolute($0, map.from)) ?? $0 } })
    }

    /// A folder deleted: it leaves the same lists.
    static func forgetFolder(_ folder: String, except active: String, device: String,
                             root: String = Paths.support) {
        let gone = PathMap(from: folder, to: folder, isFolder: true)
        changeFolders(except: active, device: device, root: root, share: share(of: folder),
                      maintenance: { $0.forget(folder) },
                      pins: { $0.filter { gone.map(absolute($0, folder)) == nil } })
    }

    private static func changeFolders(except active: String, device: String, root: String,
                                      share: String?,
                                      maintenance: (inout MaintenanceFile) -> Void,
                                      pins: ([String]) -> [String]) {
        for slug in ProfileBundle.slugs(root: root) where slug != active {
            let file = ProfileBundle.file(in: slug, "maintenance.json", root: root)
            if FileManager.default.fileExists(atPath: file) {
                var upkeep = MaintenanceFile.load(at: file)
                let before = upkeep
                maintenance(&upkeep)
                if upkeep != before { _ = upkeep.save(to: file) }
            }
            let extras = SharedExtras.stateFile(slug, root: root)
            if let share, FileManager.default.fileExists(atPath: extras) {
                var state = JSONStore.load(extras, fallback: SharedExtras.State())
                if let base = state.pinBase[share] {
                    state.pinBase[share] = pins(base)
                    if state.pinBase[share] != base { JSONStore.save(extras, state) }
                }
            }
        }
        guard let share else { return }
        for folder in personFolders(on: share) where (folder as NSString).lastPathComponent != active {
            let path = (folder as NSString).appendingPathComponent(SharedExtras.pinsName)
            guard FileManager.default.fileExists(atPath: path),
                  let token = SharedTagDisk.lock(folder: folder, by: device, budget: lockBudget) else { continue }
            if var file = SharedExtras.readJSON(SharedExtras.Pins.self, path),
               file.format <= SharedExtras.currentFormat {
                let now = pins(file.folders)
                if now != file.folders {
                    file.folders = now
                    _ = SharedExtras.write(file, path, device: device)
                }
            }
            SharedTagDisk.unlock(folder: folder, token: token)
        }
    }

    /// The share a path is on, or nil for a Mac's own disk.
    private static func share(of path: String) -> String? {
        let key = Paths.tagKey(path)
        guard !key.hasPrefix("/") else { return nil }
        return key.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// A share-relative pin, as the absolute path on the share `near` is on.
    private static func absolute(_ rest: String, _ near: String) -> String {
        Paths.volumes + (share(of: near) ?? "") + "/" + rest
    }

    /// An absolute path, back to share-relative.
    private static func restOf(_ path: String) -> String? {
        let key = Paths.tagKey(path)
        guard !key.hasPrefix("/"), let cut = key.firstIndex(of: "/") else { return nil }
        return String(key[key.index(after: cut)...])
    }

    // MARK: - a video sent to the Trash

    /// Take trashed videos out of every person's file on their share except
    /// `skip` (the profile in force, whose own sync sends its `.remove`),
    /// keeping each person's tags for Put Back first. Keys are tag keys at the
    /// videos' old paths. Returns what could not be written now.
    static func removeOnShares(_ keys: [String], skip: String, device: String) -> [Owed] {
        var byShare: [String: [String: String]] = [:]      // share → rest → key
        for key in keys {
            guard let edit = SharedTagEdit.forMove(from: key, to: nil),
                  case let .remove(rest) = edit.edit else { continue }
            byShare[edit.share, default: [:]][rest] = key
        }
        var owed: [Owed] = []
        for (share, parks) in byShare.sorted(by: { $0.key < $1.key }) {
            let edits = parks.keys.sorted().map { SharedTagEdit.remove($0) }
            for folder in personFolders(on: share) where (folder as NSString).lastPathComponent != skip {
                if !apply(edits: edits, parks: parks, inPersonFolder: folder, device: device) {
                    owed.append(Owed(folder: folder, moves: [], edits: edits, parks: parks))
                }
            }
        }
        return owed
    }

    /// Put Back, for one person's file: their kept tags go back on the video —
    /// unless they have tagged it themselves since, which stands. True when
    /// done, false when the lock could not be had.
    static func restore(_ rest: String, names: [String], inPersonFolder folder: String,
                        device: String, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let token = SharedTagDisk.lock(folder: folder, by: device, budget: lockBudget)
        else { return false }
        defer { SharedTagDisk.unlock(folder: folder, token: token) }
        guard case var .file(file, _) = SharedTagDisk.read(folder: folder), !file.isReadOnlyHere
        else { return true }            // nothing there to put them back into
        guard (file.videos[rest] ?? []).isEmpty else { return true }
        file.apply(.set(rest, names), at: now)
        return SharedTagDisk.write(file, folder: folder, device: device) == nil
    }

    // MARK: - what is owed

    /// Guards the owed file: the retry at launch and a move's own run can
    /// overlap, and both read it, change it and write it back.
    private static let owedLock = NSLock()

    static func owed() -> [Owed] {
        JSONStore.load(Paths.relocationsOwedFile, fallback: [Owed]())
    }

    /// Remember folders still to be told, beside any already waiting.
    static func owe(_ more: [Owed]) {
        guard !more.isEmpty else { return }
        owedLock.lock(); defer { owedLock.unlock() }
        JSONStore.save(Paths.relocationsOwedFile, owed() + more)
    }

    /// Have another go at every folder still owed its moves. Those that take
    /// them are struck off; the rest wait for the next try.
    static func retryOwed(device: String) {
        owedLock.lock(); defer { owedLock.unlock() }
        let waiting = owed()
        guard !waiting.isEmpty else { return }
        let left = waiting.filter {
            !apply(edits: $0.allEdits, parks: $0.parks ?? [:], inPersonFolder: $0.folder, device: device)
        }
        if left.isEmpty {
            try? FileManager.default.removeItem(atPath: Paths.relocationsOwedFile)
        } else if left != waiting {
            JSONStore.save(Paths.relocationsOwedFile, left)
        }
    }

    // MARK: - before a move leaves its share

    /// Who, besides `skip`, has tags on these videos on their share — the
    /// people whose tags cannot follow a video that leaves it. Person folder
    /// name → how many of the videos they tagged.
    static func peopleTagging(_ paths: [String], skip: String) -> [String: Int] {
        var byShare: [String: Set<String>] = [:]
        for path in paths {
            let key = Paths.tagKey(path)
            guard !key.hasPrefix("/"), let cut = key.firstIndex(of: "/") else { continue }
            byShare[String(key[..<cut]), default: []].insert(String(key[key.index(after: cut)...]))
        }
        var counts: [String: Int] = [:]
        for (share, rests) in byShare {
            for folder in personFolders(on: share) {
                let person = (folder as NSString).lastPathComponent
                guard person != skip, case let .file(file, _) = SharedTagDisk.read(folder: folder)
                else { continue }
                let tagged = rests.filter { !(file.videos[$0] ?? []).isEmpty }.count
                if tagged > 0 { counts[person, default: 0] += tagged }
            }
        }
        return counts
    }
}

extension SharedTagEdit {
    /// The edit a person's shared file needs when a video they tagged moves
    /// from one tag key to another — nil when it was never on a share. Within
    /// one share it is a move; off it — another share, a local folder, the
    /// bin — the video is gone from that share.
    static func forMove(from: String, to: String?) -> (share: String, edit: SharedTagEdit)? {
        func split(_ key: String) -> (share: String, rest: String)? {
            guard !key.hasPrefix("/"), let cut = key.firstIndex(of: "/") else { return nil }
            let rest = String(key[key.index(after: cut)...])
            return rest.isEmpty ? nil : (String(key[..<cut]), rest)
        }
        guard let old = split(from) else { return nil }
        if let to, let new = split(to), new.share == old.share {
            return (old.share, .move(old.rest, new.rest))
        }
        return (old.share, .remove(old.rest))
    }
}

extension SharedTagFile {
    /// The moves recorded here that this device has not looked at yet, each
    /// followed to where the video is now, and what it has now seen.
    ///
    /// A move made on another Mac reaches this one's TAGS by the file alone.
    /// What lives only on this Mac — watch state, moments, resume points,
    /// marks — is keyed by path too, and nothing carries it unless this Mac
    /// replays the move. `seen` is `gone`'s own path → time, so each record is
    /// looked at once, and forgotten when the file prunes it.
    func unseenMoves(seen: [String: Double]) -> (moves: [[String]], seen: [String: Double]) {
        var moves: [[String]] = []
        for (path, went) in gone.sorted(by: { $0.key < $1.key })
        where went.to != nil && seen[path] != went.at {
            if let now = destination(of: path), now != path { moves.append([path, now]) }
        }
        return (moves, gone.mapValues(\.at))
    }
}
