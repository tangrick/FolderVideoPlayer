import Foundation

/// What follows a profile to another Mac besides its tags: the people it has
/// named, and the transcripts it has made.
///
/// Both sit beside the person's `tags.json` on every share:
///
///     .FolderVideoPlayer/quincy/faces.json         names, face vectors, thumbnails
///     .FolderVideoPlayer/quincy/transcripts.json   this share's videos' transcripts
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
enum SharedExtras {

    static let facesName = "faces.json"
    static let transcriptsName = "transcripts.json"
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

    /// Per profile, in its bundle: what each share held at the last sync.
    struct State: Codable, Equatable {
        var faceBase: [String: [String: [String]]] = [:]
        var transcriptMtime: [String: Double] = [:]
        var transcriptsOnShare: [String: [String]] = [:]
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
    }

    struct Output {
        var state: State
        var facesChanged = false
        var transcriptsImported = 0
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
