import Foundation
import SQLite3

/// The versioned store the design asks for (design §8): one SQLite file per
/// profile holding timed evidence and the searchable transcript, with the schema
/// version recorded ON DISK, a backup taken before any migration, and a REFUSAL
/// — writing nothing — of a file written by a newer build.
///
/// Three rules shape the open path, and each exists because the alternative is a
/// silent loss of somebody's data:
///
/// 1. **An existing file is read READ-ONLY first.** A refusal (unrecognised
///    file, newer schema) must be provably non-destructive, and the only way to
///    prove it is never to have opened it for writing.
/// 2. **An SQLite file this app did not write is never adopted.** Our tables do
///    not go inside somebody else's database just because it happens to sit at
///    our path.
/// 3. **A migration is backed up before it runs.** The one thing that must be
///    true of a schema upgrade is that it costs nothing that was already written.
///
/// The schema version this build writes is `currentSchema`; `migrations` is the
/// registry a future version extends, and nothing else in the open path knows
/// about version numbers.
///
/// What this store deliberately does NOT do: touch the tag, suggestion or
/// analysis stores (they stay authoritative — design §8 forbids migrating the
/// whole library), decide when evidence is stale (it records the source revision
/// it was read from; the caller owns the comparison), or schedule anything.
final class EvidenceStore: EvidenceRepository {

    /// The schema this build writes and understands.
    static let currentSchema = 1

    // MARK: - identity

    /// Where this store's file lives, so a caller can report it.
    let file: String
    /// The profile whose evidence this file holds. Profile isolation is
    /// structural: a different profile is a different file, and every row also
    /// carries the profile, so a store handed the wrong file still cannot answer
    /// for another profile's rows.
    let profile: String

    private var db: OpaquePointer?
    private let lock = NSLock()
    private(set) var schemaVersion: Int = 0
    private(set) var searchMode: TranscriptSearchMode = .scan

    // MARK: - opening

    /// Open (or create) the store for one profile under `root`.
    ///
    /// `root` exists so tests get a temporary home and the app gets the support
    /// directory — the same root-aware shape the rest of the model layer uses.
    init(root: String = Paths.support, profile: String = Paths.activeProfile) throws {
        self.file = Paths.evidenceFile(in: profile, root: root)
        self.profile = profile

        let fm = FileManager.default
        let existed = fm.fileExists(atPath: file)

        if existed {
            // Rule 1: read the version without ever having had write access.
            switch Self.versionOnDisk(at: file) {
            case .failure(let error):
                throw error
            case .success(nil):
                throw EvidenceError.unrecognisedStore(file)
            case .success(let version?):
                if version > Self.currentSchema {
                    // Rule 2's spirit: a schema we do not understand is left
                    // exactly as it is, for the build that does understand it.
                    throw EvidenceError.newerSchema(found: version, supported: Self.currentSchema)
                }
                // Rule 3: copy before touching.
                if version < Self.currentSchema {
                    try Self.backup(file: file, version: version)
                }
                try open()
                if version < Self.currentSchema { try migrate(from: version) }
                schemaVersion = Self.currentSchema
            }
        } else {
            try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try open()
            try createSchema()
            try setVersion(Self.currentSchema)
            schemaVersion = Self.currentSchema
        }

        searchMode = try ensureTranscriptIndex()
    }

    private func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(file, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            if let handle { sqlite3_close(handle) }
            throw EvidenceError.storeUnreadable(why)
        }
        db = handle
        // A rollback journal rather than WAL: a refusal must not leave a sidecar
        // file behind, and this store is written in short transactions.
        try? exec("PRAGMA journal_mode=DELETE")
        try exec("PRAGMA foreign_keys=ON")
    }

    /// What the file says its schema is — read through a read-only handle, and
    /// `nil` when the file is not one of ours.
    private static func versionOnDisk(at path: String) -> Result<Int?, EvidenceError> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            return .success(nil)
        }
        defer { sqlite3_close(handle) }

        // No meta table, or not a database at all: not ours either way.
        var statement: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = 'schema_version'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .success(nil)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return .success(nil) }
        guard let version = Int(String(cString: raw)) else {
            return .failure(.unrecognisedStore(path))
        }
        return .success(version)
    }

    /// A copy beside the store, named for the version it holds. A failure here
    /// stops the migration: an upgrade that cannot be backed out of is not one
    /// this app performs.
    private static func backup(file: String, version: Int) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = "\(file).backup-v\(version)-\(stamp)"
        do {
            try FileManager.default.copyItem(atPath: file, toPath: target)
        } catch {
            throw EvidenceError.backupFailed(error.localizedDescription)
        }
    }

    /// Ask the runtime for FTS5 rather than assuming it: FTS5 is a compile-time
    /// option of the SQLite this build happens to link, and a build without it
    /// must still open the store and still be able to search.
    private func ensureTranscriptIndex() throws -> TranscriptSearchMode {
        let sql = """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts
            USING fts5(text, tokenize='unicode61 remove_diacritics 2')
            """
        do {
            try exec(sql)
            try setMeta("transcript_search", value: TranscriptSearchMode.fts5.rawValue)
            return .fts5
        } catch {
            // No FTS5 here. The store still works; search scans instead, and the
            // mode is recorded so nobody has to guess later which one ran.
            try setMeta("transcript_search", value: TranscriptSearchMode.scan.rawValue)
            return .scan
        }
    }

    deinit { close() }

    /// Close the handle. Called on deinit; explicit so a caller can release the
    /// file before moving or deleting the profile.
    func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - schema

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS evidence (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile TEXT NOT NULL,
            job_id TEXT NOT NULL DEFAULT '',
            path TEXT NOT NULL,
            capability TEXT NOT NULL,
            start_s REAL NOT NULL,
            end_s REAL NOT NULL,
            label TEXT NOT NULL,
            reason TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            space TEXT NOT NULL DEFAULT '',
            confidence REAL,
            proposed_at REAL NOT NULL,
            decision TEXT NOT NULL DEFAULT 'pending',
            src_bytes INTEGER,
            src_mtime REAL
        );
        CREATE INDEX IF NOT EXISTS evidence_by_path ON evidence(profile, path, start_s);
        CREATE INDEX IF NOT EXISTS evidence_by_capability ON evidence(profile, capability);
        CREATE TABLE IF NOT EXISTS transcript (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile TEXT NOT NULL,
            path TEXT NOT NULL,
            start_s REAL NOT NULL,
            end_s REAL NOT NULL,
            text TEXT NOT NULL,
            language TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS transcript_by_path ON transcript(profile, path, start_s);
        """

    /// Every migration, keyed by the version it upgrades FROM. v0 is "a file this
    /// app wrote before it had an evidence table": creating the schema IS the
    /// first migration, so the step a future v2 takes is the same step this one
    /// takes, with a test.
    private static let migrations: [Int: (EvidenceStore) throws -> Void] = [
        0: { try $0.createSchema() },
    ]

    private func createSchema() throws {
        guard let db else { throw EvidenceError.storeUnreadable("the store is closed") }
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, Self.schemaSQL, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite error \(rc)"
            Self.freeErrorMessage(error)
            throw EvidenceError.migrationFailed(message)
        }
    }

    private func migrate(from version: Int) throws {
        var current = version
        while current < Self.currentSchema {
            guard let step = Self.migrations[current] else {
                throw EvidenceError.migrationFailed("no upgrade is registered from schema \(current)")
            }
            try step(self)
            current += 1
            try setVersion(current)
        }
    }

    // MARK: - meta

    private func setVersion(_ version: Int) throws {
        try setMeta("schema_version", value: String(version))
    }

    private func setMeta(_ key: String, value: String) throws {
        let statement = try prepare("INSERT INTO meta(key, value) VALUES(?, ?) "
            + "ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        bindText(statement, 2, value)
        try step(statement)
    }

    /// The store this app wrote — read back rather than assumed, so a test (or a
    /// support engineer) can see what the file actually says.
    func meta(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, key)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    // MARK: - evidence

    private static let insertSQL = """
        INSERT INTO evidence
            (profile, job_id, path, capability, start_s, end_s, label, reason,
             source, space, confidence, proposed_at, decision, src_bytes, src_mtime)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

    /// Withdraw a producer's own UNANSWERED proposals for one scope. The
    /// `decision = 'pending'` clause is the whole point: a row a human answered
    /// is never in this statement's reach, so no producer can delete a verdict.
    private static let discardPendingSQL = """
        DELETE FROM evidence
         WHERE profile = ? AND path = ? AND capability = ? AND source = ? AND space = ?
           AND decision = 'pending'
           AND src_bytes IS ? AND src_mtime IS ?
        """

    private static let selectColumns = """
        id, profile, job_id, path, capability, start_s, end_s, label, reason, \
        source, space, confidence, proposed_at, decision, src_bytes, src_mtime
        """

    /// Write a batch as ONE unit: every row is checked before any row is
    /// written, and the write is a single transaction, so a batch that cannot
    /// land whole does not land at all (design §8's crash-safe idempotence).
    @discardableResult
    func insert(_ items: [TimedEvidence]) throws -> [Int64] {
        guard !items.isEmpty else { return [] }
        for item in items { try item.validate() }

        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let ids = try writeLocked(items)
            try exec("COMMIT")
            return ids
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Replace one producer's unanswered proposals with a new set, in one
    /// transaction (design §6: a pass re-run must not double the review list,
    /// and a crash must leave either the old set or the new one).
    ///
    /// Who is "one producer" is read off the rows — one video, one capability,
    /// one model, one space, one revision. A batch that mixes two of anything is
    /// refused, because the alternative is guessing which rows to withdraw and
    /// guessing wrong quietly destroys a review list.
    ///
    /// An empty batch therefore does nothing at all: it withdraws nothing and
    /// writes nothing, because a withdrawal needs a scope and there is no row
    /// here to read one off. `discardPending` is the call that means "this
    /// producer now claims nothing".
    @discardableResult
    func replacePending(_ items: [TimedEvidence]) throws -> (withdrawn: Int, written: [Int64]) {
        guard let head = items.first else { return (0, []) }
        for item in items {
            try item.validate()
            guard item.decision == .pending else { throw EvidenceError.proposalMustBePending(item.decision) }
            guard item.path == head.path,
                  item.capability == head.capability,
                  item.source == head.source,
                  item.space == head.space,
                  item.sourceRevision == head.sourceRevision else {
                throw EvidenceError.mixedProposalScope
            }
        }

        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let withdrawn = try withdrawPendingLocked(path: head.path,
                                                      capability: head.capability,
                                                      source: head.source,
                                                      space: head.space,
                                                      revision: head.sourceRevision)
            let ids = try writeLocked(items)
            try exec("COMMIT")
            return (withdrawn, ids)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func discardPending(for path: String,
                        capability: TimedEvidence.Capability,
                        source: String,
                        space: String,
                        revision: TimedEvidence.SourceRevision?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try withdrawPendingLocked(path: path, capability: capability,
                                         source: source, space: space, revision: revision)
    }

    /// The withdraw half of a transaction — and the whole of `discardPending`,
    /// the one operation here that needs no transaction because it is a single
    /// statement.
    ///
    /// `decision = 'pending'` is the guard that makes a learned verdict
    /// indestructible: whatever a producer does, a row a human answered stays.
    /// `IS` rather than `=` on the revision keeps the comparison honest when
    /// there is no revision at all (NULL = NULL is not true in SQL).
    private func withdrawPendingLocked(path: String,
                                       capability: TimedEvidence.Capability,
                                       source: String,
                                       space: String,
                                       revision: TimedEvidence.SourceRevision?) throws -> Int {
        let statement = try prepare(Self.discardPendingSQL)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        bindText(statement, 2, path)
        bindText(statement, 3, capability.rawValue)
        bindText(statement, 4, source)
        bindText(statement, 5, space)
        if let revision {
            sqlite3_bind_int64(statement, 6, revision.bytes)
            sqlite3_bind_double(statement, 7, revision.modifiedAt)
        } else {
            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
        }
        try step(statement)
        return Int(sqlite3_changes(db))
    }

    /// The write half of a transaction. Every path that writes evidence rows
    /// goes through here, so the shape of a row and the shape of its validation
    /// cannot drift apart.
    ///
    /// The caller holds the lock and has opened a transaction.
    private func writeLocked(_ items: [TimedEvidence]) throws -> [Int64] {
        let statement = try prepare(Self.insertSQL)
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        for item in items {
            try bindInsert(statement, item)
            try step(statement)
            ids.append(sqlite3_last_insert_rowid(db))
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        return ids
    }

    private func bindInsert(_ statement: OpaquePointer?, _ item: TimedEvidence) throws {
        bindText(statement, 1, profile)
        bindText(statement, 2, item.jobID)
        bindText(statement, 3, item.path)
        bindText(statement, 4, item.capability.rawValue)
        sqlite3_bind_double(statement, 5, item.start)
        sqlite3_bind_double(statement, 6, item.end)
        bindText(statement, 7, item.label)
        bindText(statement, 8, item.reason)
        bindText(statement, 9, item.source)
        bindText(statement, 10, item.space)
        if let confidence = item.confidence {
            sqlite3_bind_double(statement, 11, confidence)
        } else {
            sqlite3_bind_null(statement, 11)
        }
        sqlite3_bind_double(statement, 12, item.proposedAt)
        bindText(statement, 13, item.decision.rawValue)
        if let revision = item.sourceRevision {
            sqlite3_bind_int64(statement, 14, revision.bytes)
            sqlite3_bind_double(statement, 15, revision.modifiedAt)
        } else {
            sqlite3_bind_null(statement, 14)
            sqlite3_bind_null(statement, 15)
        }
    }

    /// One video's evidence, oldest first — the order a reviewer walks the video
    /// in. `path` is exact: a different file's evidence is a different answer,
    /// and a prefix match would silently mix two videos of the same name.
    func evidence(for path: String, capability: TimedEvidence.Capability? = nil) throws -> [TimedEvidence] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT \(Self.selectColumns) FROM evidence WHERE profile = ? AND path = ?"
        if capability != nil { sql += " AND capability = ?" }
        sql += " ORDER BY start_s, id"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        bindText(statement, 2, path)
        if let capability { bindText(statement, 3, capability.rawValue) }

        var found: [TimedEvidence] = []
        while try step(statement) == SQLITE_ROW {
            if let item = row(statement) { found.append(item) }
        }
        return found
    }

    private func evidence(id: Int64) throws -> TimedEvidence? {
        let statement = try prepare("SELECT \(Self.selectColumns) FROM evidence "
            + "WHERE profile = ? AND id = ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        sqlite3_bind_int64(statement, 2, id)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return row(statement)
    }

    /// Record a human's decision. The row is never removed by one: a rejection is
    /// what the next reviewer needs to see, and the design requires acceptance
    /// and rejection to be preserved.
    @discardableResult
    func setDecision(_ decision: TimedEvidence.Decision, id: Int64) throws -> TimedEvidence {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("UPDATE evidence SET decision = ? WHERE profile = ? AND id = ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, decision.rawValue)
        bindText(statement, 2, profile)
        sqlite3_bind_int64(statement, 3, id)
        try step(statement)
        guard sqlite3_changes(db) > 0, let updated = try evidence(id: id) else {
            throw EvidenceError.noSuchEvidence(id)
        }
        return updated
    }

    @discardableResult
    func deleteEvidence(for path: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("DELETE FROM evidence WHERE profile = ? AND path = ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        bindText(statement, 2, path)
        try step(statement)
        return Int(sqlite3_changes(db))
    }

    func count(capability: TimedEvidence.Capability? = nil) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT COUNT(*) FROM evidence WHERE profile = ?"
        if capability != nil { sql += " AND capability = ?" }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        if let capability { bindText(statement, 2, capability.rawValue) }
        guard try step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// A human's yes or no, newest first. An ignored proposal and an unanswered
    /// one are both absent, which is the whole point: a model trained on
    /// "ignored" would be trained on the user's cursor movements.
    func trainingEvidence(limit: Int = 1000) throws -> [TimedEvidence] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT \(Self.selectColumns) FROM evidence "
            + "WHERE profile = ? AND decision IN ('accepted', 'rejected') "
            + "ORDER BY proposed_at DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var found: [TimedEvidence] = []
        while try step(statement) == SQLITE_ROW {
            if let item = row(statement) { found.append(item) }
        }
        return found
    }

    private func row(_ statement: OpaquePointer?) -> TimedEvidence? {
        guard let id = Int64(exactly: sqlite3_column_int64(statement, 0)),
              let capability = text(statement, 4).flatMap(TimedEvidence.Capability.init(rawValue:)),
              let decision = text(statement, 13).flatMap(TimedEvidence.Decision.init(rawValue:)) else {
            // A row this build cannot read is skipped rather than guessed at:
            // capability and decision are both vocabularies, and inventing one
            // would present a claim nobody made.
            return nil
        }
        var item = TimedEvidence(
            capability: capability,
            path: text(statement, 3) ?? "",
            start: sqlite3_column_double(statement, 5),
            end: sqlite3_column_double(statement, 6),
            label: text(statement, 7) ?? "",
            reason: text(statement, 8) ?? "",
            source: text(statement, 9) ?? "",
            space: text(statement, 10) ?? "",
            confidence: sqlite3_column_type(statement, 11) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 11),
            proposedAt: sqlite3_column_double(statement, 12),
            decision: decision,
            jobID: text(statement, 2) ?? ""
        )
        item.id = id
        if sqlite3_column_type(statement, 14) != SQLITE_NULL,
           sqlite3_column_type(statement, 15) != SQLITE_NULL {
            item.sourceRevision = TimedEvidence.SourceRevision(
                bytes: sqlite3_column_int64(statement, 14),
                modifiedAt: sqlite3_column_double(statement, 15))
        }
        return item
    }

    // MARK: - transcript (T08 writes these; the store makes them searchable)

    /// Remove every line for one video, so a re-run replaces its transcript
    /// instead of adding to it. Two passes over one video are two answers, not
    /// twice as many lines.
    ///
    /// The search index goes first, and only when this store HAS one: the
    /// rows are keyed by the same rowid the insert used, so leaving them
    /// behind would let a search return lines that no longer exist — and
    /// preparing against a missing table would fail the whole delete (the
    /// same reason the insert guards it).
    @discardableResult
    func deleteTranscript(for path: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if searchMode == .fts5 {
            let index = try prepare("DELETE FROM transcript_fts WHERE rowid IN"
                + " (SELECT rowid FROM transcript WHERE profile = ? AND path = ?)")
            defer { sqlite3_finalize(index) }
            bindText(index, 1, profile)
            bindText(index, 2, path)
            try step(index)
        }
        let statement = try prepare("DELETE FROM transcript WHERE profile = ? AND path = ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        bindText(statement, 2, path)
        try step(statement)
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    func insertTranscript(_ lines: [TranscriptLine], path: String, language: String) throws -> Int {
        guard !lines.isEmpty else { return 0 }
        for line in lines { try line.validate() }

        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("INSERT INTO transcript"
                + " (profile, path, start_s, end_s, text, language, source) VALUES (?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            // The index is only prepared when this store HAS one: preparing it
            // against a missing table would fail the whole write.
            var index: OpaquePointer?
            if searchMode == .fts5 {
                index = try prepare("INSERT INTO transcript_fts(rowid, text) VALUES (?, ?)")
            }
            defer { if index != nil { sqlite3_finalize(index) } }

            var written = 0
            for line in lines {
                bindText(statement, 1, profile)
                bindText(statement, 2, path)
                sqlite3_bind_double(statement, 3, line.start)
                sqlite3_bind_double(statement, 4, line.end)
                bindText(statement, 5, line.text)
                bindText(statement, 6, line.language.isEmpty ? language : line.language)
                bindText(statement, 7, line.source)
                try step(statement)
                let rowid = sqlite3_last_insert_rowid(db)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                if index != nil {
                    sqlite3_bind_int64(index, 1, rowid)
                    bindText(index, 2, line.text)
                    try step(index)
                    sqlite3_reset(index)
                    sqlite3_clear_bindings(index)
                }
                written += 1
            }
            try exec("COMMIT")
            return written
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Search the transcript. Two modes, because one does not fit both languages
    /// this library holds:
    ///
    /// - FTS5 (word-based, `unicode61`) for queries with words in them;
    /// - a scan for everything else. A run of Chinese characters is ONE token to
    ///   `unicode61`, so FTS5 cannot find a two-character substring inside it —
    ///   a scan can. The design says "searchable", not "indexed", so the
    ///   fallback is part of the feature rather than a degradation.
    ///
    /// Overlap de-duplication is the decoder's job (T08), not the store's: this
    /// returns what was written, in video order.
    /// Every line stored for one video, in order. What the transcript panel
    /// draws. Search is a different question (`transcriptMatches`).
    func transcript(for path: String) throws -> [TranscriptLine] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT start_s, end_s, text, language, source "
            + "FROM transcript WHERE profile = ? AND path = ? ORDER BY start_s, id")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        bindText(statement, 2, path)

        var found: [TranscriptLine] = []
        while try step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            found.append(TranscriptLine(path: path,
                                        start: sqlite3_column_double(statement, 0),
                                        end: sqlite3_column_double(statement, 1),
                                        text: text(2),
                                        language: text(3),
                                        source: text(4)))
        }
        return found
    }

    /// Every video this profile holds a transcript for, in one query — so a
    /// list can ask "which of these are done" without a query per video.
    func transcribedPaths() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT DISTINCT path FROM transcript WHERE profile = ?")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        var found = Set<String>()
        while try step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { found.insert(String(cString: text)) }
        }
        return found
    }

    func transcriptMatches(_ query: String, limit: Int = 50) throws -> [TranscriptLine] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        lock.lock(); defer { lock.unlock() }
        if searchMode == .fts5 && Self.isWordQuery(trimmed) {
            let statement = try prepare("""
                SELECT t.id, t.path, t.start_s, t.end_s, t.text, t.language, t.source
                FROM transcript_fts f JOIN transcript t ON t.id = f.rowid
                WHERE f.text MATCH ? AND t.profile = ?
                ORDER BY t.path, t.start_s LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, Self.matchQuery(trimmed))
            bindText(statement, 2, profile)
            sqlite3_bind_int(statement, 3, Int32(limit))
            return try lines(statement)
        }

        let statement = try prepare("""
            SELECT id, path, start_s, end_s, text, language, source FROM transcript
            WHERE profile = ? AND text LIKE ? ESCAPE '\\'
            ORDER BY path, start_s LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, profile)
        bindText(statement, 2, "%\(Self.escapedForLike(trimmed))%")
        sqlite3_bind_int(statement, 3, Int32(limit))
        return try lines(statement)
    }

    private func lines(_ statement: OpaquePointer?) throws -> [TranscriptLine] {
        var found: [TranscriptLine] = []
        while try step(statement) == SQLITE_ROW {
            var line = TranscriptLine(path: text(statement, 1) ?? "",
                                      start: sqlite3_column_double(statement, 2),
                                      end: sqlite3_column_double(statement, 3),
                                      text: text(statement, 4) ?? "",
                                      language: text(statement, 5) ?? "",
                                      source: text(statement, 6) ?? "")
            line.id = Int64(exactly: sqlite3_column_int64(statement, 0))
            found.append(line)
        }
        return found
    }

    /// Can FTS5 match this? `unicode61` finds words; a query of CJK characters
    /// has none (they are all one token), and punctuation alone finds nothing.
    static func isWordQuery(_ query: String) -> Bool {
        query.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    /// An FTS5 MATCH expression cannot take user text raw: a quote or a bracket
    /// in it is syntax, and FTS5 answers with an error instead of results. Each
    /// term is quoted, and a quote inside a term is doubled — the documented
    /// escape — so a search for `he said "no"` stays a search.
    static func matchQuery(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }

    /// LIKE has its own wildcards, and a search for `50%` must not become a
    /// search for everything starting with 50.
    static func escapedForLike(_ query: String) -> String {
        query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - sqlite plumbing

    private func exec(_ sql: String) throws {
        guard let db else { throw EvidenceError.storeUnreadable("the store is closed") }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite refused the statement"
            Self.freeErrorMessage(error)
            throw EvidenceError.statementFailed(message)
        }
    }

    /// SQLite hands back a message as a typed C string; freeing it takes the
    /// untyped pointer, so the cast happens here and in one place.
    private static func freeErrorMessage(_ error: UnsafeMutablePointer<CChar>?) {
        guard let error else { return }
        sqlite3_free(UnsafeMutableRawPointer(error))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw EvidenceError.storeUnreadable("the store is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, statement != nil else {
            throw EvidenceError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    /// One step of a prepared statement, with the reason on failure.
    @discardableResult
    private func step(_ statement: OpaquePointer?) throws -> Int32 {
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            throw EvidenceError.statementFailed(why)
        }
        return rc
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    /// SQLite must copy a bound string rather than borrow this scope's buffer.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
