import Foundation

/// What follows a profile to another Mac besides its tags: the people it has
/// named, the transcripts it has made, the facts read off its files, and the
/// folders it pinned.
///
/// All four sit beside the person's `tags.json` on every share:
///
///     .FolderVideoPlayer/quincy/faces.json         names, face vectors, thumbnails
///     .FolderVideoPlayer/quincy/transcripts.json   this share's videos' transcripts
///     .FolderVideoPlayer/quincy/facts.json         this share's videos' file facts
///     .FolderVideoPlayer/quincy/pins.json          the folders pinned on this share
///
/// Without them a second Mac opening the profile got the tags and nothing
/// else: nobody recognised, and every transcript made again from scratch.
///
/// **Faces merge three ways**, like tags: against the people as they were at
/// the last sync with that share, so a name added, renamed or forgotten on one
/// Mac goes to the others instead of the union bringing it back. The vectors
/// travel with the names because a hash is only a key — recognition compares
/// vectors, and a new Mac has none of another Mac's crops.
///
/// **Transcripts only accumulate.** A transcript is what a video says, not a
/// judgement, so each Mac takes what it lacks and sends what the share lacks.
/// A video transcribed again on one Mac keeps its old lines on the others.
///
/// **File facts merge three ways, per video** — dates, camera and quality,
/// places. They are read off the files, so another Mac COULD read them again,
/// but only by opening every video over the network (and asking the internet
/// for every place): minutes to hours on a big library. Worse, a place
/// corrected by hand exists nowhere but in this profile. So a video's facts
/// follow the same rule as people: changed only on the other Mac, take theirs;
/// changed only here, send ours; changed on both, this Mac's stand. A first
/// meeting only fills gaps, so neither Mac's own reading is overwritten.
///
/// **Pinned folders merge three ways, per share**, by the facts' rule, so a
/// profile opened on another Mac comes with its pins and the Apple TV offers
/// the same folders on its home screen. A share's list is the sidebar's order,
/// so a reorder is a change. A first meeting keeps this Mac's pins and adds
/// the share's it lacks, so a new Mac with none takes them all.
enum SharedExtras {

    static let facesName = "faces.json"
    static let transcriptsName = "transcripts.json"
    static let factsName = "facts.json"
    static let pinsName = "pins.json"
    static let currentFormat = 1

    struct Faces: Codable, Equatable {
        var format = SharedExtras.currentFormat
        var people: [String: [String]] = [:]
        /// hash → the 128 little-endian Float32s of its `.f32`, base64.
        var vectors: [String: String] = [:]
        /// hash → its JPEG thumbnail, base64.
        var thumbs: [String: String] = [:]
    }

    struct Transcripts: Codable, Equatable {
        var format = SharedExtras.currentFormat
        /// Keyed from the share root, like the tags.
        var videos: [String: [Line]] = [:]

        struct Line: Codable, Equatable {
            var start: Double
            var end: Double
            var text: String
            var language: String
            var source: String
        }
    }

    struct Facts: Codable, Equatable {
        var format = SharedExtras.currentFormat
        /// Keyed from the share root, like the tags: path → the facts on it.
        var videos: [String: [String]] = [:]
    }

    struct Pins: Codable, Equatable {
        var format = SharedExtras.currentFormat
        /// Keyed from the share root, like the tags, in the sidebar's order.
        var folders: [String] = []
    }

    /// Per profile, in its bundle: what each share held at the last sync.
    struct State: Codable, Equatable {
        var faceBase: [String: [String: [String]]] = [:]
        var transcriptMtime: [String: Double] = [:]
        var transcriptsOnShare: [String: [String]] = [:]
        /// Share → the facts file as it was at the last sync. Nil for a share
        /// never met, which is what makes the first sync fill gaps only.
        var factBase: [String: [String: [String]]] = [:]
        var factMtime: [String: Double] = [:]
        /// Share → its pins as they were at the last sync. Nil for a share
        /// never met, which is what makes the first sync fill gaps only.
        var pinBase: [String: [String]] = [:]

        init() {}

        /// Every field optional on the way in: a state file written before a
        /// field existed must still load, or the face merge would lose its
        /// base and treat a known share as a first meeting.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            faceBase = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .faceBase) ?? [:]
            transcriptMtime = try c.decodeIfPresent([String: Double].self, forKey: .transcriptMtime) ?? [:]
            transcriptsOnShare = try c.decodeIfPresent([String: [String]].self, forKey: .transcriptsOnShare) ?? [:]
            factBase = try c.decodeIfPresent([String: [String: [String]]].self, forKey: .factBase) ?? [:]
            factMtime = try c.decodeIfPresent([String: Double].self, forKey: .factMtime) ?? [:]
            pinBase = try c.decodeIfPresent([String: [String]].self, forKey: .pinBase) ?? [:]
        }
    }

    static func stateFile(_ profile: String, root: String) -> String {
        ProfileBundle.file(in: profile, "shared-extras.json", root: root)
    }

    // MARK: - the face merge

    /// `local` against `shared`, with `base` the people both had at the last
    /// sync. Nil `base` is a first meeting: nothing can have been removed yet,
    /// so each name gets every face either side has for it.
    static func mergePeople(local: [String: [String]], base: [String: [String]]?,
                            shared: [String: [String]]) -> [String: [String]] {
        func union(_ a: [String]?, _ b: [String]?) -> [String] {
            var out = a ?? []
            for hash in b ?? [] where !out.contains(hash) { out.append(hash) }
            return out
        }
        var merged: [String: [String]] = [:]
        for name in Set(local.keys).union(shared.keys).union(base.map { Array($0.keys) } ?? []) {
            let (mine, theirs) = (local[name], shared[name])
            let result: [String]?
            if let base {
                let before = base[name]
                if mine == before { result = theirs }          // only they changed it
                else if theirs == before { result = mine }     // only we did
                else { result = union(mine, theirs) }          // both: keep every face
            } else {
                result = union(mine, theirs)
            }
            if let result, !result.isEmpty { merged[name] = result }
        }
        return merged
    }

    // MARK: - the fact merge

    /// One share's facts: `local` against `shared`, with `base` the file as it
    /// was at the last sync (nil: never met). Keys are paths from the share
    /// root. Returns what this Mac should hold and what the share should hold;
    /// a video with no facts is simply absent from either.
    ///
    /// Compared as sets, case-insensitively — the order readings were added in
    /// is not a change.
    static func mergeFacts(local: [String: [String]], base: [String: [String]]?,
                           shared: [String: [String]]) -> (local: [String: [String]], shared: [String: [String]]) {
        func same(_ a: [String]?, _ b: [String]?) -> Bool {
            Set((a ?? []).map { $0.lowercased() }) == Set((b ?? []).map { $0.lowercased() })
        }
        var mine: [String: [String]] = [:], theirs: [String: [String]] = [:]
        let keys = Set(local.keys).union(shared.keys).union(base.map { Array($0.keys) } ?? [])
        for key in keys {
            let (l, s) = (local[key], shared[key])
            let (keep, send): ([String]?, [String]?)
            if let base {
                let b = base[key]
                if same(l, b) { (keep, send) = (s, s) }          // only the share changed (or nothing)
                else if same(s, b) { (keep, send) = (l, l) }     // only this Mac did
                else { (keep, send) = (l, l) }                   // both: this Mac's stand
            } else {
                // First meeting: fill gaps both ways, overwrite nothing.
                keep = (l ?? []).isEmpty ? s : l
                send = (s ?? []).isEmpty ? l : s
            }
            if let keep, !keep.isEmpty { mine[key] = keep }
            if let send, !send.isEmpty { theirs[key] = send }
        }
        return (mine, theirs)
    }

    // MARK: - one sync, off the main thread

    struct Input {
        /// Support root and profile slug: where the registry, the face cache
        /// and the evidence store are.
        var root: String
        var profile: String
        var device: String
        var volumes: String
        /// Share name → this profile's folder on it.
        var folders: [String: String]
        var state: State
        /// This Mac's file facts, keyed like tags (`share/path`). A snapshot:
        /// the library applies what comes back only where it has not changed
        /// them since.
        var facts: [String: [String]] = [:]
        /// This profile's pinned folders as the sidebar holds them: absolute
        /// paths, in its order.
        var pinned: [String] = []
    }

    struct Output {
        var state: State
        var facesChanged = false
        var transcriptsImported = 0
        /// Facts this Mac should now hold, keyed like tags; an empty list means
        /// the video's facts were removed elsewhere.
        var factUpdates: [String: [String]] = [:]
        /// Share → the pins this Mac should now hold on it, keyed from the
        /// share root, for each share whose list changed elsewhere.
        var pinUpdates: [String: [String]] = [:]
    }

    /// Blocking. Every failure is silent, as the tag sync's are: the next
    /// sync tries again.
    static func sync(_ input: Input, lockBudget: Double) -> Output {
        var out = Output(state: input.state)
        let mounted = input.folders.filter { share, _ in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: input.volumes + share, isDirectory: &isDir)
                && isDir.boolValue
        }
        out.facesChanged = syncFaces(input, mounted, &out.state, lockBudget: lockBudget)
        out.transcriptsImported = syncTranscripts(input, mounted, &out.state, lockBudget: lockBudget)
        out.factUpdates = syncFacts(input, mounted, &out.state, lockBudget: lockBudget)
        out.pinUpdates = syncPins(input, mounted, &out.state, lockBudget: lockBudget)
        return out
    }

    private static func syncFaces(_ input: Input, _ folders: [String: String],
                                  _ state: inout State, lockBudget: Double) -> Bool {
        let registryFile = ProfileBundle.file(in: input.profile, "faces.json", root: input.root)
        let before = readJSON([String: [String]].self, registryFile) ?? [:]
        var people = before
        var found: [String: Faces] = [:]
        for (share, folder) in folders.sorted(by: { $0.key < $1.key }) {
            let file = readJSON(Faces.self, path(folder, facesName))
            if let file, file.format > currentFormat { continue }
            found[share] = file ?? Faces()
            people = mergePeople(local: people, base: state.faceBase[share],
                                 shared: file?.people ?? [:])
        }
        guard !found.isEmpty else { return false }

        // Faces the merge brought in that this Mac has never seen.
        for hash in Set(people.values.joined()) {
            let vector = FaceRegistry.vectorPath(root: input.root, hash: hash)
            guard !FileManager.default.fileExists(atPath: vector) else { continue }
            guard let file = found.values.first(where: { $0.vectors[hash] != nil }),
                  let data = file.vectors[hash].flatMap({ Data(base64Encoded: $0) }) else { continue }
            FaceRegistry.write(data, to: vector)
            if let jpeg = file.thumbs[hash].flatMap({ Data(base64Encoded: $0) }) {
                FaceRegistry.write(jpeg, to: FaceRegistry.thumbnailPath(root: input.root, hash: hash))
            }
        }
        if people != before, let data = try? JSONSerialization.data(withJSONObject: people) {
            FaceRegistry.write(data, to: registryFile)
        }

        for (share, file) in found {
            guard file.people != people || !carriesVectors(file, people) else {
                state.faceBase[share] = people
                continue
            }
            let folder = folders[share]!
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard let token = SharedTagDisk.lock(folder: folder, by: input.device, budget: lockBudget)
            else { state.faceBase[share] = file.people; continue }
            defer { SharedTagDisk.unlock(folder: folder, token: token) }
            // Changed since it was read: leave it for the next sync to merge.
            if (readJSON(Faces.self, path(folder, facesName)) ?? Faces()) != file {
                state.faceBase[share] = file.people
                continue
            }
            var next = Faces(people: people)
            for hash in Set(people.values.joined()) {
                next.vectors[hash] = file.vectors[hash] ?? FileManager.default
                    .contents(atPath: FaceRegistry.vectorPath(root: input.root, hash: hash))?
                    .base64EncodedString()
                next.thumbs[hash] = file.thumbs[hash] ?? FileManager.default
                    .contents(atPath: FaceRegistry.thumbnailPath(root: input.root, hash: hash))?
                    .base64EncodedString()
            }
            state.faceBase[share] = write(next, path(folder, facesName), device: input.device)
                ? people : file.people
        }
        return people != before
    }

    /// Whether every face the file names has its vector in the file. One that
    /// lacks some is written again once this Mac can fill them in.
    private static func carriesVectors(_ file: Faces, _ people: [String: [String]]) -> Bool {
        people.values.joined().allSatisfy { file.vectors[$0] != nil }
    }

    private static func syncTranscripts(_ input: Input, _ folders: [String: String],
                                        _ state: inout State, lockBudget: Double) -> Int {
        let storeFile = Paths.evidenceFile(in: input.profile, root: input.root)
        let hadStore = FileManager.default.fileExists(atPath: storeFile)
        var store: EvidenceStore?
        defer { store?.close() }
        func open() -> EvidenceStore? {
            if store == nil { store = try? EvidenceStore(root: input.root, profile: input.profile) }
            return store
        }
        let local = hadStore ? ((try? open()?.transcribedPaths()) ?? []) : []
        var imported = 0

        for (share, folder) in folders.sorted(by: { $0.key < $1.key }) {
            let prefix = input.volumes + share + "/"
            let mine = Set(local.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            let file = path(folder, transcriptsName)
            let mtime = SharedTagDisk.mtime(file)
            var onShare = Set(state.transcriptsOnShare[share] ?? [])

            if let mtime, mtime != state.transcriptMtime[share] {
                guard let shared = readJSON(Transcripts.self, file),
                      shared.format <= currentFormat else { continue }
                onShare = Set(shared.videos.keys)
                for (rest, lines) in shared.videos where !mine.contains(rest) && !lines.isEmpty {
                    guard let store = open() else { break }
                    let path = prefix + rest
                    let converted = lines.map {
                        TranscriptLine(path: path, start: $0.start, end: $0.end, text: $0.text,
                                       language: $0.language, source: $0.source)
                    }
                    if (try? store.insertTranscript(converted, path: path,
                                                    language: lines[0].language)) != nil {
                        imported += 1
                    }
                }
                state.transcriptMtime[share] = mtime
                state.transcriptsOnShare[share] = onShare.sorted()
            } else if mtime == nil {
                onShare = []
            }

            let toSend = mine.subtracting(onShare)
            guard !toSend.isEmpty, let store = open() else { continue }
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard let token = SharedTagDisk.lock(folder: folder, by: input.device, budget: lockBudget)
            else { continue }
            defer { SharedTagDisk.unlock(folder: folder, token: token) }
            var next = readJSON(Transcripts.self, file) ?? Transcripts()
            guard next.format <= currentFormat else { continue }
            for rest in toSend where next.videos[rest] == nil {
                let lines = (try? store.transcript(for: prefix + rest)) ?? []
                guard !lines.isEmpty else { continue }
                next.videos[rest] = lines.map {
                    Transcripts.Line(start: $0.start, end: $0.end, text: $0.text,
                                     language: $0.language, source: $0.source)
                }
            }
            if write(next, file, device: input.device) {
                state.transcriptMtime[share] = SharedTagDisk.mtime(file)
                state.transcriptsOnShare[share] = next.videos.keys.sorted()
            }
        }
        return imported
    }

    private static func syncFacts(_ input: Input, _ folders: [String: String],
                                  _ state: inout State, lockBudget: Double) -> [String: [String]] {
        var updates: [String: [String]] = [:]
        for (share, folder) in folders.sorted(by: { $0.key < $1.key }) {
            let prefix = share + "/"
            var mine: [String: [String]] = [:]
            for (key, names) in input.facts where key.hasPrefix(prefix) && !names.isEmpty {
                mine[String(key.dropFirst(prefix.count))] = names
            }
            let file = path(folder, factsName)
            let mtime = SharedTagDisk.mtime(file)
            let base = state.factBase[share]
            // Unchanged since the last sync: the file is what the base says,
            // and a big library is not read again for nothing.
            let shared: Facts
            if let base, let mtime, mtime == state.factMtime[share] {
                shared = Facts(videos: base)
            } else if mtime != nil {
                guard let read = readJSON(Facts.self, file) else { continue }
                shared = read
            } else {
                shared = Facts()
            }
            guard shared.format <= currentFormat else { continue }

            let merged = mergeFacts(local: mine, base: base, shared: shared.videos)
            for key in Set(mine.keys).union(merged.local.keys) where mine[key] != merged.local[key] {
                updates[prefix + key] = merged.local[key] ?? []
            }
            state.factBase[share] = shared.videos
            state.factMtime[share] = mtime
            guard merged.shared != shared.videos else { continue }

            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard let token = SharedTagDisk.lock(folder: folder, by: input.device, budget: lockBudget)
            else { continue }
            defer { SharedTagDisk.unlock(folder: folder, token: token) }
            // Written by another Mac since it was read: leave it for the next
            // sync to merge, rather than write over what it just said.
            if SharedTagDisk.mtime(file) != mtime { continue }
            if write(Facts(videos: merged.shared), file, device: input.device) {
                state.factBase[share] = merged.shared
                state.factMtime[share] = SharedTagDisk.mtime(file)
            }
        }
        return updates
    }

    // MARK: - the pin merge

    /// One share's pins: `local` against `shared` (nil: no file there), with
    /// `base` the share's list at the last sync (nil: never met). Paths are
    /// from the share root. Returns what this Mac should pin on that share,
    /// and what the share should hold — nil to leave the file as it is.
    static func mergePins(local: [String], base: [String]?,
                          shared: [String]?) -> (local: [String], shared: [String]?) {
        // No file, or one gone missing: this Mac's list, if it has one.
        guard let shared else { return (local, local.isEmpty ? nil : local) }
        guard let base else {
            // First meeting: this Mac's pins, then the share's it lacks.
            let both = local + shared.filter { !local.contains($0) }
            return (both, both == shared ? nil : both)
        }
        if local == base { return (shared, nil) }          // only the share changed (or nothing)
        return (local, local == shared ? nil : local)      // only this Mac, or both: this Mac's stand
    }

    /// Each share gets the pins that live on it, keyed from its root; a
    /// folder on this Mac's own disk means nothing anywhere else and is never
    /// sent. A file this Mac cannot read, or one a newer version wrote, is
    /// neither taken from nor written — the facts' rule.
    private static func syncPins(_ input: Input, _ folders: [String: String],
                                 _ state: inout State, lockBudget: Double) -> [String: [String]] {
        var updates: [String: [String]] = [:]
        for (share, folder) in folders.sorted(by: { $0.key < $1.key }) {
            let prefix = input.volumes + share + "/"
            let mine = input.pinned
                .filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
                .map { String($0.dropFirst(prefix.count)) }
            let file = path(folder, pinsName)
            let mtime = SharedTagDisk.mtime(file)
            var shared: [String]?
            if mtime != nil {
                guard let read = readJSON(Pins.self, file), read.format <= currentFormat else { continue }
                shared = read.folders
            }

            let merged = mergePins(local: mine, base: state.pinBase[share], shared: shared)
            if merged.local != mine { updates[share] = merged.local }
            state.pinBase[share] = shared
            guard let send = merged.shared else { continue }

            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            guard let token = SharedTagDisk.lock(folder: folder, by: input.device, budget: lockBudget)
            else { continue }
            defer { SharedTagDisk.unlock(folder: folder, token: token) }
            // Written by another Mac since it was read: the next sync merges it.
            if SharedTagDisk.mtime(file) != mtime { continue }
            if write(Pins(folders: send), file, device: input.device) {
                state.pinBase[share] = send
            }
        }
        return updates
    }

    // MARK: - disk

    private static func path(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    private static func readJSON<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Via a scratch file renamed into place, as `SharedTagDisk.write` does, so
    /// another device never reads half a file.
    private static func write<T: Encodable>(_ value: T, _ path: String, device: String) -> Bool {
        let scratch = "\(path).\(device).writing"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              (try? data.write(to: URL(fileURLWithPath: scratch))) != nil else { return false }
        guard Darwin.rename(scratch, path) == 0 else {
            try? FileManager.default.removeItem(atPath: scratch)
            return false
        }
        return true
    }
}
