import Foundation

/// One relocation: a video, or a folder of them, that now lives somewhere else.
///
/// Everything the app knows about a video is filed under its path — tags,
/// readings, watch state, Safe/NSFW marks, the hidden set, where it was got to
/// — so a file that moves without its references moving too is a video whose
/// history is silently lost. This is the one description of such a move that
/// every store answers to.
///
/// A folder moves by PREFIX, and only at a path boundary: renaming `Clips`
/// must not touch `Clips 2019`, which merely starts with the same letters.
struct PathMap: Codable, Equatable, Sendable {
    /// Absolute paths, as the file system names them.
    var from: String
    var to: String
    var isFolder: Bool

    init(from: String, to: String, isFolder: Bool = false) {
        self.from = from
        self.to = to
        self.isFolder = isFolder
    }

    /// Where an absolute path is now, or nil when this move does not touch it.
    func map(_ path: String) -> String? {
        if path == from { return to }
        guard isFolder else { return nil }
        let prefix = Self.withSlash(from)
        guard path.hasPrefix(prefix) else { return nil }
        return Self.withSlash(to) + path.dropFirst(prefix.count)
    }

    /// Where a path is after a run of moves — the first that touches it — or
    /// the path itself when none does. What a list of paths held elsewhere
    /// (the playlist) goes through after an operation.
    static func follow(_ path: String, through maps: [PathMap]) -> String {
        for map in maps { if let now = map.map(path) { return now } }
        return path
    }

    /// The same question for a key in the tag space (`Paths.tagKey`):
    /// share-relative for a file on a mounted share, absolute otherwise.
    func mapKey(_ key: String) -> String? {
        map(Paths.tagPath(key)).map(Paths.tagKey)
    }

    private static func withSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

/// Relocations begun and not yet finished, on disk.
///
/// A move is two acts: the file system's, then the bookkeeping's. A crash
/// between them leaves the file at its new path and every reference still at
/// the old one — the tags orphaned, with nothing on screen to say why. So the
/// move is written down before the file moves and struck off only once its
/// references have followed and been saved, and a launch that finds one still
/// written down finishes it (`Library.recoverRelocations`).
enum RelocationJournal {
    static func pending() -> [PathMap] {
        JSONStore.load(Paths.relocationsFile, fallback: [PathMap]())
    }

    static func begin(_ map: PathMap) {
        JSONStore.save(Paths.relocationsFile, pending() + [map])
    }

    /// Strike these off. The file goes entirely once nothing is left, so an
    /// empty journal and no journal are the same answer.
    static func end(_ maps: [PathMap]) {
        guard !maps.isEmpty else { return }
        var left = pending()
        for map in maps {
            if let at = left.firstIndex(of: map) { left.remove(at: at) }
        }
        if left.isEmpty {
            try? FileManager.default.removeItem(atPath: Paths.relocationsFile)
        } else {
            JSONStore.save(Paths.relocationsFile, left)
        }
    }
}
