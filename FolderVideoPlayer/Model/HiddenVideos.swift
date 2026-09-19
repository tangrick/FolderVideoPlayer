import Foundation
import CryptoKit

// MARK: - what a view is allowed to see

/// Which videos a view, a queue or a scan may see.
///
/// Hiding is a property of the APP, not of the file: nothing here renames,
/// moves, flags or encrypts anything. So every place that would otherwise show
/// or act on a video has to ask this first — a filter that only the playlist
/// honours is a hidden video that still turns up in a tag count, a duplicate
/// group, a moved-file result or the AI's candidate pool.
///
/// Keys are SHARE-RELATIVE (`Paths.tagKey`), the same space tags and the dupes
/// list use, so the hidden set survives a remount and means the same thing on
/// another device reaching the same drive.
enum HiddenFilter: Equatable {
    /// Normal browsing: hidden videos are not there at all.
    case omit(Set<String>)
    /// The Hidden view: nothing else is there.
    case only(Set<String>)
    /// No filtering. Used by the gates, and by anything that genuinely wants
    /// the raw list (nothing in the UI does).
    case all

    var hiddenKeys: Set<String> {
        switch self {
        case .all: return []
        case .omit(let keys), .only(let keys): return keys
        }
    }

    func apply(to paths: [String]) -> [String] {
        switch self {
        case .all:
            return paths
        case .omit(let hidden):
            guard !hidden.isEmpty else { return paths }
            return paths.filter { !hidden.contains(Paths.tagKey($0)) }
        case .only(let hidden):
            guard !hidden.isEmpty else { return [] }
            return paths.filter { hidden.contains(Paths.tagKey($0)) }
        }
    }

    func hides(_ path: String) -> Bool {
        switch self {
        case .all: return false
        case .omit(let keys), .only(let keys): return keys.contains(Paths.tagKey(path))
        }
    }

    func hides(key: String) -> Bool {
        switch self {
        case .all: return false
        case .omit(let keys), .only(let keys): return keys.contains(key)
        }
    }

    /// How many hidden videos sit under one folder.
    ///
    /// The sidebar counts videos in a folder, and the playlist shows a filtered
    /// list of the same folder. If the two were computed differently the number
    /// beside the folder would disagree with what opening it shows, which is
    /// the sort of wrongness that reads as a bug in the app rather than in the
    /// filter.
    static func hiddenCount(under root: String, hidden: Set<String>) -> Int {
        guard !hidden.isEmpty else { return 0 }
        let key = Paths.tagKey(root)
        let prefix = key.isEmpty ? "" : (key.hasSuffix("/") ? key : key + "/")
        return hidden.filter { $0 == key || (!prefix.isEmpty && $0.hasPrefix(prefix)) }.count
    }
}

// MARK: - the credential

/// The password that guards the Hidden view, and this session's answer to
/// whether it has been given yet.
///
/// **What this is not.** It does not encrypt, rename, move or flag anything —
/// the videos are exactly where they were, readable by Finder and by any other
/// app. It keeps THIS app's view of them behind a password. Every piece of UI
/// that mentions it says so, because a password prompt that implies protection
/// it does not provide is the worst kind of lie.
///
/// The record is a salt, an iteration count and an iterated SHA-256 hash —
/// never the password itself. It lives in its own file (`hidden.json`) rather
/// than in `state.json`, so "I forgot it" is one file to remove and the
/// credential never travels with shared tags.
@MainActor
final class HiddenLock: ObservableObject {

    struct Record: Codable, Equatable {
        static let currentVersion = 1
        var version: Int
        var iterations: Int
        var salt: String        // base64, 32 random bytes
        var hash: String        // base64, 32 bytes
    }

    /// Every way this can refuse, each with a sentence a person can read.
    enum Trouble: Error, LocalizedError, CustomStringConvertible, Equatable {
        case unreadable(String)     // the file is there and cannot be parsed
        case incomplete             // parsed, but missing salt or hash
        case tooNew(Int)            // written by a newer build
        case noPassword             // nothing stored yet
        case wrongPassword
        case emptyPassword
        case writeFailed(String)

        var description: String {
            switch self {
            case .unreadable(let why):
                return "the password file could not be read: \(why)"
            case .incomplete:
                return "the password file is incomplete — set a new password"
            case .tooNew(let version):
                return "the password was saved by a newer version (v\(version)) — "
                     + "this build will not guess at it"
            case .noPassword:
                return "no password has been set yet"
            case .wrongPassword:
                return "that password does not match"
            case .emptyPassword:
                return "a password cannot be empty"
            case .writeFailed(let why):
                return "the password could not be saved: \(why)"
            }
        }

        var errorDescription: String? { description }
    }

    /// The default work factor. Stored per record, so raising it later does not
    /// invalidate a password somebody already chose.
    ///
    /// `nonisolated` because it is the DEFAULT ARGUMENT of `setPassword`, and
    /// a default argument is evaluated outside the actor — referring to a
    /// main-actor static from there is a warning today and an error under
    /// Swift 6.
    nonisolated static let defaultIterations = 200_000

    /// Is there a password to satisfy? False on a fresh install, and false
    /// again after Remove.
    @Published private(set) var hasPassword = false

    /// Session-only by construction: never written to disk, so quitting locks.
    /// Deliberately not `private(set) var` read from a file — a stored unlock
    /// would be a password you only need once per install.
    @Published private(set) var isUnlocked = false

    /// Set when the stored record cannot be used. A locked app is the safe
    /// failure: a broken record must never read as "no password".
    @Published private(set) var trouble: Trouble?

    private(set) var file: String
    private var record: Record?

    init(root: String = Paths.support) {
        self.file = (root as NSString).appendingPathComponent("hidden.json")
        reload()
    }

    /// Read the record from disk. Cheap, and safe to call again.
    func reload() {
        trouble = nil
        record = nil
        hasPassword = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: file) else { return }
        guard let data = fm.contents(atPath: file) else {
            trouble = .unreadable(file)
            hasPassword = true
            return
        }
        guard let parsed = try? JSONDecoder().decode(Record.self, from: data) else {
            trouble = .unreadable("not a password record")
            hasPassword = true
            return
        }
        guard parsed.version <= Record.currentVersion else {
            trouble = .tooNew(parsed.version)
            hasPassword = true
            return
        }
        guard !parsed.salt.isEmpty, !parsed.hash.isEmpty,
              Data(base64Encoded: parsed.salt) != nil,
              Data(base64Encoded: parsed.hash) != nil else {
            trouble = .incomplete
            hasPassword = true
            return
        }
        record = parsed
        hasPassword = true
    }

    // MARK: - doing the work

    /// Choose a password. Refuses an empty one — "no password" is Remove, not
    /// an empty string, or a blank field would silently unlock everything.
    func setPassword(_ password: String, iterations: Int = HiddenLock.defaultIterations) async throws {
        guard !password.isEmpty else { throw Trouble.emptyPassword }
        let salt = Self.makeSalt()
        let hash = Self.derive(password: password, salt: salt, iterations: iterations)
        let next = Record(version: Record.currentVersion, iterations: iterations,
                          salt: salt.base64EncodedString(), hash: hash.base64EncodedString())
        try write(next)
        record = next
        hasPassword = true
        trouble = nil
        isUnlocked = true          // they just proved they know it
    }

    /// The one question the UI asks. Runs the KDF off the main thread: at a
    /// few hundred milliseconds it is long enough to show as a froze window.
    func unlock(_ password: String) async -> Bool {
        guard let record else { return false }
        let salt = Data(base64Encoded: record.salt) ?? Data()
        let expected = Data(base64Encoded: record.hash) ?? Data()
        guard !expected.isEmpty else { return false }
        let got = await Task.detached(priority: .userInitiated) {
            Self.derive(password: password, salt: salt, iterations: record.iterations)
        }.value
        guard Self.equal(got, expected) else { return false }
        isUnlocked = true
        return true
    }

    func changePassword(from old: String, to new: String) async throws {
        guard record != nil else { throw Trouble.noPassword }
        guard !new.isEmpty else { throw Trouble.emptyPassword }
        guard await unlock(old) else { throw Trouble.wrongPassword }
        try await setPassword(new)
    }

    /// Forget the password entirely, revealing nothing by itself — the hidden
    /// list is untouched, and still hidden until it is unlocked or edited by
    /// hand. Returns the file that was removed, for the sentence the UI says.
    @discardableResult
    func removePassword() -> String? {
        let fm = FileManager.default
        var removed: String?
        if fm.fileExists(atPath: file) {
            try? fm.removeItem(atPath: file)
            removed = file
        }
        record = nil
        hasPassword = false
        trouble = nil
        isUnlocked = false
        return removed
    }

    func lock() { isUnlocked = false }

    // MARK: - the arithmetic

    /// `SHA256^iterations(salt || password)`, the digest chain fed back with
    /// the salt. Pure and nonisolated so the gate can drive it directly.
    nonisolated static func derive(password: String, salt: Data, iterations: Int) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(password.utf8)))
        guard iterations > 1 else { return digest }
        for _ in 1..<iterations {
            digest = Data(SHA256.hash(data: digest + salt))
        }
        return digest
    }

    nonisolated static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }

    /// No early exit, so the comparison does not say where the first differing
    /// byte is. Both sides are always a 32-byte digest, so the length check
    /// leaks nothing either.
    nonisolated static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    private func write(_ next: Record) throws {
        let fm = FileManager.default
        let dir = (file as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        } catch {
            trouble = .writeFailed(error.localizedDescription)
            throw Trouble.writeFailed(error.localizedDescription)
        }
    }
}
