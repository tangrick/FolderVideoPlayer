import AppKit
import Foundation

/// Moving, renaming and deleting the video files themselves — and the one
/// that gathers a tag into a folder of its own.
///
/// Every operation here is a file operation *and* a bookkeeping operation:
/// tags are keyed on a video's path, so a file that moves without its tag
/// reference moving with it is a tag silently lost. Nothing in this file
/// touches a file without carrying its tags, resume position and favorite
/// status across in the same breath.
///
/// Nothing here deletes: "delete" means the Trash, and on a share with no
/// Trash it means a folder you nominate. The user decides when bytes really
/// go, not the app.
@MainActor
enum FileOps {

    /// What a batch did, for the report the window shows.
    struct Report {
        var done: [String] = []                 // new paths, in order
        var failed: [(name: String, why: String)] = []
        var skipped: [(name: String, why: String)] = []

        var isEmpty: Bool { done.isEmpty && failed.isEmpty && skipped.isEmpty }

        /// A plain-English summary line.
        var summary: String {
            var bits: [String] = []
            if !done.isEmpty { bits.append("\(done.count) done") }
            if !skipped.isEmpty { bits.append("\(skipped.count) skipped") }
            if !failed.isEmpty { bits.append("\(failed.count) failed") }
            return bits.isEmpty ? "Nothing to do" : bits.joined(separator: " · ")
        }

        /// The detail the notice shows under the summary.
        var detail: String {
            (skipped.map { "– \($0.name): \($0.why)" }
             + failed.map { "✗ \($0.name): \($0.why)" })
                .prefix(12).joined(separator: "\n")
        }
    }

    // MARK: - moving

    /// Move videos into a folder, carrying their tags with them.
    ///
    /// A name already taken in the destination is not overwritten — two
    /// folders can hold different videos with the same name, and one quietly
    /// replacing the other is exactly the loss this guards against. The
    /// mover gets " (2)" and so on, the way Finder does it.
    @discardableResult
    static func move(_ paths: [String], into folder: String, library: Library) -> Report {
        var report = Report()
        guard !paths.isEmpty else { return report }
        library.rememberForUndo("moving \(paths.count) video\(paths.count == 1 ? "" : "s")")
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard FileManager.default.fileExists(atPath: path) else {
                report.skipped.append((name, "the file is not there any more"))
                continue
            }
            let target = freeName(in: folder, for: name)
            if (path as NSString).deletingLastPathComponent == folder {
                report.skipped.append((name, "already in that folder"))
                continue
            }
            do {
                try FileManager.default.moveItem(atPath: path, toPath: target)
                carryBookkeeping(from: path, to: target, library: library)
                report.done.append(target)
            } catch {
                report.failed.append((name, (error as NSError).localizedDescription))
            }
        }
        library.saveTags()
        library.save()
        return report
    }

    // MARK: - renaming

    /// Rename one video, keeping its extension unless the new name carries
    /// one. The tags, resume position and favorite status follow the file.
    @discardableResult
    static func rename(_ path: String, to newName: String, library: Library) -> Report {
        var report = Report()
        let name = (path as NSString).lastPathComponent
        let wanted = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            report.skipped.append((name, "a name cannot be empty"))
            return report
        }
        guard !wanted.contains("/") else {
            report.failed.append((name, "a name cannot contain “/”"))
            return report
        }
        guard FileManager.default.fileExists(atPath: path) else {
            report.skipped.append((name, "the file is not there any more"))
            return report
        }
        // Typing "Beach" for Beach.mp4 means Beach.mp4, not a file with no
        // extension that nothing will open.
        let ext = (path as NSString).pathExtension
        let leaf = (wanted as NSString).pathExtension.isEmpty && !ext.isEmpty
            ? wanted + "." + ext : wanted
        let folder = (path as NSString).deletingLastPathComponent
        let target = (folder as NSString).appendingPathComponent(leaf)
        guard target != path else { return report }
        guard !FileManager.default.fileExists(atPath: target) else {
            report.failed.append((name, "“\(leaf)” is already in that folder"))
            return report
        }
        library.rememberForUndo("renaming “\(name)”")
        do {
            try FileManager.default.moveItem(atPath: path, toPath: target)
            carryBookkeeping(from: path, to: target, library: library)
            library.saveTags()
            library.save()
            report.done.append(target)
        } catch {
            report.failed.append((name, (error as NSError).localizedDescription))
        }
        return report
    }

    // MARK: - deleting

    /// Move videos to the Trash, and their tag references with them.
    ///
    /// On a volume with no Trash — most NAS shares — the caller is asked for
    /// a folder to sweep them into instead, once per volume. Nothing is ever
    /// deleted outright by this app.
    @discardableResult
    static func trash(_ paths: [String], library: Library,
                      askFolder: (String, String) -> String?) -> Report {
        var report = Report()
        guard !paths.isEmpty else { return report }
        library.rememberForUndo("deleting \(paths.count) video\(paths.count == 1 ? "" : "s")")
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard FileManager.default.fileExists(atPath: path) else {
                // Already gone: drop the reference so the library stops
                // claiming it exists.
                library.forgetPath(path)
                report.skipped.append((name, "was already gone — reference removed"))
                continue
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                                  resultingItemURL: nil)
                dropBookkeeping(path, library: library)
                report.done.append(path)
            } catch {
                let why = (error as NSError).localizedDescription
                let volume = Paths.volumeOf(path)
                var folder = library.discardFolders[volume]
                if let known = folder, !FileManager.default.fileExists(atPath: known) {
                    folder = nil
                }
                if folder == nil || folder?.isEmpty == true {
                    folder = askFolder(volume, why)
                    library.discardFolders[volume] = folder ?? ""
                    library.save()
                }
                guard let folder, !folder.isEmpty else {
                    report.failed.append((name, why))
                    continue
                }
                let target = freeName(in: folder, for: name)
                do {
                    try FileManager.default.moveItem(atPath: path, toPath: target)
                    dropBookkeeping(path, library: library)
                    report.done.append(target)
                } catch {
                    report.failed.append((name, (error as NSError).localizedDescription))
                }
            }
        }
        library.saveTags()
        library.save()
        return report
    }

    // MARK: - replacing with a converted copy

    /// A converted copy takes the original's place: its tags, rating, readings
    /// and resume point move to the copy, then the original goes the way
    /// `trash` sends anything — the Trash, or the nominated folder on a share
    /// with none. Never deleted outright. If the original cannot be moved it
    /// stays where it is and the report says so; the copy keeps the details.
    @discardableResult
    static func replace(_ original: String, with copy: String, library: Library,
                        askFolder: (String, String) -> String?) -> Report {
        carryBookkeeping(from: original, to: copy, library: library)
        library.saveTags()
        library.save()
        return trash([original], library: library, askFolder: askFolder)
    }

    // MARK: - a tag, gathered into a folder

    /// Gather every video carrying a tag into one folder named after it.
    ///
    /// The point of tags is that the files can live anywhere; the point of
    /// this is the afternoon you decide one of those tags deserves to be a
    /// real folder on disk. The tag is kept — the videos still carry it, so
    /// the tag playlist works exactly as before, only now its contents sit
    /// together.
    @discardableResult
    static func gather(tag: String, into parent: String, library: Library) -> Report {
        let folder = (parent as NSString).appendingPathComponent(safeFolderName(tag))
        var report = Report()
        do {
            try FileManager.default.createDirectory(atPath: folder,
                                                    withIntermediateDirectories: true)
        } catch {
            report.failed.append((tag, "could not make the folder — \((error as NSError).localizedDescription)"))
            return report
        }
        let paths = library.taggedWith(tag)
        guard !paths.isEmpty else {
            report.skipped.append((tag, "no videos carry this tag"))
            return report
        }
        return move(paths, into: folder, library: library)
    }

    /// Where a tag's folder belongs: the folder its videos already live in.
    ///
    /// The user's rule is "the same location as the video files", so nothing is
    /// picked and nothing is typed — the tag names the folder. When every video
    /// carrying the tag shares one folder, that is the answer. A tag spanning
    /// several folders has no single "where the videos are": the library root
    /// is used, and the confirmation the window shows names the exact path
    /// before anything moves, so a wrong guess is visible rather than silent.
    static func gatherParent(for paths: [String], fallback: String?) -> String? {
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        if folders.count == 1, let only = folders.first, !only.isEmpty { return only }
        if let fallback, !fallback.isEmpty { return fallback }
        return paths.first.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// The folder a gather would make, so the window can say so before it runs.
    static func gatherTarget(tag: String, into parent: String) -> String {
        (parent as NSString).appendingPathComponent(safeFolderName(tag))
    }

    // MARK: - the bookkeeping

    /// Everything the library knows about a video, moved to its new path:
    /// tags (the star ratings are tags), and where you had got to watching it.
    private static func carryBookkeeping(from old: String, to new: String,
                                         library: Library) {
        library.moveTags(from: old, to: new)
        if let position = library.progress[old] {
            library.progress[new] = position
            library.progressSeen[new] = library.progressSeen[old] ?? Date().timeIntervalSince1970
            library.progress.removeValue(forKey: old)
            library.progressSeen.removeValue(forKey: old)
        }
        library.recent = library.recent.map { $0 == old ? new : $0 }
    }

    /// The same, for a file that has gone to the Trash.
    private static func dropBookkeeping(_ path: String, library: Library) {
        library.forgetPath(path)
        library.progress.removeValue(forKey: path)
        library.progressSeen.removeValue(forKey: path)
    }

    // MARK: - names

    /// A path in `folder` for `name` that is not already taken: "clip.mp4",
    /// then "clip (2).mp4", and so on.
    static func freeName(in folder: String, for name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = (folder as NSString).appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target) {
            let leaf = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            target = (folder as NSString).appendingPathComponent(leaf)
            n += 1
        }
        return target
    }

    /// A tag turned into something a file system will accept as a folder.
    static func safeFolderName(_ tag: String) -> String {
        let cleaned = tag.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Tag" : cleaned
    }
}
