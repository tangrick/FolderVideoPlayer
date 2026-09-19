import Foundation

/// Which tags were read off the FILE rather than guessed from the picture.
///
/// ## Why this exists
///
/// The app has two completely different ways of producing a tag, and until now
/// the library could not tell them apart once they landed:
///
/// - **The metadata scan** reads the file. The folder it sits in, the capture
///   date, the camera that shot it, the resolution, the GPS the phone wrote.
///   These are FACTS. `2016` is not an opinion about the picture, it is the
///   date in the file's own header.
/// - **The suggestion engine** looks at the frames with a model and guesses.
///   `Beach`, `Cat`, a person's name — every one of them a probability.
///
/// A user cannot act sensibly on a tag without knowing which kind it is. A
/// wrong guess is worth re-checking; a wrong fact means the file itself says
/// something odd — a camera with the wrong clock, a batch copy that rewrote
/// the dates — and that is a different problem with a different fix.
///
/// ## Why a separate file
///
/// Same reason as `tagGroupsFile`: `tags.json` is published to the other
/// devices verbatim, and provenance is this Mac's knowledge of how a tag got
/// here, not part of the tag itself. A device that has never seen this file
/// still reads every tag correctly — it just cannot say where they came from,
/// which degrades to today's behaviour.
///
/// ## What it deliberately does NOT do
///
/// It does not gate anything. A metadata tag is an ordinary tag: it can be
/// removed, re-added, trained on, searched. This only records where it came
/// from so the UI can say so. Provenance that silently changed behaviour would
/// be a second, invisible tag system.
struct TagProvenance: Codable {

    /// The origin of one tag on one video. Only `metadata` is recorded: a tag
    /// with no entry is either the user's own or an accepted suggestion, and
    /// treating "unknown" as "not from metadata" is exactly right for a store
    /// that starts empty on every existing library.
    enum Origin: String, Codable {
        /// Read from the file: folder name, capture date, camera, resolution,
        /// or GPS. No model was involved.
        case metadata
    }

    /// videoKey → [tag: origin]. Keyed like `Library.tags`, so the two can be
    /// read side by side without converting paths twice.
    private(set) var origins: [String: [String: Origin]] = [:]

    // MARK: - reading

    /// Did the metadata scan write this tag on this video?
    func isFromMetadata(_ tag: String, on key: String) -> Bool {
        origins[key]?[tag] == .metadata
    }

    /// Every metadata tag on one video, in the order given. Used by the panel
    /// to split one chip list into two groups without asking per chip.
    func metadataTags(on key: String, from tags: [String]) -> [String] {
        guard let mine = origins[key] else { return [] }
        return tags.filter { mine[$0] == .metadata }
    }

    /// Is this tag EVER written by the metadata scan, anywhere in the library?
    ///
    /// The vocabulary view has no single video to ask about, and a tag like
    /// `2016` is a fact wherever it appears. Deliberately "ever" rather than
    /// "always": a user who types `Singapore` by hand on one video does not
    /// stop the GPS-written `Singapore` on two hundred others from being a
    /// fact.
    func isMetadataTagAnywhere(_ tag: String) -> Bool {
        metadataVocabulary.contains(tag)
    }

    /// Every tag the metadata scan has ever written. Derived once on load and
    /// maintained on write, because the panel asks per chip and walking every
    /// video for each one would be quadratic on a big library.
    private(set) var metadataVocabulary: Set<String> = []

    var isEmpty: Bool { origins.isEmpty }

    // MARK: - writing

    /// Record that the metadata scan produced these tags for this video.
    ///
    /// Additive on purpose. A video re-scanned after the user removed a tag by
    /// hand should not have that removal forgotten, and the scan itself never
    /// removes tags — it only ever proposes more.
    mutating func recordMetadata(_ tags: [String], on key: String) {
        guard !tags.isEmpty else { return }
        var mine = origins[key] ?? [:]
        for tag in tags { mine[tag] = .metadata }
        origins[key] = mine
        metadataVocabulary.formUnion(tags)
    }

    /// Forget one video entirely — it was deleted, or moved out of the library.
    mutating func forget(_ key: String) {
        origins.removeValue(forKey: key)
    }

    /// Carry provenance across a rename or a repair, so a moved file does not
    /// silently lose the fact that its date tag is a fact.
    mutating func move(from old: String, to new: String) {
        guard let mine = origins.removeValue(forKey: old) else { return }
        origins[new] = mine
    }

    // MARK: - persistence

    /// Rebuilt rather than stored, so a hand-edited or partial file cannot
    /// leave the vocabulary disagreeing with the per-video entries.
    private mutating func rebuildVocabulary() {
        var out = Set<String>()
        for (_, byTag) in origins {
            for (tag, origin) in byTag where origin == .metadata { out.insert(tag) }
        }
        metadataVocabulary = out
    }

    /// The same rebuild, reachable by the gate: a decoded store must be able to
    /// prove its vocabulary comes from its entries and not from the file.
    static func rebuilt(_ store: TagProvenance) -> TagProvenance {
        var out = store
        out.rebuildVocabulary()
        return out
    }

    enum CodingKeys: String, CodingKey { case origins }

    static func load() -> TagProvenance {
        var out: TagProvenance = JSONStore.load(Paths.tagProvenanceFile,
                                                fallback: TagProvenance())
        out.rebuildVocabulary()
        return out
    }

    func save() {
        JSONStore.save(Paths.tagProvenanceFile, self)
    }
}
