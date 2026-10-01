import Foundation

/// One folder the library draws videos from, as Organize Folders lists it.
struct LibraryFolder: Identifiable, Equatable {
    /// The folder, as the file system names it.
    var path: String
    /// Videos the profile holds anything for — tags, stars, readings, watch
    /// history, a resume point — anywhere under it.
    var videos: Int
    var pinned: Bool
    var recent: Bool
    /// Kept up to date in the background (Settings ▸ Background).
    var maintained: Bool

    var id: String { path }

    /// In the library only because of what the profile holds for its videos:
    /// not pinned, not in Recent, not kept up to date. The kind of folder that
    /// is easy not to notice, and so the kind this list exists to show.
    var viaVideosOnly: Bool { !pinned && !recent && !maintained }
}

/// Every folder the library gets its videos from — the question Organize
/// Folders' root menu could not answer, since it offered only the pinned and
/// recent ones.
enum LibraryFolders {

    /// The folders, the ones the user chose first (pinned, then recent, then
    /// kept-up-to-date) and then the folders the library holds videos from
    /// without having been asked to — most videos first.
    ///
    /// A chosen folder counts every video under it, at any depth, so it says
    /// what removing it would take. A video under none of them is grouped by
    /// the folder it sits in.
    static func build(pinned: [String], recent: [String], maintained: [String],
                      videoPaths: [String]) -> [LibraryFolder] {
        let pinnedSet = Set(pinned), recentSet = Set(recent), maintainedSet = Set(maintained)
        var seen = Set<String>()
        let roots = (pinned + recent + maintained).filter { seen.insert($0).inserted }

        // The prefixes are worked out once: this runs over every video the
        // profile holds anything for, tens of thousands on a big library.
        let prefixed = roots.map { (root: $0, prefix: $0.hasSuffix("/") ? $0 : $0 + "/") }
        var counts = [String: Int](uniqueKeysWithValues: roots.map { ($0, 0) })
        var strays: [String: Int] = [:]
        for path in videoPaths {
            var covered = false
            for (root, prefix) in prefixed where path == root || path.hasPrefix(prefix) {
                counts[root, default: 0] += 1
                covered = true
            }
            if !covered { strays[(path as NSString).deletingLastPathComponent, default: 0] += 1 }
        }

        let chosen = roots.map {
            LibraryFolder(path: $0, videos: counts[$0] ?? 0, pinned: pinnedSet.contains($0),
                          recent: recentSet.contains($0), maintained: maintainedSet.contains($0))
        }
        let others = strays
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { LibraryFolder(path: $0.key, videos: $0.value, pinned: false, recent: false,
                                 maintained: false) }
        return chosen + others
    }

    /// Whether `path` is the folder or anywhere inside it. Only at a path
    /// boundary: `/v/Clips` holds `/v/Clips/a.mp4`, not `/v/Clips 2019/a.mp4`.
    static func contains(_ folder: String, _ path: String) -> Bool {
        PathMap(from: folder, to: folder, isFolder: true).map(path) != nil
    }
}
