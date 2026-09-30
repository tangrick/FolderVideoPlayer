import Foundation

/// Creating, renaming, moving and deleting FOLDERS — folder management,
/// phase 4.
///
/// A folder rename is one atomic rename on disk, instant even for thousands
/// of videos on a NAS. The bookkeeping is not: every video under it is keyed
/// by a path that just changed, for this profile, every other profile on this
/// Mac and every person on the share. So a folder move is a file move for
/// each video in it — found by walking the folder, plus any the library
/// still knows under the old name whose file is already gone — carried in
/// one batch (`Library.moveTags(_:)`), and then the lists that name folders
/// themselves: pinned and recent, scans, background upkeep, the session.
///
/// Deleting is `FolderDelete`'s, and only ever of an empty folder.
///
/// Folders move within one volume only: across volumes it would be a copy of
/// a whole tree over the network, and the user decided against it.
@MainActor
enum FolderOps {

    /// Whether two paths are on one volume. A seam for the tests, which have
    /// only one disk.
    static var sameVolume: (String, String) -> Bool = { a, b in
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = try? URL(fileURLWithPath: a).resourceValues(forKeys: key).volumeIdentifier,
              let y = try? URL(fileURLWithPath: b).resourceValues(forKeys: key).volumeIdentifier
        else { return false }
        return x.isEqual(y)
    }

    /// Told of a folder that moved or went, for what lives outside the model
    /// layer: the background upkeep in hand and the playlist. Set by the app.
    static var folderRelocated: ((PathMap) -> Void)?
    static var folderDeleted: ((String) -> Void)?

    /// The videos among `paths` that a move into `folder` takes off the share
    /// they are on — whose other people's tags cannot follow them.
    nonisolated static func leavingShare(_ paths: [String], into folder: String) -> [String] {
        func share(_ path: String) -> String? {
            let key = Paths.tagKey(path)
            guard !key.hasPrefix("/") else { return nil }
            return key.split(separator: "/", maxSplits: 1).first.map(String.init)
        }
        let destination = share(folder)
        return paths.filter { share($0).map { $0 != destination } ?? false }
    }

    // MARK: - names

    /// Why a name will not do, or nil when it will. Trimmed first, as Finder
    /// trims.
    static func validateName(_ raw: String, isFolder: Bool) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "a name cannot be empty" }
        if name.contains("/") { return "a name cannot contain “/”" }
        if name.contains(":") { return "a name cannot contain “:”" }
        // The scanner skips dot-names: the item would vanish from the library.
        // `.FolderVideoPlayer`, where the share's tags live, is one of them.
        if name.hasPrefix(".") { return "a name cannot start with “.” — it would be hidden" }
        if name.utf8.count > 255 { return "that name is too long" }
        if !isFolder {
            let ext = (name as NSString).pathExtension.lowercased()
            // No extension keeps the old one (FileOps.rename); a new one must
            // still be a video, or the file drops out of the library.
            if !ext.isEmpty && !videoExtensions.contains(ext) {
                return "“.\(ext)” is not a video the app plays — it would leave the library"
            }
        }
        return nil
    }

    // MARK: - creating

    /// A new folder in `parent`: "untitled folder", "untitled folder 2"… when
    /// no name is given. Never over anything already there.
    @discardableResult
    static func makeFolder(in parent: String, named: String? = nil) async -> FileOps.Report {
        var report = FileOps.Report()
        let name = named?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, let why = validateName(name, isFolder: true) {
            report.failed.append((name, why))
            return report
        }
        let made: Result<String, NSError> = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var candidates: [String] = []
            if let name { candidates = [name] } else {
                candidates = ["untitled folder"] + (2...999).map { "untitled folder \($0)" }
            }
            for leaf in candidates {
                let target = (parent as NSString).appendingPathComponent(leaf)
                guard !fm.fileExists(atPath: target) else { continue }
                do {
                    try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
                    return .success(target)
                } catch {
                    return .failure(error as NSError)
                }
            }
            return .failure(NSError(domain: "FolderOps", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "“\(name ?? "untitled folder")” is already there"]))
        }.value
        switch made {
        case .success(let path): report.done.append(path)
        case .failure(let error): report.failed.append((name ?? "untitled folder", error.localizedDescription))
        }
        return report
    }

    // MARK: - renaming and moving

    static func renameFolder(_ path: String, to name: String, library: Library) async -> FileOps.Report {
        let leaf = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let why = validateName(leaf, isFolder: true) {
            var report = FileOps.Report()
            report.failed.append(((path as NSString).lastPathComponent, why))
            return report
        }
        let parent = (path as NSString).deletingLastPathComponent
        return await relocateFolder(from: path, to: (parent as NSString).appendingPathComponent(leaf),
                                    library: library)
    }

    static func moveFolder(_ path: String, into parent: String, library: Library) async -> FileOps.Report {
        await relocateFolder(from: path,
                             to: (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent),
                             library: library)
    }

    /// Why a folder may not go from `old` to `new`, or nil.
    static func refusal(moving old: String, to new: String) -> String? {
        let fm = FileManager.default
        if let why = untouchable(old) { return why }
        if old == new { return "it is already there" }
        if PathMap(from: old, to: old, isFolder: true).map(new) != nil {
            return "a folder cannot go inside itself"
        }
        if !sameVolume(old, (new as NSString).deletingLastPathComponent) {
            return "folders move within one drive only — move the videos inside instead"
        }
        if fm.fileExists(atPath: new) && !FileOps.sameFile(old, new) {
            return "“\((new as NSString).lastPathComponent)” is already there"
        }
        return nil
    }

    /// Folders no operation here may rename, move or delete.
    static func untouchable(_ path: String) -> String? {
        let clean = (path as NSString).standardizingPath
        let volumes = (Paths.volumes as NSString).standardizingPath
        if clean == "/" || clean == NSHomeDirectory() || clean == volumes
            || (clean as NSString).deletingLastPathComponent == volumes {
            return "that folder belongs to the system"
        }
        if (clean as NSString).lastPathComponent == Paths.shareDir
            || FileManager.default.fileExists(atPath: (clean as NSString).appendingPathComponent(Paths.shareDir)) {
            return "that folder holds the share's tags"
        }
        return nil
    }

    private static func relocateFolder(from old: String, to new: String,
                                       library: Library) async -> FileOps.Report {
        var report = FileOps.Report()
        let name = (old as NSString).lastPathComponent
        if let why = refusal(moving: old, to: new) {
            report.failed.append((name, why))
            return report
        }
        let planned = PathMap(from: old, to: new, isFolder: true)
        RelocationJournal.begin(planned)
        let landed: Result<String, NSError> = await Task.detached(priority: .userInitiated) {
            do {
                try FileOps.moveFile(old, to: new)
                return .success(FileOps.onDisk(new))
            } catch {
                return .failure(error as NSError)
            }
        }.value
        switch landed {
        case .failure(let error):
            RelocationJournal.end([planned])
            report.failed.append((name, error.localizedDescription))
        case .success(let path):
            let map = PathMap(from: old, to: path, isFolder: true)
            await finishRelocation(map, library: library)
            RelocationJournal.end([planned])
            report.done.append(path)
            report.moves.append(map)
        }
        return report
    }

    /// Everything after the folder itself has moved: each video under it, on
    /// this Mac and past it, and the lists that name the folder. Also what a
    /// launch runs for a folder move a crash cut short.
    static func finishRelocation(_ map: PathMap, library: Library) async {
        let found = await Task.detached(priority: .userInitiated) { Scanner.scan(map.to) }.value
        // A walk reports the folder's real path (`/private/var` for `/var`):
        // map each back from whichever form it came in.
        let real = (map.to as NSString).resolvingSymlinksInPath
        let back = [PathMap(from: map.to, to: map.from, isFolder: true),
                    PathMap(from: realPath(map.to), to: map.from, isFolder: true),
                    PathMap(from: real, to: map.from, isFolder: true)]
        var olds = Set(found.compactMap { path in back.lazy.compactMap { $0.map(path) }.first })
        olds.formUnion(library.keys(under: map.from))
        let moves = olds.sorted().compactMap { old in map.map(old).map { PathMap(from: old, to: $0) } }

        library.moveTags(moves)
        library.relocateFolderLists(map)
        folderRelocated?(map)
        library.saveTags()
        library.save()
        await ProfileRelocation.spread(moves, library: library)
        let active = library.profileOpen ? slug(library.person) : ""
        let device = slug(library.device)
        let root = Paths.support
        await Task.detached(priority: .utility) {
            ProfileRelocation.carryFolder(map, except: active, device: device, root: root)
        }.value
    }

    private nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - deleting

    /// Delete a folder that holds no files — see `FolderDelete`. `root`, when
    /// given, is the folder the user is organising, which is never deleted
    /// from under them.
    static func deleteFolder(_ path: String, library: Library, root: String? = nil) async -> FileOps.Report {
        var report = FileOps.Report()
        let name = (path as NSString).lastPathComponent
        if let why = untouchable(path) {
            report.failed.append((name, why))
            return report
        }
        if let root, (root as NSString).standardizingPath == (path as NSString).standardizingPath {
            report.failed.append((name, "it is the folder being organised"))
            return report
        }
        let outcome = await Task.detached(priority: .userInitiated) { FolderDelete.delete(path) }.value
        switch outcome {
        case .refused(let why):
            report.failed.append((name, why))
        case .deleted:
            library.forgetFolderEverywhere(path)
            folderDeleted?(path)
            let active = library.profileOpen ? slug(library.person) : ""
            let device = slug(library.device)
            let supportRoot = Paths.support
            await Task.detached(priority: .utility) {
                ProfileRelocation.forgetFolder(path, except: active, device: device, root: supportRoot)
            }.value
            report.done.append(path)
        }
        return report
    }

    // MARK: - after a crash

    /// Finish every move a crash cut short: a file's through the rings, a
    /// folder's through `finishRelocation`. Run once at launch, after the
    /// stores behind the library's hooks are attached.
    static func recover(library: Library) async {
        let finished = library.recoverRelocations()
        for map in finished where map.isFolder {
            await finishRelocation(map, library: library)
        }
        await ProfileRelocation.spread(finished.filter { !$0.isFolder }, library: library)
    }
}
