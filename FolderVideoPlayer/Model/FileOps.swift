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
    /// mover gets " (2)" and so on, the way Finder does it — and so do its
    /// subtitle files, which travel with it.
    ///
    /// The file work happens off the main thread: a video going to or from a
    /// share is a copy, and a window that stops drawing for the length of a
    /// few gigabytes over Wi-Fi has hung as far as anyone can tell. The
    /// bookkeeping comes back here, one file at a time, so the stores never
    /// disagree with the disk for longer than one file takes.
    @discardableResult
    static func move(_ paths: [String], into folder: String, library: Library) async -> Report {
        var report = Report()
        guard !paths.isEmpty else { return report }
        let undo = "moving \(paths.count) video\(paths.count == 1 ? "" : "s")"
        var journal: [PathMap] = []
        var moved: [PathMap] = []
        var listings: [String: [String]] = [:]
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let source = (path as NSString).deletingLastPathComponent
            if source == folder {
                report.skipped.append((name, "already in that folder"))
                continue
            }
            let listing = listings[source]
            let outcome = await Task.detached(priority: .userInitiated) {
                shift(path, into: folder, leaf: name, findFree: true, listing: listing)
            }.value
            listings[source] = outcome.listing
            record(outcome, name: name, undo: undo, library: library,
                   report: &report, journal: &journal, moved: &moved)
        }
        library.saveTags()
        library.save()
        await ProfileRelocation.spread(moved, library: library)
        RelocationJournal.end(journal)
        return report
    }

    // MARK: - renaming

    /// Rename one video, keeping its extension unless the new name carries
    /// one. The tags, resume position and favorite status follow the file, and
    /// its subtitle files are renamed to match.
    @discardableResult
    static func rename(_ path: String, to newName: String, library: Library) async -> Report {
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
        let outcome = await Task.detached(priority: .userInitiated) {
            shift(path, into: folder, leaf: leaf, findFree: false, listing: nil)
        }.value
        var journal: [PathMap] = []
        var moved: [PathMap] = []
        record(outcome, name: name, undo: "renaming “\(name)”", library: library,
               report: &report, journal: &journal, moved: &moved)
        library.saveTags()
        library.save()
        await ProfileRelocation.spread(moved, library: library)
        RelocationJournal.end(journal)
        return report
    }

    // MARK: - one file, off the main thread

    /// What moving one video did.
    struct Shifted: Sendable {
        enum Result: Sendable {
            /// Moved. `planned` is the journal's entry, struck off once the
            /// bookkeeping is saved; `landed` is where it is, spelt as the
            /// volume spells it.
            case done(planned: PathMap, landed: String, trouble: [(String, String)])
            case skipped(String)
            case failed(String)
        }
        var result: Result
        /// The source folder's listing, handed back so a batch out of one
        /// folder lists it once rather than once per video.
        var listing: [String]?
    }

    /// Move one video and its subtitle files to `leaf` in `folder` — or, when
    /// `findFree`, to the first free " (2)" variant — never over anything.
    ///
    /// The journal entry is written before the file moves: from that moment a
    /// crash leaves something for the next launch to finish.
    nonisolated static func shift(_ path: String, into folder: String, leaf: String,
                                  findFree: Bool, listing known: [String]?) -> Shifted {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        guard fm.fileExists(atPath: path) else {
            return Shifted(result: .skipped("the file is not there any more"), listing: known)
        }
        let source = (path as NSString).deletingLastPathComponent
        let listing = known ?? ((try? fm.contentsOfDirectory(atPath: source)) ?? [])
        // A sidecar is the video's stem plus a tail: `clip` + `.en.srt`. The
        // tail is what the new name keeps, so `clip.en.srt` becomes
        // `beach.en.srt`. Matched case-insensitively, so the stem's length is
        // the same in either spelling.
        let companions = SubtitleFile.sidecars(for: path, in: listing)
        let stem = (name as NSString).deletingPathExtension
        let tails = companions.map { String($0.dropFirst(stem.count)) }
        func inFolder(_ leaf: String) -> String { (folder as NSString).appendingPathComponent(leaf) }
        func inSource(_ leaf: String) -> String { (source as NSString).appendingPathComponent(leaf) }

        let target: String
        if findFree {
            target = freeName(in: folder, for: leaf, companions: tails)
        } else {
            // A name taken by ANOTHER file is refused. The same file under
            // another spelling — `clip.mp4` → `Clip.mp4` on a volume that
            // ignores case — is not a clash, it is the rename asked for.
            let newStem = (leaf as NSString).deletingPathExtension
            let wanted = [(path, inFolder(leaf))]
                + zip(companions, tails).map { (inSource($0.0), inFolder(newStem + $0.1)) }
            if let taken = wanted.first(where: { fm.fileExists(atPath: $0.1) && !sameFile($0.0, $0.1) }) {
                let what = (taken.1 as NSString).lastPathComponent
                return Shifted(result: .failed("“\(what)” is already in that folder"), listing: listing)
            }
            target = inFolder(leaf)
        }

        let planned = PathMap(from: path, to: target)
        RelocationJournal.begin(planned)
        do {
            try moveFile(path, to: target)
        } catch {
            RelocationJournal.end([planned])
            return Shifted(result: .failed((error as NSError).localizedDescription), listing: listing)
        }
        let landed = onDisk(target)
        let landedStem = ((landed as NSString).lastPathComponent as NSString).deletingPathExtension
        var trouble: [(String, String)] = []
        for (companion, tail) in zip(companions, tails) {
            do {
                try moveFile(inSource(companion), to: inFolder(landedStem + tail))
            } catch {
                trouble.append((companion, "the subtitle file could not follow — "
                                + (error as NSError).localizedDescription))
            }
        }
        let left = listing.filter { $0 != name && !companions.contains($0) }
        return Shifted(result: .done(planned: planned, landed: landed, trouble: trouble),
                       listing: left)
    }

    /// Put one file's outcome into the report, and its bookkeeping into the
    /// library — here, on the main actor, where the stores live.
    ///
    /// The Undo snapshot is taken as the FIRST file lands, not before the
    /// batch: the tags have not changed until then, and a rename refused as a
    /// clash must not leave an Undo behind that puts back nothing.
    private static func record(_ outcome: Shifted, name: String, undo: String, library: Library,
                               report: inout Report, journal: inout [PathMap],
                               moved: inout [PathMap]) {
        switch outcome.result {
        case let .done(planned, landed, trouble):
            if journal.isEmpty { library.rememberForUndo(undo) }
            carryBookkeeping(from: planned.from, to: landed, library: library)
            report.done.append(landed)
            for (companion, why) in trouble { report.failed.append((companion, why)) }
            journal.append(planned)
            moved.append(PathMap(from: planned.from, to: landed))
        case .skipped(let why):
            report.skipped.append((name, why))
        case .failed(let why):
            report.failed.append((name, why))
        }
    }

    /// Move one file, never over another.
    ///
    /// A target that is the SAME file under another spelling — the case-only
    /// rename — goes through a hidden scratch name: the direct move would be
    /// refused as a clash with itself. `moveItem` refuses a target that
    /// exists, which is the no-overwrite rule held by the file system itself.
    nonisolated static func moveFile(_ from: String, to target: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target), sameFile(from, target) else {
            try fm.moveItem(atPath: from, toPath: target)
            return
        }
        let scratch = ((target as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".fvp-renaming-" + UUID().uuidString)
        try fm.moveItem(atPath: from, toPath: scratch)
        do {
            try fm.moveItem(atPath: scratch, toPath: target)
        } catch {
            try? fm.moveItem(atPath: scratch, toPath: from)
            throw error
        }
    }

    /// Whether two paths name one file — the same file under two spellings on
    /// a volume that ignores case. Compared by device and inode, not by name.
    nonisolated static func sameFile(_ a: String, _ b: String) -> Bool {
        var x = stat()
        var y = stat()
        guard lstat(a, &x) == 0, lstat(b, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// A path, spelt the way its volume stores it.
    ///
    /// Swift compares names by their Unicode meaning, so the tags do not care
    /// whether `Café` was typed with one accented letter or with a letter and
    /// an accent. The transcript store and `NSString` compare the bytes, and a
    /// share may store a name in the other form from the one typed. Taking the
    /// name back from the folder's listing keys every store by the form every
    /// later scan of that folder will produce. A plain-ASCII name has only one
    /// form, so it costs no listing.
    nonisolated static func onDisk(_ path: String) -> String {
        let leaf = (path as NSString).lastPathComponent
        guard !leaf.unicodeScalars.allSatisfy(\.isASCII) else { return path }
        let folder = (path as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return path
        }
        let bytes = Array(leaf.utf8)
        guard names.first(where: { Array($0.utf8) == bytes }) == nil,
              let stored = names.first(where: { $0 == leaf }) else { return path }
        return (folder as NSString).appendingPathComponent(stored)
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
        // Everybody's tags take the copy, not only the profile in force's. Its
        // own task: the caller is waiting on a report, not on the share.
        Task { await ProfileRelocation.spread([PathMap(from: original, to: copy)], library: library) }
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
    static func gather(tag: String, into parent: String, library: Library) async -> Report {
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
        return await move(paths, into: folder, library: library)
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

    /// Everything the library knows about a video, moved to its new path.
    /// `moveTags` is the one place that carries it — tags and stars, readings,
    /// watch state, where you had got to, the hidden flag, and through its hook
    /// the stores kept outside the library.
    private static func carryBookkeeping(from old: String, to new: String,
                                         library: Library) {
        library.moveTags(from: old, to: new)
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
    ///
    /// `companions` are the tails of the files that travel with it —
    /// `.en.srt` for `clip.en.srt` — and a name is only free when every one of
    /// them is free under it too, so a video never arrives as "clip (2)" with
    /// its subtitles stranded as "clip".
    nonisolated static func freeName(in folder: String, for name: String,
                                     companions: [String] = []) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func taken(_ candidate: String) -> Bool {
            let leaf = ext.isEmpty ? candidate : "\(candidate).\(ext)"
            let paths = [leaf] + companions.map { candidate + $0 }
            return paths.contains {
                FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent($0))
            }
        }
        var candidate = stem
        var n = 2
        while taken(candidate) {
            candidate = "\(stem) (\(n))"
            n += 1
        }
        return (folder as NSString).appendingPathComponent(ext.isEmpty ? candidate : "\(candidate).\(ext)")
    }

    /// A tag turned into something a file system will accept as a folder.
    static func safeFolderName(_ tag: String) -> String {
        let cleaned = tag.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Tag" : cleaned
    }
}
