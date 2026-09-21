import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A face the engine found in one frame: the content hash that keys its cached
/// vector and thumbnail, the unit vector itself, and how big the detection was.
///
/// The area is carried because prominence is what orders the add-a-person
/// chooser — the person on camera, not the background extras (pitfall 38).
struct FoundFace {
    let hash: String
    let vector: [Float]
    let area: Double
}

/// The app-side half of face recognition that is NOT a model: what a face's
/// identity is keyed by, which names are bound to which faces, and which faces
/// look like which person.
///
/// This is the Swift port of `engine.py`'s face block (`_face_cache_*`,
/// `_face_thumb_*`, `_load_face_registry`, `_face_matches`, `face_people`,
/// `name_cluster`, `forget_person`, `set_photo`, `set_representative`,
/// `similar_faces`, `detect_faces`), and it exists for the same reason the
/// models do: the shipped app has no Python, so a feature that only runs on this
/// Mac is a feature a stranger does not get.
///
/// **Two stores, two lifetimes, on purpose.** The vectors and thumbnails are
/// keyed by a hash of the *crop pixels*, so they describe the video and are
/// shared by every profile (`faces/<xx>/<hash>.f32`). The registry — which name
/// is bound to which face — is one person's judgement, so it is per profile
/// (`profiles/<slug>/faces.json`). Mixing them would mean a second profile
/// re-encoding the library, or one person's names appearing under another's.
///
/// **The hash is engine-specific, and that is stated rather than hidden.** It is
/// `sha256(112×112×3 BGR pixels)[:32]`, exactly the engine's formula, but the
/// aligned crop comes back from a hand-written bilinear warp that matches
/// `cv2.warpAffine` to ~1.7/255 per pixel rather than bit-for-bit (see
/// `FaceAlignment`). So a library already analysed by the Python engine gains a
/// parallel set of hashes the first time the Swift engine scans it. Nothing
/// breaks: the registry's existing hashes still resolve, because their vectors
/// are still on disk and the matcher reads them by hash — the two sets simply
/// coexist until the old ones age out of use.
actor FaceRegistry {

    /// SFace's width, and `engine.FACE_DIM`.
    static let dim = 128
    /// `engine.FACE_MAX_FRAMES` — frames scanned per video. A stride across the
    /// WHOLE video, never a prefix (pitfall 29): someone who appears mid-clip is
    /// the normal case.
    static let maxFrames = 40
    /// `engine.FACE_MAX_FACES` — a safety net on distinct faces, not an early
    /// exit (pitfall 29 again).
    static let maxFaces = 48
    /// `engine.FACE_MAX_CHOICES` — people offered by the add-a-person chooser.
    static let maxChoices = 5
    /// `engine.FACE_CHOICE_LIMIT` — faces offered by the pick-a-picture chooser.
    static let choiceLimit = 48
    /// `engine.FACE_CLUSTER_COSINE` — merge two sightings into one person.
    static let clusterCosine = 0.30

    /// Extensions `set_photo` accepts, from the engine's own list.
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "bmp", "webp", "tiff",
    ]

    private let root: String
    /// The profile whose `faces.json` this registry reads, fixed at
    /// construction. Readable so a cached registry can be checked against the
    /// profile that is active NOW — see `CoreMLClassifier.faceEngine`.
    let profile: String

    private var detector: FaceDetector?
    private var embedder: SFaceEmbedder?

    init(root: String = Paths.support, profile: String = Paths.activeProfile) {
        self.root = root
        self.profile = profile
    }

    // MARK: - where everything lives

    /// Shared by every profile: a face's vector is a fact about the video.
    static func faceRoot(_ root: String) -> String {
        (root as NSString).appendingPathComponent("faces")
    }

    static func vectorPath(root: String, hash: String) -> String {
        (faceRoot(root) as NSString).appendingPathComponent("\(hash.prefix(2))/\(hash).f32")
    }

    static func thumbnailPath(root: String, hash: String) -> String {
        (faceRoot(root) as NSString).appendingPathComponent("\(hash.prefix(2))/\(hash).jpg")
    }

    /// The identity of a crop, by the engine's own formula.
    ///
    /// `sha256(bytes)[:32]` over the packed `112×112×3` BGR array — the first 16
    /// bytes of the digest, hex, which is why it is a 32-character key rather
    /// than a 64-character one. Idempotent by construction: the same crop hashes
    /// the same, so re-scanning a video cannot duplicate a cache entry.
    static func hash(of bgr: [UInt8]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(bgr))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Are the two models this needs on disk? Cheap — two directory checks.
    nonisolated static func isInstalled(root: String) -> Bool {
        FaceDetector.isInstalled(root: root) && SFaceEmbedder.isInstalled(root: root)
    }

    private func models() throws -> (FaceDetector, SFaceEmbedder) {
        if let detector, let embedder { return (detector, embedder) }
        guard Self.isInstalled(root: root) else {
            throw RegistryError.modelsMissing(FaceDetector.modelURL(root: root).path)
        }
        let madeDetector = try FaceDetector(root: root)
        let madeEmbedder = try SFaceEmbedder(root: root)
        detector = madeDetector
        embedder = madeEmbedder
        return (madeDetector, madeEmbedder)
    }

    // MARK: - the cache

    /// The cached vector behind a face hash, or nil when it is gone.
    ///
    /// A miss is a miss, never a zero vector: `matches` treats an unreadable
    /// hash as "no evidence", and a zero vector would instead read as a face
    /// that resembles nothing — which turns a pruned cache into silence rather
    /// than a visible gap.
    nonisolated func vector(for hash: String) -> [Float]? {
        guard !hash.isEmpty,
              let data = FileManager.default.contents(atPath:
                  Self.vectorPath(root: root, hash: hash)),
              !data.isEmpty, data.count % 4 == 0 else { return nil }
        var out = [Float](repeating: 0, count: data.count / 4)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        guard out.count == Self.dim else { return nil }
        return out
    }

    nonisolated func thumbnailExists(_ hash: String) -> Bool {
        FileManager.default.fileExists(
            atPath: Self.thumbnailPath(root: root, hash: hash))
    }

    /// Persist a detected face. Both writes are best-effort and atomic (a
    /// `.tmp` beside the destination, then a rename), because the alternative
    /// is a zero-length `.f32` that reads as a face with no vector.
    func store(hash: String, vector: [Float], crop: CGImage) {
        let manager = FileManager.default
        let vectorFile = Self.vectorPath(root: root, hash: hash)
        try? manager.createDirectory(
            atPath: (vectorFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        Self.write(data, to: vectorFile)
        if let jpeg = Self.thumbnail(crop) {
            Self.write(jpeg, to: Self.thumbnailPath(root: root, hash: hash))
        }
    }

    /// An atomic small-file write: `.tmp` beside the destination, then a rename.
    /// Static and non-isolated so both the cache and the per-profile registry
    /// go through one path — a zero-length `.f32` reads as a face with no
    /// vector, and a half-written `faces.json` reads as nobody named.
    nonisolated static func write(_ data: Data, to path: String) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                     withIntermediateDirectories: true)
        let tmp = path + ".tmp"
        guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
        _ = try? manager.replaceItemAt(URL(fileURLWithPath: path),
                                       withItemAt: URL(fileURLWithPath: tmp))
    }

    /// The crop as the thumbnail a People row shows. JPEG at 0.82, the engine's
    /// own quality — the bytes are whatever ImageIO makes of them, which is fine
    /// for a picture and is why nothing is keyed off the thumbnail.
    static func thumbnail(_ crop: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, crop,
                                   [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - the registry

    /// `{name: [faceHash…]}` from this profile's `faces.json`, or empty.
    ///
    /// A corrupt or absent file reads as empty rather than throwing: this runs
    /// at launch, and `FaceStore` has the last-known-good copy in memory already.
    nonisolated func registry() -> [String: [String]] {
        let file = Paths.facesFile(in: profile)
        guard let data = FileManager.default.contents(atPath: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
        else { return [:] }
        return raw
    }

    nonisolated func save(_ registry: [String: [String]]) {
        let file = Paths.facesFile(in: profile)
        guard let data = try? JSONSerialization.data(withJSONObject: registry) else { return }
        Self.write(data, to: file)
    }

    /// The person key a name resolves to, case-insensitively — so the app never
    /// has to match the stored spelling, and "quincy" cannot become a second
    /// person beside "Quincy".
    nonisolated static func existingKey(_ name: String,
                                        in registry: [String: [String]]) -> String? {
        registry.keys.first { $0.casefolded == name.casefolded }
    }

    /// Named people and their face counts. The representative is the first hash
    /// that actually has a thumbnail on disk, so a row can draw a face without
    /// checking again — falling back to the first hash so a person whose thumbs
    /// were all pruned still appears.
    nonisolated func people() -> [FacePerson] {
        registry().map { name, hashes in
            let rep = hashes.first { thumbnailExists($0) } ?? hashes.first
            return FacePerson(name: name, faces: hashes.count, representative: rep)
        }
        .sorted { $0.name.casefolded < $1.name.casefolded }
    }

    /// Bind face hashes to a name. **Merge, never replace** — naming one cluster
    /// must not detach the faces the user already bound under the same name, and
    /// re-binding an existing face is a no-op rather than a duplicate.
    @discardableResult
    func bind(name: String, hashes: [String]) throws -> Int {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !hashes.isEmpty else { throw RegistryError.noName }
        var registry = self.registry()
        let key = Self.existingKey(cleaned, in: registry) ?? cleaned
        var existing = registry[key] ?? []
        // `known` is updated as the request is walked, so a hash repeated
        // inside ONE request is bound once. The engine only compared against
        // what was already stored, which appended the second copy — a registry
        // list holding one face twice is a row drawn twice waiting to happen,
        // and nothing downstream ever wants it.
        var known = Set(existing)
        var added: [String] = []
        for hash in hashes where !hash.isEmpty && !known.contains(hash) {
            known.insert(hash)
            added.append(hash)
        }
        existing.append(contentsOf: added)
        registry[key] = existing
        save(registry)
        return added.count
    }

    /// Rename a person: the same face bindings under a new name.
    ///
    /// The case-insensitive key rule decides who is being renamed, so "quincy"
    /// renames "Quincy" rather than failing to find them. Renaming onto a
    /// name that already exists (case-insensitively) is refused rather than
    /// merged — merging is `bind`'s job and a deliberate act, while a typo in
    /// a rename must not quietly fold two people into one.
    ///
    /// Returns the registry key actually renamed, which the store reports.
    @discardableResult
    func rename(from oldName: String, to newName: String) throws -> String {
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty else { throw RegistryError.noName }
        guard old.casefolded != new.casefolded else { throw RegistryError.noName }
        var registry = self.registry()
        guard let key = Self.existingKey(old, in: registry) else {
            throw RegistryError.noSuchPerson(old)
        }
        if Self.existingKey(new, in: registry) != nil {
            throw RegistryError.personExists(new)
        }
        let hashes = registry.removeValue(forKey: key)!  // existingKey found it
        registry[new] = hashes
        save(registry)
        return new
    }

    /// Drop a person from the registry. Only the binding goes — the cached
    /// vectors and thumbnails stay, so the same face can be bound to the right
    /// person afterwards (that is the whole point of a reversible correction).
    @discardableResult
    func forget(name: String) throws -> Int {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RegistryError.noName }
        var registry = self.registry()
        let victims = registry.keys.filter { $0.casefolded == cleaned.casefolded }
        guard !victims.isEmpty else { return 0 }
        var removed = 0
        for key in victims { removed += registry.removeValue(forKey: key)?.count ?? 0 }
        save(registry)
        return removed
    }

    /// Make an already-cached face a person's representative thumbnail.
    ///
    /// Order is the mechanism: the first hash with a thumbnail is what the rows
    /// show, so the chosen face is PREPENDED (pitfall 50). The thumbnail has to
    /// exist — picking a face with no picture would leave a blank circle where
    /// the user chose a picture.
    ///
    /// Returns the face hash, which is what the engine reported as `photo`.
    /// Picking a hash the person already has is a no-op rather than a second
    /// copy of it: the point is which face leads the list, not how many times
    /// it appears in it.
    @discardableResult
    func setRepresentative(name: String, hash: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !hash.isEmpty else { throw RegistryError.noName }
        guard thumbnailExists(hash) else { throw RegistryError.noThumbnail(hash) }
        var registry = self.registry()
        let key = Self.existingKey(cleaned, in: registry) ?? cleaned
        var hashes = registry[key] ?? []
        if let index = hashes.firstIndex(of: hash) {
            hashes.remove(at: index)
        }
        hashes.insert(hash, at: 0)
        registry[key] = hashes
        save(registry)
        return hash
    }

    /// Give a person a portrait photo as their thumbnail: the biggest face in
    /// the picture is detected, embedded and persisted, then prepended.
    ///
    /// Returns nil when no face was found, and the registry is left untouched —
    /// a portrait with nobody recognisable in it must not silently re-point the
    /// person's thumbnail at nothing.
    @discardableResult
    func setPhoto(name: String, path: String) async throws -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RegistryError.noName }
        guard FileManager.default.fileExists(atPath: path) else {
            throw RegistryError.noSuchFile(path)
        }
        guard Self.photoExtensions.contains(
            (path as NSString).pathExtension.lowercased()) else {
            throw RegistryError.notAnImage(path)
        }
        guard let image = Self.loadImage(path) else {
            throw RegistryError.unreadableImage(path)
        }
        // A photo is a single frame, so there is no stride or dedupe: the
        // biggest face by pixel area is the person the picture is of.
        let found = try await faces(in: image)
        guard let best = found.max(by: { $0.area < $1.area }) else { return nil }
        try setRepresentative(name: cleaned, hash: best.hash)
        return best.hash
    }

    /// Faces the system has already seen that look most like this person, best
    /// first — straight out of the cache, no re-decoding.
    ///
    /// The person's own faces lead the list and are excluded, and the score is
    /// the best cosine over all their stored vectors rather than a mean: a
    /// person photographed from many angles has several distinct vectors, and a
    /// mean of them resembles nobody.
    @discardableResult
    func similarFaces(name: String) -> (faces: [String], total: Int) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ([], 0) }
        let registry = self.registry()
        let key = Self.existingKey(cleaned, in: registry) ?? cleaned
        let own = Set(registry[key] ?? [])
        let references = own.compactMap { vector(for: $0) }
        guard !references.isEmpty else { return ([], 0) }

        var scored: [(score: Double, hash: String)] = []
        for hash in Self.cachedHashes(root: root) {
            guard let candidate = vector(for: hash) else { continue }
            let best = references.reduce(-1.0) { running, reference in
                max(running, SFaceEmbedder.cosine(candidate, reference))
            }
            scored.append((best, hash))
        }
        scored.sort { $0.score > $1.score }
        let chosen = scored.prefix(Self.choiceLimit).map(\.hash).filter { !own.contains($0) }
        return (chosen, scored.count)
    }

    /// Every face hash in the shared cache — `faces/<xx>/<hash>.f32`.
    nonisolated static func cachedHashes(root: String) -> [String] {
        let manager = FileManager.default
        let root = faceRoot(root)
        guard let subdirectories = try? manager.contentsOfDirectory(atPath: root) else {
            return []
        }
        var out: [String] = []
        for sub in subdirectories.sorted() {
            let dir = (root as NSString).appendingPathComponent(sub)
            let names = (try? manager.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted() where name.hasSuffix(".f32") {
                out.append(String(name.dropLast(4)))
            }
        }
        return out
    }

    /// Best person match per detected face, above the threshold.
    ///
    /// Returns `{name: bestCosine}` for names whose ANY stored vector matches
    /// ANY detected face, which is the shape the engine's `_face_matches`
    /// returns. Names whose cached vectors have since been pruned simply stop
    /// matching until re-bound — no error, no zero vector.
    ///
    /// `threshold` defaults to the engine's own 0.30 so this stays a faithful
    /// port and the parity gate keeps comparing like with like. The APP asks a
    /// harder question than the engine's one-to-one comparison — "is this
    /// person anywhere in this video", against every face in it — and passes
    /// `SFaceEmbedder.videoMatchCosine`, which is measured for that question.
    nonisolated func matches(vectors: [[Float]],
                             in registry: [String: [String]],
                             threshold: Double = SFaceEmbedder.matchCosine) -> [String: Double] {
        guard !vectors.isEmpty, !registry.isEmpty else { return [:] }
        var hits: [String: Double] = [:]
        for (name, hashes) in registry {
            var best = -1.0
            for hash in hashes {
                guard let stored = vector(for: hash) else { continue }
                for candidate in vectors {
                    best = max(best, SFaceEmbedder.cosine(stored, candidate))
                }
            }
            if best >= threshold { hits[name] = best }
        }
        return hits
    }

    // MARK: - finding faces

    /// Detect, align, embed and PERSIST every face in one frame.
    ///
    /// Persisting here rather than at the call site is the engine's own design
    /// and it is load-bearing: a later cluster pass or a name lookup reads the
    /// cache instead of re-decoding video, so the cost of looking is paid once.
    /// Idempotent, because the key is the crop's hash.
    func faces(in image: CGImage) async throws -> [FoundFace] {
        let (detector, embedder) = try models()
        let detections = try await detector.detect(image)
        var out: [FoundFace] = []
        out.reserveCapacity(detections.count)
        for detection in detections {
            try Task.checkCancellation()
            guard let crop = FaceAlignment.align(image, landmarks: detection.landmarks) else {
                continue
            }
            let vector = SFaceEmbedder.unit(try await embedder.embed(crop.image))
            guard vector.count == Self.dim else { continue }
            let hash = Self.hash(of: crop.bgr)
            store(hash: hash, vector: vector, crop: crop.image)
            out.append(FoundFace(hash: hash, vector: vector, area: detection.area))
        }
        return out
    }

    /// Every distinct face across ALREADY-SAMPLED frames, biggest sighting kept.
    ///
    /// Strides across the whole video (pitfall 29) and stops at `maxFaces`, which
    /// is a net against a pathological clip, never an early exit that would hide
    /// someone who appears late.
    ///
    /// The frames are handed in rather than sampled here because the suggestion
    /// pass has already decoded them for CLIP: sampling again would double the
    /// decode cost of every video the user watches, and the frames are the same
    /// ones either way (engine.py's own face pass reads `frames[]` for exactly
    /// this reason).
    func faces(inFrames frames: [FrameSampler.SampledFrame],
               onStatus: ((String) -> Void)? = nil) async throws -> [FoundFace] {
        guard !frames.isEmpty else { return [] }
        let step = max(1, Int(ceil(Double(frames.count) / Double(Self.maxFrames))))
        var seen = Set<String>()
        var out: [FoundFace] = []
        for index in stride(from: 0, to: frames.count, by: step) {
            try Task.checkCancellation()
            onStatus?("\(index + 1)/\(frames.count)")
            for face in try await faces(in: frames[index].image) where !seen.contains(face.hash) {
                seen.insert(face.hash)
                out.append(face)
            }
            if out.count >= Self.maxFaces { break }
        }
        return out
    }

    /// Every distinct face hash in a video, in the order they were first seen.
    func faces(inVideoAt path: String,
               onStatus: ((String) -> Void)? = nil) async throws -> [String] {
        let frames = try await FrameSampler.sample(url: URL(fileURLWithPath: path))
        return try await faces(inFrames: frames, onStatus: onStatus).map(\.hash)
    }

    /// The most prominent DISTINCT people in one video or image.
    ///
    /// 'Add a person' step 1, and the reason it is not just "the biggest face":
    /// one person is detected many times at different angles and scales, so a
    /// crowd scene would otherwise be dozens of choices for two people. The
    /// sightings are clustered by cosine (the engine's greedy running-centroid
    /// merge), each cluster is represented by its biggest — and therefore
    /// clearest — crop, and the `maxChoices` biggest clusters are returned.
    func detectFaces(path: String) async throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw RegistryError.noSuchFile(path)
        }
        var seen: [String: (area: Double, vector: [Float])] = [:]
        func ingest(_ found: [FoundFace]) {
            for face in found {
                if let previous = seen[face.hash], previous.area >= face.area { continue }
                seen[face.hash] = (face.area, face.vector)
            }
        }

        if Self.photoExtensions.contains((path as NSString).pathExtension.lowercased()) {
            guard let image = Self.loadImage(path) else {
                throw RegistryError.unreadableImage(path)
            }
            ingest(try await faces(in: image))
        } else {
            let frames = try await FrameSampler.sample(url: URL(fileURLWithPath: path))
            let step = max(1, Int(ceil(Double(frames.count) / Double(Self.maxFrames))))
            for index in stride(from: 0, to: frames.count, by: step) {
                try Task.checkCancellation()
                ingest(try await faces(in: frames[index].image))
                if seen.count >= Self.maxFaces { break }
            }
        }
        return Self.choose(seen: seen)
    }

    /// The clustering half of `detect_faces`, split out so the merge rule is
    /// testable without a video: one person seen often must be ONE choice.
    nonisolated static func choose(seen: [String: (area: Double, vector: [Float])]) -> [String] {
        // Biggest sighting first, so the representative of a cluster is decided
        // by prominence and not by whichever hash the dictionary happened to
        // hand over first.
        let ordered = seen.sorted { $0.value.area > $1.value.area }
        var clusters: [(centroid: [Float], count: Int, representative: String, area: Double)] = []
        for (hash, sighting) in ordered {
            var best: (score: Double, index: Int)?
            for (index, cluster) in clusters.enumerated() {
                let score = SFaceEmbedder.cosine(sighting.vector, cluster.centroid)
                if score >= clusterCosine, best == nil || score > best!.score {
                    best = (score, index)
                }
            }
            guard let match = best else {
                clusters.append((sighting.vector, 1, hash, sighting.area))
                continue
            }
            let cluster = clusters[match.index]
            let count = cluster.count
            // The running centroid is the engine's own arithmetic — a plain mean
            // of the members, NOT re-normalised after each merge. Re-normalising
            // is the tempting "fix", and it is a different algorithm: it keeps
            // the centroid at unit length, so it matches later sightings more
            // easily and merges more aggressively, and `FACE_CLUSTER_COSINE`
            // was tuned against the shrinking one. The unit-length version is
            // not obviously worse for a chooser that wants one person to be one
            // choice — but it is unverifiable, because `engine.face_clusters` is
            // the only oracle for this rule and it does not normalise.
            let blended = zip(cluster.centroid, sighting.vector).map {
                ($0 * Float(count) + $1) / Float(count + 1)
            }
            var updated = cluster
            updated.centroid = blended
            updated.count = count + 1
            if sighting.area > cluster.area {
                updated.area = sighting.area
                updated.representative = hash
            }
            clusters[match.index] = updated
        }
        return clusters.sorted { $0.area > $1.area }
            .prefix(maxChoices).map(\.representative)
    }

    // MARK: - loading an image

    /// A still image off disk, as the detector and aligner want it.
    nonisolated static func loadImage(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    enum RegistryError: Error, LocalizedError, CustomStringConvertible {
        case modelsMissing(String)
        case noName
        case noThumbnail(String)
        case noSuchFile(String)
        case notAnImage(String)
        case unreadableImage(String)
        case noSuchPerson(String)
        case personExists(String)

        var description: String {
            switch self {
            case .modelsMissing(let path):
                return "the face models are not installed (looked for \(path))"
            case .noName:
                return "a person needs a name, and a binding needs at least one face"
            case .noThumbnail(let hash):
                return "face \(hash) has no thumbnail on disk"
            case .noSuchFile(let path):
                return "there is no file at \(path)"
            case .notAnImage(let path):
                return "\(path) is not an image"
            case .unreadableImage(let path):
                return "could not read the image at \(path)"
            case .noSuchPerson(let name):
                return "there is no person named “\(name)” to rename"
            case .personExists(let name):
                return "there is already a person named “\(name)” — removing or "
                     + "merging them is a deliberate act, not a side effect of a rename"
            }
        }

        /// So a refusal reaches the UI as a sentence, never a code.
        var errorDescription: String? { description }
    }
}

extension String {
    /// Python's `str.casefold()` — what the engine used to decide two names were
    /// the same person.
    ///
    /// `lowercased()` is not the same thing: it leaves `ß` as `ß` where
    /// `casefold()` maps it to `ss`. Case folding is the right operation here
    /// because this is only ever a comparison key for a person's name, and two
    /// spellings that differ only in case must not become two people.
    ///
    /// Deliberately NOT diacritic-insensitive: the engine never was, and
    /// folding accents away would merge "Jose" and "José" into one person.
    var casefolded: String { folding(options: [.caseInsensitive], locale: nil) }
}
