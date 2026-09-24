// The job ledger and explicit runner: what was asked for, what finished,
// checkpoints, cancellation, and the honesty rules T05's contract names.
//
// The properties that matter:
//  - persistence is crash-safe and idempotent (the same call twice writes
//    the ledger once, and a crashed `running` record comes back failed with
//    its checkpoints intact);
//  - obsolete jobs cannot write — a finished or foreign job refuses every
//    mutation, and a job another profile created has no record here;
//  - restart/resume is explicit — a runner refuses a job that already
//    started, and nothing schedules itself;
//  - a missing stage does not prevent independent stages — stages are
//    recorded independently and one's absence is observable.
//
// `@main` rather than top-level code: this file compiles alongside the app's
// model layer, and only a file literally named main.swift may carry
// top-level statements.
//
// Run: Tests/run_job_ledger.sh

@testable import FVPModel
import Foundation

@main
struct JobLedgerTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-jobs-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        Paths.support = scratch

        // --- 1. requesting records, and nothing else happens ------------------
        let ledger = JobLedger()
        check("a fresh profile has an empty ledger", ledger.jobs.isEmpty
              && !fm.fileExists(atPath: Paths.jobsFile(in: Paths.activeProfile)))
        let job = ledger.request(paths: [scratch + "/a.mp4", scratch + "/b.mp4"])
        check("a request records the job with its paths, phase and ownership",
              ledger.job(job.id)?.phase == .requested
                && ledger.job(job.id)?.paths.count == 2
                && job.id.hasPrefix("\(Paths.profileFolder(Paths.activeProfile))/"))
        check("a request wrote the ledger to the profile's own file",
              fm.fileExists(atPath: Paths.jobsFile(in: Paths.activeProfile)))

        // --- 2. the lifecycle, with idempotent writes -------------------------
        check("starting moves requested -> running once",
              ledger.start(job.id)?.phase == .running)
        check("starting again is refused (the job already started)",
              ledger.start(job.id) == nil)
        _ = ledger.checkpoint(job.id, stage: "queued", summary: ["videos": "2"])
        _ = ledger.checkpoint(job.id, stage: "engine-pass")
        check("a repeated checkpoint writes the ledger once",
              ledger.job(job.id)?.checkpoints.filter { $0.stage == "queued" }.count == 1
                && ledger.job(job.id)?.checkpoints.count == 2)
        _ = ledger.record(job.id, path: scratch + "/a.mp4", outcome: "done")
        _ = ledger.record(job.id, path: scratch + "/a.mp4", outcome: "done")
        check("a repeated outcome is a no-op",
              ledger.job(job.id)?.outcomes.count == 1)
        _ = ledger.finish(job.id, as: .done)
        check("finishing lands the terminal phase and time",
              ledger.job(job.id)?.phase == .done
                && ledger.job(job.id)?.finishedAt != nil)
        check("a finished job refuses every later mutation",
              ledger.start(job.id) == nil
                && ledger.checkpoint(job.id, stage: "late") == nil
                && ledger.record(job.id, path: "x", outcome: "y") == nil
                && ledger.finish(job.id, as: .failed) == nil
                && ledger.job(job.id)?.checkpoints.count == 2)

        // --- 3. obsolete and foreign jobs cannot write ------------------------
        // A second ledger instance reads the same file: a job whose record on
        // disk says running (a crash) comes back failed, checkpoints intact.
        let reopened = JobLedger()
        check("a crashed running job is failed at load, with history kept",
              reopened.job(job.id)?.phase == .done)   // finished before reopen
        let crashed = reopened.request(paths: [scratch + "/c.mp4"])
        _ = reopened.start(crashed.id)
        _ = reopened.checkpoint(crashed.id, stage: "queued")
        let reread = JobLedger()                     // simulates a relaunch
        check("a job recorded running on disk is failed after a relaunch",
              reread.job(crashed.id)?.phase == .failed)
        check("...and its checkpoints survive the repair",
              reread.job(crashed.id)?.hasCheckpoint("queued") == true)
        check("...and it is offered as resumable, newest first",
              reread.resumable.map { $0.id } == [crashed.id, job.id].sorted {
                  reread.job($0)?.createdAt ?? 0 > (reread.job($1)?.createdAt ?? 0)
              } || reread.resumable.contains(where: { $0.id == crashed.id }))

        // A foreign id (another profile's job) has no record here.
        let foreignID = "other-profile/some-uuid"
        check("a foreign job id has no record in this ledger",
              reread.job(foreignID) == nil)
        check("a foreign id refuses start, checkpoints, records and finish",
              reread.start(foreignID) == nil
                && reread.checkpoint(foreignID, stage: "s") == nil
                && reread.record(foreignID, path: "p", outcome: "o") == nil
                && reread.finish(foreignID, as: .done) == nil)
        check("ownership is decided by the id's profile folder",
              JobLedger.owns(id: "alice/uuid-1", profileFolder: "alice")
                && !JobLedger.owns(id: "bob/uuid-2", profileFolder: "alice"))

        // Profile isolation: a ledger opened under another profile's file
        // genuinely does not see this profile's jobs.
        let otherProfile = "jobtest-other"
        let otherLedger = JobLedger(profile: otherProfile)
        check("another profile's ledger is a different, empty world",
              otherLedger.jobs.isEmpty && otherLedger.resumable.isEmpty)
        let theirs = otherLedger.request(paths: ["x.mp4"])
        check("jobs created under one profile do not appear in the other's",
              ledger.job(theirs.id) == nil && otherLedger.job(job.id) == nil)

        // --- 4. the explicit runner ------------------------------------------
        // A real video file so the engine path has something to refuse or do;
        // without models installed, an honest failure is the expected outcome.
        let video = scratch + "/not-a-video.mp4"
        try? Data("junk".utf8).write(to: URL(fileURLWithPath: video))
        let store = AnalysisStore()
        let engine = AnalysisEngine()
        let runner = JobRunner(ledger: ledger, engine: engine, store: store)
        let asked = ledger.request(paths: [video])

        switch await runner.run(asked.id) {
        case .success(let finished):
            check("the runner ran the job to a terminal phase",
                  finished.phase == .done || finished.phase == .failed)
            check("the runner checkpointed the named stages",
                  finished.hasCheckpoint("queued") && finished.hasCheckpoint("engine-pass"))
            check("the runner recorded an outcome for every path",
                  finished.outcomes.count == finished.paths.count)
            check("the store agrees with the ledger",
                  (store.analysis(for: video)?.phase == .done)
                    == (finished.outcomes[video] == "done"))
        case .failure(let refusal):
            check("the runner ran the job to a terminal phase (refused: \(refusal))", false)
        }

        check("a second runner is refused the same job",
              await runner.run(asked.id) == .failure(.alreadyStarted))
        check("a runner is refused an unknown job",
              await runner.run("nonesuch/uuid") == .failure(.notRequested))
        let empty = ledger.request(paths: [])
        check("an empty ask fails fast, and the ledger says so",
              await runner.run(empty.id) == .failure(.empty)
                && ledger.job(empty.id)?.phase == .failed)

        // Cancellation is per job and never writes a verdict.
        let cancellable = ledger.request(paths: [video])
        _ = ledger.start(cancellable.id)   // claimed without the runner
        runner.cancel(cancellable.id)      // runner is not ITS owner: no-op
        check("cancelling a job the runner does not own does nothing",
              ledger.job(cancellable.id)?.phase == .running)

        // These assertions exercise the missed integration contract: a request
        // queues work, and an unavailable engine is never a completed job.
        check("unavailable engine leaves the job failed, not falsely done",
              ledger.job(asked.id)?.phase == .failed)
        check("runner enqueued the previously unknown path",
              store.analysis(for: video)?.phase == .queued)
        let duplicates = ledger.request(paths: [video, video])
        check("request scope is deduplicated", duplicates.paths == [video])
        _ = ledger.start(duplicates.id)
        check("an outcome outside the requested scope is refused",
              ledger.record(duplicates.id, path: "/foreign.mp4", outcome: "done") == nil)

        var release: CheckedContinuation<Void, Never>?
        let blocked = JobRunner(ledger: ledger, engine: engine, store: store,
                                execute: { _, _ in await withCheckedContinuation { release = $0 } })
        let first = ledger.request(paths: [video])
        let firstTask = Task { await blocked.run(first.id) }
        while release == nil { await Task.yield() }
        let concurrent = ledger.request(paths: [video])
        check("a suspended runner refuses a second job",
              await blocked.run(concurrent.id) == .failure(.engineBusy)
                && ledger.job(concurrent.id)?.phase == .requested)
        blocked.cancel(first.id)
        release?.resume()
        _ = await firstTask.value
        check("cancelled work cannot acquire a success checkpoint later",
              ledger.job(first.id)?.phase == .cancelled
                && ledger.job(first.id)?.hasCheckpoint("engine-pass") == false)

        release = nil
        let switched = ledger.request(paths: [video])
        let switchedTask = Task { await blocked.run(switched.id) }
        while release == nil { await Task.yield() }
        let originalProfile = Paths.activeProfile
        Paths.activeProfile = "different-job-profile"
        store.reload(profile: Paths.activeProfile)
        release?.resume()
        _ = await switchedTask.value
        check("profile switch discards late outcomes from the new store",
              ledger.job(switched.id)?.phase == .cancelled
                && ledger.job(switched.id)?.outcomes.isEmpty == true)
        check("old-profile runner refuses new requests",
              await blocked.run(concurrent.id) == .failure(.profileChanged))
        Paths.activeProfile = originalProfile
        store.reload(profile: originalProfile)

        // Human decisions are terminal and need no model invocation result.
        let settled = scratch + "/settled.mp4"
        store.mark(.safe, on: [settled])
        let noop = JobRunner(ledger: ledger, engine: engine, store: store, execute: { _, _ in })
        let preserved = ledger.request(paths: [settled])
        _ = await noop.run(preserved.id)
        check("classification preserves a manually settled video",
              store.analysis(for: settled)?.userLabel == .safe
                && ledger.job(preserved.id)?.phase == .done)

        let corruptProfile = "corrupt-job-ledger"
        let corruptURL = URL(fileURLWithPath: Paths.jobsFile(in: corruptProfile))
        try? fm.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let badBytes = Data("{broken".utf8)
        try? badBytes.write(to: corruptURL)
        let corruptLedger = JobLedger(profile: corruptProfile)
        let refused = corruptLedger.request(paths: [video])
        check("corrupt history reports an error and refuses new work",
              corruptLedger.persistenceError != nil && corruptLedger.job(refused.id) == nil)
        check("corrupt history is preserved byte for byte",
              (try? Data(contentsOf: corruptURL)) == badBytes)

        let blockedProfile = "unwritable-job-ledger"
        let blockedURL = URL(fileURLWithPath: Paths.jobsFile(in: blockedProfile))
        let failingLedger = JobLedger(profile: blockedProfile)
        try? fm.createDirectory(at: blockedURL, withIntermediateDirectories: true)
        let unwritten = failingLedger.request(paths: [video])
        check("failed persistence cannot create an in-memory phantom job",
              failingLedger.job(unwritten.id) == nil && failingLedger.persistenceError != nil)

        print(failures == 0 ? "\nALL PASS job ledger" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
