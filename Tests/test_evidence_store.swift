// The versioned evidence store: timed evidence, decisions, transcript search,
// schema migrations and the refusals — without Xcode, models or a network.
//
// T05's other half (design §6, §8). The things worth proving, in the order the
// file proves them:
//
//   1. a fresh root gets a store with the schema version RECORDED on disk, not
//      remembered in memory;
//   2. timed evidence round-trips exactly — times, label, reason, source, the
//      embedding space, the confidence and the file revision it came from;
//   3. a row that could not be reviewed is refused, and a batch that cannot land
//      whole does not land at all (the design's crash-safe idempotence);
//   4. confidence stays beside its capability and is never averaged across them;
//   5. a human's decision is recorded and never deletes the evidence — a
//      rejection is what the next reviewer needs to see;
//   6. ONLY an accepted or a rejected row is a label: an ignored proposal and an
//      unanswered one are both absent from training data;
//   7. one video's evidence is one answer, and deleting it deletes only that;
//   8. a file this app did not write is refused and left untouched, and so is a
//      file written by a NEWER build — provably, because it is only ever opened
//      read-only before that decision is made;
//   9. an older schema is backed up before it is migrated;
//  10. transcript search works for both languages this library holds: FTS5 for
//      word queries, a scan for the queries FTS5 cannot tokenise (CJK), with
//      LIKE's own wildcards escaped;
//  11. profiles do not see each other's evidence.
//
// `@main` rather than top-level code: this file compiles alongside the app's
// model layer and only main.swift may carry top-level statements.
//
// Run: Tests/run_evidence_store.sh

@testable import FVPModel
import Foundation
import SQLite3

@main
struct EvidenceStoreTest {

    static func main() {
        do {
            try run()
        } catch {
            print("FAIL the harness threw before finishing — \(error)")
            exit(1)
        }
    }

    static func run() throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-evidence-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let profile = "harness"
        let file = Paths.evidenceFile(in: profile, root: root)
        let video = "/library/holiday.mp4"
        let other = "/library/same-name-elsewhere/holiday.mp4"

        func row(_ capability: TimedEvidence.Capability, _ label: String,
                 _ start: Double, _ end: Double = -1, confidence: Double? = nil,
                 reason: String = "", path: String = "/library/holiday.mp4") -> TimedEvidence {
            TimedEvidence(capability: capability, path: path, start: start,
                          end: end < 0 ? start : end, label: label,
                          reason: reason, source: "siglip2-base", space: "space-abc",
                          confidence: confidence)
        }

        // --- 1. a fresh root gets a store whose version is on disk ---------------
        var store: EvidenceStore? = try EvidenceStore(root: root, profile: profile)
        check("a store is created under the root", fm.fileExists(atPath: file), file)
        check("it reports the schema this build writes",
              store?.schemaVersion == EvidenceStore.currentSchema, "\(store?.schemaVersion ?? -1)")
        check("and the version is recorded on disk, not just remembered",
              (try store?.meta("schema_version")) == String(EvidenceStore.currentSchema))
        // FTS5 is a compile-time option of whatever SQLite this build links, so
        // the harness reports which mode it actually got instead of assuming.
        let mode = store?.searchMode ?? .scan
        print("     (transcript search mode on this runtime: \(mode.rawValue))")
        check("the search mode it reports is the one it recorded",
              (try store?.meta("transcript_search")) == mode.rawValue)
        check("and it is a mode this build implements",
              mode == .fts5 || mode == .scan)

        // --- 2. timed evidence round-trips exactly ------------------------------
        var full = row(.tags, "beach", 12.5, 15.0, confidence: 0.82, reason: "waves and sand")
        full.sourceRevision = TimedEvidence.SourceRevision(bytes: 1_234_567, modifiedAt: 1_700_000_000)
        full.jobID = "harness/job-1"
        let scene = row(.scenes, "kitchen", 30, 42, confidence: 0.51)
        let point = row(.tags, "sunset", 61.25)
        let ids = try store?.insert([full, scene, point]) ?? []
        check("a batch returns one id per row", ids.count == 3, "\(ids.count)")

        let all = try store?.evidence(for: video) ?? []
        check("every row comes back", all.count == 3, "\(all.count)")
        check("oldest first, the order a reviewer walks the video",
              all.map { $0.start } == [12.5, 30, 61.25], "\(all.map { $0.start })")
        if let read = all.first {
            check("the claim and its reason survive",
                  read.label == "beach" && read.reason == "waves and sand",
                  "\(read.label) / \(read.reason)")
            check("the time range survives",
                  read.start == 12.5 && read.end == 15.0 && read.duration == 2.5)
            check("confidence survives on its own scale",
                  read.confidence == 0.82, "\(read.confidence ?? -1)")
            check("the model and its embedding space travel with it",
                  read.source == "siglip2-base" && read.space == "space-abc",
                  "\(read.source) / \(read.space)")
            check("the file revision it was read from travels with it",
                  read.sourceRevision == TimedEvidence.SourceRevision(bytes: 1_234_567,
                                                                     modifiedAt: 1_700_000_000),
                  "\(String(describing: read.sourceRevision))")
            check("the job that asked for it travels with it", read.jobID == "harness/job-1")
            check("nothing is decided before a human decides",
                  read.decision == .pending && read.id != nil)
        }
        check("a point in time is a range that starts and ends together",
              all.last?.isPointInTime == true && all.last?.duration == 0)
        check("one capability can be asked for on its own",
              (try store?.evidence(for: video, capability: .tags) ?? []).count == 2)
        check("and a capability with no evidence says so rather than guessing",
              (try store?.count(capability: .objects)) == 0)
        check("the store can count everything it holds", (try store?.count()) == 3)

        // --- 3. what cannot be reviewed is refused, and a batch is all or nothing -
        let before = try store?.count() ?? 0
        var refused: [String] = []
        func refuses(_ name: String, _ candidate: TimedEvidence) {
            do {
                try store?.insert([candidate])
                refused.append("\(name): accepted")
            } catch {
                guard let error = error as? EvidenceError else {
                    refused.append("\(name): wrong error \(error)")
                    return
                }
                // The message matters as much as the refusal: it is what a
                // caller (and a supporter reading a log) has to go on.
                if error.errorDescription == nil { refused.append("\(name): no message") }
            }
        }
        refuses("no video", row(.tags, "beach", 1, path: ""))
        refuses("no label", row(.tags, "", 1))
        refuses("a time before the start", row(.tags, "beach", -1))
        refuses("an end before the start", row(.tags, "beach", 10, 5))
        refuses("a time that is not a number",
                row(.tags, "beach", .nan).withEnd(.infinity))
        refuses("a confidence that is not a number", row(.tags, "beach", 1, confidence: .infinity))
        refuses("a revision that is not real",
                row(.tags, "beach", 1).withRevision(.init(bytes: -5, modifiedAt: 0)))
        check("every unreviewable row is refused, with a reason a user could read",
              refused.isEmpty, refused.joined(separator: "; "))
        check("and a refused row wrote nothing", (try store?.count() ?? -1) == before)

        do {
            try store?.insert([row(.tags, "fine", 2), row(.tags, "not fine", 3, 1)])
            check("a batch containing an unreviewable row is refused", false, "it was accepted")
        } catch {
            check("a batch containing an unreviewable row is refused", true)
        }
        check("and the good row of that batch did not land either",
              (try store?.count() ?? -1) == before, "\(try store?.count() ?? -1) vs \(before)")

        // --- 4. confidence belongs to its capability ----------------------------
        let detector = row(.objects, "car", 20, 21, confidence: 0.8)
        _ = try store?.insert([detector])
        let objects = try store?.evidence(for: video, capability: .objects) ?? []
        check("a detector's number is kept as the detector's, not blended with a cosine",
              objects.first?.confidence == 0.8 && objects.first?.capability == .objects)

        // --- 5. a decision is recorded and deletes nothing ----------------------
        guard let beachID = all.first?.id else { throw EvidenceError.emptyPath }
        let accepted = try store?.setDecision(.accepted, id: beachID)
        check("an accepted decision comes back with the row",
              accepted?.decision == .accepted && accepted?.id == beachID)
        check("and the evidence is still there to review",
              (try store?.count()) == before + 1)
        check("the claim itself is untouched by the decision",
              accepted?.label == "beach" && accepted?.proposedAt == all.first?.proposedAt)
        do {
            _ = try store?.setDecision(.rejected, id: 999_999)
            check("deciding about evidence that does not exist is refused", false)
        } catch let error as EvidenceError {
            check("deciding about evidence that does not exist is refused",
                  error == .noSuchEvidence(999_999))
        }

        // --- 6. only a human's yes or no trains anything ------------------------
        if let sunsetID = all.last?.id {
            _ = try store?.setDecision(.ignored, id: sunsetID)
        }
        let rejected = try store?.insert([row(.scenes, "studio", 90, 95)]) ?? []
        if let id = rejected.first { _ = try store?.setDecision(.rejected, id: id) }
        let training = try store?.trainingEvidence(limit: 100) ?? []
        check("a human's yes and a human's no are both labels",
              training.contains { $0.decision == .accepted } && training.contains { $0.decision == .rejected },
              training.map { $0.decision.rawValue }.joined(separator: ","))
        check("an ignored proposal is NOT a no",
              !training.contains { $0.label == "sunset" },
              training.map { $0.label }.joined(separator: ","))
        check("and nothing unanswered trains anything either",
              !training.contains { $0.label == "kitchen" })
        check("only a real decision is training data by definition",
              TimedEvidence.Decision.accepted.forTraining
                && TimedEvidence.Decision.rejected.forTraining
                && !TimedEvidence.Decision.ignored.forTraining
                && !TimedEvidence.Decision.pending.forTraining)

        // --- 7. one video's evidence is one answer ------------------------------
        _ = try store?.insert([row(.tags, "other video's tag", 1, path: other)])
        check("another file's evidence is not mixed in",
              (try store?.evidence(for: video) ?? []).count == 5,
              "\(try store?.evidence(for: video).count ?? -1)")
        check("and its own query finds its own row",
              (try store?.evidence(for: other) ?? []).count == 1)

        // --- 8. transcript: both languages, and the wildcards ---------------
        let lines = [
            TranscriptLine(path: video, start: 0, end: 2.5, text: "he said no to the offer", source: "whisper"),
            TranscriptLine(path: video, start: 2.5, end: 5, text: "the discount was 50% off", source: "whisper"),
            TranscriptLine(path: video, start: 5, end: 8, text: "今天我们去海边看日落", source: "whisper"),
        ]
        let written = try store?.insertTranscript(lines, path: video, language: "mixed") ?? 0
        check("transcript lines are written", written == 3, "\(written)")
        let word = try store?.transcriptMatches("offer", limit: 10) ?? []
        check("a word query finds its line, in video order",
              word.count == 1 && word.first?.start == 0 && word.first?.path == video,
              "\(word.count)")
        check("a phrase with quotes in it is a search, not a syntax error",
              (try store?.transcriptMatches("he said \"no\"", limit: 10) ?? []).count == 1)
        check("a query of punctuation alone finds nothing rather than failing",
              (try store?.transcriptMatches("\"", limit: 10) ?? []).isEmpty)
        check("percent is a character, not a wildcard",
              (try store?.transcriptMatches("50%", limit: 10) ?? []).count == 1,
              "\(try store?.transcriptMatches("50%", limit: 10).count ?? -1)")
        check("a single underscore does not match everything",
              (try store?.transcriptMatches("_", limit: 10) ?? []).isEmpty,
              "\(try store?.transcriptMatches("_", limit: 10).count ?? -1)")
        // unicode61 tokenises a run of Chinese as ONE token, so FTS5 cannot find
        // a substring inside it. The scan is the feature here, not a fallback.
        let chinese = try store?.transcriptMatches("海边", limit: 10) ?? []
        check("a Chinese substring is found even though FTS5 cannot tokenise it",
              chinese.count == 1 && chinese.first?.text.contains("海边") == true,
              "\(chinese.count) hits")
        check("an empty query finds nothing", (try store?.transcriptMatches("  ", limit: 10) ?? []).isEmpty)
        check("a limit is a limit",
              (try store?.transcriptMatches("the", limit: 1) ?? []).count <= 1)

        // The panel groups hits by video, so they come back by video, then by
        // time — never interleaved across videos by timestamp.
        _ = try store?.insertTranscript([
            TranscriptLine(path: other, start: 9, end: 10, text: "a better offer came later", source: "whisper"),
            TranscriptLine(path: other, start: 1, end: 2, text: "the first offer", source: "whisper"),
            TranscriptLine(path: other, start: 4, end: 5, text: "去海边吧", source: "whisper"),
        ], path: other, language: "mixed")
        let expectedOrder = [video, other].sorted()
        for query in ["offer", "海边"] {
            let hits = try store?.transcriptMatches(query, limit: 10) ?? []
            let order = hits.map(\.path)
            let byVideo = zip(order, order.dropFirst()).allSatisfy { $0 <= $1 }
            let byTime = Dictionary(grouping: hits, by: \.path).values.allSatisfy { lines in
                zip(lines, lines.dropFirst()).allSatisfy { $0.start <= $1.start }
            }
            check("hits for \(query) come back grouped by video, then in time order",
                  Set(order) == Set(expectedOrder) && byVideo && byTime,
                  hits.map { "\($0.path.suffix(8))@\($0.start)" }.joined(separator: " "))
        }
        // Back to one video's transcript for the checks below.
        try store?.deleteTranscript(for: other)
        var transcriptRefused = false
        do {
            _ = try store?.insertTranscript([TranscriptLine(path: video, start: 0, end: 1, text: "")],
                                            path: video, language: "en")
        } catch {
            transcriptRefused = true
        }
        check("an empty transcript line is refused", transcriptRefused)
        check("and the refused line did not join the transcript",
              (try store?.transcriptMatches("he said \"no\"", limit: 10) ?? []).count == 1)

        // The pure helpers are where injection would live, so they are checked
        // directly rather than only through a query.
        check("a MATCH expression quotes every term",
              EvidenceStore.matchQuery("he said \"no\"") == "\"he\" \"said\" \"\"\"no\"\"\"",
              EvidenceStore.matchQuery("he said \"no\""))
        check("LIKE's wildcards are escaped",
              EvidenceStore.escapedForLike("50%_x\\") == "50\\%\\_x\\\\",
              EvidenceStore.escapedForLike("50%_x\\"))
        check("a CJK query is not a word query", !EvidenceStore.isWordQuery("海边"))
        check("an ASCII word query is", EvidenceStore.isWordQuery("beach day"))

        // --- 9. it all survives a restart --------------------------------------
        let decided = (try store?.evidence(for: video) ?? []).map { "\($0.label)=\($0.decision.rawValue)" }
        store?.close()
        store = nil
        let reopened = try EvidenceStore(root: root, profile: profile)
        check("evidence survives a restart",
              (try reopened.count()) == 6, "\(try reopened.count())")
        check("so do the decisions",
              (try reopened.evidence(for: video) ?? []).map { "\($0.label)=\($0.decision.rawValue)" } == decided,
              decided.joined(separator: ","))
        check("and the transcript",
              (try reopened.transcriptMatches("offer", limit: 10)).count == 1)
        check("the schema version is still the one this build writes",
              reopened.schemaVersion == EvidenceStore.currentSchema)
        store = reopened

        // --- 10. profiles do not see each other ---------------------------------
        let second = try EvidenceStore(root: root, profile: "someone-else")
        check("a second profile is a second file",
              Paths.evidenceFile(in: "someone-else", root: root) != file)
        check("and starts empty", (try second.count()) == 0)
        check("with no transcript either",
              (try second.transcriptMatches("offer", limit: 10)).isEmpty)
        second.close()

        // --- 11. an older schema is backed up before it is migrated -------------
        // Its own profile, because a migration legitimately costs the rows of a
        // table that did not exist: the rest of this harness must not be
        // collateral damage of proving that.
        let migrating = "migrating"
        let migratingFile = Paths.evidenceFile(in: migrating, root: root)
        let old = try EvidenceStore(root: root, profile: migrating)
        _ = try old.insert([row(.tags, "before the upgrade", 5),
                            row(.scenes, "before the upgrade too", 9)])
        old.close()
        // A file this app wrote BEFORE it had an evidence table: version 0 with
        // no tables yet. (This is the same shape a future v2 migration has.)
        try befriend(migratingFile) { db in
            try exec(db, "DROP TABLE evidence")
            try exec(db, "UPDATE meta SET value = '0' WHERE key = 'schema_version'")
        }
        let beforeMigration = try Data(contentsOf: URL(fileURLWithPath: migratingFile))
        let migrated = try EvidenceStore(root: root, profile: migrating)
        check("an older schema is upgraded to the one this build writes",
              migrated.schemaVersion == EvidenceStore.currentSchema)
        check("and the version on disk says so",
              (try migrated.meta("schema_version")) == String(EvidenceStore.currentSchema))
        let backups = (try fm.contentsOfDirectory(atPath: (migratingFile as NSString).deletingLastPathComponent))
            .filter { $0.contains(".backup-v0-") }
        check("a backup was taken BEFORE the migration ran",
              backups.count == 1, backups.joined(separator: ","))
        if let backup = backups.first {
            let backupPath = ((migratingFile as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(backup)
            check("and the backup is the pre-migration file",
                  (try Data(contentsOf: URL(fileURLWithPath: backupPath))) == beforeMigration)
            check("whose own schema version is still the old one",
                  (try versionOnDisk(backupPath)) == 0,
                  "\(String(describing: try versionOnDisk(backupPath)))")
        }
        check("a table that did not exist held nothing, and the store says exactly that",
              (try migrated.count()) == 0, "\(try migrated.count())")
        check("and the upgraded store immediately takes new evidence",
              (try migrated.insert([row(.tags, "after the upgrade", 120)])).count == 1)
        migrated.close()

        // --- 12. a schema from a NEWER build is refused, without writing --------
        let newer = "newer"
        let newerFile = Paths.evidenceFile(in: newer, root: root)
        let future = try EvidenceStore(root: root, profile: newer)
        future.close()
        try befriend(newerFile) { db in
            try exec(db, "UPDATE meta SET value = '99' WHERE key = 'schema_version'")
        }
        let newerBytes = try Data(contentsOf: URL(fileURLWithPath: newerFile))
        var newerRefused: EvidenceError?
        do {
            _ = try EvidenceStore(root: root, profile: newer)
        } catch let error as EvidenceError {
            newerRefused = error
        }
        check("a store from a newer build is refused, by name",
              newerRefused == .newerSchema(found: 99, supported: EvidenceStore.currentSchema),
              "\(String(describing: newerRefused))")
        check("the refusal tells the user which versions",
              (newerRefused?.errorDescription ?? "").contains("99")
                && (newerRefused?.errorDescription ?? "").contains("newer"),
              newerRefused?.errorDescription ?? "no message")
        check("and the file it refused was NOT modified",
              (try Data(contentsOf: URL(fileURLWithPath: newerFile))) == newerBytes)
        check("no backup was made for a refusal either",
              (try fm.contentsOfDirectory(atPath: (newerFile as NSString).deletingLastPathComponent))
                .filter { $0.contains(".backup-v99-") }.isEmpty)

        // --- 13. a database this app did not write is refused, untouched --------
        let foreign = Paths.evidenceFile(in: "foreign", root: root)
        try fm.createDirectory(atPath: (foreign as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try befriend(foreign, create: true) { db in
            try exec(db, "CREATE TABLE notes (body TEXT)")
            try exec(db, "INSERT INTO notes(body) VALUES('somebody else''s data')")
        }
        let foreignBytes = try Data(contentsOf: URL(fileURLWithPath: foreign))
        var foreignRefused: EvidenceError?
        do {
            _ = try EvidenceStore(root: root, profile: "foreign")
        } catch let error as EvidenceError {
            foreignRefused = error
        }
        check("an SQLite file this app did not write is refused",
              foreignRefused == .unrecognisedStore(foreign), "\(String(describing: foreignRefused))")
        check("and it is left exactly as it was",
              (try Data(contentsOf: URL(fileURLWithPath: foreign))) == foreignBytes)
        let foreignTables = try tableNames(foreign)
        check("nothing of ours was added to it",
              foreignTables.contains("notes") && !foreignTables.contains("evidence"),
              foreignTables.joined(separator: ","))

        let garbage = Paths.evidenceFile(in: "garbage", root: root)
        try fm.createDirectory(atPath: (garbage as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try Data("this is not a database".utf8).write(to: URL(fileURLWithPath: garbage))
        var garbageRefused = false
        do {
            _ = try EvidenceStore(root: root, profile: "garbage")
        } catch let error as EvidenceError {
            if case .unrecognisedStore = error { garbageRefused = true }
        }
        check("a file that is not a database at all is refused too", garbageRefused)
        check("and it is left as it was",
              (try String(contentsOfFile: garbage, encoding: .utf8)) == "this is not a database")

        // --- 14. deleting one video's evidence is not deleting the rest ---------
        // Close the earlier handle first: one writer at a time is what SQLite
        // wants, and re-opening is also what a relaunch does.
        store?.close()
        store = nil
        let reopened2 = try EvidenceStore(root: root, profile: profile)
        let removed = try reopened2.deleteEvidence(for: other)
        check("a deletion reports how many rows it took", removed == 1, "\(removed)")
        let rowsLeft = try reopened2.count()
        let otherRows = try reopened2.evidence(for: other)
        check("it took only that video's rows", otherRows.isEmpty && rowsLeft == 5, "\(rowsLeft)")
        check("and deleting a video with no evidence is a no-op, not an error",
              (try reopened2.deleteEvidence(for: "/library/never-analyzed.mp4")) == 0)
        reopened2.close()

        // --- 15. the repository is what the app talks to ------------------------
        // The protocol exists so storage can change without touching callers; if
        // the concrete store stops conforming, this is where it shows.
        let asRepository: EvidenceRepository = try EvidenceStore(root: root, profile: profile)
        let repositoryRows = try asRepository.count()
        let repositoryVideoRows = try asRepository.evidence(for: video)
        let repositoryHits = try asRepository.transcriptMatches("offer")
        check("the SQLite store IS the repository the app is written against",
              repositoryRows == 5, "\(repositoryRows)")
        check("and the default-argument conveniences agree with the explicit calls",
              repositoryVideoRows.count == 5 && repositoryHits.count == 1)
        asRepository.close()

        print(failures == 0 ? "\nALL PASS evidence store" : "\n\(failures) CHECK(S) FAILED")
        if failures > 0 { exit(1) }
    }
}

// MARK: - reading the file the way a support engineer would

/// A few helpers that open the store's file with SQLite directly, so a check can
/// look at what is ACTUALLY on disk rather than at what the store remembers.
private func befriend(_ path: String, create: Bool = false, _ body: (OpaquePointer?) throws -> Void) throws {
    var db: OpaquePointer?
    let flags = create ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) : SQLITE_OPEN_READWRITE
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
        throw EvidenceError.storeUnreadable("the harness could not open \(path)")
    }
    defer { sqlite3_close(db) }
    try body(db)
}

private func exec(_ db: OpaquePointer?, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
        let message = error.map { String(cString: $0) } ?? "sqlite refused it"
        if let error { sqlite3_free(UnsafeMutableRawPointer(error)) }
        throw EvidenceError.statementFailed(message)
    }
}

private func versionOnDisk(_ path: String) throws -> Int? {
    var found: Int?
    try befriend(path) { db in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'schema_version'", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return }
        found = Int(String(cString: raw))
    }
    return found
}

private func tableNames(_ path: String) throws -> [String] {
    var names: [String] = []
    try befriend(path) { db in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { names.append(String(cString: raw)) }
        }
    }
    return names
}

private extension TimedEvidence {
    func withEnd(_ end: Double) -> TimedEvidence {
        var copy = self
        copy.end = end
        return copy
    }

    func withRevision(_ revision: SourceRevision) -> TimedEvidence {
        var copy = self
        copy.sourceRevision = revision
        return copy
    }
}
