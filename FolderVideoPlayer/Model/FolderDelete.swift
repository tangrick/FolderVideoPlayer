import Foundation

/// What a folder holds, as far as deleting it goes. Relative paths.
struct FolderContents: Equatable {
    var videos: [String] = []
    /// Anything that is not a video and not clutter — a subtitle file, a
    /// cover picture, a dotfile somebody put there. The app never shows these,
    /// which is exactly why they must never be deleted without a word.
    var otherFiles: [String] = []
    /// Files the Mac or the NAS made by themselves.
    var clutter: [String] = []
    /// Every subfolder, deepest first — the order they can be removed in.
    var folders: [String] = []

    var isEmpty: Bool { videos.isEmpty && otherFiles.isEmpty }

    /// "12 videos and 3 other files", for saying why a folder stays.
    var description: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let parts = [videos.isEmpty ? nil : count(videos.count, "video", "videos"),
                     otherFiles.isEmpty ? nil : count(otherFiles.count, "other file", "other files")]
            .compactMap { $0 }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
    }
}

/// Deleting a folder — only ever an empty one.
///
/// A folder holding a single file is not deleted, whatever the file is: a
/// video, a subtitle file, a note, a hidden file somebody put there. Only what
/// the Mac or the NAS writes by itself does not count — Finder's `.DS_Store`,
/// AppleDouble `._` files, Synology's `@eaDir` and QNAP's `.@__thumb` — and
/// those go with the folder, along with any empty subfolders.
///
/// Three layers, each enough on its own: the Organize window disables the
/// button for a folder with anything in it; this looks again, fresh, at the
/// moment of deleting; and the folders are removed with `rmdir(2)`, which the
/// system refuses for a folder that is not empty — so a file another device
/// drops in between makes the delete fail harmlessly rather than take it.
///
/// This file never removes a directory any other way. There is no recursive
/// delete here, and a test holds it to that.
enum FolderDelete {
    static let clutterNames: Set<String> = [".ds_store", ".localized", "icon\r", "thumbs.db", "desktop.ini"]
    /// Folders a NAS indexer fills wholesale: everything under one is clutter.
    static let clutterFolders: Set<String> = ["@eadir", ".@__thumb"]

    /// Whether a relative path is something the Mac or a NAS made by itself.
    static func isClutter(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map { $0.lowercased() }
        if parts.dropLast().contains(where: clutterFolders.contains) { return true }
        guard let name = parts.last else { return false }
        return clutterNames.contains(name) || name.hasPrefix("._")
    }

    /// What is in a folder, hidden files included. Blocking: a walk.
    static func contents(of folder: String) -> FolderContents {
        var out = FolderContents()
        guard let walk = FileManager.default.enumerator(atPath: folder) else { return out }
        var folders: [String] = []
        while let relative = walk.nextObject() as? String {
            if walk.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                folders.append(relative)
            } else if isClutter(relative) {
                out.clutter.append(relative)
            } else if videoExtensions.contains((relative as NSString).pathExtension.lowercased()) {
                out.videos.append(relative)
            } else {
                out.otherFiles.append(relative)
            }
        }
        out.folders = folders.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        return out
    }

    enum Outcome: Equatable {
        case deleted
        case refused(String)
    }

    /// Runs after the clutter is cleared and before the folders are removed.
    /// The tests drop a file in here to prove the last layer holds.
    static var beforeRemoving: (() -> Void)?

    /// Delete an empty folder: its clutter unlinked, its empty subfolders and
    /// then itself removed with `rmdir`. Refused, with what is in the way, for
    /// anything else. Blocking.
    static func delete(_ folder: String) -> Outcome {
        let seen = contents(of: folder)
        guard seen.isEmpty else { return .refused("it holds \(seen.description)") }
        // Twice at most: Finder can write a `.DS_Store` again between the
        // clutter going and the folder going, and that is worth one retry.
        for _ in 0..<2 {
            let now = contents(of: folder)
            guard now.isEmpty else { return .refused("\(now.description) arrived in it just now") }
            for file in now.clutter { unlinkFile((folder as NSString).appendingPathComponent(file)) }
            beforeRemoving?()
            var blocked = false
            for relative in now.folders + [""] {
                let path = relative.isEmpty ? folder : (folder as NSString).appendingPathComponent(relative)
                if rmdir(path) != 0 && errno != ENOENT {
                    blocked = true
                    break
                }
            }
            if !blocked { return .deleted }
        }
        let after = contents(of: folder)
        return .refused(after.isEmpty ? "the folder could not be removed"
                                      : "\(after.description) arrived in it just now")
    }

    /// Unlink one file — never a directory, whatever it is called.
    private static func unlinkFile(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { return }
        unlink(path)
    }
}
