import Foundation
import Combine

/// The app's smart collections: this profile's saved questions, and — kept
/// current as the library changes — the videos that answer each one.
///
/// Answers are worked out here, not while the sidebar draws. The in-memory
/// rules (tags, ratings, playback…) are cheap; the two that need a file's stat
/// (date added, missing/playable) are gathered off the main thread first, and
/// only when some collection actually asks them. A change anywhere in the
/// library schedules one re-evaluation a second later, so a burst of tagging is
/// one pass, not one per tag.
@MainActor
final class SmartCollectionStore: ObservableObject {

    @Published private(set) var collections: [SmartCollection] = []
    /// Each collection's members, as absolute paths in library order.
    @Published private(set) var members: [UUID: [String]] = [:]
    /// Set while a re-evaluation is running, so a count can say "…".
    @Published private(set) var evaluating = false
    @Published private(set) var problem: String?

    private var profile = ""
    private weak var library: Library?
    private weak var analysis: AnalysisStore?
    private weak var journal: EvidenceJournal?
    private var watchers: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var existenceCache: [String: Bool] = [:]
    private var existenceCheckedAt = Date.distantPast
    /// Told when members change, so a playlist showing a collection can re-ask.
    var onMembersChanged: (() -> Void)?

    func attach(library: Library, analysis: AnalysisStore, journal: EvidenceJournal) {
        self.library = library
        self.analysis = analysis
        self.journal = journal
        watchers = []
        // Any change a rule could read: tags, ratings, readings, hiding,
        // watching (library); verdicts and analysis state; transcripts.
        library.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watchers)
        analysis.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watchers)
        journal.$transcriptEdits.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &watchers)
        reload(profile: Paths.activeProfile)
    }

    /// Point at a profile: its collections, nobody else's. An empty profile is
    /// the closed state, which has none.
    func reload(profile: String) {
        self.profile = profile
        collections = profile.isEmpty ? [] : SmartCollectionFile.load(at: Paths.smartCollectionsFile(profile)).collections
        members = [:]
        existenceCache = [:]
        existenceCheckedAt = .distantPast
        scheduleRefresh(after: 0)
    }

    // MARK: - editing

    func collection(_ id: UUID) -> SmartCollection? { collections.first { $0.id == id } }

    /// Add or replace one collection, by id.
    func save(_ collection: SmartCollection) {
        if let i = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[i] = collection
        } else {
            collections.append(collection)
        }
        persist()
        scheduleRefresh(after: 0)
    }

    @discardableResult
    func duplicate(_ id: UUID) -> SmartCollection? {
        guard var copy = collection(id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " copy")
        for i in copy.rules.indices { copy.rules[i].id = UUID() }
        save(copy)
        return copy
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, var item = collection(id) else { return }
        item.name = clean
        save(item)
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        members.removeValue(forKey: id)
        persist()
    }

    /// "Smart Collection", "Smart Collection 2"… — never two with one name.
    func uniqueName(_ wanted: String) -> String {
        func taken(_ name: String) -> Bool {
            collections.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard taken(wanted) else { return wanted }
        var n = 2
        while taken("\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    private func persist() {
        guard !profile.isEmpty else { return }
        let path = Paths.smartCollectionsFile(profile)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        problem = SmartCollectionFile(collections: collections).save(to: path)
            ? nil : "Smart collections could not be saved."
    }

    // MARK: - problems

    /// What is wrong with a collection's rules, one sentence per bad rule.
    func problems(in collection: SmartCollection) -> [UUID: String] {
        guard let library else { return [:] }
        var out: [UUID: String] = [:]
        for rule in collection.rules {
            if let why = SmartEvaluator.problem(with: rule, knownNames: { !library.pathsCarrying($0).isEmpty }) {
                out[rule.id] = why
            }
        }
        return out
    }

    // MARK: - answering

    func scheduleRefresh(after delay: Double = 1) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Re-answer every collection. The only waits are the stats, and they are
    /// off the main thread; everything else reads memory.
    func refresh() async {
        guard let library, !collections.isEmpty, library.profileOpen else {
            if !members.isEmpty { members = [:]; onMembersChanged?() }
            return
        }
        evaluating = true
        defer { evaluating = false }
        guard let next = await evaluate(collections), !Task.isCancelled else { return }
        if next != members {
            members = next
            onMembersChanged?()
        }
    }

    /// The members of some collections — saved ones, or a draft in the editor
    /// that has not been saved yet. Nil when there is no library to ask.
    func evaluate(_ items: [SmartCollection]) async -> [UUID: [String]]? {
        guard let library, library.profileOpen else { return nil }
        let analysed = Set(analysis?.records.keys.map { $0 } ?? [])
        let transcribed = Set((journal?.transcribedPaths ?? []).map { Paths.tagKey($0) })
        var context = library.smartContext(adding: analysed.union(transcribed))
        if let analysis {
            context.analysis = { key in AnalysisStore.bucket(record: analysis.records[key]) }
        }
        let rules = items.flatMap(\.rules)
        // Transcript words: one store query per distinct phrase.
        for rule in rules where rule.kind == .transcript {
            let words = SmartEvaluator.normalised(rule.text)
            guard !words.isEmpty, context.transcriptHits[words] == nil else { continue }
            let hits = journal?.transcriptMatches(words, limit: 100_000) ?? []
            context.transcriptHits[words] = Set(hits.map { Paths.tagKey($0.path) })
        }
        // Stats, only when a rule needs them, and off the main thread.
        let universe = context.universe
        if rules.contains(where: { $0.kind == .added }) {
            let paths = universe.map { Paths.tagPath($0) }
            await library.warmStats(paths)
            for (key, path) in zip(universe, paths) { context.addedOn[key] = library.addedOn(path) }
        }
        if rules.contains(where: { $0.kind == .file }) {
            // Re-asked at most every two minutes, and for new videos: the
            // library changes every few seconds while something plays, and a
            // NAS should not be asked about every file each time.
            let stale = Date().timeIntervalSince(existenceCheckedAt) > 120
            let unknown = universe.filter { existenceCache[$0] == nil }
            if stale || !unknown.isEmpty {
                let fresh = await Self.existence(of: stale ? universe : unknown)
                existenceCache.merge(fresh) { _, new in new }
                if stale { existenceCheckedAt = Date() }
            }
            context.fileExists = existenceCache
        }
        var out: [UUID: [String]] = [:]
        for collection in items {
            out[collection.id] = SmartEvaluator.members(collection, in: context).map { Paths.tagPath($0) }
        }
        return out
    }

    /// Whether each file is there, eight at a time off the main thread — a
    /// share asleep answers slowly, and the window must not wait on it.
    nonisolated static func existence(of keys: [String]) async -> [String: Bool] {
        await Task.detached(priority: .utility) {
            var out: [String: Bool] = [:]
            await withTaskGroup(of: (String, Bool).self) { group in
                var next = keys.makeIterator()
                func add() {
                    guard let key = next.next() else { return }
                    group.addTask { (key, FileManager.default.fileExists(atPath: Paths.tagPath(key))) }
                }
                for _ in 0..<8 { add() }
                while let (key, exists) = await group.next() {
                    out[key] = exists
                    add()
                }
            }
            return out
        }.value
    }
}
