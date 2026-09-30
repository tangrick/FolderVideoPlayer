import Foundation

/// One folder in the Organize window's tree.
struct FolderNode: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    /// Videos directly in it, and other files directly in it that are not
    /// clutter — a hidden folder with anything in it counts as one.
    var ownVideos: Int
    var ownOthers: Int
    /// The same, with every subfolder's added in.
    var videoCount: Int
    var otherCount: Int
    /// Subfolders, nil for a leaf — the shape a disclosure list wants.
    var children: [FolderNode]?

    init(path: String, ownVideos: Int, ownOthers: Int, children: [FolderNode]?) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.ownVideos = ownVideos
        self.ownOthers = ownOthers
        self.videoCount = ownVideos
        self.otherCount = ownOthers
        self.children = children
        total()
    }

    /// Nothing under it but the Mac's and the NAS's clutter and empty
    /// folders: what `FolderDelete` will delete.
    var isEmpty: Bool { videoCount == 0 && otherCount == 0 }

    /// Every folder in the tree, this one first.
    var flattened: [FolderNode] { [self] + (children ?? []).flatMap(\.flattened) }

    /// Totals from its own files and its subfolders'.
    mutating func total() {
        videoCount = ownVideos + (children ?? []).reduce(0) { $0 + $1.videoCount }
        otherCount = ownOthers + (children ?? []).reduce(0) { $0 + $1.otherCount }
    }

    /// The same subtree under a new name — a folder that moved has the same
    /// contents, so nothing needs reading again.
    func relocated(_ map: PathMap) -> FolderNode {
        FolderNode(path: map.map(path) ?? path, ownVideos: ownVideos, ownOthers: ownOthers,
                   children: children?.map { $0.relocated(map) })
    }
}

/// The folders under a root, for the Organize window.
///
/// The playlist lists videos, and a folder heading exists only above one — so
/// an empty folder never appears there, and could be neither filled nor
/// deleted. This is the other view: the folders themselves.
///
/// Built for a share. A folder is read with ONE listing that carries whether
/// each entry is a folder (asking entry by entry was a round trip per file);
/// NAS index folders are never entered; a hidden folder is read only as far as
/// its first real file; and after an operation only the folders it touched
/// are read again (`refreshed`), not the whole tree.
enum FolderTree {

    /// The whole tree, blocking — run it off the main thread.
    static func build(root: String, skipping: [String] = Scanner.discarded) -> FolderNode {
        node(root, skipping: Scanner.expanded(skipping))
    }

    /// The tree after an operation: each folder in `touched` read again —
    /// its own files, and which folders it holds — with every subfolder that
    /// is still where it was reused as it stands, and a folder that `moved`
    /// reused under its new name. Only a folder the tree has never seen is
    /// walked. The totals of everything above a touched folder are summed
    /// again. Blocking.
    static func refreshed(_ tree: FolderNode, touched: [String], moved: [PathMap] = [],
                          skipping: [String] = Scanner.discarded) -> FolderNode {
        let skip = Scanner.expanded(skipping)
        let before = index(tree)
        let inside = PathMap(from: tree.path, to: tree.path, isFolder: true)
        let folders = Set(touched).filter { inside.map($0) != nil }
            .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        var result = tree
        for folder in folders {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let now = index(result)
            let fresh = shallow(folder, skipping: skip) { child in
                if let known = now[child] { return known }
                for map in moved {
                    let back = PathMap(from: map.to, to: map.from, isFolder: true)
                    if let old = back.map(child), let node = before[old] { return node.relocated(map) }
                }
                return node(child, skipping: skip)
            }
            result = replacing(result, at: folder, with: fresh)
        }
        return result
    }

    /// Every folder in a tree by path.
    static func index(_ tree: FolderNode) -> [String: FolderNode] {
        Dictionary(tree.flattened.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - reading

    /// A folder and everything under it.
    private static func node(_ path: String, skipping: [String]) -> FolderNode {
        shallow(path, skipping: skipping) { node($0, skipping: skipping) }
    }

    /// A folder read once: its own files counted, and each subfolder's node
    /// asked of `child` — reused, or read in turn.
    private static func shallow(_ path: String, skipping: [String],
                                child: (String) -> FolderNode) -> FolderNode {
        var videos = 0, others = 0
        var children: [FolderNode] = []
        for entry in entries(of: path) {
            if entry.isDir {
                if FolderDelete.clutterFolders.contains(entry.name.lowercased()) { continue }
                if entry.name.hasPrefix(".") || Scanner.isInside(entry.path, skipping) {
                    if hasAnyFile(entry.path) { others += 1 }
                    continue
                }
                children.append(child(entry.path))
            } else if FolderDelete.isClutter(entry.name) {
                continue
            } else if isVideo(entry.name) {
                videos += 1
            } else {
                others += 1
            }
        }
        children.sort { naturalLess($0.name, $1.name) }
        return FolderNode(path: path, ownVideos: videos, ownOthers: others,
                          children: children.isEmpty ? nil : children)
    }

    /// The tree with one folder's node replaced, and every total above it
    /// summed again.
    private static func replacing(_ node: FolderNode, at path: String, with fresh: FolderNode) -> FolderNode {
        if node.path == path { return fresh }
        guard PathMap(from: node.path, to: node.path, isFolder: true).map(path) != nil else { return node }
        var copy = node
        copy.children = node.children?.map { replacing($0, at: path, with: fresh) }
        copy.total()
        return copy
    }

    /// Whether a folder holds any file that is not clutter — stopping at the
    /// first. A share's `.FolderVideoPlayer` holds thousands of poster frames,
    /// and all it takes to know it is not empty is one of them.
    static func hasAnyFile(_ path: String) -> Bool {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return false }
        for case let url as URL in walk {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if FolderDelete.clutterFolders.contains(url.lastPathComponent.lowercased()) {
                    walk.skipDescendants()
                }
                continue
            }
            if !FolderDelete.isClutter(url.lastPathComponent) { return true }
        }
        return false
    }

    private static func isVideo(_ name: String) -> Bool {
        !name.hasPrefix(".") && videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private struct Entry {
        var name: String
        var path: String
        var isDir: Bool
        var size: Int64
        var created: Date?
    }

    /// A folder's entries — whether each is a folder, its size and its date —
    /// from ONE listing: the share sends them with the names.
    private static func entries(of path: String) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: []) else { return [] }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            return Entry(name: name, path: (path as NSString).appendingPathComponent(name),
                         isDir: values?.isDirectory ?? false,
                         size: Int64(values?.fileSize ?? 0), created: values?.creationDate)
        }
    }

    // MARK: - one folder's files

    struct Video: Hashable, Sendable {
        var path: String
        var size: Int64
        var added: Date?
        /// Whether subtitle files sit beside it — they travel with it.
        var hasSubtitles: Bool
    }

    struct Listing: Sendable {
        var videos: [Video] = []
        /// Other files that are not clutter, by name.
        var otherFiles: [String] = []
    }

    /// One folder, not its subfolders: its videos with their size, date and
    /// whether subtitles travel with them, and the other files that are not
    /// clutter. One listing, whatever the folder holds. Blocking.
    static func listing(of folder: String) -> Listing {
        let all = entries(of: folder)
        let subtitles = SubtitleFile.sidecarIndex(all.filter { !$0.isDir }.map(\.name))
        var out = Listing()
        for entry in all where !entry.isDir && !FolderDelete.isClutter(entry.name) {
            if isVideo(entry.name) {
                out.videos.append(Video(path: entry.path, size: entry.size, added: entry.created,
                                        hasSubtitles: !SubtitleFile.sidecars(for: entry.path, in: subtitles).isEmpty))
            } else {
                out.otherFiles.append(entry.name)
            }
        }
        out.videos.sort { naturalLess(($0.path as NSString).lastPathComponent, ($1.path as NSString).lastPathComponent) }
        out.otherFiles.sort { naturalLess($0, $1) }
        return out
    }
}
