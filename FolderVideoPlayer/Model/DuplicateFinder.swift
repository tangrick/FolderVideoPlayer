import AppKit
import Foundation

/// One set of files that are the same file, with its survivor decided.
struct DupeGroup: Identifiable, Hashable {
    var id: String
    var keys: [String]
    var keeper: String
    var why: String
    var size: Int64
    var doomed: [String]
    var reclaim: Int64
    var verified: Bool
}

/// The duplicate finder: a sweep that fills the index, results derived from
/// it, and the machinery for deciding what survives.
@MainActor
final class DuplicateFinder: ObservableObject {
    private let library: Library

    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    @Published private(set) var sweptCount = 0
    @Published var filter = ""
    /// Which copy the user picked in each set, remembered across redraws.
    @Published private var keeperChoice: [String: String] = [:]
    /// Derived results, held until something changes what the answer would be.
    ///
    /// Deriving asks the disk whether every copy in every set still exists.
    /// Over SMB that is a round trip each — at 300 sets, 900 of them, about a
    /// second of dead application. It used to run on every click, including
    /// picking a keeper, which is what made that appear to hang.
    @Published private(set) var groups: [DupeGroup] = []

    private var generation = 0
    private var stopRequested = false
    private var derivedFor = -1

    init(library: Library) {
        self.library = library
    }

    // MARK: - the sweep

    func startScan() {
        guard !library.scanFolders().isEmpty else {
            status = "Add a folder to scan."
            return
        }
        stopRequested = false
        scanning = true
        sweptCount = 0
        generation += 1
        status = "Listing files…"
        let mine = generation
        let folders = library.scanFolders()
        let verify = library.verifyDupes
        let index = library.prints
        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.sweep(folders: folders, verify: verify, index: index) {
                await self?.cancelled(mine) ?? true
            } report: { text in
                await self?.report(text, mine)
            }
            await self?.finished(mine, index: outcome.index, seen: outcome.seen)
        }
    }

    func stopScan() {
        stopRequested = true
        status = "Stopping…"
    }

    private func cancelled(_ mine: Int) -> Bool {
        stopRequested || mine != generation
    }

    private func report(_ text: String, _ mine: Int) {
        guard mine == generation else { return }
        status = text
    }

    private func finished(_ mine: Int, index: [String: PrintEntry], seen: Int) {
        // A sweep that was superseded has nothing to report: the live one owns
        // the scanning flag and the scan's record now.
        guard mine == generation else { return }
        scanning = false
        sweptCount = seen
        library.replacePrints(index)
        library.savePrints()
        let stopped = stopRequested
        status = stopped
            ? "Stopped — fingerprints taken are kept, and the scan still shows its last full run."
            : "Done."
        derive()
        // Only a run that finished writes the scan's record: stamping a
        // stopped one would claim the library had just been covered when a
        // fraction of it had.
        if var scan = library.currentScan, !stopped {
            scan.ran = Date().timeIntervalSince1970
            scan.seen = seen
            scan.groups = groups.count
            library.updateScan(scan)
        }
    }

    /// List, sieve by size, fingerprint, verify. All off the main thread.
    private nonisolated static func sweep(folders: [String], verify: Bool,
                                          index start: [String: PrintEntry],
                                          cancelled: () async -> Bool,
                                          report: (String) async -> Void)
        async -> (index: [String: PrintEntry], seen: Int) {
        var index = start
        // 1 — list, taking the size that comes free with the listing
        var sizes: [String: Int64] = [:]
        var seen = 0
        let fm = FileManager.default
        for folder in folders {
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: folder),
                                           includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                           options: [.skipsHiddenFiles]) else { continue }
            // Stepped by hand rather than with `for in`: an enumerator's
            // iterator is not available from an async context.
            while let url = walk.nextObject() as? URL {
                if await cancelled() { return (index, seen) }
                guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize else { continue }
                sizes[Paths.tagKey(url.path)] = Int64(size)
                seen += 1
                if seen % 200 == 0 { await report("Listed \(seen.formatted()) videos…") }
            }
        }

        // 2 — only files whose size is shared with something can be duplicates
        let candidates = Fingerprints.sizeCandidates(sizes)
        await report("\(candidates.count.formatted()) of \(seen.formatted()) share a size — fingerprinting…")
        var done = 0
        for key in candidates {
            if await cancelled() { return (index, seen) }
            let path = Paths.tagPath(key)
            if !isFresh(index[key], path) {
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value,
                   let mark = Fingerprints.fingerprint(path, size: size) {
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    index[key] = PrintEntry(size: size, mtime: mtime, fp: mark, full: nil,
                                            seen: Date().timeIntervalSince1970)
                }
            }
            done += 1
            if done % 25 == 0 {
                await report("Fingerprinting \(done.formatted()) of \(candidates.count.formatted())…")
            }
        }

        // Anything whose size is unique cannot be a duplicate, so a stale entry
        // claiming otherwise has to go or it will haunt the results.
        let shared = Set(candidates)
        for key in index.keys where sizes[key] != nil && !shared.contains(key) {
            index.removeValue(forKey: key)
        }

        // 3 — read in full, but only what the fingerprints already agree on
        guard verify else { return (index, seen) }
        let groups = Fingerprints.duplicateGroups(index)
            .filter { $0.contains { sizes[$0] != nil } }
        let total = groups.reduce(0) { $0 + $1.count }
        var checked = 0
        for group in groups {
            for key in group {
                if await cancelled() { return (index, seen) }
                guard var entry = index[key], entry.full == nil else {
                    checked += 1
                    continue
                }
                // Cancellation is checked between files rather than between
                // blocks: one long read may finish before a stopped scan ends.
                let mark = Fingerprints.fullHash(Paths.tagPath(key)) { false }
                guard let mark else { continue }
                entry.full = mark
                index[key] = entry
                checked += 1
                await report("Verifying \(checked.formatted()) of \(total.formatted())…")
            }
        }
        return (index, seen)
    }

    private nonisolated static func isFresh(_ known: PrintEntry?, _ path: String) -> Bool {
        guard let known, !known.fp.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return known.size == size && abs(known.mtime - mtime) < 1
    }

    // MARK: - the results

    /// Recompute the visible sets if the index has moved since last time.
    func refresh() {
        if derivedFor != library.indexRevision { derive() }
    }

    /// Sets, biggest reclaim first, each with its keeper decided.
    ///
    /// A copy taken out of the list is gone from here entirely rather than
    /// marked up — that is the point of taking it out — and a set that drops
    /// to one copy that way stops being a set. With a scan selected, a set
    /// shows when any of its copies is inside that scan's folders, and then
    /// all of them are: hiding the others would leave a set of one, and the
    /// thing worth knowing is precisely that the file also exists somewhere
    /// you did not scan.
    ///
    /// Whether each copy still exists is a question for the disk, and over
    /// SMB it is a round trip a copy — hundreds of them when the window
    /// opens — so the asking happens off the main thread and the answer
    /// lands here when it is ready.
    func derive() {
        derivedFor = library.indexRevision
        let folders = library.scanFolders()
        let groups = library.dupeGroups()
        let prints = library.prints
        let spared = library.sparedDupes
        // A hidden video is invisible to the app, so it is not a copy the
        // finder may propose deleting — and it does not hold a set open by
        // being the only surviving member.
        let hidden = library.hidden
        let keeperPicks = keeperChoice
        Task { [weak self] in
            // The disk is asked out there: one round trip per copy, and over
            // SMB that is seconds the window should not be frozen for.
            var rows: [DupeGroup] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var out: [DupeGroup] = []
                for group in groups {
                    let alive = group.filter {
                        !spared.contains($0) && !hidden.contains($0)
                            && fm.fileExists(atPath: Paths.tagPath($0))
                    }
                    guard alive.count > 1 else { continue }
                    if !folders.isEmpty,
                       !alive.contains(where: { Scanner.under(Paths.tagPath($0), folders) }) { continue }
                    let gid = alive[0]
                    let size = prints[alive[0]]?.size ?? 0
                    let verified = alive.allSatisfy { prints[$0]?.full != nil }
                    out.append(DupeGroup(id: gid, keys: alive, keeper: "", why: "",
                                         size: size, doomed: [],
                                         reclaim: size * Int64(alive.count - 1),
                                         verified: verified))
                }
                return out.sorted { $0.reclaim > $1.reclaim }
            }.value
            guard let self, self.derivedFor == library.indexRevision else { return }
            // Keepers are decided here, on the main actor, where the tags and
            // the user's own picks live.
            for i in rows.indices {
                let alive = rows[i].keys
                if let chosen = keeperPicks[rows[i].id], alive.contains(chosen) {
                    rows[i].keeper = chosen
                    rows[i].why = "your choice"
                } else {
                    let (keeper, why) = self.suggestKeeper(alive)
                    rows[i].keeper = keeper
                    rows[i].why = why
                }
                rows[i].doomed = alive.filter { $0 != rows[i].keeper }
                rows[i].reclaim = rows[i].size * Int64(rows[i].doomed.count)
            }
            self.groups = rows
        }
    }

    /// Which copy to keep, and why, in words.
    ///
    /// Tags first, because they are the only part of a video that is your work
    /// rather than the file's: a re-download can be replaced, an afternoon of
    /// labelling cannot. Then the oldest, usually the original. Then the
    /// shortest path, usually the one filed somewhere deliberate.
    func suggestKeeper(_ group: [String]) -> (String, String) {
        let tagged = group.filter { !library.tagsFor(Paths.tagPath($0)).isEmpty }
        if tagged.count == 1 { return (tagged[0], "has tags") }
        let pool = tagged.isEmpty ? group : tagged
        let dated = pool.map { (library.prints[$0]?.mtime ?? 0, $0) }
        let oldest = dated.map(\.0).min() ?? 0
        let sameAge = dated.filter { abs($0.0 - oldest) < 2 }.map(\.1)
        if sameAge.count == 1 {
            return (sameAge[0], "oldest" + (tagged.isEmpty ? "" : " of the tagged"))
        }
        let shortest = sameAge.min { ($0.count, $0) < ($1.count, $1) } ?? pool[0]
        return (shortest, "shortest path")
    }

    var filteredGroups: [DupeGroup] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in
            group.keys.contains { Paths.tagPath($0).lowercased().contains(needle) }
        }
    }

    var reclaimable: Int64 { filteredGroups.reduce(0) { $0 + $1.reclaim } }
    var doomedCount: Int { filteredGroups.reduce(0) { $0 + $1.doomed.count } }

    /// Point a set at a different survivor, in place — the list is edited
    /// where it sits rather than derived again, so the disk is not asked about
    /// a single file.
    func setKeeper(_ group: DupeGroup, _ key: String, why: String = "your choice") {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        keeperChoice[group.id] = key
        groups[i].keeper = key
        groups[i].why = why
        groups[i].doomed = groups[i].keys.filter { $0 != key }
        groups[i].reclaim = groups[i].size * Int64(groups[i].doomed.count)
    }

    enum KeepRule: String { case tags, oldest, shortest }

    /// Apply a keep rule to the sets on screen — the filtered ones only. A
    /// rule you cannot see act on is hard to trust, so when the filter has
    /// narrowed the list the rule narrows with it.
    @discardableResult
    func applyKeepRule(_ rule: KeepRule) -> Int {
        let visible = filteredGroups
        for group in visible {
            let pick: String
            switch rule {
            case .tags:
                let tagged = group.keys.filter { !library.tagsFor(Paths.tagPath($0)).isEmpty }
                pick = tagged.first ?? suggestKeeper(group.keys).0
            case .oldest:
                pick = group.keys.min { (library.prints[$0]?.mtime ?? 0) < (library.prints[$1]?.mtime ?? 0) }
                    ?? group.keeper
            case .shortest:
                pick = group.keys.min { ($0.count, $0) < ($1.count, $1) } ?? group.keeper
            }
            setKeeper(group, pick)
        }
        return visible.count
    }

    /// Take a copy out of the results without touching the file — a decision
    /// already made, which nothing should keep asking about.
    func removeFromList(_ keys: [String]) {
        library.sparedDupes.formUnion(keys)
        library.save()
        library.dupesChanged()
        derive()
    }

    func restoreRemoved() {
        library.sparedDupes.removeAll()
        library.save()
        library.dupesChanged()
        derive()
    }

    // MARK: - discarding

    struct TrashReport {
        var moved = 0
        var failed: [(String, String)] = []
        var reclaimed: Int64 = 0
    }

    /// Discard every doomed copy in the visible sets. Tags on a copy about to
    /// go are carried over to the one being kept first: they are the part of a
    /// video that was your work.
    func discardDoomed(_ chosen: [DupeGroup]) -> TrashReport {
        var report = TrashReport()
        for group in chosen {
            for key in group.doomed {
                mergeTags(into: group.keeper, from: key)
                let path = Paths.tagPath(key)
                let (ok, why) = discard(path)
                if ok {
                    report.moved += 1
                    report.reclaimed += group.size
                    library.forgetPrint(key)
                } else {
                    report.failed.append((path, why))
                }
            }
        }
        library.saveTags()
        library.savePrints()
        library.dupesChanged()
        derive()
        return report
    }

    private func mergeTags(into keeper: String, from doomed: String) {
        let keeperPath = Paths.tagPath(keeper)
        let extra = library.tagsFor(Paths.tagPath(doomed))
            .filter { !library.hasTag(keeperPath, $0) }
        if !extra.isEmpty {
            library.setTags(library.tagsFor(keeperPath) + extra, for: keeperPath)
        }
        library.setTags([], for: Paths.tagPath(doomed))
    }

    /// To the Trash — or, on a volume that has none, to a folder you pick.
    ///
    /// SMB shares generally have no Trash, which is most of this app's
    /// library. Refusing to remove anything there would make the feature
    /// useless on a NAS; deleting instead would be worse. So the third option:
    /// move them somewhere you nominate, once per volume, and you delete them
    /// yourself when you are satisfied.
    private func discard(_ path: String) -> (Bool, String) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                              resultingItemURL: nil)
            return (true, "")
        } catch {
            let why = error.localizedDescription
            let volume = Paths.volumeOf(path)
            var folder = library.discardFolders[volume]
            if let known = folder,
               !FileManager.default.fileExists(atPath: known) { folder = nil }
            if folder == nil {
                folder = askDiscardFolder(volume, why)
                library.discardFolders[volume] = folder ?? ""
                library.save()
            }
            guard let folder, !folder.isEmpty else { return (false, why) }
            return moveInto(folder, path)
        }
    }

    private func askDiscardFolder(_ volume: String, _ why: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "“\((volume as NSString).lastPathComponent)” has no Trash"
        alert.informativeText = """
        \(why)

        The duplicates can be moved to a folder on that same volume instead, \
        which is instant and changes nothing else. You delete them yourself \
        once you are happy.

        Nothing is deleted either way.
        """
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Where should duplicates from this volume go?"
        panel.directoryURL = URL(fileURLWithPath: volume)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Move a file into a folder without ever overwriting what is there: two
    /// folders can hold different videos with the same name, and one quietly
    /// replacing the other is exactly the data loss this is meant to prevent.
    private func moveInto(_ folder: String, _ path: String) -> (Bool, String) {
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var target = (folder as NSString).appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: target) {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            target = (folder as NSString).appendingPathComponent(name)
            n += 1
        }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
