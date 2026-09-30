import Foundation

enum Scanner {
    /// The folders videos are swept into on a volume with no Trash
    /// (`Library.discardFolders`), kept in step by the library. What is in one
    /// has been deleted as far as the user is concerned, so no walk that builds
    /// a view of the library may list it — otherwise a "trashed" video turns
    /// straight up again in the playlist, the counts, the duplicate finder.
    static var discarded: [String] = []

    /// Folders, and each one again with its symlinks resolved: a walk reports
    /// paths under the resolved form (`/private/var` for `/var`), so a folder
    /// named the other way would never match. Resolved once here, not per
    /// file — on a share that is a round trip per path component.
    static func expanded(_ folders: [String]) -> [String] {
        var out: [String] = []
        for folder in folders {
            for form in [folder, realPath(folder)] where !out.contains(form) {
                out.append(form)
            }
        }
        return out
    }

    /// `realpath(3)`: the form a walk reports. Not `resolvingSymlinksInPath`,
    /// which deliberately strips `/private` and so gives the other form.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a path is one of `folders`, or inside one — at a path boundary.
    static func isInside(_ path: String, _ folders: [String]) -> Bool {
        folders.contains { PathMap(from: $0, to: $0, isFolder: true).map(path) != nil }
    }

    /// Every video under a folder, in the order the folder headings describe:
    /// depth-first, dot-directories skipped, natural order throughout.
    static func scan(_ root: String, skipping: [String] = Scanner.discarded) -> [String] {
        let skipping = expanded(skipping)
        var found: [String] = []
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                       includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walk {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if isInside(url.path, skipping) { walk.skipDescendants() }
                continue
            }
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url.path)
            }
        }
        // The sort key is built once per path rather than on each comparison:
        // at five thousand files that is sixty thousand comparisons, and
        // splitting the path into its digit runs inside each of them showed.
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return found
            .map { (String($0.dropFirst($0.hasPrefix(prefix) ? prefix.count : 0)), $0) }
            .sorted { naturalLess($0.0, $1.0) }
            .map(\.1)
    }

    /// Whether a path sits under any of these folders — how a scan decides
    /// which duplicates are its business.
    static func under(_ path: String, _ folders: [String]) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// How many videos a folder holds — a plain walk, no sorting and no path
    /// reshaping. The sidebar asks for one folder at a time, and a count does
    /// not care what order anything is in.
    static func count(_ root: String, skipping: [String] = Scanner.discarded) -> Int {
        let skipping = expanded(skipping)
        var found = 0
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                       includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in walk {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if isInside(url.path, skipping) { walk.skipDescendants() }
                continue
            }
            if videoExtensions.contains(url.pathExtension.lowercased()) { found += 1 }
        }
        return found
    }
}
