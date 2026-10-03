import Foundation
import Combine

/// A point — or a stretch — in a video worth coming back to: a bookmark with a
/// title, perhaps a note, and where it came from.
///
/// Keyed share-relative (`Paths.tagKey`) like tags, and kept per profile: what
/// somebody found worth marking is theirs. A moved file takes its moments with
/// it through the same repair that carries its tags.
struct Moment: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        /// Added at the playhead by hand.
        case manual
        /// Made from a line of the transcript.
        case transcript
        /// Made from something the AI saw (timed evidence).
        case evidence
    }

    var id = UUID()
    var key: String
    var start: Double
    /// Nil for a single point; a stretch when set (always after `start`).
    var end: Double?
    var title: String
    var note: String = ""
    var createdAt: Double
    var modifiedAt: Double
    var source: Source = .manual

    var isRange: Bool { end != nil }

    enum Problem: Error, Equatable, LocalizedError {
        case invalidTime
        case endNotAfterStart
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .invalidTime: return "Times must be zero or later."
            case .endNotAfterStart: return "The end must come after the start."
            case .emptyTitle: return "Give the moment a title."
            }
        }
    }

    /// Why this moment cannot be kept as it is, or nil.
    var problem: Problem? {
        guard start.isFinite, start >= 0 else { return .invalidTime }
        if let end {
            guard end.isFinite else { return .invalidTime }
            if end <= start { return .endNotAfterStart }
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyTitle }
        return nil
    }

    /// "Moment at 1:23" — what a moment is called until the user names it.
    static func defaultTitle(at seconds: Double) -> String {
        "Moment at \(momentClock(seconds))"
    }
}

/// h:mm:ss past an hour, m:ss below it — the transcript panel's clock, kept in
/// the model layer so moments can name themselves without a view.
func momentClock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// A profile's moments, as stored. Versioned; reads what it understands of a
/// newer file.
struct MomentBook: Codable, Equatable {
    static let currentVersion = 1
    var version = MomentBook.currentVersion
    private(set) var moments: [Moment] = []

    init(moments: [Moment] = []) { self.moments = moments }

    /// One video's moments, in time order (then the order they were made).
    func moments(for key: String) -> [Moment] {
        moments.filter { $0.key == key }
            .sorted { ($0.start, $0.createdAt) < ($1.start, $1.createdAt) }
    }

    func moment(_ id: UUID) -> Moment? { moments.first { $0.id == id } }

    /// Add or replace a moment by id. Refused, changing nothing, when it is not
    /// valid.
    mutating func upsert(_ moment: Moment, now: Double = Date().timeIntervalSince1970) throws {
        if let problem = moment.problem { throw problem }
        var stamped = moment
        stamped.title = moment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = moments.firstIndex(where: { $0.id == moment.id }) {
            stamped.createdAt = moments[i].createdAt
            stamped.modifiedAt = now
            moments[i] = stamped
        } else {
            moments.append(stamped)
        }
    }

    @discardableResult
    mutating func delete(_ id: UUID) -> Moment? {
        guard let i = moments.firstIndex(where: { $0.id == id }) else { return nil }
        return moments.remove(at: i)
    }

    /// A file moved: every moment on it moves too.
    mutating func move(from old: String, to new: String) -> Int {
        guard old != new else { return 0 }
        var moved = 0
        for i in moments.indices where moments[i].key == old {
            moments[i].key = new
            moved += 1
        }
        return moved
    }

    /// Many files moved — a folder — in one pass over the book rather than
    /// one pass per file. `renames` is old key → new key.
    mutating func move(_ renames: [String: String]) -> Int {
        var moved = 0
        for i in moments.indices {
            guard let new = renames[moments[i].key], new != moments[i].key else { continue }
            moments[i].key = new
            moved += 1
        }
        return moved
    }

    mutating func forget(_ key: String) { moments.removeAll { $0.key == key } }

    /// Take out the moments on every video `belongs` says yes to, and return
    /// them — a folder removed from the library.
    mutating func take(where belongs: (String) -> Bool) -> [Moment] {
        let taken = moments.filter { belongs($0.key) }
        moments.removeAll { belongs($0.key) }
        return taken
    }

    static func load(at path: String) -> MomentBook {
        guard let data = FileManager.default.contents(atPath: path),
              let book = try? JSONDecoder().decode(MomentBook.self, from: data) else { return MomentBook() }
        return book
    }

    func save(to path: String) -> Bool {
        var copy = self
        copy.version = max(version, Self.currentVersion)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        return JSONStore.save(path, copy)
    }
}

/// The app's moments: the active profile's book, written on every change, and
/// the last deletion kept for Undo.
@MainActor
final class MomentStore: ObservableObject {
    @Published private(set) var book = MomentBook() {
        didSet { byVideo = nil }
    }
    /// The book by video, each video's moments in order. Built when first
    /// asked after a change: the scrubber asks for the playing video's moments
    /// on every tick of the playhead, and filtering and sorting every moment
    /// in the profile each time grows with the whole book.
    private var byVideo: [String: [Moment]]?
    @Published private(set) var problem: String?
    /// The most recent deletion, for Undo. Cleared by any other change.
    @Published private(set) var lastDeleted: Moment?

    private var profile = ""
    private let root: String

    /// `root` is the support folder; tests hand in a scratch one.
    init(root: String = Paths.support) { self.root = root }

    private var file: String { ProfileBundle.file(in: profile, "moments.json", root: root) }

    func reload(profile: String) {
        self.profile = profile
        book = profile.isEmpty ? MomentBook() : MomentBook.load(at: file)
        lastDeleted = nil
        problem = nil
    }

    func moments(for path: String) -> [Moment] {
        if byVideo == nil {
            byVideo = Dictionary(grouping: book.moments, by: \.key).mapValues {
                $0.sorted { ($0.start, $0.createdAt) < ($1.start, $1.createdAt) }
            }
        }
        return byVideo?[Paths.tagKey(path)] ?? []
    }

    /// The videos this profile has marked moments on.
    var videoKeys: Set<String> { Set(book.moments.map(\.key)) }

    /// A folder removed from the library: its videos' moments go, and are
    /// handed back for the undo.
    func take(under folder: String) -> [Moment] {
        let map = PathMap(from: folder, to: folder, isFolder: true)
        var copy = book
        let taken = copy.take { map.mapKey($0) != nil }
        guard !taken.isEmpty else { return [] }
        book = copy
        persist()
        return taken
    }

    func restore(_ moments: [Moment]) {
        guard !moments.isEmpty else { return }
        var copy = book
        for moment in moments { try? copy.upsert(moment, now: moment.modifiedAt) }
        book = copy
        persist()
    }

    /// A new moment at `seconds` on `path`, titled by its time. Returns it, so
    /// the list can put it into editing.
    @discardableResult
    func add(path: String, at seconds: Double, end: Double? = nil, title: String? = nil,
             source: Moment.Source = .manual) -> Moment? {
        guard !profile.isEmpty else { return nil }
        let now = Date().timeIntervalSince1970
        let moment = Moment(key: Paths.tagKey(path), start: max(0, seconds), end: end,
                            title: title?.isEmpty == false ? title! : Moment.defaultTitle(at: seconds),
                            createdAt: now, modifiedAt: now, source: source)
        return commit { try $0.upsert(moment) } ? moment : nil
    }

    /// Save an edited moment. False, with `problem` set, when it is not valid.
    @discardableResult
    func update(_ moment: Moment) -> Bool { commit { try $0.upsert(moment) } }

    func delete(_ id: UUID) {
        var copy = book
        guard let gone = copy.delete(id) else { return }
        book = copy
        persist()
        lastDeleted = gone
    }

    func undoDelete() {
        guard let moment = lastDeleted else { return }
        _ = commit { try $0.upsert(moment) }
    }

    func move(from oldPath: String, to newPath: String) {
        move([(oldPath, newPath)])
    }

    /// Many at once — a folder moved — saved once.
    func move(_ pairs: [(String, String)]) {
        var copy = book
        let renames = Dictionary(pairs.map { (Paths.tagKey($0.0), Paths.tagKey($0.1)) },
                                 uniquingKeysWith: { first, _ in first })
        let moved = copy.move(renames)
        guard moved > 0 else { return }
        book = copy
        persist()
    }

    private func commit(_ change: (inout MomentBook) throws -> Void) -> Bool {
        var copy = book
        do {
            try change(&copy)
        } catch {
            problem = error.localizedDescription
            return false
        }
        book = copy
        lastDeleted = nil
        persist()
        return true
    }

    private func persist() {
        guard !profile.isEmpty else { return }
        problem = book.save(to: file) ? nil : "Moments could not be saved."
    }
}
