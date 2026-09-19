import Foundation

/// The facts the app READ off a file, kept in a store of their own — apart
/// from the tags a person or the AI writes.
///
/// ## Why the two are not one store
///
/// A **tag** is a judgement: `Iceland`, `Beach`, `Birthday`, a person's name —
/// something someone, or a model, decided about the picture. A **fact** is a
/// reading: `2016`, `May 2016`, `1080p`, `iPhone 16 Plus`, `Singapore` — the
/// date out of the file's own header, the resolution out of its video track,
/// the camera that wrote it, the GPS the phone embedded. Nothing was decided
/// and nothing is open to opinion.
///
/// Held in one store the two cannot be told apart once they land, which is
/// exactly what the live library showed: **3,838 of its 4,617 tag entries
/// (83%) were facts**, every "what is in this library" list opened with 27
/// year rows, and the AI's vocabulary, the filters and the training-readiness
/// counts each had to special-case them. Separate stores make "your tags"
/// mean what it says.
///
/// ## What stays a tag
///
/// **Folder names.** `Iceland` and `Asian Cruise` came from folders, but they
/// are the words the user chose and they describe what is in the clip — the
/// scan writing them down did not make them readings. Only date, quality,
/// camera and place-from-GPS are facts.
///
/// ## How a name is known to be a fact
///
/// By SHAPE for date, quality and camera (`TagKinds.isFileFact`): `2016` and
/// `1080p` cannot plausibly be anything else.
///
/// A **place name cannot be judged that way** — `Iceland` is a country name
/// and a folder name and a tag the user means — so a place is a fact only when
/// the scan's own record says the scan wrote it (`TagProvenance`). On a library
/// whose scans predate that record, places stay tags: honest, and reversible by
/// re-running the scan.
///
/// ## What this store deliberately does NOT do
///
/// It does not gate anything. A fact is still browsable, still filterable, and
/// still plays its videos — finding your 2016 clips is the whole point of the
/// date being on them. The separation is about which store owns the name, not
/// about hiding it. See `Library.carries(_:)` for the one accessor that answers
/// "everything this video is known by".
struct MetadataFacts: Codable, Equatable, Sendable {

    /// videoKey → the facts read off that file, in the order they were added.
    /// Keyed exactly like `Library.tags`, so the two can be read side by side.
    private(set) var byKey: [String: [String]] = [:]

    static let empty = MetadataFacts()

    var isEmpty: Bool { byKey.isEmpty }
    var count: Int { byKey.count }

    // MARK: - reading

    /// The facts on one video.
    func names(for key: String) -> [String] { byKey[key] ?? [] }

    func has(_ name: String, on key: String) -> Bool {
        names(for: key).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Every video carrying this fact.
    func carrying(_ name: String) -> [String] {
        byKey.filter { _, names in
            names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }.keys.sorted()
    }

    /// Every fact in use, case-insensitively unique and alphabetical — the
    /// counterpart of `Library.knownTags()`. Built on demand: the library keeps
    /// its own counted copy so views never walk this.
    ///
    /// When the same name appears in two spellings ("Singapore" and
    /// "singapore"), the one shown must not depend on which video happened to
    /// be visited first — a dictionary has no order, so that would change the
    /// sidebar's spelling between launches for no reason a person could see.
    /// The videos are walked in key order, so the FIRST video alphabetically
    /// decides, and the answer is the same every time.
    func vocabulary() -> [String] {
        var display: [String: String] = [:]
        for key in byKey.keys.sorted() {
            for name in byKey[key] ?? [] where display[name.lowercased()] == nil {
                display[name.lowercased()] = name
            }
        }
        return display.keys.sorted().compactMap { display[$0] }
    }

    // MARK: - writing

    /// Replace one video's facts. Empty means the video has none, and the key
    /// goes rather than lingering as an empty list.
    mutating func set(_ names: [String], for key: String) {
        var clean: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if !clean.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                clean.append(trimmed)
            }
        }
        byKey[key] = clean.isEmpty ? nil : clean
    }

    /// Add facts without disturbing the ones already there — the merge rule
    /// `AutoTagCore.merged` states for tags, applied to the fact store.
    mutating func add(_ names: [String], to key: String) {
        set(AutoTagCore.merged(existing: self.names(for: key), adding: names), for: key)
    }

    /// Take one fact off every video carrying it. The videos, their tags and
    /// everything else are untouched.
    mutating func remove(_ name: String) {
        var updated = byKey
        for (key, names) in byKey {
            let kept = names.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
            updated[key] = kept.isEmpty ? nil : kept
        }
        byKey = updated
    }

    /// The same fact under a new name, wherever it appears, **in the place it
    /// already had** — a reading's position in a video's list does not change
    /// because somebody corrected its spelling.
    mutating func rename(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        var updated = byKey
        for (key, names) in byKey {
            guard let index = names.firstIndex(where: {
                $0.caseInsensitiveCompare(old) == .orderedSame
            }) else { continue }
            var renamed = names
            renamed[index] = trimmed
            // One copy of a name on a video: the earlier position wins, which is
            // the rule the store applies everywhere else.
            var seen = Set<String>()
            renamed = renamed.filter { seen.insert($0.lowercased()).inserted }
            renamed.removeAll { $0.isEmpty }
            updated[key] = renamed.isEmpty ? nil : renamed
        }
        byKey = updated
    }

    /// Carry a video's readings across a move or a repair, keeping whatever the
    /// destination already holds — a same-named file's readings are not
    /// overwritten by a repair, the same rule `Library.moveTags` states for
    /// tags. The destination's own names lead and the movers join.
    mutating func move(from old: String, to new: String) {
        guard let mine = byKey.removeValue(forKey: old) else { return }
        set(AutoTagCore.merged(existing: byKey[new] ?? [], adding: mine), for: new)
    }

    /// Forget one video entirely — deleted, or moved out of the library.
    mutating func forget(_ key: String) { byKey.removeValue(forKey: key) }

    // MARK: - persistence

    /// A store built from a plain dictionary — the shape `Library.undoable`
    /// carries and the shape `tags.json` used to hold. Names are cleaned the
    /// same way `set` cleans them.
    init(_ raw: [String: [String]] = [:]) {
        for (key, names) in raw { set(names, for: key) }
    }

    private enum CodingKeys: String, CodingKey { case byKey = "facts" }

    /// A missing or unreadable file is an empty store, never a crash: every
    /// library that predates this store has no facts file at all.
    static func load(at path: String) -> MetadataFacts {
        JSONStore.load(path, fallback: MetadataFacts())
    }

    func save(to path: String) { JSONStore.save(path, self) }
}

/// Moving the facts out of the tag store, as a pure function.
///
/// Kept separate from `Library` so the rule can be run against a real
/// `tags.json` without an app, a model or a library on disk — which is how the
/// split was checked against the live 3,595-video store before anything was
/// rewritten.
enum MetadataSplit {

    struct Report: Equatable {
        /// The tags that remain the user's, keyed like `tags.json`.
        var tags: [String: [String]] = [:]
        /// The readings that moved out.
        var facts: [String: [String]] = [:]
        /// How many tag ENTRIES moved (a video with `2016` and `May 2016`
        /// and `1080p` counts three).
        var moved = 0
        /// The distinct names that moved — what a notice reports.
        var names: [String] = []
        /// Videos that lost at least one name.
        var videos = 0

        var isEmpty: Bool { moved == 0 }
    }

    /// Split one store into tags and facts.
    ///
    /// Idempotent by construction: run it on the output and nothing moves,
    /// because the facts are already gone from the tags. Order within each
    /// side is the order the names were in, so a re-run cannot reshuffle a
    /// list the user has been looking at.
    ///
    /// A name is a fact when it is fact-SHAPED (date, quality, camera) **or**
    /// when the scan's own record says the scan wrote it on that video — the
    /// second clause is what moves a GPS place like `Singapore`, which no
    /// shape rule can distinguish from a tag the user meant.
    static func separate(tags: [String: [String]],
                         provenance: TagProvenance = TagProvenance()) -> Report {
        var report = Report()
        var movedNames = Set<String>()
        for (key, names) in tags {
            var kept: [String] = []
            var moved: [String] = []
            for name in names {
                if TagKinds.isFileFact(name) || provenance.isFromMetadata(name, on: key) {
                    moved.append(name)
                    movedNames.insert(name)
                } else {
                    kept.append(name)
                }
            }
            if !moved.isEmpty {
                report.moved += moved.count
                report.videos += 1
                report.facts[key] = moved
            }
            if !kept.isEmpty { report.tags[key] = kept }
        }
        report.names = movedNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return report
    }

    /// Drop the readings a snapshot still carries that the fact store already
    /// holds **for the same video**.
    ///
    /// What `undoTagChange` needs, and deliberately narrower than `separate`.
    /// `separate` moves a name by its shape alone, which is right for the
    /// one-time migration — every `2016` in the tag store then is a reading the
    /// scan wrote. On an Undo it would be wrong: a user who types `2016` onto a
    /// video that holds no such reading is using a year as a tag, and that is
    /// theirs to keep. Matching per video rather than per name is what tells the
    /// two apart.
    static func dropKnownReadings(tags: [String: [String]],
                                  facts: MetadataFacts) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (key, names) in tags {
            let kept = names.filter { !(TagKinds.isFileFact($0) && facts.has($0, on: key)) }
            if !kept.isEmpty { out[key] = kept }
        }
        return out
    }
}

extension MetadataSplit {

    /// What the one-time separation did, kept on disk so the app can say it.
    ///
    /// The separation is the only edit in the app that takes names out of the
    /// user's tag store without them asking for it at that moment, so it is also
    /// the only edit that reports itself afterwards. Written once, at the end of
    /// `Library.migrateMetadataFacts()`.
    struct Summary: Codable, Equatable {
        var date: Date
        /// How many tag ENTRIES moved out.
        var moved: Int
        /// How many videos lost at least one name.
        var videos: Int
        /// The distinct names that moved.
        var names: [String]

        /// One line a person can read: "38 readings (2015, 2016, 1080p and 28
        /// more) moved out of your tags on 16 Sep, from 3,045 videos."
        var sentence: String {
            let shown = names.prefix(3).joined(separator: ", ")
            let rest = names.count > 3 ? " and \(names.count - 3) more" : ""
            let list = names.isEmpty ? "" : " (\(shown)\(rest))"
            let day = Self.day.string(from: date)
            return "\(moved) readings\(list) moved out of your tags on \(day), "
                + "from \(videos) videos. Your tags are unchanged."
        }

        private static let day: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d MMM yyyy"
            return f
        }()

        /// Absent until the separation has run and something moved.
        static func load() -> Summary? {
            JSONStore.load(Paths.separationReportFile, fallback: nil)
        }

        func save() { JSONStore.save(Paths.separationReportFile, self) }
    }
}
