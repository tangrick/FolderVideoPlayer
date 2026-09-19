import Foundation

enum Scanner {
    /// Every video under a folder, in the order the folder headings describe:
    /// depth-first, dot-directories skipped, natural order throughout.
    static func scan(_ root: String) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                       includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walk {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
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
    static func count(_ root: String) -> Int {
        var found = 0
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: root),
                                       includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in walk {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            if videoExtensions.contains(url.pathExtension.lowercased()) { found += 1 }
        }
        return found
    }
}
