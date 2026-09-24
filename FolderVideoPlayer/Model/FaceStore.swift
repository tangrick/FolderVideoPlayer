import Foundation
import SwiftUI

/// One identity cluster the face engine found — a person, not yet named.
struct FaceCluster: Codable, Equatable {
    let representative: String      // face hash with a thumbnail
    let faces: Int                  // how many distinct faces merged into it
    let hashes: [String]            // every face hash in the cluster
}

/// A named person: a name bound to face vectors.
struct FacePerson: Codable, Equatable {
    let name: String
    let faces: Int
    let representative: String?
}

/// The app-side half of face recognition.
///
/// The engine is the standalone face module (detect → embed → cluster); this
/// store is the integration that turns a named cluster into a TAG. It owns the
/// face→video index (which faces came from which video), which is what makes
/// "name this person once" apply that tag to every video they appear in.
///
/// Flow: the engine returns face hashes per video (suggest + face_index) →
/// recorded here → the People view asks the engine to cluster unnamed faces →
/// naming a cluster calls `nameCluster`, which binds the name in the engine
/// AND tags every video whose faces are in that cluster. The tag then flows
/// through the normal filter/sort/group as if typed by hand.
///
/// ## Two engines behind one API
///
/// In Core ML mode — the default, and the only one a shipped build runs —
/// every call here goes to `FaceRegistry` in-process: the shipped app has no
/// Python, so a face feature that only runs on the developer's Mac is a face
/// feature a stranger does not get. In Python mode (the `~/.fvp-engine`
/// fallback) every call goes to the child process, exactly as before, so the
/// dev path is untouched.
///
/// The split is per CALL, not per feature, and that is deliberate: the registry
/// reads the cache and the name registry with no model loaded, so listing
/// people and ranking look-alikes keep working on a Mac where the face bundle
/// was never downloaded — the two commands that need a model (scanning a video,)
/// report the honest reason instead.
@MainActor
final class FaceStore: ObservableObject {
    @Published private(set) var faceVideos: [String: Set<String>] = [:]  // faceHash -> video keys
    @Published private(set) var clusters: [FaceCluster] = []
    @Published private(set) var people: [FacePerson] = []
    @Published private(set) var loading = false
    @Published private(set) var indexing = false
    /// Live progress while indexing: "N/M filename" from the engine.
    @Published private(set) var indexProgress: String = ""

    private var engine: AnalysisEngine?
    private var library: Library?

    /// The in-process face engine, when this build is running Core ML. Created
    /// lazily and re-made on a profile change, because it reads that profile's
    /// `faces.json`.
    private var registry: FaceRegistry?
    /// The in-flight index, so `cancelIndex()` has something to cancel. The
    /// engine path cancels through the child; this path cancels the task.
    private var indexTask: Task<[String: [String]], Never>?

    /// The face→video index. Deliberately NOT per profile: it records which
    /// faces appear in which videos, which is the same fact for everyone and
    /// costs a full detection pass to rebuild.
    private let indexFile = (Paths.support as NSString)
        .appendingPathComponent("face_index.json")
    /// Whose people these are. The registry — which NAME is bound to which face
    /// — is a judgement, so it is kept per profile.
    private var profile: String

    init(profile: String = Paths.activeProfile) {
        self.profile = profile
        // Persist the face→video index across launches: it is the link that
        // turns "name this cluster" into "tag these videos", and rebuilding it
        // would mean re-detecting faces on the whole library.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: indexFile)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            var map: [String: Set<String>] = [:]
            for (h, paths) in obj { map[h] = Set(paths) }
            faceVideos = map
        }
        // Named people must survive a relaunch WITHOUT waiting for the engine.
        // The registry is a plain file; reading it here means the People
        // section is populated the moment a window opens, even before the
        // engine has been spawned. `reload()` later refreshes from the engine.
        people = Self.peopleFromDisk(profile: profile)
    }

    /// Move to another profile's people, leaving this one's behind. Naming a
    /// face is one person's judgement, so it is not carried across — the next
    /// profile starts with nobody named.
    func reload(profile: String) {
        self.profile = profile
        registry = nil             // it holds the old profile's faces.json
        people = Self.peopleFromDisk(profile: profile)
        clusters = []
    }

    /// Re-read the people after a share sync brought names in from another
    /// Mac. Only the list: clusters being named here are left alone.
    func reloadPeople() {
        people = Self.peopleFromDisk(profile: profile)
    }

    /// The face engine for this run, or nil when the child process is the one
    /// doing the work. Cheap: constructing it loads no model, and the two
    /// commands that need one say so themselves.
    private var coreMLRegistry: FaceRegistry? {
        guard !profile.isEmpty, CoreMLClassifier.mode == .coreml else { return nil }
        if let registry { return registry }
        let made = FaceRegistry(root: Paths.support, profile: profile)
        registry = made
        return made
    }

    /// The person registry straight off disk: faces.json is `{name: [hash…]}`.
    /// Used at launch so people are never missing just because the engine has
    /// not been asked yet. A representative is the first hash that has a
    /// thumbnail on disk, so a chip can draw a face immediately.
    private static func peopleFromDisk(profile: String) -> [FacePerson] {
        guard !profile.isEmpty else { return [] }
        let file = Paths.facesFile(in: profile)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return [] }
        return obj.compactMap { name, hashes in
            guard !name.isEmpty, !hashes.isEmpty else { return nil }
            let rep = hashes.first { hash in
                let p = (Paths.support as NSString)
                    .appendingPathComponent("faces/\(hash.prefix(2))/\(hash).jpg")
                return FileManager.default.fileExists(atPath: p)
            } ?? hashes.first
            return FacePerson(name: name, faces: hashes.count, representative: rep)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func saveIndex() {
        let obj = faceVideos.mapValues { Array($0) }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []) {
            try? data.write(to: URL(fileURLWithPath: indexFile), options: .atomic)
        }
    }

    /// A face thumbnail as an Image, loaded lazily from faces/<hash>.jpg.
    static func thumbnail(_ hash: String) -> Image? {
        let path = (Paths.support as NSString)
            .appendingPathComponent("faces/\(hash.prefix(2))/\(hash).jpg")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
    }

    func attach(engine: AnalysisEngine?, library: Library?) {
        self.engine = engine
        self.library = library
    }

    // MARK: - indexing (face → video)

    /// Record which faces the engine found in one video. `path` is absolute,
    /// exactly what the engine returns and what `library.setTags` consumes.
    func recordFaces(_ hashes: [String], for path: String) {
        // The last line of defence for the Face Recognition switch. Callers
        // check it too, but this is the one place every face record passes
        // through, so a future caller cannot forget and quietly start writing
        // face data the user has switched off.
        guard !profile.isEmpty, library?.facesEnabled ?? true else { return }
        guard !hashes.isEmpty else { return }
        for h in hashes {
            faceVideos[h, default: []].insert(path)
        }
        saveIndex()
    }

    /// Detect + persist faces across a batch of already-known videos.
    /// Button-triggered only — never runs on its own. Reports live progress
    /// and is cancellable via `cancelIndex()`.
    func index(paths: [String]) async {
        guard !profile.isEmpty, library?.facesEnabled ?? true else { return }
        guard !paths.isEmpty, !indexing else { return }

        if let registry = coreMLRegistry {
            indexing = true
            indexProgress = ""
            defer { indexing = false; indexProgress = ""; indexTask = nil }
            // A stored task rather than a detached one, because there has to be
            // SOMETHING for `cancelIndex()` to cancel — and one video in, not
            // after the whole library.
            let task = Task { () -> [String: [String]] in
                var out: [String: [String]] = [:]
                for (offset, path) in paths.enumerated() {
                    if Task.isCancelled { break }
                    indexProgress = "\(offset + 1)/\(paths.count) "
                        + (path as NSString).lastPathComponent
                    out[path] = (try? await registry.faces(inVideoAt: path)) ?? []
                }
                return out
            }
            indexTask = task
            for (path, hashes) in await task.value {
                recordFaces(hashes, for: path)
            }
            return
        }

        guard let engine else { return }
        indexing = true
        indexProgress = ""
        defer { indexing = false; indexProgress = "" }
        do {
            let result = try await engine.faceIndex(paths: paths) { [weak self] text in
                Task { @MainActor in self?.indexProgress = text }
            }
            for (path, hashes) in result {
                recordFaces(hashes, for: path)
            }
        } catch {
            // Indexing is a convenience; the engine logs its own trouble.
        }
    }

    /// Stop an in-flight index at the next video boundary.
    func cancelIndex() {
        guard indexing else { return }
        indexTask?.cancel()
        engine?.cancelFaceIndex()
    }

    // MARK: - people

    /// Ask the engine for named people. Clusters are deliberately NOT loaded:
    /// the unnamed-cluster dump was replaced by the add-a-person flow (the
    /// user picks a face, the engine scans), and `face_clusters` is an O(n²)
    /// walk over every cached face that no UI consumes any more.
    func reload() async {
        guard !profile.isEmpty else { return }
        loading = true
        defer { loading = false }
        if let registry = coreMLRegistry {
            // Reads the profile's own `faces.json`, so a failure here is an
            // empty file rather than a lost name — and the launch copy on disk
            // is what `peopleFromDisk` already had in memory (pitfall 45).
            self.people = registry.people()
            self.clusters = []
            return
        }
        guard let engine else { return }
        self.people = (try? await engine.facePeople()) ?? Self.peopleFromDisk(profile: profile)
        self.clusters = []
    }

    // MARK: - add a person (face-first)

    /// 'Add a person' step 1: the biggest faces (by pixel area) in one video
    /// or image, for the user to choose from. Capped at 5 by the engine.
    func detectFaces(path: String) async -> [String] {
        guard !profile.isEmpty else { return [] }
        if let registry = coreMLRegistry {
            return (try? await registry.detectFaces(path: path)) ?? []
        }
        guard let engine else { return [] }
        return (try? await engine.detectFaces(path: path)) ?? []
    }

    /// 'Add a person': bind the chosen face to the name and tag the source
    /// video immediately. That is all — there is NO full-library scan. Adding
    /// five faces is five instant binds, never a hang.
    ///
    /// Recognition is lazy and happens during playback: when a video is
    /// analysed/suggested the engine already detects its faces and matches them
    /// against the named people, suggesting the name wherever it appears. The
    /// tag is created FROM face recognition — never the other way around — and
    /// is usable the moment the person is added.
    func addPerson(_ name: String, faceHash: String, sourceVideo: String?,
                   photoPath: String? = nil) async {
        guard !profile.isEmpty else { return }
        guard let library else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !faceHash.isEmpty else { return }
        // 1. Bind name -> face hash (merge, never replace). Picking an existing
        //    person lands here with their name, so the face joins that person.
        if let registry = coreMLRegistry {
            do { try await registry.bind(name: cleaned, hashes: [faceHash]) }
            catch { return }
            if let photoPath, photoPath != sourceVideo {
                _ = try? await registry.setPhoto(name: cleaned, path: photoPath)
            }
        } else {
            guard let engine else { return }
            do { try await engine.nameCluster(cleaned, hashes: [faceHash]) }
            catch { return }
            // A portrait photo only makes sense for a brand-new person — it
            // would override an existing person's established thumbnail.
            if let photoPath, photoPath != sourceVideo {
                do { _ = try await engine.setPhoto(cleaned, path: photoPath) }
                catch {}
            }
        }
        // 2. Tag the source video immediately — the user just picked this face
        //    from it, so the video HAS this person in it and the tag is usable
        //    right now. This is what makes "select a known person" mean
        //    "this video contains them".
        if let sourceVideo {
            recordFaces([faceHash], for: sourceVideo)
            var have = library.tagsFor(sourceVideo)
            if !have.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                have.append(cleaned)
                library.setTags(have, for: sourceVideo)
            }
            library.saveTags()
        }
        // 3. Reload so the person appears in the People section at once.
        await reload()
    }

    /// What renaming a person came back as, so the UI can say why not.
    enum RenameResult: Equatable {
        case renamed
        case failed(String)
    }

    /// Rename a person: the face bindings AND the tag move to the new name.
    ///
    /// The tag is the person as far as the rest of the app is concerned —
    /// every video that carries the old name carries the new one afterwards,
    /// exactly as if it had always been spelled that way. Renaming onto a
    /// name that already exists is refused (merging two people is a
    /// deliberate act, done by picking them in Add-a-face), not a silent
    /// fold triggered by a typo.
    func renamePerson(_ oldName: String, to newName: String) async -> RenameResult {
        guard !profile.isEmpty else { return .failed("Open a profile first.") }
        guard let library else { return .failed("The library is not ready.") }
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return .failed("Type a name.") }
        guard old.caseInsensitiveCompare(new) != .orderedSame else {
            return .failed("That is already their name.")
        }
        guard !new.contains(",") else {
            return .failed("A name cannot contain a comma — that would become two tags.")
        }
        if let registry = coreMLRegistry {
            do { try await registry.rename(from: old, to: new) }
            catch {
                return .failed((error as? LocalizedError)?.errorDescription
                               ?? "Could not rename \u{201C}\(old)\u{201D}.")
            }
        } else if let engine {
            // The child process has no rename command; the same result comes
            // from binding the old person's faces under the new name, then
            // dropping the old binding. Two official commands, same outcome.
            let file = Paths.facesFile(in: profile)
            let stored = (try? Data(contentsOf: URL(fileURLWithPath: file)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] }
            guard let stored,
                  let key = stored.keys.first(where: { $0.casefolded == old.casefolded }),
                  let hashes = stored[key], !hashes.isEmpty
            else { return .failed("No faces are stored for \u{201C}\(old)\u{201D}.") }
            do {
                try await engine.nameCluster(new, hashes: hashes)
                try await engine.forgetPerson(old)
            } catch {
                return .failed("Could not rename \u{201C}\(old)\u{201D} — the engine refused.")
            }
        } else {
            return .failed("The face engine is not running.")
        }
        // The person IS a tag, so the tag follows the name everywhere.
        library.renameTag(old, to: new)
        await reload()
        return .renamed
    }

    /// Forget a person entirely: drop their name→face binding in the engine
    /// so they are never suggested again. Their videos KEEP the tag unless
    /// `alsoRemoveTag` is set — a wrong identity is usually a naming mistake,
    /// not a reason to lose the labelling work. Face crops stay on disk, so
    /// the same face can be bound to the right person afterwards.
    func forgetPerson(_ name: String, alsoRemoveTag: Bool) async {
        guard !profile.isEmpty else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let registry = coreMLRegistry {
            do { try await registry.forget(name: cleaned) }
            catch { return }
        } else {
            guard let engine else { return }
            do { try await engine.forgetPerson(cleaned) }
            catch { return }
        }
        if alsoRemoveTag { library?.deleteTag(cleaned) }
        await reload()
    }

    /// Faces the system has already seen that look most like this person —
    /// every angle and lighting across the library, best match first.
    func similarFaces(_ name: String) async -> [String] {
        guard !profile.isEmpty else { return [] }
        if let registry = coreMLRegistry {
            return await registry.similarFaces(name: name).faces
        }
        guard let engine else { return [] }
        return (try? await engine.similarFaces(name)) ?? []
    }

    /// Use an existing cached face as the person's representative thumbnail.
    /// No image decoding — the face already lives in the cache.
    func setRepresentative(_ name: String, hash: String) async -> Bool {
        guard !profile.isEmpty else { return false }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !hash.isEmpty else { return false }
        do {
            if let registry = coreMLRegistry {
                try await registry.setRepresentative(name: cleaned, hash: hash)
            } else if let engine {
                try await engine.setRepresentative(cleaned, hash: hash)
            } else {
                return false
            }
            await reload()
            return true
        } catch {
            return false
        }
    }

    /// Set a person's portrait photo as their thumbnail. Used right after
    /// adding them (the sheet can pick a clear picture) or from the People
    /// window row. No tag changes — the photo only improves what a row shows
    /// and gives the matcher one more clean vector of the same identity.
    enum PhotoResult { case success, noFace, failed }

    func setPhoto(_ name: String, path: String) async -> PhotoResult {
        guard !profile.isEmpty else { return .failed }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .failed }
        do {
            // Both engines return the crop hash only when they found a face.
            let hash: String?
            if let registry = coreMLRegistry {
                hash = try await registry.setPhoto(name: cleaned, path: path)
            } else if let engine {
                hash = try await engine.setPhoto(cleaned, path: path)
            } else {
                return .failed
            }
            await reload()
            return hash == nil ? .noFace : .success
        } catch {
            return .failed
        }
    }

    /// How many distinct videos a cluster's faces appear in.
    func videoCount(for cluster: FaceCluster) -> Int {
        var keys = Set<String>()
        for h in cluster.hashes { keys.formUnion(faceVideos[h] ?? []) }
        return keys.count
    }

    /// Name a cluster: bind the name in the engine, then apply it as a tag to
    /// every video whose faces are in the cluster. The tag is created from
    /// face recognition, not the other way around.
    func nameCluster(_ name: String, cluster: FaceCluster) async {
        guard !profile.isEmpty else { return }
        guard let library else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        do {
            if let registry = coreMLRegistry {
                try await registry.bind(name: cleaned, hashes: cluster.hashes)
            } else if let engine {
                try await engine.nameCluster(cleaned, hashes: cluster.hashes)
            } else {
                return
            }
        } catch {
            return
        }
        // The name now lives in the engine registry; apply it as a real tag
        // to every video that carries one of these faces.
        var paths = Set<String>()
        for h in cluster.hashes { paths.formUnion(faceVideos[h] ?? []) }
        for path in paths {
            var have = library.tagsFor(path)
            if !have.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                have.append(cleaned)
                library.setTags(have, for: path)
            }
        }
        library.saveTags()
        await reload()
    }
}
