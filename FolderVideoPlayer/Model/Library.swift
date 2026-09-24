import Foundation
import Combine
import SwiftUI

/// The app's memory: tags, resume positions, preferences and the duplicate
/// index. Everything that survives a quit lives here; the views observe it and
/// the playback controller asks it questions.
@MainActor
final class Library: ObservableObject {

    // -- tags ------------------------------------------------------------
    //
    // Kept in their own file, keyed on the video's path, and never trimmed: a
    // resume position that ages out costs you nothing, a tag you typed is
    // work. The cost of keying on path is that renaming a video orphans its
    // tags, which is what Tag Profiles is there to clean up.
    @Published private(set) var tags: [String: [String]] = [:]

    /// Which of those tags were read off the FILE rather than guessed from the
    /// picture. Empty on an existing library and on every device that has never
    /// run a metadata scan, which reads as "nothing is known to be metadata" —
    /// the honest answer, and today's behaviour.
    @Published private(set) var provenance = TagProvenance()
    /// The facts READ off the files — capture date, resolution, the camera that
    /// shot it, the place out of the GPS. A store of their own, never a tag:
    /// `MetadataFacts` sets out why the two cannot share a dictionary, and the
    /// live library is the argument (3,838 of its 4,617 tag entries were
    /// readings, not judgements).
    ///
    /// **One store for the whole machine, not one per profile.** A reading does
    /// not depend on who is looking: the date in a file's header is the same
    /// date under every profile. Profiles separate judgement, which is why they
    /// own tags. `migrateMetadataFacts()` empties the readings out of every
    /// profile's tag store, once.
    ///
    /// **Local, and never published.** `tags` goes to the shares verbatim so
    /// the TV and the other Macs can read it; a reading is not part of that
    /// conversation, and re-reading the same files on the other device yields
    /// the same facts anyway. See `docs/plans/2026-09-16-metadata-separation.md`
    /// for what that costs the TV.
    @Published private(set) var facts = MetadataFacts()
    /// What the one-time separation did, if it has happened. Read at launch so
    /// the app can say so: 31 names leaving the tag list deserves a sentence
    /// rather than silence. See `MetadataSplit.Summary`.
    @Published private(set) var separationReport = MetadataSplit.Summary.load()
    /// How many videos carry each tag, and the tags in use most-first.
    ///
    /// The library panel draws a count beside every tag and the tag panel
    /// offers the popular ones; counting those from scratch walks every tagged
    /// video once per tag, on every redraw. They are derived once per change
    /// instead.
    @Published private(set) var tagCounts: [String: Int] = [:]
    private var tagDisplay: [String: String] = [:]
    private var popular: [String] = []
    /// The vocabulary, alphabetical, worked out when the tags change rather
    /// than when somebody asks. Views ask several times per redraw and this
    /// used to sort the whole list each time.
    private var sortedTags: [String] = []
    /// How many videos carry each fact, and the fact vocabulary — derived the
    /// same way as `tagCounts`/`sortedTags` (hidden videos out, one pass per
    /// change rather than one per redraw).
    ///
    /// Deliberately NOT folded into `tagCounts`: a fact with a count beside it
    /// sitting in the tag counts is the exact confusion the split removes. The
    /// sidebar's "From the file" section reads these; nothing trains, suggests
    /// or files on them.
    @Published private(set) var factCounts: [String: Int] = [:]
    private var sortedFacts: [String] = []

    // -- remembered state -------------------------------------------------
    @Published var recent: [String] = []
    @Published var progress: [String: Double] = [:]
    var progressSeen: [String: Double] = [:]
    @Published var session: Session?
    @Published var order: PlayOrder = .all { didSet { save() } }
    @Published var speed: Double = Tuning.normalSpeed { didSet { save() } }
    /// How far the skip controls jump, in seconds. One of
    /// `Library.skipChoices`; anything else in a settings file falls back
    /// to the old 15 rather than putting an odd number on the button.
    @Published var skipSeconds: Int = Library.defaultSkip { didSet { save() } }
    /// Whether `note(position:total:for:)` remembers the middle of a video.
    /// Off means every video starts at the beginning.
    @Published var resumeEnabled = true { didSet { save() } }
    /// How many recent folders the sidebar keeps. Pinned folders are not
    /// affected — they are the list that does not slide.
    @Published var recentLimit: Int = Tuning.recentMax { didSet { save() } }
    /// The skip steps the Settings window offers, and the one an unset or
    /// unrecognised settings file gets.
    static let skipChoices = [5, 10, 15, 30, 60]
    static let defaultSkip = 15
    /// Whose tags these are — the tag profile in force. The account name is
    /// only a default: an Apple TV has no account name to borrow, and renaming
    /// a Mac account should not orphan a library.
    @Published var person: String = NSUserName() {
        didSet {
            // Everything a profile decided for itself — heads, suggestions,
            // marks, people — is filed under this slug, so it has to move with
            // `person`. Set here rather than read from the stores so a file can
            // find its own name without every store being handed the profile.
            // An empty name is a closed profile: it owns no folder, and
            // `slug("")` would invent the name "unknown" and make writes to
            // `Paths.tagsFile` land in a stray bundle.
            Paths.activeProfile = person.isEmpty ? "" : slug(person)
            profileContext = UUID()
            isPublishing = false
            save()
        }
    }
    /// Every profile this Mac holds tags for, the active one included.
    @Published var profiles: [String] = []
    /// Slugs of profiles forgotten on this Mac. Held because the list also
    /// offers whatever is found on the shares, and without this a profile you
    /// had just forgotten came straight back from there — which read as the
    /// forgetting having done nothing at all.
    @Published private(set) var hiddenProfiles: Set<String> = []
    /// The profiles opened most recently, newest first — File ▸ Open Recent
    /// Profile. Kept by name because it is read by a person, and matched by
    /// slug so a rename moves its entry instead of leaving the old name behind.
    @Published var recentProfiles: [String] = []
    /// Whether a profile document is open. Closing (File ▸ Close Profile)
    /// empties every tag surface but leaves the player working, so every
    /// tagging write asks this first — see the guards in `saveTags`,
    /// `saveFacts`, `scheduleAutoPublish` and `publishTags`. Reopening reads
    /// the bundle back in.
    @Published private(set) var profileOpen = true
    /// When this profile's tags last reached the shares, from the bundle
    /// manifest. Zero means never — which is different from "0 seconds ago"
    /// and is what the title's Published wording reads.
    ///
    /// These three document fields are internal-var rather than
    /// `private(set)`: the writes happen in the TagSharing extension, which is
    /// the same type but another file, and a private setter cannot reach
    /// there. The rule stays a convention: views read, `Library` and its
    /// extensions write.
    @Published var lastPublishedAt: Double = 0
    /// Whether the tag set in hand is what the shares hold. Broken by any tag
    /// edit; set right again by a publish that every mounted share accepted.
    /// A publish that some share refused leaves it broken — "published" would
    /// be a claim about a file this Mac cannot see inside the TV, and the
    /// title only makes claims this Mac can stand behind.
    @Published var publishedClean = true
    /// Set while a publish is in flight, so the title can say so instead of
    /// leaving the user to guess whether the click did anything.
    @Published var isPublishing = false
    /// The tag set as it was before the last destructive edit, and what that
    /// edit was — what Undo puts back. The facts come with it: a metadata scan
    /// adds readings as well as tags, so an Undo that put the tags back and
    /// left the facts behind would be half an undo.
    @Published private(set) var undoable: (label: String,
                                           tags: [String: [String]],
                                           facts: [String: [String]])?
    /// Whether to offer the choice of profile when the app opens.
    @Published var askProfileAtStartup = true { didSet { save() } }
    @Published var device: String = String(UUID().uuidString.prefix(8)).lowercased()
    private var deviceHost: String = ""

    /// This machine, as the kernel knows it.
    nonisolated static func hostIdentifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&bytes, &timeout) == 0 else { return "" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    @Published var lastMerge: Double = 0
    @Published var showThumbnails = true { didSet { save() } }
    @Published var playlistStyle: PlaylistStyle = .list { didSet { save() } }
    /// How wide the playlist is, dragged by its edge and remembered.
    @Published var playlistWidth: Double = 320
    /// How wide the library sidebar is, dragged by its edge and remembered.
    @Published var librarySidebarWidth: Double?
    @Published var playlistSort: PlaylistSort = .folder { didSet { save() } }
    @Published var sortDescending = false { didSet { save() } }
    @Published var volume: Int = 100
    /// Folders pinned in the sidebar — the short list that survives the
    /// sliding Recent window. See `pin(folder:)`.
    @Published var pinned: [String] = []
    /// Every profile's pinned folders, keyed by profile slug. `pinned` above
    /// is the profile in force; this is where the others wait.
    private var pinnedByProfile: [String: [String]] = [:]
    /// Recent folders per profile — see `pinnedByProfile`, same rule.
    private var recentByProfile: [String: [String]] = [:]
    @Published var discardFolders: [String: String] = [:]
    /// Fingerprinting as videos play. Off unless asked for: a video that was
    /// moved and then found again gets matched against where it used to be
    /// and reported as a copy of itself, so this waits for a deliberate yes.
    @Published var watchDupes = false { didSet { save() } }
    /// Whether the app looks for faces at all.
    ///
    /// Off means off everywhere: no face detection during suggestions, no
    /// face vectors or crops written, and the People window closed to new
    /// work. Already-named people stay named — a switch is not a delete —
    /// and their tags keep working as ordinary tags.
    @Published var facesEnabled = true { didSet { save() } }
    /// Working on the video being watched, in the background: classify it, then
    /// offer tag ideas for it.
    ///
    /// The Python engine's shape was: press Classify, then watch a queue fill
    /// and drain. The Core ML engine is fast enough to work on ONE video while
    /// it plays, so a library fills itself in as it is watched — the verdict
    /// and the suggestion chips are there by the time the video ends. On
    /// unless switched off: it is a burst of model time per video, never per
    /// second of playback, and nothing leaves the Mac.
    ///
    /// This is the switch Settings ▸ AI shows. It gates BOTH passes
    /// (`PlayerWindow.autoClassify` and `.autoSuggest`); the right-click
    /// Classify and the tag panel's own controls are unaffected by it. Named
    /// for classification only because that is what it was when it was written
    /// with no control at all; the stored key keeps that name.
    @Published var autoWorkWhilePlaying = true { didSet { save() } }
    @Published var verifyDupes = true { didSet { save() } }
    /// Star ratings are TAGS now ("Favorite" = 5 stars, "4 Stars" … "1 Star"),
    /// so the store itself has no ratings map — see the stars MARK below. This
    /// holds a v1.1.1 library's ratings long enough for the one-time migration
    /// to turn them into tags; empty on every newer library.
    private var legacyRatings: [String: Int] = [:]
    @Published var sparedDupes: Set<String> = []

    // MARK: - hidden videos
    //
    // App-only hiding: the file is not renamed, moved, flagged or encrypted,
    // so this is a filter the app applies everywhere it would otherwise list
    // or act on a video, and nothing else. `hidden` holds share-relative keys
    // (`Paths.tagKey`), the same space tags use. See HiddenVideos.swift.

    /// The hidden set, keyed like tags. Empty on a fresh install.
    @Published private(set) var hidden: Set<String> = []

    /// The password that guards the Hidden view, and this session's answer to
    /// whether it has been given. Owned here so every view that already holds
    /// the library — the sidebar, the menu, Settings — can reach it without a
    /// fourth environment object for one feature.
    let lock = HiddenLock()

    /// What every list should apply before showing a video in ordinary
    /// browsing: hidden videos are not there. The Hidden view is the playback
    /// controller's `.hidden` mode, which applies `.only` itself — one source
    /// of truth for which list is on screen. The filter does NOT depend on the
    /// password being unlocked: a locked app still hides them, and the lock
    /// only gates revealing them.
    var hiddenFilter: HiddenFilter { .omit(hidden) }

    /// The list a view should actually show, filtered through `hiddenFilter`.
    func visible(_ paths: [String]) -> [String] { hiddenFilter.apply(to: paths) }

    func isHidden(_ path: String) -> Bool { hidden.contains(Paths.tagKey(path)) }

    /// Hide these videos. Returns how many were newly hidden, so the UI can
    /// say "3 hidden" rather than "chosen". Idempotent.
    @discardableResult
    func hide(_ paths: [String]) -> Int {
        let keys = Set(paths.map(Paths.tagKey))
        let added = keys.subtracting(hidden)
        guard !added.isEmpty else { return 0 }
        hidden.formUnion(added)
        recount()
        save()
        return added.count
    }

    /// Reveal these videos again. Tags, marks and progress were never touched,
    /// so an unhidden video comes back exactly as it was. Returns how many
    /// actually came back.
    @discardableResult
    func unhide(_ paths: [String]) -> Int {
        let keys = Set(paths.map(Paths.tagKey))
        let removed = keys.intersection(hidden)
        guard !removed.isEmpty else { return 0 }
        hidden.subtract(removed)
        recount()
        save()
        return removed.count
    }

    /// Every hidden video as an openable path. May name files that have since
    /// gone; the playlist reports a missing one the same as any other.
    func hiddenPaths() -> [String] { hidden.map(Paths.tagPath).sorted { naturalLess($0, $1) } }

    /// How many hidden videos sit under a folder — what the sidebar count
    /// subtracts so the number beside a folder matches what opening it shows.
    func hiddenCount(under root: String) -> Int {
        HiddenFilter.hiddenCount(under: root, hidden: hidden)
    }

    /// The video a Resume row may name, or nil when there is nothing safe to
    /// offer.
    ///
    /// The Resume row is in the LEFT PANEL and it PRINTS A FILE NAME, on
    /// screen while the app is locked — so offering a hidden video there would
    /// hand out exactly what the password exists to keep out of sight
    /// (hiding the video that was playing used to leave its name sitting in
    /// the sidebar). It is refused, and so is a session left by the Hidden
    /// view itself: a relaunch is locked, so there is nothing to resume into.
    ///
    /// The answer changes when the video is unhidden, because hiding is a
    /// visibility flag and nothing else — no session is burnt.
    func resumable(_ session: Session?) -> String? {
        guard let session, !session.path.isEmpty else { return nil }
        guard session.mode != PlayMode.hidden.rawValue else { return nil }
        guard !isHidden(session.path) else { return nil }
        return session.path
    }
    @Published var scans: [DupeScan] = []
    @Published var scanId: String?
    /// Tag -> group, keyed lower-case. Published so the tag list redraws when
    /// a tag is filed under a heading.
    @Published var groups: [String: String] = [:]
    private var favoritesMigrated = false
    /// Whether the readings have been moved out of the tag stores into
    /// `metadata.json`. False on any library tagged before the split — which is
    /// what `migrateMetadataFacts()` acts on — and written true the moment it
    /// has run, so the move happens once and never again.
    private var metadataSeparated = false

    // MARK: - the duplicate index
    //
    // The write is held for a few seconds rather than paid at once: a video
    // starting fingerprints itself, and writing the whole index — tens of
    // thousands of entries — in the middle of opening that video stalled the
    // window every time one did.

    @Published private(set) var prints: [String: PrintEntry] = [:]
    private var dupeCache: [String: [String]]?
    /// How many sets the index knows about, counted lazily: the menu title
    /// asks for it, and counting it on every index change was a full regroup
    /// of the index on the main thread each time a video started.
    ///
    /// Deliberately not `@Published`: the getter fills it in on first ask,
    /// and the menu reads it while being drawn — publishing from inside a
    /// view update is what SwiftUI warns about. Nothing needs the notice:
    /// `indexRevision` is published, changes with the index, and the menu
    /// redraws on that, picking up the fresh count as it goes.
    private var dupeGroupCount = 0
    private var dupeGroupCountKnown = false
    private var printsDirty = false
    private var printsSaveTask: Task<Void, Never>?
    /// The groups of the index as they were at `dupeGroupsRevision`, held so
    /// the count and `dupeSets` share one regroup instead of each doing their
    /// own. Deriving the visible sets asks for the same groups again.
    private var dupeGroupsCache: [[String]]?
    private var dupeGroupsRevision = -1

    /// Set when the tags have changed and the shares have not been told yet.
    private var tagsDirty = false
    private var autoPublish: Task<Void, Never>?
    /// The publish in flight, so the next one waits rather than writing
    /// through it. See `publishTags()`.
    var publishQueue: Task<Void, Never>?
    /// Invalidates async share work even after closing and reopening the same name.
    private(set) var profileContext = UUID()
    private var lastCatchUp: TimeInterval = 0

    /// Bumped whenever the index changes, so views deriving from it redraw.
    @Published private(set) var indexRevision = 0

    // Stat results are asked once per file per launch and kept: a NAS should
    // not be round-tripped again every time the sort changes.
    private var addedDates: [String: Double] = [:]
    private var fileSizes: [String: Int64] = [:]

    /// Keeps `lock`'s changes visible to anything observing the library.
    ///
    /// The password lives on its own object so the credential stays separate
    /// from library state, but a view that shows "Change Password…" must
    /// redraw when the password appears — and a nested `ObservableObject` is
    /// not tracked by the one above it unless the change is forwarded.
    private var lockObserver: AnyCancellable?

    init() {
        load()
        // Before anything reads a profile's files: the legacy layout becomes a
        // bundle per profile, once. After `load()` because the migration needs
        // whose profile this is — the root tag file belongs to THAT profile —
        // and before the profile's files are read. An empty name (a closed
        // profile) migrates every other profile but seeds no "active" one.
        ProfileBundle.migrateIfNeeded(
            activeProfile: person,
            names: Dictionary(uniqueKeysWithValues: profiles.map { (slug($0), $0) }),
            device: device)
        setProfileInForce(person)
        migrateMetadataFacts()
        migrateFavorites()
        migrateRatingsIntoTags()
        lockObserver = lock.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - which profile is in force

    /// Read a profile's bundle in — or establish the closed state — after the
    /// state file is known. One path for launch, close and reopen, the same
    /// reason `profileDidChange` exists.
    ///
    /// With no profile in force, `Paths.activeProfile` is "" and every
    /// per-profile path points at a stray `profiles/unknown/` bundle. The
    /// reads here are harmless — an absent file loads as empty, which IS the
    /// closed state — and the writes are guarded by `profileOpen`.
    private func setProfileInForce(_ name: String) {
        if name.isEmpty {
            profileOpen = false
            tags = [:]
            groups = [:]
            facts = MetadataFacts()
            provenance = TagProvenance.load()
            pinned = []
            recent = []
            lastPublishedAt = 0
            publishedClean = true
            recount()
            recountFacts()
            return
        }
        profileOpen = true
        // The parsing half of what loadTags did: names are re-parsed and
        // videos with none are dropped, so a hand-edited bundle cannot smuggle
        // an empty or malformed tag list into the counts.
        let stored: [String: [String]] = JSONStore.load(Paths.profileFile(name), fallback: [:])
        var clean: [String: [String]] = [:]
        for (path, names) in stored {
            let parsed = parseTags(names.joined(separator: ","))
            if !parsed.isEmpty { clean[Paths.tagKey(path)] = parsed }
        }
        tags = clean
        recount()
        loadGroups(for: name)
        provenance = TagProvenance.load()
        // An older file keyed on /Volumes paths is rewritten in place. This is
        // idempotent, so it needs no flag to remember it was done.
        if clean != stored { saveTags() }
        facts = MetadataFacts.load(at: Paths.metadataFile)
        recountFacts()
        pinned = pinnedByProfile[slug(name)] ?? []
        // Pinned folders live in Pinned only — never also in Recent.
        recent = (recentByProfile[slug(name)] ?? []).filter { !pinned.contains($0) }
        lastPublishedAt = ProfileBundle.manifest(name)?.lastPublishedAt ?? 0
        publishedClean = ProfileBundle.manifest(name)?.publishedClean ?? (lastPublishedAt == 0)
    }

    /// Fold a v1.1.1 library's star RATINGS (a map in state.json, invisible to
    /// the other devices) into star TAGS, once, at the first start with the
    /// tag-backed stars. Every mapped video gets its star tag, and anything
    /// tagged Favorite keeps it — the Favorite tag is what 5 stars IS now.
    ///
    /// Deliberately NOT gated on a persisted flag: it fires only while the
    /// state file still carries a ratings map, and the map is gone from the
    /// next save — so a second run reads nothing to migrate. Running it inside
    /// `init` is what makes every path (including a resume before onAppear)
    /// see stars that are tags, and a test library is unaffected because its
    /// state file carries no ratings unless a test writes them.
    private func migrateRatingsIntoTags() {
        guard !legacyRatings.isEmpty else { return }
        // A closed profile must not consume the map: its `saveTags` is a no-op,
        // so the star tags would be folded out of the ratings, written
        // nowhere, and the map then gone — the stars would be lost. Deferred
        // instead, so the next launch with a profile open does the fold.
        guard profileOpen else { return }
        var updated = tags
        for (key, stars) in legacyRatings {
            let name = starTag(stars)
            guard !name.isEmpty else { continue }
            var names = updated[key] ?? []
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
            updated[key] = names.isEmpty ? nil : names
        }
        tags = updated
        legacyRatings = [:]
        saveTags()
        save()
    }

    // MARK: - putting a destructive edit back
    //
    // Nothing here asks who you are. Deleting a tag or forgetting a profile is
    // a mistake anyone can make, including the person it belongs to, so the
    // protection is that mistakes are reversible rather than that they are
    // forbidden.

    /// Keep the tags as they are, before something destructive changes them.
    /// Written to disk as well, so an Undo survives a quit or a crash. The
    /// facts are kept with them: the metadata scan is one of the destructive
    /// edits, and an Undo that restored the tags but left its readings behind
    /// would be half an undo.
    func rememberForUndo(_ label: String) {
        undoable = (label, tags, facts.byKey)
        JSONStore.save(Paths.tagsBackup, tags)
        JSONStore.save(Paths.factsBackup, facts)
    }

    /// Whether there is a set on disk to go back to, from a previous run.
    var hasStoredUndo: Bool {
        FileManager.default.fileExists(atPath: Paths.tagsBackup)
    }

    /// Put back the tags as they were before the last destructive edit, and the
    /// facts with them.
    ///
    /// A snapshot taken before the split still has readings inside it — the
    /// backup on disk can be days older than the separation — so what comes back
    /// is passed through `dropKnownReadings` first: a name the fact store
    /// already holds for that same video would otherwise reappear among the
    /// tags, and the library would be half-separated again with the facts
    /// already safely in their own store.
    @discardableResult
    func undoTagChange() -> Bool {
        let previousTags: [String: [String]]
        var previousFacts: [String: [String]]?
        if let held = undoable {
            previousTags = held.tags
            previousFacts = held.facts
        } else {
            previousTags = JSONStore.load(Paths.tagsBackup, fallback: [:])
            guard !previousTags.isEmpty else { return false }
            if FileManager.default.fileExists(atPath: Paths.factsBackup) {
                previousFacts = JSONStore.load(Paths.factsBackup, fallback: [:])
            }
        }
        undoable = nil
        tags = MetadataSplit.dropKnownReadings(tags: previousTags, facts: facts)
        if let previousFacts {
            facts = MetadataFacts(previousFacts)
            saveFacts()
            tags = MetadataSplit.dropKnownReadings(tags: tags, facts: facts)
        }
        saveTags()
        try? FileManager.default.removeItem(atPath: Paths.tagsBackup)
        try? FileManager.default.removeItem(atPath: Paths.factsBackup)
        return true
    }

    // MARK: - loading and saving

    func load() {
        let state = JSONStore.load(Paths.stateFile, fallback: PersistedState())
        recent = state.recent      // replaced below once the profile is known
        progress = state.progress.filter { $0.value.isFinite }
        progressSeen = state.progressSeen
        session = state.session
        order = state.repeatMode.flatMap(PlayOrder.init(rawValue:)) ?? .all
        speed = Tuning.speeds.contains(state.speed ?? 0) ? state.speed! : Tuning.normalSpeed
        skipSeconds = Library.skipChoices.contains(state.skipSeconds ?? 0)
            ? state.skipSeconds! : Library.defaultSkip
        resumeEnabled = state.resumeEnabled ?? true
        recentLimit = min(max(state.recentLimit ?? Tuning.recentMax, 3), 20)
        favoritesMigrated = state.favoritesMigrated ?? false
        metadataSeparated = state.metadataSeparated ?? false
        // Whose tags these are. The account name is only a default — renaming
        // a Mac account should not orphan a library. An EMPTY name is not
        // missing, though: it is a closed profile (File ▸ Close Profile), and
        // it must come back closed rather than as the account name.
        person = state.person ?? NSUserName()
        // And which machine wrote them, so this Mac never fights its own TV.
        device = state.device.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(UUID().uuidString.prefix(8)).lowercased()
        // Copying Application Support to a second Mac is a normal way to move
        // in, and it would give both machines the same device id — so both
        // would write the same file on the share and each would overwrite the
        // other, which is the very thing a file per device prevents.
        let host = Library.hostIdentifier()
        if let known = state.deviceHost, known != host {
            device = String(UUID().uuidString.prefix(8)).lowercased()
        }
        deviceHost = host
        lastMerge = state.lastMerge ?? 0
        profiles = state.profiles ?? []
        recentProfiles = (state.recentProfiles ?? []).filter { !$0.isEmpty }
        hiddenProfiles = Set(state.hiddenProfiles ?? [])
        hidden = Set(state.hidden ?? [])
        if !person.isEmpty,
           !profiles.contains(where: { slug($0) == slug(person) }) { profiles.append(person) }
        askProfileAtStartup = state.askProfileAtStartup ?? true
        showThumbnails = state.thumbnails ?? true
        playlistStyle = state.playlistStyle.flatMap(PlaylistStyle.init(rawValue:)) ?? .list
        playlistWidth = min(max(state.playlistWidth ?? 320, 260), 900)
        librarySidebarWidth = state.librarySidebarWidth.map { min(max($0, 200), 600) }
        playlistSort = state.playlistSort.flatMap(PlaylistSort.init(rawValue:)) ?? .folder
        sortDescending = state.sortDescending ?? playlistSort.defaultDescending
        volume = state.volume ?? 100
        pinnedByProfile = state.pinnedByProfile ?? [:]
        // A library written before pinned folders belonged to a profile has
        // one flat list: it becomes the profile in force's, once.
        if let legacy = state.pinned, !legacy.isEmpty,
           pinnedByProfile[slug(person)] == nil {
            pinnedByProfile[slug(person)] = legacy
        }
        pinned = pinnedByProfile[slug(person)] ?? []
        // Recent belongs to the profile the same way pinned does. A library
        // written before that has one flat list, which becomes the profile in
        // force's, once — exactly the migration above.
        recentByProfile = state.recentByProfile ?? [:]
        if !state.recent.isEmpty, recentByProfile[slug(person)] == nil {
            recentByProfile[slug(person)] = state.recent
        }
        recent = recentByProfile[slug(person)] ?? []
        // Pinned folders live in Pinned only — never also in Recent.
        recent.removeAll { pinned.contains($0) }
        discardFolders = state.discardFolders ?? [:]
        // Deliberately ignores what is on disk. Nothing can switch this on any
        // more, so an old settings file saying true would leave the feature
        // running with no way to reach it. Restore the stored value here on
        // the day the control comes back.
        watchDupes = false
        facesEnabled = state.facesEnabled ?? true
        autoWorkWhilePlaying = state.autoWorkWhilePlaying ?? true
        verifyDupes = state.verifyDupes ?? true
        legacyRatings = state.ratings ?? [:]
        sparedDupes = Set(state.sparedDupes ?? [])
        scans = (state.scans ?? []).filter { !$0.id.isEmpty }
        if !scans.contains(where: { $0.id == Library.autoScanId }) {
            scans.insert(DupeScan(id: Library.autoScanId, name: "Auto Scan", folders: []), at: 0)
        }
        scanId = scans.contains { $0.id == state.scan } ? state.scan : Library.autoScanId
        suspendSaves = false
    }

    /// Set while loading, so the property observers above do not each write
    /// the file back out as they are filled in.
    private var suspendSaves = true

    func save() {
        guard !suspendSaves else { return }
        // Newest positions win; older ones age out.
        var kept = progress
        if kept.count > Tuning.progressMax {
            let order = kept.keys.sorted { (progressSeen[$0] ?? 0) > (progressSeen[$1] ?? 0) }
            for key in order.dropFirst(Tuning.progressMax) {
                kept.removeValue(forKey: key)
                progressSeen.removeValue(forKey: key)
            }
        }
        var state = PersistedState()
        state.recent = Array(recent.prefix(recentLimit))
        state.progress = kept
        state.progressSeen = progressSeen
        state.session = session
        state.repeatMode = order.rawValue
        state.speed = speed
        state.skipSeconds = skipSeconds
        state.resumeEnabled = resumeEnabled
        state.recentLimit = recentLimit
        state.favoritesMigrated = favoritesMigrated
        state.metadataSeparated = metadataSeparated
        state.person = person
        state.profiles = profiles
        state.recentProfiles = recentProfiles
        state.hiddenProfiles = hiddenProfiles.sorted()
        state.askProfileAtStartup = askProfileAtStartup
        state.device = device
        state.deviceHost = deviceHost
        state.lastMerge = lastMerge
        state.thumbnails = showThumbnails
        state.playlistStyle = playlistStyle.rawValue
        state.playlistWidth = playlistWidth
        state.librarySidebarWidth = librarySidebarWidth
        state.playlistSort = playlistSort.rawValue
        state.sortDescending = sortDescending
        state.volume = volume
        // The list in hand is this profile's; the rest are carried through.
        if !person.isEmpty { pinnedByProfile[slug(person)] = pinned }
        state.pinnedByProfile = pinnedByProfile.filter { !$0.value.isEmpty }
        state.pinned = pinned
        if !person.isEmpty { recentByProfile[slug(person)] = Array(recent.prefix(recentLimit)) }
        state.recentByProfile = recentByProfile.filter { !$0.value.isEmpty }
        state.discardFolders = discardFolders.filter { !$0.value.isEmpty }
        state.watchDupes = watchDupes
        state.facesEnabled = facesEnabled
        state.autoWorkWhilePlaying = autoWorkWhilePlaying
        state.verifyDupes = verifyDupes
        state.sparedDupes = sparedDupes.sorted()
        state.hidden = hidden.sorted()
        state.scans = scans
        state.scan = scanId
        JSONStore.save(Paths.stateFile, state)
    }

    func saveTags() {
        // A closed profile owns nothing: the tags in hand are already empty,
        // and writing them would create a stray bundle for a person that does
        // not exist. Every real path here is a tagging action, and every
        // tagging surface is disabled while closed.
        guard profileOpen else { return }
        recount()
        JSONStore.save(Paths.tagsFile, tags)
        tagsDirty = true
        publishedClean = false
        ProfileBundle.markEdited(profile: person)
        scheduleAutoPublish()
    }

    /// Read the readings off disk.
    ///
    /// **Global, not per profile** — a reading does not depend on who is
    /// looking, so this happens once at launch rather than on every profile
    /// switch the way `tags` is. An absent file is an empty store, which is
    /// every library until the scan has run once.
    /// Write the readings. Nothing is published: they are this Mac's, and the
    /// devices that share the tag file read the same values out of the same
    /// files.
    func saveFacts() {
        guard profileOpen else { return }
        recountFacts()
        facts.save(to: Paths.metadataFile)
    }

    // MARK: - the one-time separation

    /// Move the readings out of the tag stores and into the facts store, once.
    ///
    /// Runs at launch, over **every store that holds tags**: the one in hand
    /// (the root file, which is what the app is showing) and each profile's own
    /// file — a profile this session never opens would otherwise resurrect its
    /// year tags the moment it was switched to, with the flag already set and
    /// the migration never running again.
    ///
    /// Each file it rewrites is copied to `<file>.bak.<timestamp>` first. This
    /// is the one edit in the app that takes names away from the user without
    /// them asking at that moment, so it is the one edit that leaves a full copy
    /// of what it changed beside it.
    ///
    /// Gated on a persisted flag rather than on finding something to move. The
    /// rule is idempotent, so a second run would be harmless — but a user who
    /// hand-tags a video `2016` on purpose afterwards must find it still there
    /// on the next launch, and a flag is the difference between "sort out the
    /// old library" and "second-guess the new one".
    private func migrateMetadataFacts() {
        guard !metadataSeparated else { return }
        var moved = 0
        var videos = 0
        var names = Set<String>()
        func tally(_ report: MetadataSplit.Report) {
            moved += report.moved
            videos += report.videos
            names.formUnion(report.names)
        }
        // 1. the store in hand, which is also the file the shares are given
        let inHand = MetadataSplit.separate(tags: tags, provenance: provenance)
        if !inHand.isEmpty {
            backUp(Paths.tagsFile)
            tally(inHand)
            for (key, readings) in inHand.facts { facts.add(readings, to: key) }
            tags = inHand.tags
            saveTags()
        }
        // 2. every profile's own store, visited or not.
        //
        // Each profile's readings are written to ITS OWN facts file, not pooled
        // into the one in hand. They came out of that profile's tags, so that
        // is whose they are — pooling them would hand every profile every other
        // profile's scan the first time it was opened.
        for (slug, file) in unsavedProfileTagFiles() {
            let stored: [String: [String]] = JSONStore.load(file, fallback: [:])
            let report = MetadataSplit.separate(tags: stored, provenance: provenance)
            guard !report.isEmpty else { continue }
            backUp(file)
            tally(report)
            JSONStore.save(file, report.tags)
            var theirs = MetadataFacts.load(at: Paths.profileFactsFile(slug))
            for (key, readings) in report.facts { theirs.add(readings, to: key) }
            theirs.save(to: Paths.profileFactsFile(slug))
        }
        metadataSeparated = true
        save()
        saveFacts()
        guard moved > 0 else { return }
        let summary = MetadataSplit.Summary(date: Date(), moved: moved, videos: videos,
                                            names: names.sorted())
        summary.save()
        // In memory too, not only on disk: the first launch after the separation
        // is exactly when the app has something to say, and that launch read the
        // file before it existed.
        separationReport = summary
    }

    /// Every OTHER profile's tag file, so the move reaches a profile this
    /// session never opens. Read from the directory rather than from the
    /// remembered profile list: a bundle in there is a profile holding tags.
    ///
    /// The profile in force is left out because its tags came off disk already
    /// and are handled above, in hand — and because writing its bundle's file
    /// here would race the `saveTags()` that follows. With nothing open there
    /// is no profile in force, so no file is left out and no in-hand save
    /// races anything.
    private func unsavedProfileTagFiles() -> [(slug: String, path: String)] {
        let mine = profileOpen ? slug(person) : nil
        return ProfileBundle.slugs()
            .filter { $0 != mine }
            .map { ($0, Paths.profileFile($0)) }
    }

    /// A full copy of a store before the separation rewrites it, named with the
    /// minute it happened. Never overwrites an earlier copy.
    private func backUp(_ path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let stamp = Library.backupStamp.string(from: Date())
        var target = "\(path).bak.\(stamp)"
        var attempt = 2
        while fm.fileExists(atPath: target) {
            target = "\(path).bak.\(stamp)-\(attempt)"
            attempt += 1
        }
        try? fm.copyItem(atPath: path, toPath: target)
    }

    private static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }()

    /// Leave the tags on the shares shortly after they stop changing.
    ///
    /// The Apple TV has no Publish button because it saves as it goes, and a
    /// Mac that only published at launch meant tagging an afternoon's worth
    /// and having none of it reach the other device until a relaunch. Held for
    /// a few seconds so that tagging twenty videos is one write per share
    /// rather than twenty.
    func scheduleAutoPublish() {
        // The hold exists to batch tag edits; with no profile open there is
        // nothing to publish and the guard keeps the timer from waking a
        // publish into an empty profile.
        guard profileOpen else { return }
        autoPublish?.cancel()
        autoPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.publishIfNeeded()
        }
    }

    /// Publish, and take in whatever the other devices have said. Silent: a
    /// NAS asleep, unplugged or mounted read-only is a normal Tuesday.
    func publishIfNeeded() async {
        guard tagsDirty, profileOpen else { return }
        let context = profileContext
        let outcome = await publishTags()
        guard context == profileContext else { return }
        // Only counted as done when a share actually took it, so a NAS that
        // was asleep is tried again rather than quietly skipped for good.
        if !outcome.written.isEmpty, outcome.skipped.isEmpty, publishedClean { tagsDirty = false }
    }

    /// Catch up with the other devices, at most this often. Called when the
    /// app comes to the front, which is when a share is most likely to have
    /// just been mounted or another device to have just finished tagging.
    func catchUpWithOtherDevices(minimumGap: TimeInterval = 60) async {
        let now = Date().timeIntervalSince1970
        guard now - lastCatchUp > minimumGap else { return }
        lastCatchUp = now
        _ = await mergeShared()
        await publishIfNeeded()
    }

    /// A last push on the way out, for changes the hold above has not reached
    /// yet. Best effort and off the main thread's critical path.
    func publishOnQuit() {
        guard tagsDirty, profileOpen else { return }
        _ = Library.write(shareTags(), as: myTagFile)
    }

    /// Derive everything the views ask about tags, in one pass.
    private    func recount() {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        // A hidden video is invisible to the app, so it must not prop up a
        // tag's count either — otherwise the chip says "12" and lists 9.
        for (key, names) in tags where !hidden.contains(key) {
            for name in names {
                let key = name.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = name }
            }
        }
        tagDisplay = display
        tagCounts = Dictionary(uniqueKeysWithValues: counts.compactMap { key, count in
            display[key].map { ($0, count) }
        })
        popular = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .compactMap { display[$0.key] }
        sortedTags = display.keys.sorted().compactMap { display[$0] }
        // Facts are counted here as well, so every path that already recounts
        // tags — a save, a profile switch, a video hidden — keeps the fact
        // counts in step without a second call at each site.
        recountFacts()
    }

    /// Derive what the views ask about facts, one pass per change.
    ///
    /// Deliberately its own pass into its own published properties: folding a
    /// fact into `tagCounts` is the confusion this whole split removes, and a
    /// view that wants both asks for both.
    private func recountFacts() {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        // A hidden video is invisible to the app, so it must not prop up a
        // fact's count either — the same rule as a tag's, for the same reason.
        //
        // Walked in key order so that when one name appears in two spellings,
        // the one the sidebar shows is settled by the first video
        // alphabetically rather than by dictionary order, which would change
        // between launches for no visible reason.
        for key in facts.byKey.keys.sorted() where !hidden.contains(key) {
            for name in facts.byKey[key] ?? [] {
                let folded = name.lowercased()
                counts[folded, default: 0] += 1
                if display[folded] == nil { display[folded] = name }
            }
        }
        factCounts = Dictionary(uniqueKeysWithValues: counts.compactMap { key, count in
            display[key].map { ($0, count) }
        })
        sortedFacts = display.keys.sorted().compactMap { display[$0] }
    }

    // MARK: - tags

    func tagsFor(_ path: String) -> [String] { tags[Paths.tagKey(path)] ?? [] }

    func setTags(_ names: [String], for path: String) {
        // The backstop behind the disabled surfaces: a closed profile is not
        // a person, so nothing they own accepts a tag. Everything visible is
        // disabled while closed (plan §8); this is what a hot key or a stale
        // menu state would otherwise reach.
        guard profileOpen else { return }
        let key = Paths.tagKey(path)
        if names.isEmpty { tags.removeValue(forKey: key) } else { tags[key] = names }
    }

    /// Re-point a file's library references at its new location — the
    /// moved-video scan's repair, and the carry behind FileOps' moves. Tags
    /// carry over — the stars among them, because stars are tags. Tags on the
    /// destination (a same-named file already tagged) merge in rather than
    /// being overwritten. One undoable edit covers a whole scan's repairs.
    @discardableResult
    func moveTags(from oldPath: String, to newPath: String) -> Bool {
        let from = Paths.tagKey(oldPath)
        let to = Paths.tagKey(newPath)
        // The readings travel with the tags. Every caller that re-points a file
        // — `MovedScan`'s repair and FileOps' moves — comes through here, so a
        // move is handled in one place, and a re-nested folder cannot silently
        // drop the date off a file that never changed.
        let carried = moveFacts(from: oldPath, to: newPath)
        guard let moving = tags[from], !moving.isEmpty else { return carried }
        defer { saveTags() }
        // The destination may already carry tags of its own (a same-named
        // file tagged on this Mac): they lead, the movers join, and a tag
        // already there is not added twice — case-insensitively.
        var kept = tags[to] ?? []
        for name in moving
        where !kept.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            kept.append(name)
        }
        tags[to] = kept
        tags.removeValue(forKey: from)
        return true
    }

    /// Drop one tag reference entirely — a file that is gone for good. The
    /// scan's "remove reference"; always inside an undoable edit.
    @discardableResult
    func forgetPath(_ path: String) -> Bool {
        let key = Paths.tagKey(path)
        // A file gone for good takes its readings with it.
        forgetFacts(path)
        guard tags[key] != nil else { return false }
        tags.removeValue(forKey: key)
        saveTags()
        return true
    }

    func hasTag(_ path: String, _ tag: String) -> Bool {
        tagsFor(path).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    func taggedWith(_ tag: String) -> [String] {
        tags.filter { key, names in
            !hidden.contains(key)
                && names.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }.keys.map(Paths.tagPath).sorted { naturalLess($0, $1) }
    }

    /// Every tag in use, case-insensitively unique, alphabetical.
    func knownTags() -> [String] { sortedTags }

    /// Every tag in use EXCEPT the five star marks — the vocabulary the
    /// generic tag lists offer. Stars have their own sidebar section and
    /// their own rating controls, so a star tag among the ordinary chips
    /// would offer the same fact twice on one screen.
    func assignableTags() -> [String] { sortedTags.filter { !isStarTag($0) } }

    /// The tags a human is OFFERED to apply by hand.
    ///
    /// Metadata tags are excluded. `2016`, `May 2016`, `iPhone 7`, `1080p`,
    /// `Singapore` written from GPS — these are read off the file, and the
    /// scan is the only thing entitled to write them. Offering them as chips
    /// invites a hand-applied `2016` on a clip shot in 2017, which is not a
    /// tag but a false statement about the file, and one nothing downstream
    /// can tell from the real thing.
    ///
    /// They remain fully browsable: the sidebar's Years section, the tag
    /// profiles window and every filter still list them, because finding your
    /// 2016 clips is exactly what they are for. This governs one question
    /// only — what a person may stick onto a video themselves.
    ///
    /// Library-wide rather than per video (`isMetadataTagAnywhere`): a tag the
    /// scan writes anywhere is the scan's to write everywhere, so the chip
    /// list does not flicker between videos depending on which ones have been
    /// scanned yet.
    ///
    /// Since the split this filter is belt and braces rather than the mechanism:
    /// a reading lives in its own store and never reaches `assignableTags()` at
    /// all. It still catches a tag from a library that has not been separated
    /// yet — and the one case the store cannot: a name the user typed that the
    /// old scan had also written, whose provenance record long outlives it.
    func handTaggableTags() -> [String] {
        assignableTags().filter { !provenance.isMetadataTagAnywhere($0) }
    }

    /// Record that the metadata scan produced these tags for this video, and
    /// save. Called only by `MetadataTagger.apply` — the ONE place in the app
    /// that writes tags without a model having an opinion.
    func recordMetadataTags(_ names: [String], for path: String) {
        provenance.recordMetadata(names, on: Paths.tagKey(path))
    }

    func saveProvenance() { provenance.save() }

    /// The tags in use, most-used first — what the tag panel offers as chips.
    func popularTags() -> [String] { popular }

    /// How many videos carry this tag, without walking them again.
    func count(of tag: String) -> Int { tagCounts[tag] ?? 0 }

    // MARK: - the facts read off the files
    //
    // A second store, with a deliberately smaller surface than `tags`. Nothing
    // here trains, files under a heading, sorts a playlist or gets suggested;
    // the metadata scan is the only thing that writes one, and the sidebar, the
    // filter and the tag panel are the only things that read one.
    //
    // The point of the split is in what is NOT here: there is no
    // `factsToTrainFrom`, no fact in `popularTags()`, no fact in the hand-tag
    // chips. See `MetadataFacts` for the reasoning.

    func factsFor(_ path: String) -> [String] { facts.names(for: Paths.tagKey(path)) }

    func hasFact(_ path: String, _ name: String) -> Bool {
        facts.has(name, on: Paths.tagKey(path))
    }

    func setFacts(_ names: [String], for path: String) {
        guard profileOpen else { return }
        facts.set(names, for: Paths.tagKey(path))
    }

    /// Add readings without disturbing the ones already there.
    func addFacts(_ names: [String], for path: String) {
        guard profileOpen else { return }
        facts.add(names, to: Paths.tagKey(path))
    }

    /// How many videos carry this fact, without walking them again.
    func factCount(of name: String) -> Int { factCounts[name] ?? 0 }

    /// The fact vocabulary, alphabetical.
    func factsInUse() -> [String] { sortedFacts }

    /// Every video carrying this fact.
    func factsWith(_ name: String) -> [String] { facts.carrying(name) }

    /// The fact vocabulary in the order the sidebar draws it: Date with the
    /// newest year first and a month filed under nothing but its own year
    /// (as the Years section has always read), then the other kinds
    /// alphabetically. Kinds with nothing in them are absent rather than empty.
    ///
    /// `TagKinds.kind(ofFact:)` decides the kind, so this invents no vocabulary
    /// of its own: a quality mark arrives under Camera & Quality, a date under
    /// Date, and whatever the scan read out of a file that is neither is a
    /// Place.
    func factsByKind() -> [(kind: String, names: [String])] {
        var kinds: [String: [String]] = [:]
        for name in sortedFacts { kinds[TagKinds.kind(ofFact: name), default: []].append(name) }
        // Date first, then the rest as the sidebar's heading order has them.
        let order = [TagKinds.when, TagKinds.camera, TagKinds.place]
        return order.compactMap { kind in
            guard var names = kinds[kind], !names.isEmpty else { return nil }
            if kind == TagKinds.when {
                names.sort { factsDateRank($0) > factsDateRank($1) }
            } else {
                names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            return (kind, names)
        }
    }

    /// `2026` → 202612, `May 2016` → 201605, anything undated → 0. Enough to put
    /// a newest-first list in order without a second date parser.
    private func factsDateRank(_ name: String) -> Int {
        let year = AutoTagCore.yearIn(name) ?? 0
        guard year > 0 else { return 0 }
        let month = AutoTagCore.monthIn(name) ?? 12
        return year * 100 + month
    }

    /// Everything the app knows this video by: its tags, then the readings off
    /// it.
    ///
    /// THE accessor for "is this video one of the ones I mean" — the filter
    /// matches through it, the playlist's tag strip is built from it, and a row
    /// shows its chips from it. That is what keeps a fact exactly as findable as
    /// it was while the two stores stay apart: finding your 2016 clips is the
    /// whole reason the date is on them.
    func carries(_ path: String) -> [String] {
        let names = factsFor(path)
        guard !names.isEmpty else { return tagsFor(path) }
        var all = tagsFor(path)
        for name in names
        where !all.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            all.append(name)
        }
        return all
    }

    /// Every video carrying this name, whether it is a tag or a reading.
    ///
    /// `facts.carrying` answers in STORE KEYS, the way the tags dictionary is
    /// keyed; `taggedWith` answers in real paths. Mixing the two silently
    /// yields a playlist of half-paths that plays nothing, so the keys are put
    /// through `Paths.tagPath` on the way in. Hidden videos are dropped here
    /// too — `taggedWith` already drops them, and a reading must not be the
    /// thing that smuggles a hidden video into a playlist.
    func pathsCarrying(_ name: String) -> [String] {
        var paths = Set(taggedWith(name))
        for key in facts.carrying(name) where !hidden.contains(key) {
            paths.insert(Paths.tagPath(key))
        }
        return paths.sorted { naturalLess($0, $1) }
    }

    /// How many videos carry this name, tag or fact — what a sidebar row's
    /// count means, so a fact row and a tag row count the same way.
    func count(anyName name: String) -> Int {
        tagCounts[name] ?? factCounts[name] ?? 0
    }

    /// Put a fact's name right everywhere it appears — a wrong camera model or
    /// a place name the phone guessed, corrected by hand. Only the facts store
    /// is touched: a tag of the same name is the user's and is left alone.
    func renameFact(_ old: String, to new: String) {
        facts.rename(old, to: new)
        saveFacts()
    }

    /// Take a fact off every video carrying it. The videos, their tags and
    /// their files are untouched.
    func deleteFact(_ name: String) {
        facts.remove(name)
        saveFacts()
    }

    /// Carry a video's readings across a move or a repair, so re-nesting a
    /// folder does not silently drop the date off a file that never changed.
    @discardableResult
    func moveFacts(from oldPath: String, to newPath: String) -> Bool {
        let from = Paths.tagKey(oldPath)
        let to = Paths.tagKey(newPath)
        guard !facts.names(for: from).isEmpty else { return false }
        facts.move(from: from, to: to)
        saveFacts()
        return true
    }

    /// Forget one video's readings entirely — a file gone for good.
    @discardableResult
    func forgetFacts(_ path: String) -> Bool {
        let key = Paths.tagKey(path)
        guard !facts.names(for: key).isEmpty else { return false }
        facts.forget(key)
        saveFacts()
        return true
    }

    func applyTags(_ names: [String], to paths: [String]) {
        guard profileOpen else { return }
        var updated = tags
        for path in paths { updated[Paths.tagKey(path)] = names.isEmpty ? nil : names }
        tags = updated
        saveTags()
    }

    /// Take a tag off a run of videos as ONE undoable edit.
    ///
    /// The destructive direction, paired with `addTag`, and the reason the two
    /// are separate functions rather than one toggle: the undo record is one
    /// slot, so a click that takes
    /// a tag off must record ONCE for the whole gesture rather than once per
    /// video inside a loop — the last call would win and the rest of the
    /// removal would be unrecorded. `label` names the edit on the Undo button.
    ///
    /// Records nothing when nothing actually changes: a click on a tag the
    /// videos do not carry must not spend the undo slot on a no-op, or the
    /// Undo button offers to undo a change that never happened and the real
    /// last edit is lost behind it.
    ///
    /// Returns how many videos were changed.
    @discardableResult
    func removeTag(_ name: String, from paths: [String], label: String? = nil) -> Int {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The closed backstop, like `setTags`: nothing removes a tag from a
        // profile that is not open.
        guard profileOpen, !cleaned.isEmpty, !paths.isEmpty else { return 0 }
        var updated = tags
        var changed = 0
        for path in paths {
            let key = Paths.tagKey(path)
            guard let names = updated[key] else { continue }
            let kept = names.filter { $0.caseInsensitiveCompare(cleaned) != .orderedSame }
            if kept.count != names.count {
                updated[key] = kept.isEmpty ? nil : kept
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        rememberForUndo(label ?? (changed == 1
                                  ? "taking “\(cleaned)” off"
                                  : "taking “\(cleaned)” off \(changed) videos"))
        tags = updated
        saveTags()
        return changed
    }

    /// Tag a run of videos, ADDING to whatever each one already carries —
    /// the bulk-tag action ("tag every video in this folder Holiday").
    /// Deliberately not a toggle: a toggle over a folder where some videos
    /// already carry the tag would REMOVE it from those, the opposite of what
    /// the user asked for. Adding is idempotent and case-insensitive, and the
    /// whole folder is one write to the store, not one per video — `tags` is
    /// published, so per-video writes would tell every view a thousand times.
    ///
    /// Returns how many videos were changed, for the report.
    @discardableResult
    func addTag(_ name: String, to paths: [String]) -> Int {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profileOpen, !cleaned.isEmpty, !paths.isEmpty else { return 0 }
        var updated = tags
        var changed = 0
        for path in paths {
            let key = Paths.tagKey(path)
            var names = updated[key] ?? []
            if !names.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                names.append(cleaned)
                updated[key] = names
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        tags = updated
        saveTags()
        return changed
    }

    // MARK: - stars

    /// Star ratings are tags: the Favorite tag is 5 stars (the Apple TV
    /// favourites with it), and "4 Stars" … "1 Star" carry the rest. One
    /// store, so sharing, publishing, filtering, bulk-tag, folder tagging and
    /// a moved file's carry all work for the stars with no second bookkeeping.
    ///
    /// The functions below are the shim the views already speak — they read
    /// and write the star TAGS, and every tag function applies unchanged.

    /// The ratings a video can carry. Unrated is `0`, never stored.
    static let starValues = [1, 2, 3, 4, 5]

    /// A video's stars, 0–5 — the strongest star tag it carries. Zero means
    /// unrated. (Rating and clearing are exclusive by construction; a video
    /// hand-tagged with two star tags shows the better of the two.)
    func rating(_ path: String) -> Int {
        for stars in [5, 4, 3, 2, 1] where hasTag(path, starTag(stars)) { return stars }
        return 0
    }

    /// Rate one video.
    func setRating(_ stars: Int, for path: String) {
        setRating(stars, for: [path])
    }

    /// Rate a run of videos — the playlist selection, or a whole folder. One
    /// write to the store. Zero clears: the star tags come off. A video that
    /// carried a different star tag is re-tagged, not doubled up.
    func setRating(_ stars: Int, for paths: [String]) {
        let clamped = min(max(stars, 0), 5)
        var updated = tags
        for path in paths {
            let key = Paths.tagKey(path)
            var names = updated[key] ?? []
            names.removeAll { isStarTag($0) }
            if clamped > 0 { names.append(starTag(clamped)) }
            updated[key] = names.isEmpty ? nil : names
        }
        tags = updated
        saveTags()
    }

    /// Every video carrying a given star rating, best first (5 down to 1),
    /// share-relative like tags. The playlist behind a Stars row.
    func rated(_ stars: Int) -> [String] {
        guard (1...5).contains(stars) else { return [] }
        return taggedWith(starTag(stars))
    }

    /// How many videos carry a given rating — the Stars row's count.
    func countRated(_ stars: Int) -> Int {
        guard (1...5).contains(stars) else { return 0 }
        return count(of: starTag(stars))
    }

    func renameTag(_ old: String, to new: String) {
        rememberForUndo("renaming “\(old)”")
        for (key, names) in tags {
            guard names.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame })
            else { continue }
            var renamed = names.map { $0.caseInsensitiveCompare(old) == .orderedSame ? new : $0 }
            renamed = parseTags(renamed.joined(separator: ","))
            tags[key] = renamed.isEmpty ? nil : renamed
        }
        // The group is filed under the tag's own name, so it has to move with
        // it or a renamed tag silently falls out of its heading.
        if let g = groups.removeValue(forKey: old.lowercased()) {
            groups[new.lowercased()] = g
            saveGroups()
        }
        saveTags()
    }

    func deleteTag(_ name: String) {
        rememberForUndo("deleting “\(name)”")
        for (key, names) in tags {
            let kept = names.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
            if kept.count != names.count { tags[key] = kept.isEmpty ? nil : kept }
        }
        groups.removeValue(forKey: name.lowercased())
        saveGroups()
        saveTags()
    }

    /// Fold several tags into one.
    ///
    /// Rename cannot do this: renaming "Iceland trip" to "Iceland" on a video
    /// that already carries "Iceland" would leave it holding the tag twice.
    /// Merging de-duplicates as it goes, so near-identical tags collected over
    /// years can be collapsed without hand-editing every video.
    ///
    /// Returns how many videos were touched.
    @discardableResult
    func mergeTags(_ sources: [String], into target: String) -> Int {
        let doomed = sources.filter { $0.caseInsensitiveCompare(target) != .orderedSame }
        guard !doomed.isEmpty else { return 0 }
        rememberForUndo(doomed.count == 1
                        ? "merging “\(doomed[0])” into “\(target)”"
                        : "merging \(doomed.count) tags into “\(target)”")
        var touched = 0
        for (key, names) in tags {
            guard names.contains(where: { name in
                doomed.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }) else { continue }
            var kept = names.filter { name in
                !doomed.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
            // The target may already be there — that is the whole point of
            // merging rather than renaming, so it must not be added twice.
            if !kept.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
                kept.append(target)
            }
            tags[key] = kept.isEmpty ? nil : kept
            touched += 1
        }
        // A merged-away tag takes its group membership with it; the target
        // keeps whatever group it already had.
        for name in doomed { groups.removeValue(forKey: name.lowercased()) }
        saveGroups()
        saveTags()
        return touched
    }

    // MARK: - tag groups

    /// What kind of thing a tag names — Place, Person, Event, and so on.
    ///
    /// Kept beside the tags rather than inside them: a tag is a plain word the
    /// user typed, and burying "Place/" in it would change what gets published
    /// to the other devices and what the engine trains on.
    func group(of tag: String) -> String? { groups[tag.lowercased()] }

    func setGroup(_ group: String?, for tags: [String]) {
        guard profileOpen else { return }
        for tag in tags {
            if let group, !group.isEmpty { groups[tag.lowercased()] = group }
            else { groups.removeValue(forKey: tag.lowercased()) }
        }
        saveGroups()
    }

    /// Every group in use, alphabetical. The ungrouped are not a group.
    func knownGroups() -> [String] { Set(groups.values).sorted() }

    /// Tags under each group, plus everything not yet sorted — what the tag
    /// list shows when it is grouped rather than flat.
    func tagsByGroup() -> [(group: String?, tags: [String])] {
        var out: [String: [String]] = [:]
        var loose: [String] = []
        for tag in knownTags() {
            if let g = group(of: tag) { out[g, default: []].append(tag) } else { loose.append(tag) }
        }
        var rows: [(group: String?, tags: [String])] =
            out.keys.sorted().map { ($0, out[$0]!.sorted()) }
        if !loose.isEmpty { rows.append((nil, loose.sorted())) }
        return rows
    }

    /// This profile's headings, adopting the old shared file once.
    ///
    /// Headings used to live in one file every profile read. A library written
    /// before they belonged to a profile has that file, and it becomes the
    /// filing of the profile in force — the same migration the pinned folders
    /// and the recent folders get. It is READ and never written, so a second
    /// profile finds its own (empty) filing rather than inheriting somebody
    /// else's a second time.
    private func loadGroups(for profile: String? = nil) {
        let who = profile ?? person
        let mine = Paths.tagGroupsFile(in: who)
        if FileManager.default.fileExists(atPath: mine) {
            groups = JSONStore.load(mine, fallback: [:])
            return
        }
        let shared: [String: String] = JSONStore.load(Paths.sharedTagGroupsFile, fallback: [:])
        if !shared.isEmpty, slug(who) == slug(person) {
            groups = shared
            saveGroups(for: who)
        } else {
            groups = [:]
        }
    }

    private func saveGroups(for profile: String? = nil) {
        let who = profile ?? person
        // The closed state owns nothing, so it writes nothing — not even an
        // empty headings file into the stray bundle its slug would name.
        guard !who.isEmpty else { return }
        // `ensure` rather than a bare `createDirectory`: a profile's folder is
        // now a document, so the first write to one also gives it a manifest —
        // otherwise a profile made here would be a bundle the File menu could
        // not describe. Idempotent, and it never rewrites an existing manifest.
        ProfileBundle.ensure(profile: who, name: who, device: device)
        JSONStore.save(Paths.tagGroupsFile(in: who), groups)
    }

    /// Tags whose every video has gone missing — what Tag Profiles cleans up.
    ///
    /// One question to the disk per tagged video, so it is asked off the main
    /// thread and only when the window that shows it opens.
    func orphanedTags() async -> [String] {
        let entries = tags
        let names = knownTags()
        return await Task.detached(priority: .utility) { () -> [String] in
            var alive: Set<String> = []
            for (key, tagged) in entries
            where FileManager.default.fileExists(atPath: Paths.tagPath(key)) {
                alive.formUnion(tagged.map { $0.lowercased() })
            }
            return names.filter { !alive.contains($0.lowercased()) }
        }.value
    }

    func clearOrphans() async -> Int {
        rememberForUndo("clearing orphaned tags")
        let entries = tags
        let gone = await Task.detached(priority: .utility) { () -> [String] in
            entries.keys.filter { !FileManager.default.fileExists(atPath: Paths.tagPath($0)) }
        }.value
        guard !gone.isEmpty else { return 0 }
        var updated = tags
        for key in gone { updated.removeValue(forKey: key) }
        tags = updated
        saveTags()
        return gone.count
    }

    /// Fold an older version's favorites.json into the Favorite tag. Runs once,
    /// unprompted. The file is left where it is: it costs nothing to keep and
    /// it is the obvious thing to restore from.
    private func migrateFavorites() {
        guard !favoritesMigrated,
              FileManager.default.fileExists(atPath: Paths.favoritesFile) else { return }
        let starred: [String] = JSONStore.load(Paths.favoritesFile, fallback: [])
        var moved = 0
        for path in starred where !hasTag(path, favoriteTag) {
            setTags(tagsFor(path) + [favoriteTag], for: path)
            moved += 1
        }
        favoritesMigrated = true
        if moved > 0 { saveTags() }
        save()
    }

    // MARK: - resume positions

    func note(position: Double, total: Double, for path: String) {
        // Only the middle of a video is worth remembering: at either end the
        // right thing to do next time is start from the beginning.
        let finished = total > 0 && position > total - Tuning.resumeTail
        if !resumeEnabled || position < Tuning.resumeMin || finished {
            progress.removeValue(forKey: path)
            progressSeen.removeValue(forKey: path)
        } else {
            progress[path] = position
            progressSeen[path] = Date().timeIntervalSince1970
        }
    }

    func resumePoint(_ path: String) -> Double { progress[path] ?? 0 }

    func remember(folder root: String) {
        // Pinned folders stay out of Recent: one sidebar entry each.
        guard !isPinned(root) else { return }
        recent.removeAll { $0 == root }
        recent.insert(root, at: 0)
        recent = Array(recent.prefix(Tuning.recentMax))
        save()
    }

    func forget(folder root: String) {
        recent.removeAll { $0 == root }
        save()
    }

    // MARK: - pinned folders

    /// Pin a folder so it stays in the sidebar whatever Recent does. The
    /// most recent folder pins itself — the one you are looking at is the
    /// one you are most likely to want back.
    func pin(folder root: String) {
        guard !isPinned(root) else { return }
        pinned.insert(root, at: 0)
        recent.removeAll { $0 == root }   // pinned folder leaves Recent
        save()
    }

    func unpin(folder root: String) {
        pinned.removeAll { $0 == root }
        save()
    }

    func isPinned(_ root: String) -> Bool { pinned.contains(root) }

    /// Drag-reorder: move a pinned folder onto another row's position,
    /// clamped like the test table expects. Pure so the tests can table it.
    static func reordered(_ items: [String], from: Int, to: Int) -> [String] {
        guard items.indices.contains(from), !items.isEmpty else { return items }
        var out = items
        let moved = out.remove(at: from)
        let dest = min(max(to, 0), out.count)
        out.insert(moved, at: dest)
        return out
    }

    func movePinned(from: Int, to: Int) {
        pinned = Self.reordered(pinned, from: from, to: to)
        save()
    }

    // MARK: - stat caches

    /// When this video joined the collection, and how big it is — as already
    /// known, and zero if nobody has asked yet.
    ///
    /// Deliberately no stat here. These are read while rows are drawn, and a
    /// stat is an SMB round trip: a share that has gone to sleep answers its
    /// first one in seconds, with the window frozen behind it. `stats(for:)`
    /// and `warmStats` do the asking, off the main thread.
    func addedOn(_ path: String) -> Double { addedDates[path] ?? 0 }
    func fileSize(_ path: String) -> Int64 { fileSizes[path] ?? 0 }

    /// Every video whose date is ALREADY known, for `NeighbourPrior`.
    ///
    /// Two obligations live here rather than in the prior, and both are pinned
    /// by `Tests/test_neighbour_prior.swift`:
    ///
    /// - **Never stats.** This reads the warm cache only. Building a
    ///   neighbourhood out of `stats(for:)` would be one SMB round trip per
    ///   neighbour, on every video change, on a share that may be asleep —
    ///   the spinning-wheel class of bug the performance notes exist to
    ///   document. A cold cache yields a small pool or none, the prior then
    ///   declines to have an opinion, and the suggester ranks exactly as it
    ///   does today. That is the right trade: a suggestion is a convenience,
    ///   a frozen window is not.
    /// - **Hidden videos are dropped here.** Nothing hidden is counted, listed
    ///   or trained on, and a hidden video quietly supporting a tag would be a
    ///   door into the hidden set that opens without the password.
    ///
    /// Keyed by path, like `addedDates` itself, so the caller's `tagsFor` can
    /// be handed the same key without a second conversion.
    func datedPool() -> [(key: String, when: Double)] {
        addedDates.compactMap { path, when in
            guard when > 0, !isHidden(path) else { return nil }
            return (path, when)
        }
    }

    /// The two columns for one row, stat-ing it off the main thread if this is
    /// the first time anyone has asked. Called by a row as it appears.
    func stats(for path: String) async -> (date: String, size: String) {
        if let when = addedDates[path], let size = fileSizes[path] {
            return (dateText(when), humanSize(size))
        }
        let values = await Task.detached(priority: .utility) { () -> (Double, Int64) in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let created = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let changed = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (created > 0 ? created : changed,
                    (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }.value
        addedDates[path] = values.0
        fileSizes[path] = values.1
        return (dateText(values.0), humanSize(values.1))
    }

    func sizeText(_ path: String) -> String { humanSize(fileSize(path)) }

    /// Stat a list of files off the main thread and keep the answers.
    ///
    /// Date Added and File Size sort on a stat apiece, and asking for a
    /// thousand of them from the main thread is a thousand SMB round trips
    /// with the window frozen behind them. Eight at a time, off the actor,
    /// then handed back in one go.
    func warmStats(_ paths: [String]) async {
        let cold = paths.filter { addedDates[$0] == nil || fileSizes[$0] == nil }
        guard !cold.isEmpty else { return }
        let measured = await Task.detached(priority: .utility) { () -> [String: (Double, Int64)] in
            var out: [String: (Double, Int64)] = [:]
            await withTaskGroup(of: (String, Double, Int64).self) { group in
                var next = cold.makeIterator()
                var running = 0
                func add() {
                    guard let path = next.next() else { return }
                    running += 1
                    group.addTask {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                        let created = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        let changed = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        return (path, created > 0 ? created : changed, size)
                    }
                }
                for _ in 0..<8 { add() }
                while let (path, when, size) = await group.next() {
                    out[path] = (when, size)
                    running -= 1
                    add()
                }
            }
            return out
        }.value
        for (path, values) in measured {
            addedDates[path] = values.0
            fileSizes[path] = values.1
        }
    }
    func dateColumn(_ path: String) -> String { dateText(addedOn(path)) }

    /// The list in the order the current sort calls for. Folder Order is the
    /// order the scan found it in, so nothing moves; the others sort the whole
    /// list flat the way Finder sorts a column. The name always breaks ties,
    /// and a file we know nothing about sinks to the end rather than leading a
    /// list it has no business leading.
    func sorted(_ items: [String]) -> [String] {
        guard playlistSort != .folder else { return items }
        // Decorate, sort, undecorate. The name key is what the comparison
        // actually works on and it is built once per path: rebuilding it
        // inside every comparison cost 254ms on five thousand videos, which
        // is a visibly frozen window.
        let keys = items.map { path -> ([Either], Double, String) in
            let name = naturalParts((path as NSString).lastPathComponent)
            switch playlistSort {
            case .date: return (name, addedOn(path), path)
            case .size: return (name, Double(fileSize(path)), path)
            default: return (name, 0, path)
            }
        }
        let descending = sortDescending
        if playlistSort == .name {
            return keys.sorted {
                descending ? naturalLess($1.0, $0.0) : naturalLess($0.0, $1.0)
            }.map(\.2)
        }
        // Newest or largest first when descending, but a file whose stat never
        // came back sinks to the end either way rather than leading a list it
        // has no business leading.
        return keys.sorted { a, b in
            if (a.1 <= 0) != (b.1 <= 0) { return b.1 <= 0 }
            if a.1 != b.1 { return descending ? a.1 > b.1 : a.1 < b.1 }
            return naturalLess(a.0, b.0)
        }.map(\.2)
    }

    // MARK: - the duplicate index

    func loadPrints() {
        prints = JSONStore.load(Paths.fingerprintFile, fallback: [:])
        dupesChanged()
    }

    /// The index on disk, held a moment so a run of starts is one write.
    /// Flushes on quit, so nothing is lost by waiting.
    func savePrints() {
        printsDirty = true
        printsSaveTask?.cancel()
        printsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.flushPrints()
        }
    }

    /// Write the index now, if it has changed. Called on quit; safe to call
    /// any time.
    func flushPrints() {
        printsSaveTask?.cancel()
        printsSaveTask = nil
        guard printsDirty else { return }
        printsDirty = false
        if prints.count > Tuning.fpMax {
            // Oldest first. An index is a convenience, not a record, so it is
            // allowed to forget rather than grow without limit.
            let order = prints.keys.sorted { (prints[$0]?.seen ?? 0) < (prints[$1]?.seen ?? 0) }
            for key in order.prefix(prints.count - Tuning.fpMax) {
                prints.removeValue(forKey: key)
            }
        }
        JSONStore.saveCompact(Paths.fingerprintFile, prints)
    }

    /// The duplicate groups of the live index, kept against the revision that
    /// produced them. One regroup serves the menu count, the playlist's dupe
    /// chips and the finder's derivation.
    func dupeGroups() -> [[String]] {
        if let cached = dupeGroupsCache, dupeGroupsRevision == indexRevision {
            return cached
        }
        let groups = Fingerprints.duplicateGroups(prints)
        dupeGroupsCache = groups
        dupeGroupsRevision = indexRevision
        return groups
    }

    /// Drop one entry — a copy that has just been discarded.
    func forgetPrint(_ key: String) {
        prints.removeValue(forKey: key)
    }

    func replacePrints(_ index: [String: PrintEntry]) {
        prints = index
        dupesChanged()
    }

    /// Whether what we already know about this file is still true.
    func printIsFresh(_ key: String, _ path: String) -> Bool {
        Self.isFresh(prints[key], path)
    }

    nonisolated static func isFresh(_ entry: PrintEntry?, _ path: String) -> Bool {
        guard let known = entry, !known.fp.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        else { return false }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return known.size == size && abs(known.mtime - mtime) < 1
    }

    /// Fingerprint one file into the index. 128 KB of reading, wherever the
    /// file is and however big it is.
    @discardableResult
    func takePrint(_ path: String) -> String? {
        let key = Paths.tagKey(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mark = Fingerprints.fingerprint(path, size: size) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        prints[key] = PrintEntry(size: size, mtime: mtime, fp: mark, full: nil,
                                 seen: Date().timeIntervalSince1970)
        return key
    }

    func dupesChanged() {
        dupeCache = nil
        dupeGroupsCache = nil
        // The count is not recomputed here: this runs on the main thread each
        // time a video starts, and regrouping the whole index to keep a menu
        // title current was tens of milliseconds of stall each time. It is
        // derived on first ask instead.
        dupeGroupCountKnown = false
        indexRevision += 1
    }

    /// How many sets there are, derived on first ask after a change. The only
    /// reader is the menu title, which opens the finder when chosen — by
    /// which time deriving for real was needed anyway.
    var groupCount: Int {
        if !dupeGroupCountKnown {
            dupeGroupCount = dupeGroups().filter { $0.count > 1 }.count
            dupeGroupCountKnown = true
        }
        return dupeGroupCount
    }

    /// Every group of two or more, as key → the other copies. Cached, because
    /// the playlist asks per row: recomputing over an index of tens of
    /// thousands on every row would make scrolling crawl.
    func dupeSets() -> [String: [String]] {
        if let cache = dupeCache { return cache }
        var out: [String: [String]] = [:]
        for group in dupeGroups() {
            // A copy taken out of the list is a decision already made, so
            // nowhere should keep asking about it.
            let live = group.filter { !sparedDupes.contains($0) }
            guard live.count > 1 else { continue }
            for key in live { out[key] = live.filter { $0 != key } }
        }
        dupeCache = out
        return out
    }

    func dupes(for path: String) -> [String] { dupeSets()[Paths.tagKey(path)] ?? [] }



    /// Fingerprint what just started playing, off the main thread. The point
    /// of this mode is that it is not a scan: one file, 128 KB, and anything
    /// already known and unchanged costs nothing at all.
    func noticeWhilePlaying(_ path: String?) {
        guard watchDupes, let path else { return }
        // Whether what we know is still true is itself a question for the
        // disk, so it is asked out there too: this runs as a video starts, and
        // a share that has gone to sleep would stall that.
        let known = prints[Paths.tagKey(path)]
        Task.detached(priority: .utility) {
            guard !Self.isFresh(known, path) else { return }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mark = Fingerprints.fingerprint(path, size: size) else { return }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let entry = PrintEntry(size: size, mtime: mtime, fp: mark, full: nil,
                                   seen: Date().timeIntervalSince1970)
            await MainActor.run {
                self.prints[Paths.tagKey(path)] = entry
                self.dupesChanged()
                self.savePrints()
            }
        }
    }

    // MARK: - scans

    /// The built-in scan that is always there and can never be removed.
    static let autoScanId = "auto"

    var currentScan: DupeScan? { scans.first { $0.id == scanId } }

    func scanFolders() -> [String] { currentScan?.folders ?? [] }

    @discardableResult
    func addScan(folders: [String], name: String? = nil) -> DupeScan {
        let scan = DupeScan(id: UUID().uuidString,
                            name: name ?? defaultScanName(folders),
                            folders: folders)
        scans.append(scan)
        scanId = scan.id
        save()
        return scan
    }

    func defaultScanName(_ folders: [String]) -> String {
        if folders.isEmpty { return "New Scan" }
        let first = (folders[0] as NSString).lastPathComponent
        return folders.count == 1 ? first : "\(first) + \(folders.count - 1)"
    }

    func updateScan(_ scan: DupeScan) {
        guard let i = scans.firstIndex(where: { $0.id == scan.id }) else { return }
        scans[i] = scan
        save()
    }

    func deleteScan(_ id: String) {
        guard id != Library.autoScanId else { return }
        scans.removeAll { $0.id == id }
        if scanId == id { scanId = Library.autoScanId }
        save()
    }
}

// MARK: - tag profiles

/// A tag profile is one person's set of tags: their own local file, their own
/// folder on every share, and their own devices publishing into it.
///
/// The profile in force keeps its tags in `tags.json` — the file the PyObjC
/// build reads — and the others wait in `profiles/`. Switching swaps them, so
/// picking a profile shows that profile's tags and nobody else's.
extension Library {

    var activeProfile: String { person }

    func isActive(_ name: String) -> Bool { slug(name) == slug(person) }

    /// Whether a listed name is the nameless entry — a profile row with
    /// nothing in it, which is what a hand-edited or half-written state file
    /// leaves behind.
    ///
    /// It can be named and deleted, and nothing else: every path that opens a
    /// profile refuses an empty name, so nothing can put it in force, and the
    /// window's "Rename" therefore has no active profile to work on. It also
    /// cannot be told apart from a profile *called* "unknown", because
    /// `slug("")` is "unknown" — so `deleteProfile` and `nameNamelessProfile`
    /// both refuse to touch the files when such a profile is listed.
    func isNameless(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the blank row's slug — "unknown" — is also some listed profile's
    /// own name. The one case where a blank row must never be allowed to take
    /// files with it: they belong to that profile, not to the blank row.
    private var namelessSlugIsTaken: Bool {
        profiles.contains { !isNameless($0) && slug($0) == slug("") }
    }

    /// Every profile worth offering: the ones this Mac holds, and any found on
    /// the shares that it does not.
    func allProfiles(includingShared shared: [SharePerson] = []) -> [String] {
        var out = profiles
        for person in shared
        where !out.contains(where: { slug($0) == slug(person.name) })
            && !hiddenProfiles.contains(slug(person.name)) {
            out.append(person.name)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Start a profile with no tags in it and switch to it.
    func createProfile(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !profiles.contains(where: { slug($0) == slug(name) }) else { return }
        profiles.append(name)
        switchProfile(to: name, startingEmpty: true)
    }

    /// Put a different profile in force.
    ///
    /// The tags in hand belong to the profile being left, so they are written
    /// to its own file before the new one's are read. Nothing is merged: two
    /// profiles are two people, and running them together is the confusion
    /// this exists to end.
    func switchProfile(to name: String, startingEmpty: Bool = false) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Opening from the closed state skips the leave-half: the stores in
        // hand are already empty, and writing them would file nothing into a
        // stray bundle under the closed state's slug.
        if !profileOpen {
            reopenClosed(name)
            return
        }
        guard !isActive(name) || startingEmpty else { return }
        // What is in hand belongs to the profile being left, so it is
        // written where that profile keeps it before the new one is read.
        JSONStore.save(Paths.profileFile(person), tags)
        // The readings travel with the tags, and for the same reason. A file's
        // date is the same fact whoever is looking, but a profile is a fresh
        // start: somebody who has just made one has scanned nothing yet, and
        // handing them 3,000 readings off somebody else's scan would mean a
        // brand new profile was not new. Theirs arrive when they scan.
        facts.save(to: Paths.profileFactsFile(person))
        // Pinned folders belong to the profile too: the ones in hand are put
        // away under the profile being left, and the new one's taken up.
        //
        // Both happen *before* `person` changes: assigning it fires a save,
        // and a save files whatever `pinned` holds under the profile then in
        // force — so swapping afterwards wrote the old list under the new
        // profile's name and both ended up sharing one set.
        pinnedByProfile[slug(person)] = pinned
        pinned = startingEmpty ? [] : (pinnedByProfile[slug(name)] ?? [])
        recentByProfile[slug(person)] = recent
        recent = startingEmpty ? [] : (recentByProfile[slug(name)] ?? [])
        // Headings are this profile's filing of this profile's tags, so they
        // are written under the profile being left before `person` moves, and
        // the new one's are read after it.
        saveGroups()
        // Recent travels the same way, and for the timing reason spelled out
        // above: put this profile's away before `person` moves, then take up
        // the new one's. A brand new profile has been nowhere and shows an
        // empty Recent rather than the last person's folders.
        if !profiles.contains(where: { slug($0) == slug(name) }) { profiles.append(name) }
        person = name
        let incoming: [String: [String]] = startingEmpty
            ? [:] : JSONStore.load(Paths.profileFile(name), fallback: [:])
        tags = incoming
        // A brand new profile has filed nothing and starts with no headings.
        if startingEmpty { groups = [:]; saveGroups() } else { loadGroups(for: name) }
        facts = startingEmpty ? MetadataFacts()
                              : MetadataFacts.load(at: Paths.profileFactsFile(name))
        recount()
        lastPublishedAt = ProfileBundle.manifest(name)?.lastPublishedAt ?? 0
        publishedClean = ProfileBundle.manifest(name)?.publishedClean ?? (lastPublishedAt == 0)
        // The undo belonged to the profile being left; keeping it would offer
        // to put one profile's tags into another.
        undoable = nil
        try? FileManager.default.removeItem(atPath: Paths.tagsBackup)
        try? FileManager.default.removeItem(atPath: Paths.factsBackup)
        // A profile that has never been seen on this Mac starts from whatever
        // its own devices have published, rather than from nothing.
        lastMerge = 0
        saveTags()
        saveFacts()
        save()
        profileDidChange(to: name)
    }

    /// Tell the rest of the app whose judgement is now in force.
    ///
    /// The stores holding a profile's own decisions (suggestions, marks,
    /// people) hear this and reload from the new profile's folder. Posted after
    /// the files are in place, so a listener never reads a half-moved profile.
    /// An empty slug is the closed state, and the stores treat it the same way
    /// — empty.
    private func profileDidChange(to name: String) {
        // Every way the profile in force can change ends here — switching,
        // creating, duplicating, renaming — so the recent list is kept in step
        // in one place rather than at five call sites that could drift.
        noteProfileOpened(name)
        NotificationCenter.default.post(name: .fvpProfileChanged, object: slug(name))
    }

    /// Put a profile at the front of File ▸ Open Recent Profile.
    ///
    /// Closing posts too — but nothing named "" is kept or shown, so a cycle
    /// of close-and-reopen cannot fill the menu with empty entries.
    func noteProfileOpened(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let who = slug(name)
        recentProfiles.removeAll { slug($0) == who }
        recentProfiles.insert(name, at: 0)
        if recentProfiles.count > 10 { recentProfiles.removeLast(recentProfiles.count - 10) }
        save()
    }

    /// Everything that has to happen on the shares the first time this Mac sees
    /// a profile: take what it has already published, make its folder exist so
    /// the other devices can see who it is, take in their tags, and give back
    /// whatever this Mac has of its own.
    ///
    /// One function rather than the same four calls in a window and a menu:
    /// the order matters (a claim before a merge, a merge before a publish) and
    /// two copies of an order is two chances to get it wrong.
    func adoptProfileOnShares() async {
        guard profileOpen else { return }
        let context = profileContext
        await seedFromSharesIfEmpty()
        guard context == profileContext else { return }
        await claimName()
        guard context == profileContext else { return }
        _ = await mergeShared()
        guard context == profileContext else { return }
        await publishTags()
    }

    // MARK: - the profile as a document

    /// File ▸ Close Profile: the full empty state. The player keeps working;
    /// every tagging surface is off.
    ///
    /// The empty state is `person == ""`, which makes `Paths.activeProfile` ""
    /// too — and every per-profile path under it becomes a stray bundle under
    /// `profiles/unknown/`. That is safe only because every write asks
    /// `profileOpen` first (saveTags, saveFacts, publish, the auto triggers);
    /// nothing else exists that writes into a profile.
    ///
    /// What is deliberately NOT cleared: the device-level state — progress,
    /// hidden videos, fingerprints, the caches, the models. Those belong to
    /// the Mac, not to the person, and wiping them would punish closing.
    func closeProfile() {
        guard profileOpen else { return }
        autoPublish?.cancel()
        autoPublish = nil
        tagsDirty = false
        // What is in hand belongs to the profile being closed, so it goes to
        // its bundle first — the same order switchProfile keeps.
        JSONStore.save(Paths.profileFile(person), tags)
        facts.save(to: Paths.profileFactsFile(person))
        saveGroups()
        pinnedByProfile[slug(person)] = pinned
        recentByProfile[slug(person)] = Array(recent.prefix(recentLimit))
        // The empty state. `pinned` and `recent` go first: assigning `person`
        // fires its didSet, which saves — and the save files whatever those
        // two hold under the profile then in force. Empty now, they file
        // nothing under the slug of the closed state instead of the old
        // profile's folders under "unknown".
        pinned = []
        recent = []
        person = ""
        profileOpen = false
        tags = [:]
        groups = [:]
        facts = MetadataFacts()
        recount()
        undoable = nil
        try? FileManager.default.removeItem(atPath: Paths.tagsBackup)
        try? FileManager.default.removeItem(atPath: Paths.factsBackup)
        lastPublishedAt = 0
        publishedClean = true
        save()
        NotificationCenter.default.post(name: .fvpProfileChanged, object: "")
        noteProfileOpened("")
    }

    /// Whether a profile document is open, by name. A closed library is open
    /// only in the sense that closing again does nothing.
    func isOpen(_ name: String) -> Bool { profileOpen && isActive(name) }

    /// Reopen a profile from the closed state (or switch from another one),
    /// running the share adoption the Tag Profiles window runs. One path so
    /// File ▸ Open and Open Recent and the chooser cannot drift apart.
    func openProfile(_ name: String) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if profileOpen { switchProfile(to: name) } else { reopenClosed(name) }
        await adoptProfileOnShares()
    }

    /// The read half of putting a profile back in force while closed. Reached
    /// only through `switchProfile`, which routes here when nothing is open —
    /// the switch that matters is the one from nothing, and the stores in hand
    /// are already empty, so there is nothing to put away first. The one save
    /// that matters is `person`'s didSet writing the state file with the new
    /// name, so the closed state does not come back at the next launch.
    private func reopenClosed(_ name: String) {
        // Read before person.didSet saves the incoming profile’s folder lists.
        pinned = pinnedByProfile[slug(name)] ?? []
        recent = (recentByProfile[slug(name)] ?? []).filter { !pinned.contains($0) }
        if !profiles.contains(where: { slug($0) == slug(name) }) { profiles.append(name) }
        person = name
        profileOpen = true
        tags = JSONStore.load(Paths.profileFile(name), fallback: [:])
        loadGroups(for: name)
        provenance = TagProvenance.load()
        facts = MetadataFacts.load(at: Paths.profileFactsFile(name))
        pinned = pinnedByProfile[slug(name)] ?? []
        // Pinned folders live in Pinned only — never also in Recent.
        recent = (recentByProfile[slug(name)] ?? []).filter { !pinned.contains($0) }
        recount()
        recountFacts()
        lastPublishedAt = ProfileBundle.manifest(name)?.lastPublishedAt ?? 0
        publishedClean = ProfileBundle.manifest(name)?.publishedClean ?? (lastPublishedAt == 0)
        saveTags()
        save()
        profileDidChange(to: name)
    }

    /// Move a profile's own AI folder to a new name. Nothing to move is not an
    /// error: a profile that never trained, decided or named anybody has none.
    private func moveProfileDir(from old: String, to new: String) {
        let fm = FileManager.default
        let (from, into) = (Paths.profileDir(old), Paths.profileDir(new))
        guard fm.fileExists(atPath: from), !fm.fileExists(atPath: into) else { return }
        try? fm.createDirectory(atPath: Paths.profilesDir, withIntermediateDirectories: true)
        try? fm.moveItem(atPath: from, toPath: into)
    }

    /// Carry a profile's AI state into a duplicate. A duplicate exists to carry
    /// on where the original left off; a brand new profile is the one that
    /// starts blank.
    private func copyProfileDir(from source: String, to name: String) {
        let fm = FileManager.default
        let (from, into) = (Paths.profileDir(source), Paths.profileDir(name))
        guard fm.fileExists(atPath: from), !fm.fileExists(atPath: into) else { return }
        try? fm.createDirectory(atPath: Paths.profilesDir, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: from, toPath: into)
    }

    /// Copy a profile's tags into a new profile of your own.
    ///
    /// A working copy: take one before a big re-tagging and the original is
    /// still there to fall back to. The original is not touched — the copy
    /// leaves with a new name and publishes to its own folder.
    func duplicateProfile(_ source: String, as name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !profiles.contains(where: { slug($0) == slug(trimmed) }) else { return false }
        let copied = await tagsOnDisk(ofProfile: source)
        let copiedFacts = factsOnDisk(ofProfile: source)
        JSONStore.save(Paths.profileFile(person), tags)
        facts.save(to: Paths.profileFactsFile(person))
        pinnedByProfile[slug(person)] = pinned
        profiles.append(trimmed)
        // A copy is for carrying on where the original left off, so it starts
        // with the same folders pinned. In hand before `person` changes: the
        // assignment saves, and a save files `pinned` under whoever is then
        // in force.
        let inheritedPins = pinnedByProfile[slug(source)] ?? []
        pinned = inheritedPins
        pinnedByProfile[slug(trimmed)] = inheritedPins
        // A duplicate carries on where the original left off, so it inherits
        // where the original had been too — unlike a new profile, which has
        // been nowhere.
        recentByProfile[slug(person)] = recent
        let inheritedRecent = recentByProfile[slug(source)] ?? []
        recent = inheritedRecent
        recentByProfile[slug(trimmed)] = inheritedRecent
        person = trimmed
        // A duplicate carries on where the original left off, so it inherits
        // the headings too. `groups` still holds the source's, so this only
        // has to file them under the new name.
        saveGroups()
        tags = copied
        // A duplicate carries on where the original left off, so it inherits
        // the readings too — unlike `createProfile`, which starts blank.
        facts = copiedFacts
        lastMerge = 0
        saveTags()
        saveFacts()
        save()
        copyProfileDir(from: source, to: trimmed)
        profileDidChange(to: trimmed)
        return true
    }

    /// A profile's readings as they are on disk, whether or not it is the one
    /// in force. The counterpart of `tagsOnDisk`.
    private func factsOnDisk(ofProfile name: String) -> MetadataFacts {
        isActive(name) ? facts : MetadataFacts.load(at: Paths.profileFactsFile(name))
    }

    /// A profile's tags as they are on disk, whether or not it is the one in
    /// force.
    private func tagsOnDisk(ofProfile name: String) async -> [String: [String]] {
        isActive(name) ? tags : await tags(ofProfile: name)
    }

    /// Forget a profile's tags on this Mac. The share keeps its own copy —
    /// this is not a way to delete somebody else's work.
    ///
    /// Delete a profile: this Mac's copy, and its folder on every mounted
    /// share. There is no undo, which is why the window makes you type the
    /// name rather than click a button.
    ///
    /// It is also remembered as hidden. A share that was offline at the time
    /// still holds its folder, and without this the profile would reappear the
    /// next time that share was mounted — which is the deletion apparently
    /// doing nothing.
    ///
    /// A NAMELESS entry is the exception, and is why this could not delete one
    /// at all: an empty name slugs to "unknown", which is the same slug as a
    /// profile actually *called* `unknown`. When one of those is listed, the
    /// blank row goes from the list alone — its bundle and its share folder are
    /// that profile's, and deleting somebody's folder to tidy a blank row is
    /// not a trade this may make.
    @discardableResult
    func deleteProfile(_ name: String) async
        -> (cleared: [String], failed: [(String, String)]) {
        // The profile in force is not deletable from here — the window closes
        // it first. The CLOSED state is not a profile, though it is an empty
        // name too: nothing owns those files while nothing is open, which is
        // exactly what a blank row is.
        guard !profileOpen || !isActive(name) else {
            return ([], [("", "it is the profile in force")])
        }
        let nameless = isNameless(name)
        let sharedSlug = nameless && namelessSlugIsTaken
        if !sharedSlug {
            try? FileManager.default.removeItem(atPath: Paths.profileFile(name))
            // Its heads, suggestions, marks and people go with it: the profile no
            // longer exists, so nothing may be left that could be read under it.
            try? FileManager.default.removeItem(atPath: Paths.profileDir(name))
        }
        // Matched as itself when it has no name: every blank row slugs to the
        // same word, and only the blank rows are this deletion's business.
        func isTheDeletedOne(_ other: String) -> Bool {
            nameless ? isNameless(other) : slug(other) == slug(name)
        }
        profiles.removeAll(where: isTheDeletedOne)
        // Nothing else is keyed by a name a blank row owns. Its slug belongs to
        // whoever is called "unknown", and leaving that profile's folders,
        // recents and pins alone is the whole point of the guard above.
        guard !sharedSlug else {
            save()
            return ([], [])
        }
        pinnedByProfile.removeValue(forKey: slug(name))
        recentByProfile.removeValue(forKey: slug(name))
        // ...and out of File ▸ Open Recent Profile, or the menu would offer a
        // profile that no longer exists and reopening it would rebuild the
        // bundle this just deleted.
        recentProfiles.removeAll(where: isTheDeletedOne)
        // Not for a blank row: `hiddenProfiles` is keyed by slug, so hiding
        // "unknown" would hide every profile of that name for good — and there
        // is nothing to hide a blank row from. A share's folder is only offered
        // as a person when it carries a `tags-*.json`, and this one never did.
        if !nameless { hiddenProfiles.insert(slug(name)) }
        save()
        return await deleteFromShares(name)
    }

    /// Give the nameless entry a name — the other half of what a blank row
    /// could not be given.
    ///
    /// A row with nothing in it can never be put in force, because every path
    /// that opens a profile refuses an empty name, and the window's rename only
    /// ever renamed the profile in force. So naming it is the only way to keep
    /// what is in it. Everything after that is an ordinary rename: the entry in
    /// the list, the pinned and recent folders filed under its slug, and the
    /// bundle on this Mac. The folder on the shares is the window's half, as it
    /// already is for a rename (`renameOnShares`) — which also means a blank
    /// name's folder is left where it is. See `deleteProfile` for why.
    @discardableResult
    func nameNamelessProfile(to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard isNameless(person) || profiles.contains(where: isNameless),
              !trimmed.isEmpty,
              !namelessSlugIsTaken,
              !profiles.contains(where: { slug($0) == slug(trimmed) }) else { return false }
        // The bundle is filed under the blank row's slug, so it moves with the
        // name — the same rule an ordinary rename follows, and for the same
        // reason: otherwise the profile comes back with everything it had
        // learned apparently lost.
        moveProfileDir(from: "", to: trimmed)
        if let pins = pinnedByProfile.removeValue(forKey: slug("")) {
            pinnedByProfile[slug(trimmed)] = pins
        }
        if let recents = recentByProfile.removeValue(forKey: slug("")) {
            recentByProfile[slug(trimmed)] = recents
        }
        profiles = profiles.map { isNameless($0) ? trimmed : $0 }
        if !profiles.contains(where: { slug($0) == slug(trimmed) }) {
            profiles.append(trimmed)
        }
        // A correction, not a second bundle: the folder that has just moved is
        // the same one, so its manifest is corrected in place rather than a
        // fresh bundle being created beside it.
        ProfileBundle.ensure(profile: trimmed, name: trimmed, device: device)
        save()
        return true
    }

    /// Change the name a profile goes by, keeping everything in it.
    ///
    /// The tags do not move — they are already in `tags.json`, which belongs to
    /// whichever profile is in force — so this is a change of name and nothing
    /// else. The stale copy under the old name goes, since that profile no
    /// longer exists.
    @discardableResult
    func renameActiveProfile(to name: String) -> Bool {
        let old = person
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              slug(name) != slug(old) else { return false }
        // Renaming into a name already in use would publish this profile's
        // tags into that one's folder on the share, over the top of theirs.
        guard !profiles.contains(where: { slug($0) == slug(name) }) else { return false }
        profiles.removeAll { slug($0) == slug(old) }
        profiles.append(name)
        // The pins are this profile's and it is the same profile, so they
        // move to the new slug rather than being left under the old one.
        // `pinned` is already what they should be, and assigning `person`
        // saves it under the new slug.
        pinnedByProfile.removeValue(forKey: slug(old))
        // The recent-profiles list is keyed by NAME rather than slug, so a
        // rename has to drop the old name here: it is not a profile any more,
        // and File ▸ Open Recent would offer to reopen one that does not exist.
        // The new name is added by `profileDidChange` when `person` moves.
        recentProfiles.removeAll { slug($0) == slug(old) }
        // Recent moves with the rename for the same reason the pins do: it is
        // the same profile under a new name, `recent` already holds the right
        // list, and assigning `person` files it under the new slug.
        recentByProfile.removeValue(forKey: slug(old))
        person = name
        try? FileManager.default.removeItem(atPath: Paths.profileFile(old))
        // The AI folder is named after the profile, so a rename has to take it
        // along or the profile would come back with everything it had learned
        // apparently lost. Moved before anyone is told the name changed.
        moveProfileDir(from: old, to: name)
        // ...and the bundle's own manifest still calls the profile by its old
        // name. Corrected here so a bundle read on its own — off a share, or by
        // the File menu — does not disagree with the list it was opened from.
        ProfileBundle.ensure(profile: name, name: name, device: device)
        saveTags()
        save()
        profileDidChange(to: name)
        return true
    }

    /// What this Mac publishes as, inside this profile's folder on the shares:
    /// the `<device>` of `tags-<device>.json`. Visible and editable in Profile
    /// Settings, at the maintainer's decision of 2026-09-17.
    ///
    /// One name across every profile is deliberate: the id is the MACHINE's,
    /// and two people's files can never collide anyway — each publishes into
    /// its own person folder. Renaming generates nothing; it writes what you
    /// typed, and the next publish creates the file under the new name and the
    /// old one sits until it is forgotten from the shares by hand.
    var publishDeviceName: String { device }

    func setPublishDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Same rules as the device id itself: a filename on other people's
        // disks, and one spelling per machine.
        guard !trimmed.isEmpty, trimmed != device,
              !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return }
        device = slug(trimmed)
        // The bundle says what this profile publishes as; a rename must not
        // leave it claiming the old device.
        ProfileBundle.ensure(profile: person, name: person, device: device)
        if profileOpen {
            publishedClean = false
            tagsDirty = true
            ProfileBundle.markEdited(profile: person)
            scheduleAutoPublish()
        }
        save()
    }

    /// Move a profile's folder on every mounted share, so a rename is a rename
    /// rather than a second profile appearing beside the first.
    ///
    /// Other devices still set to the old name will make it again when they
    /// next publish — nothing here can reach into an Apple TV's settings — so
    /// this says which shares it managed and leaves the rest to be told.
    @discardableResult
    func renameOnShares(from old: String, to new: String) async -> [String] {
        let (oldFolder, newFolder) = (Paths.shareDir + "/" + slug(old),
                                      Paths.shareDir + "/" + slug(new))
        return await Task.detached(priority: .utility) { () -> [String] in
            var moved: [String] = []
            for share in Paths.mountedShares() {
                let root = Paths.volumes + share
                let from = (root as NSString).appendingPathComponent(oldFolder)
                let to = (root as NSString).appendingPathComponent(newFolder)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: from, isDirectory: &isDir),
                      isDir.boolValue,
                      !FileManager.default.fileExists(atPath: to) else { continue }
                if (try? FileManager.default.moveItem(atPath: from, toPath: to)) != nil {
                    moved.append(share)
                }
            }
            return moved
        }.value
    }

    /// Take a profile's folder off the mounted shares. Every device's tags for
    /// that profile go with it, which is why the window asks first and never
    /// does it as part of an ordinary Forget.
    @discardableResult
    func deleteFromShares(_ name: String) async -> (cleared: [String], failed: [(String, String)]) {
        let folder = Paths.shareDir + "/" + slug(name)
        return await Task.detached(priority: .utility)
            { () -> (cleared: [String], failed: [(String, String)]) in
            var cleared: [String] = []
            var failed: [(String, String)] = []
            for share in Paths.mountedShares() {
                let path = ((Paths.volumes + share) as NSString).appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    try FileManager.default.removeItem(atPath: path)
                    cleared.append(share)
                } catch {
                    // Reported rather than passed over. Listing only the shares
                    // that worked read as "deleted everywhere" while a share
                    // that had refused kept the folder — and the profile came
                    // back in the list from exactly there.
                    failed.append((share, (error as NSError).localizedDescription))
                }
            }
            return (cleared, failed)
        }.value
    }

    /// The tags of a profile that is not in force: this Mac's copy if it holds
    /// one, and otherwise whatever that profile's devices have published.
    func tags(ofProfile name: String) async -> [String: [String]] {
        if isActive(name) { return tags }
        let local: [String: [String]] = JSONStore.load(Paths.profileFile(name), fallback: [:])
        if !local.isEmpty { return local }
        return await publishedTags(ofProfile: name)
    }

    /// A profile with no copy on this Mac takes what has been published for
    /// it, this device's own file included.
    ///
    /// The merge skips our own file by design — it is normally a copy of what
    /// we already hold. But when the local copy has gone, it is the only copy
    /// there is, and skipping it showed the profile as empty while its tags
    /// sat on the share. Switching to a profile then looked like the tags had
    /// moved somewhere else.
    func seedFromSharesIfEmpty() async {
        guard profileOpen, tags.isEmpty else { return }
        let context = profileContext
        let published = await publishedTags(ofProfile: person)
        guard profileOpen, context == profileContext, tags.isEmpty, !published.isEmpty else { return }
        tags = published
        saveTags()
    }

    /// Everything published for a profile, across every device and share.
    func publishedTags(ofProfile name: String) async -> [String: [String]] {
        let folder = Paths.shareDir + "/" + slug(name)
        return await Task.detached(priority: .utility) {
            var found: [String: [String]] = [:]
            for share in Paths.mountedShares() {
                let dir = ((Paths.volumes + share) as NSString).appendingPathComponent(folder)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
                else { continue }
                for leaf in names.sorted()
                where leaf.hasPrefix("tags-") && leaf.hasSuffix(".json") {
                    let path = (dir as NSString).appendingPathComponent(leaf)
                    let entries: [String: [String]] = JSONStore.load(path, fallback: [:])
                    for (rest, tagged) in entries { found["\(share)/\(rest)"] = tagged }
                }
            }
            return found
        }.value
    }

    /// The tags in a set, with how many videos carry each — for showing a
    /// profile that is not the one in force.
    nonisolated static func counts(in entries: [String: [String]]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for names in entries.values {
            for name in names {
                counts[name.lowercased(), default: 0] += 1
                if display[name.lowercased()] == nil { display[name.lowercased()] = name }
            }
        }
        return counts.keys.sorted().compactMap { key in
            display[key].map { ($0, counts[key] ?? 0) }
        }
    }
}
