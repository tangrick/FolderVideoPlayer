import Foundation

/// One offered reattachment the user must judge: the orphaned tags and more
/// than one place the file name now lives. Single matches never land here —
/// the scan repairs those by itself.
struct MovedCandidate: Identifiable, Equatable {
    var id: String { oldKey + "→" + newPath }
    let oldKey: String          // share-relative tag key, file now missing
    let oldName: String
    let oldFolder: String
    let newPath: String         // a file that exists with the same name
    let newFolder: String
    let tagNames: [String]      // what would move, shown on the row
}

/// A tagged video whose file could not be found anywhere it was asked. The
/// reference is offered for removal — never dropped silently.
struct MissingRef: Identifiable, Equatable {
    var id: String { key }
    let key: String             // share-relative tag key, file gone
    let name: String
    let folder: String
}

/// Finds tagged videos whose file has moved since they were tagged.
///
/// Tags are keyed to a video's path; reorganising folders on the NAS strands
/// every tag under the old key. Where the file's name answers exactly once on
/// the shares, the reference is repaired automatically (one undoable edit).
/// Ambiguous names (several matches) are offered as rows to tick, and files
/// found nowhere are reported missing with an explicit "remove reference".
///
/// Both heavy passes run off the main thread and report progress, so a share
/// with thousands of files never locks the window.
@MainActor
final class MovedScan: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking(done: Int, total: Int)   // stat per tagged video
        case indexing(files: Int)              // walking the shares
        case done
    }

    var isRunning: Bool {
        if case .idle = phase { return false }
        if case .done = phase { return false }
        return true
    }

    @Published private(set) var phase: Phase = .idle
    /// Names that matched in several places — needs a human to pick.
    @Published private(set) var candidates: [MovedCandidate] = []
    /// Names with exactly one live match, repaired automatically at the end
    /// of the scan.
    @Published private(set) var autoFixes: [(key: String, newPath: String, tags: [String])] = []
    /// Orphans with no same-named file anywhere — offered for removal.
    @Published private(set) var unmatched: [MissingRef] = []

    /// Anything worth keeping the panel on screen for — rows to decide, files
    /// it could not find, or a report of what it just fixed. Idle with none of
    /// these, the panel has nothing to say and is not shown at all.
    var hasFindings: Bool {
        !candidates.isEmpty || !unmatched.isEmpty || repaired != nil || removed != nil
    }
    @Published private(set) var totalTagged = 0
    /// Optional folder scope: only tag keys under this path are checked.
    @Published var scopeRoot: String?
    /// Where to hunt for the missing files: nil = every mounted share;
    /// a folder the user picked = only inside that folder.
    @Published var searchRoot: String?
    /// Optional playlist scope: exactly these videos are checked (a tag
    /// playlist's rows, or the favorites list) — three rows means three stats.
    @Published var scopePaths: [String]?
    @Published var scopeLabel: String?
    /// Rows ticked for re-tagging (the ambiguous ones only).
    @Published var chosen: Set<String> = []
    /// What the last apply re-tagged, for the panel's summary and Undo.
    @Published var repaired: Int?
    /// What the last removal cleared.
    @Published var removed: Int?
    private var work: Task<Void, Never>?

    deinit { work?.cancel() }

    /// Videos (distinct old locations) awaiting judgement — a file matching
    /// in several places is still one moved video.
    var movedVideoCount: Int {
        Set(candidates.map(\.oldKey)).count
    }

    /// Scan. Finds every tag key whose file has gone, tries the cached name
    /// index, hunts the rest, repairs single matches, and reports the rest.
    func run(library: Library) {
        work?.cancel()
        repaired = nil
        removed = nil
        chosen = []
        candidates = []
        autoFixes = []
        unmatched = []
        work = Task { [weak self] in
            guard let self else { return }
            var entries: [String: [String]]
            if let root = scopeRoot, !root.isEmpty {
                // Folder scope: only tag keys under this folder are checked.
                let prefix = Paths.tagKey(root)
                entries = library.tags.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "/") }
            } else if let paths = scopePaths {
                // Playlist scope: only the rows the playlist is showing.
                var picked: [String: [String]] = [:]
                for path in paths { picked[Paths.tagKey(path)] = library.tagsFor(path) }
                entries = picked
            } else {
                entries = library.tags
            }
            // A hidden video is invisible to the app: the scan must not repair
            // it, re-point its tags, or report it missing. Hiding is not the
            // same as deleting, and the scan's job is gone files.
            let hidden = library.hidden
            entries = entries.filter { !hidden.contains($0.key) }
            self.totalTagged = entries.count
            self.phase = .checking(done: 0, total: entries.count)
            // One stat per tagged video — off the main thread, or a library
            // of thousands freezes the UI while the NAS answers.
            let orphans = await Self.collectOrphans(entries) { done in
                Task { @MainActor [weak self] in
                    self?.phase = .checking(done: done, total: entries.count)
                }
            }
            guard !orphans.isEmpty, !Task.isCancelled else {
                self.phase = .done
                return
            }

            // Where to hunt: the folder the user picked, else every share.
            let roots: [String]
            if let root = searchRoot, !root.isEmpty {
                roots = [root]
            } else {
                roots = Paths.networkShares().map { Paths.volumes + $0 }
            }
            // Try the cached name index first: stat each remembered spot.
            // Only names it cannot confirm need a walk at all.
            let wanted = Set(orphans.map { $0.name.lowercased() })
            let cached = NameIndex.freshAcrossShares(Paths.networkShares())
            let (confirmed, toHunt) = NameIndex.resolve(names: wanted, index: cached) { key in
                FileManager.default.fileExists(atPath: Paths.tagPath(key))
            }
            var places: [String: [String]] = confirmed.mapValues { $0.map { Paths.tagPath($0) } }
            if !toHunt.isEmpty {
                self.phase = .indexing(files: 0)
                let (hits, seen, completed) = await Self.locateNames(toHunt, roots: roots) { count in
                    Task { @MainActor [weak self] in
                        self?.phase = .indexing(files: count)
                    }
                }
                for (name, paths) in hits { places[name] = paths }
                // A full, untruncated walk is worth remembering — next time
                // these names answer from the index instead of a walk.
                if completed, searchRoot == nil {
                    NameIndex.absorb(seen)
                }
            }

            // Split the news: single match = auto-repair, several = ask,
            // none = report missing.
            var ambiguous: [MovedCandidate] = []
            var fixes: [(key: String, newPath: String, tags: [String])] = []
            var gone: [MissingRef] = []
            for orphan in orphans {
                if Task.isCancelled { return }
                let spots = places[orphan.name.lowercased()] ?? []
                if spots.isEmpty {
                    gone.append(MissingRef(key: orphan.key,
                                           name: orphan.name,
                                           folder: orphan.folder))
                } else if spots.count == 1 {
                    fixes.append((orphan.key, spots[0], orphan.tags))
                } else {
                    for place in spots {
                        ambiguous.append(MovedCandidate(oldKey: orphan.key,
                                                        oldName: orphan.name,
                                                        oldFolder: orphan.folder,
                                                        newPath: place,
                                                        newFolder: (place as NSString).deletingLastPathComponent,
                                                        tagNames: orphan.tags))
                    }
                }
            }
            // Repairs land as one undoable edit the moment the scan ends —
            // the user asked the scan to fix what it can.
            if !fixes.isEmpty {
                library.rememberForUndo("reattaching moved videos")
                for fix in fixes {
                    _ = library.moveTags(from: fix.key, to: fix.newPath)
                }
                library.saveTags()
            }
            self.autoFixes = fixes
            self.candidates = ambiguous
            self.unmatched = gone
            self.repaired = fixes.isEmpty ? nil : fixes.count
            self.phase = .done
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    /// Back to a fresh strip (Scan button), e.g. after Done.
    func reset() {
        work?.cancel()
        work = nil
        phase = .idle
        candidates = []
        autoFixes = []
        unmatched = []
        chosen = []
        repaired = nil
        removed = nil
        totalTagged = 0
    }

    func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    /// Tick one row per moved video — the first place its name was found.
    /// Extra matches for the same name stay manual, since re-tagging twice
    /// would split the tags.
    func selectAll() {
        chosen = Set(Self.firstPerKey(candidates))
    }

    /// Carry the ticked ambiguous rows over too, as one edit.
    func apply(_ picked: [MovedCandidate], library: Library) {
        guard !picked.isEmpty else { return }
        library.rememberForUndo("reattaching moved videos")
        for item in picked {
            _ = library.moveTags(from: item.oldKey, to: item.newPath)
        }
        library.saveTags()
        candidates.removeAll { item in picked.contains(item) }
        chosen = []
        repaired = (repaired ?? 0) + movedVideoCount(of: picked)
    }

    /// Drop references whose file is gone for good — explicit, undoable.
    func remove(_ refs: [MissingRef], library: Library) {
        guard !refs.isEmpty else { return }
        library.rememberForUndo("removing missing video references")
        for ref in refs {
            _ = library.forgetPath(ref.key)
        }
        library.saveTags()
        unmatched.removeAll { ref in refs.contains(ref) }
        removed = refs.count
    }

    /// How many distinct videos a ticked selection re-tags (a name matching
    /// in several places is still one video).
    private func movedVideoCount(of picked: [MovedCandidate]) -> Int {
        Set(picked.map(\.oldKey)).count
    }

    // MARK: - Pure helpers (unit-tested)

    /// The first candidate id per old location, in finding order.
    nonisolated static func firstPerKey(_ items: [MovedCandidate]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for item in items where !seen.contains(item.oldKey) {
            seen.insert(item.oldKey)
            ids.append(item.id)
        }
        return ids
    }

    /// The tag keys whose file is gone, with the file's name, folder and tags
    /// for display. Reports progress every 25 keys and yields so the task
    /// stays responsive to cancel.
    nonisolated static func collectOrphans(
        _ entries: [String: [String]],
        progress: @escaping @Sendable (Int) -> Void
    ) async -> [(key: String, name: String, folder: String, tags: [String])] {
        var orphans: [(key: String, name: String, folder: String, tags: [String])] = []
        var done = 0
        for (key, tags) in entries {
            if Task.isCancelled { break }
            let full = Paths.tagPath(key)
            if FileManager.default.fileExists(atPath: full) == false {
                orphans.append((key,
                                (full as NSString).lastPathComponent,
                                (full as NSString).deletingLastPathComponent,
                                tags))
            }
            done += 1
            if done.isMultiple(of: 25) {
                progress(done)
                await Task.yield()
            }
        }
        progress(done)
        return orphans
    }

    /// name (lowercased) → every video path with that name, across all
    /// mounted network shares. A single walk per share; reports the running
    /// file count so the panel can show live stats.

    /// The targeted hunt: walk the given roots but collect only the wanted
    /// names, and stop the moment every one has been found. On a full walk it
    /// sees the same files as indexedShares — no faster in the worst case,
    /// but a move into a small folder is found after a fraction of it.
    /// Returns the hits, plus everything seen grouped per share (share name →
    /// name → share-relative keys) and whether the walk ran to completion —
    /// only a completed walk is trustworthy enough to feed the index.
    nonisolated static func locateNames(
        _ wanted: Set<String>,
        roots: [String],
        progress: @escaping @Sendable (Int) -> Void
    ) async -> (hits: [String: [String]], seen: [String: [String: [String]]], completed: Bool) {
        var hits: [String: [String]] = [:]
        var seen: [String: [String: [String]]] = [:]
        let fm = FileManager.default
        var seenCount = 0
        for root in roots {
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                           includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles]) else { continue }
            let share = (Paths.volumeOf(root) as NSString).lastPathComponent
            let prefix = Paths.volumes + share + "/"
            // Stepped by nextObject() rather than for-in: makeIterator is
            // unavailable from async contexts (Swift 6 will make it an error).
            while let url = walk.nextObject() as? URL {
                if Task.isCancelled {
                    return (hits, seen, false)
                }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDir {
                    let name = url.lastPathComponent.lowercased()
                    if wanted.contains(name) {
                        hits[name, default: []].append(url.path)
                        seen[share, default: [:]][name, default: []].append(String(url.path.dropFirst(prefix.count)))
                        if hits.count == wanted.count {   // every name located — stop
                            progress(seenCount)
                            return (hits, seen, false)    // early exit: partial knowledge
                        }
                    }
                }
                seenCount += 1
                if seenCount.isMultiple(of: 250) {
                    progress(seenCount)
                    await Task.yield()
                }
            }
        }
        progress(seenCount)
        return (hits, seen, true)
    }
}
