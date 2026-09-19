import Foundation
import Combine

/// The explicit job ledger: what was ASKED for, what it went through, and
/// what it produced — persisted crash-safely so restart/resume is a decision
/// the user makes, not a surprise the app springs.
///
/// T05's contract (design §8): restart/resume is explicit; obsolete jobs
/// cannot write; a missing stage does not prevent independent stages;
/// persistence is crash-safe and idempotent. Nothing here scans, warms or
/// launches work on its own — the ledger only RECORDS; a runner (below, or a
/// later capability) drives the actual engine on an explicit ask, as the app
/// already requires everywhere.
///
/// Profile isolation is structural, not a convention: the file lives under
/// `Paths.jobsFile(in:)`, one per profile, and every id carries the profile
/// it was created under — a foreign id refuses to touch this profile's
/// ledger even if a bug hands it there.
@MainActor
final class JobLedger: ObservableObject {

    // MARK: - the job record

    enum Phase: String, Codable, Equatable {
        case requested      // recorded, never started
        case running
        case done
        case cancelled      // a decision, preserved across restarts
        case failed

        var isTerminal: Bool { self == .done || self == .cancelled || self == .failed }
    }

    /// One checkpoint inside a job: the named stage and when it completed.
    /// `payloads` are that stage's outputs, written per stage — a missing or
    /// corrupt stage file loses that stage, not the job.
    struct Checkpoint: Codable, Equatable {
        var stage: String
        var completedAt: Double
        /// The stage's own record (counts, ids, anything its consumer needs).
        var summary: [String: String] = [:]
    }

    struct Job: Codable, Equatable {
        /// Unique, and self-describing about ownership:
        /// `<profile-folder>/<uuid>`.
        var id: String
        var createdAt: Double
        var startedAt: Double? = nil
        var finishedAt: Double? = nil
        var phase: Phase = .requested
        /// Absolute paths, in the order they were asked for.
        var paths: [String] = []
        /// Completed stages, in completion order.
        var checkpoints: [Checkpoint] = []
        /// Per-path outcomes, filled by the runner as it goes.
        var outcomes: [String: String] = [:]

        func hasCheckpoint(_ stage: String) -> Bool {
            checkpoints.contains { $0.stage == stage }
        }
    }

    // MARK: - storage

    private let file: String
    @Published private(set) var jobs: [String: Job] = [:]
    @Published private(set) var persistenceError: String?
    let profile: String
    private var writable = true

    init(profile: String = Paths.activeProfile) {
        self.profile = profile
        self.file = Paths.jobsFile(in: profile)
        load()
    }

    /// Read the ledger from disk, discarding what a crash left half-said.
    ///
    /// A job that says `running` after its process died cannot still be
    /// running — this process just started — so it comes back as `failed`
    /// with its checkpoints intact: the resume decision (restart it, or leave
    /// it) is the user's, and the record of what finished survives.
    private func load() {
        guard FileManager.default.fileExists(atPath: file) else { return }
        let stored: [String: Job]
        do {
            stored = try JSONDecoder().decode([String: Job].self,
                from: Data(contentsOf: URL(fileURLWithPath: file)))
        } catch {
            writable = false
            persistenceError = "The analysis history could not be read. It has been preserved: \(error.localizedDescription)"
            return
        }
        var loaded: [String: Job] = [:]
        for (id, job) in stored where id == job.id && Self.owns(id: id, profileFolder: folder(of: file)) {
            var repaired = job
            if repaired.phase == .running {
                repaired.phase = .failed
                repaired.finishedAt = repaired.finishedAt ?? Date().timeIntervalSince1970
            }
            loaded[id] = repaired
        }
        jobs = loaded
    }

    /// Does this id belong to the named profile folder? The id's first path
    /// component is the profile the job was created under.
    static func owns(id: String, profileFolder: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[1].isEmpty && parts[0] == profileFolder[...]
    }

    private func folder(of file: String) -> String {
        let jobsDir = (file as NSString).deletingLastPathComponent
        // The directory is the profile's bundle (`<slug>.fvpprofile`), while a
        // job id carries the bare slug — so the bundle extension comes off
        // here. Leaving it on made every job of an owning profile look foreign
        // and refuse to load.
        return ProfileBundle.slug(fromBundleName: (jobsDir as NSString).lastPathComponent)
    }

    /// Publish the new in-memory state only after atomic replacement succeeds.
    /// A failed write preserves the previous history and reports the error.
    @discardableResult
    private func persist(_ job: Job) -> Bool {
        guard writable else { return false }
        var proposed = jobs
        proposed[job.id] = job
        do {
            let url = URL(fileURLWithPath: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(proposed).write(to: url, options: .atomic)
        } catch {
            persistenceError = "Could not save analysis history: \(error.localizedDescription)"
            return false
        }
        jobs = proposed
        persistenceError = nil
        return true
    }

    // MARK: - lifecycle

    /// Record that something was ASKED for. No engine, no scan, no side
    /// effects beyond this ledger.
    @discardableResult
    func request(paths: [String]) -> Job {
        let id = "\(folder(of: file))/\(UUID().uuidString)"
        var job = Job(id: id, createdAt: Date().timeIntervalSince1970)
        var seen = Set<String>()
        job.paths = paths.filter { seen.insert($0).inserted }
        _ = persist(job)
        return job
    }

    func job(_ id: String) -> Job? {
        jobs[id]
    }

    /// A foreign id — a job another profile created — has no record here, and
    /// every mutation below refuses it rather than guessing.
    private func owned(_ id: String) -> Job? {
        guard let job = jobs[id], Self.owns(id: id, profileFolder: folder(of: file)) else {
            return nil
        }
        return job
    }

    /// Mark a job started. Only a `requested` job can start: a job already
    /// running under another process (its record says `running` on disk) is
    /// not re-started by this one — that is the "obsolete jobs cannot write"
    /// rule from the runner's side.
    func start(_ id: String) -> Job? {
        guard var job = owned(id), job.phase == .requested else { return nil }
        job.phase = .running
        job.startedAt = Date().timeIntervalSince1970
        return persist(job) ? job : nil
    }

    /// Record one finished stage. A stage already recorded is a no-op — the
    /// same call twice (a retry, a resumed run) writes the ledger once.
    func checkpoint(_ id: String, stage: String, summary: [String: String] = [:]) -> Job? {
        guard var job = owned(id), job.phase == .running else { return nil }
        guard !job.hasCheckpoint(stage) else { return job }
        job.checkpoints.append(Checkpoint(stage: stage,
                                          completedAt: Date().timeIntervalSince1970,
                                          summary: summary))
        return persist(job) ? job : nil
    }

    /// Fill in one path's outcome. Idempotent per (job, path).
    func record(_ id: String, path: String, outcome: String) -> Job? {
        guard var job = owned(id), job.phase == .running else { return nil }
        guard job.paths.contains(path) else { return nil }
        guard job.outcomes[path] == nil else { return job }
        job.outcomes[path] = outcome
        return persist(job) ? job : nil
    }

    /// Finish a job. Only a running job reaches a terminal phase, and only
    /// once — later calls are no-ops, so a stale runner cannot reopen or
    /// rewrite history.
    func finish(_ id: String, as phase: Phase) -> Job? {
        guard var job = owned(id), job.phase == .running else { return nil }
        guard phase == .done || phase == .cancelled || phase == .failed else { return nil }
        job.phase = phase
        job.finishedAt = Date().timeIntervalSince1970
        return persist(job) ? job : nil
    }

    // MARK: - queries

    /// Jobs that were asked for and never finished, newest first — what a
    /// "resume?" prompt would offer. Cancelled jobs are a decision, not an
    /// offer.
    var resumable: [Job] {
        jobs.values
            .filter { $0.phase == .requested || $0.phase == .failed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Is anything still claimed as running? Under normal operation this is
    /// always false at load (see `load`), but a second ledger instance in one
    /// process can legitimately observe it.
    var hasRunning: Bool {
        jobs.values.contains { $0.phase == .running }
    }
}

/// The explicit job runner: drives ONE job through the engine with
/// checkpoints, cancellation and per-path outcomes recorded in the ledger.
///
/// This is the piece that makes restart/resume EXPLICIT: nothing schedules
/// itself, and `cancel` acts only on the job it is handed. A runner instance
/// owns its job for its lifetime — a second runner asked to run the same id
/// is refused, because the ledger says the job already started.
@MainActor
final class JobRunner {

    /// Why a run refused to start.
    enum Refusal: Error, Equatable {
        case notRequested       // no such job in this profile's ledger
        case alreadyStarted     // another runner owns it (or it finished)
        case empty
        case engineBusy
        case profileChanged
        case persistence
    }

    private let ledger: JobLedger
    private let engine: AnalysisEngine
    private let store: AnalysisStore
    private let execute: @MainActor (AnalysisStore, [String]) async -> Void
    private(set) var runningID: String?
    private var cancellationRequested = false

    init(ledger: JobLedger, engine: AnalysisEngine, store: AnalysisStore,
         execute: (@MainActor (AnalysisStore, [String]) async -> Void)? = nil) {
        self.ledger = ledger
        self.engine = engine
        self.store = store
        self.execute = execute ?? { store, paths in await engine.run(store: store, paths: paths) }
    }

    /// Run a requested job to completion (or until cancelled). The stages
    /// are named, and each is checkpointed as it finishes, so a job resumed
    /// later knows exactly what completed.
    func run(_ id: String) async -> Result<JobLedger.Job, Refusal> {
        guard ledger.profile == Paths.activeProfile else { return .failure(.profileChanged) }
        guard runningID == nil, !engine.isBusy else { return .failure(.engineBusy) }
        guard let requested = ledger.job(id), ledger.job(id)?.phase == .requested else {
            if ledger.job(id) == nil { return .failure(.notRequested) }
            return .failure(.alreadyStarted)
        }
        guard !requested.paths.isEmpty else {
            // An empty ask is recorded and closed, not left dangling.
            _ = ledger.start(id)
            _ = ledger.finish(id, as: .failed)
            return .failure(.empty)
        }
        guard ledger.start(id) != nil else { return .failure(.persistence) }
        runningID = id
        cancellationRequested = false

        defer { runningID = nil }

        let context = store.contextID
        guard ledger.checkpoint(id, stage: "queued", summary: ["videos": String(requested.paths.count)]) != nil else {
            return .failure(.persistence)
        }
        store.enqueue(requested.paths)
        await execute(store, requested.paths)
        // A profile switch/cancel cannot turn the old job's completion into a
        // report about another profile's store, even if inference finishes late.
        if ledger.job(id)?.phase == .cancelled { return .success(ledger.job(id)!) }
        guard ledger.profile == Paths.activeProfile, context == store.contextID,
              !Task.isCancelled, !cancellationRequested else {
            guard let cancelled = ledger.finish(id, as: .cancelled) else { return .failure(.persistence) }
            return .success(cancelled)
        }

        // What actually happened, per path, from the store the engine wrote.
        for path in requested.paths {
            let outcome: String
            switch store.analysis(for: path)?.phase {
            case .done: outcome = "done"
            case .failed: outcome = "failed"
            case .analyzing: outcome = "interrupted"
            case .queued: outcome = "not reached"
            case nil: outcome = "not reached"
            }
            guard ledger.record(id, path: path, outcome: outcome) != nil else { return .failure(.persistence) }
        }
        guard ledger.checkpoint(id, stage: "engine-pass",
                              summary: ["outcomes": String(requested.paths.count)]) != nil else {
            return .failure(.persistence)
        }
        let complete = requested.paths.allSatisfy {
            store.analysis(for: $0)?.phase == .done
        }
        guard ledger.finish(id, as: complete ? .done : .failed) != nil,
              ledger.persistenceError == nil else { return .failure(.persistence) }
        return .success(ledger.job(id) ?? requested)
    }

    /// Ask the engine to stop. The runner records the decision; the engine's
    /// own stop path rescues the in-flight row. Cancellation here never
    /// writes a verdict — the engine guarantees that already.
    func cancel(_ id: String) {
        guard runningID == id else { return }
        cancellationRequested = true
        engine.stop()
        _ = ledger.finish(id, as: .cancelled)
    }
}
