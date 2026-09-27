// Opt-in background upkeep, the decisions half: what changed between two scans
// (added, removed, moved — and a move only when it is unambiguous), what gets
// queued (never a hidden video), when work waits, when a file is given up on,
// and a queue that survives a quit.
//
// Run: Tests/run_maintenance.sh

@testable import FVPModel
import Foundation

@main
struct MaintenanceTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        // --- diff ---------------------------------------------------------------

        let old: [String: Int64] = ["a.mp4": 10, "trip/b.mp4": 20, "c.mp4": 30, "dup1/x.mp4": 5, "dup2/x.mp4": 5]
        let new: [String: Int64] = ["a.mp4": 10, "2026/b.mp4": 20, "d.mp4": 40,
                                    "dup3/x.mp4": 5, "dup4/x.mp4": 5, "c-renamed.mp4": 30]
        let changes = MaintenancePlanner.diff(old: old, new: new)
        check("a file with the same name and size elsewhere is a move",
              changes.moved == [.init(from: "trip/b.mp4", to: "2026/b.mp4")], "\(changes.moved)")
        check("new files are added", changes.added.contains("d.mp4") && changes.added.contains("c-renamed.mp4"))
        check("a renamed file is a removal and an addition, not a guess",
              changes.removed.contains("c.mp4"))
        check("two namesakes of one size are not guessed at",
              Set(changes.added).isSuperset(of: ["dup3/x.mp4", "dup4/x.mp4"])
                && Set(changes.removed).isSuperset(of: ["dup1/x.mp4", "dup2/x.mp4"]))
        check("an unchanged file is not news", !changes.added.contains("a.mp4") && !changes.removed.contains("a.mp4"))
        check("no change is empty", MaintenancePlanner.diff(old: old, new: old).isEmpty)

        // --- the queue ------------------------------------------------------------

        let hidden: Set = [Paths.tagKey("/m/secret.mp4")]
        var queue = MaintenancePlanner.enqueue(["/m/one.mp4", "/m/secret.mp4", "/m/two.mp4"],
                                               work: [.metadata, .posters], into: [], hidden: hidden, now: 1)
        check("hidden videos are never queued", queue.map(\.path) == ["/m/one.mp4", "/m/two.mp4"])
        check("work is in the working order", queue.first?.remaining == [.posters, .metadata])
        queue = MaintenancePlanner.enqueue(["/m/one.mp4"], work: [.classify], into: queue, hidden: [], now: 2)
        check("queuing a queued video widens its work instead of doubling it",
              queue.count == 2 && queue[0].remaining == [.posters, .metadata, .classify])
        check("no allowed work queues nothing",
              MaintenancePlanner.enqueue(["/m/z.mp4"], work: [], into: [], hidden: [], now: 1).isEmpty)
        queue = MaintenancePlanner.drop(["/m/two.mp4"], from: queue)
        check("a removed video leaves the queue", queue.map(\.path) == ["/m/one.mp4"])
        queue = MaintenancePlanner.move([(from: "/m/one.mp4", to: "/m/moved/one.mp4")], in: queue)
        check("a moved video's work follows it", queue.first?.path == "/m/moved/one.mp4")

        // --- failures ----------------------------------------------------------------

        var item = queue[0]
        for _ in 1..<MaintenancePlanner.maxAttempts {
            guard let next = MaintenancePlanner.afterFailure(item, error: "unreadable") else { break }
            item = next
        }
        check("a failing video is retried", item.attempts == MaintenancePlanner.maxAttempts - 1 && item.lastError == "unreadable")
        check("...and set aside after the last attempt", MaintenancePlanner.afterFailure(item, error: "again") == nil)

        // --- pausing -----------------------------------------------------------------

        var settings = MaintenanceSettings()
        check("nothing opted in is nothing to do",
              MaintenancePlanner.pauseReason(settings, playing: false, onBattery: false, hour: 12) != nil)
        settings.folders = ["/m"]
        check("free to run", MaintenancePlanner.pauseReason(settings, playing: false, onBattery: false, hour: 12) == nil)
        check("pauses while playing by default",
              MaintenancePlanner.pauseReason(settings, playing: true, onBattery: false, hour: 12)?.contains("plays") == true)
        check("pauses on battery by default",
              MaintenancePlanner.pauseReason(settings, playing: false, onBattery: true, hour: 12)?.contains("battery") == true)
        settings.pauseWhilePlaying = false
        settings.pauseOnBattery = false
        check("both pauses can be turned off",
              MaintenancePlanner.pauseReason(settings, playing: true, onBattery: true, hour: 12) == nil)
        settings.schedule = .overnight
        check("overnight waits in the day",
              MaintenancePlanner.pauseReason(settings, playing: false, onBattery: false, hour: 15) != nil)
        check("overnight runs at night",
              MaintenancePlanner.pauseReason(settings, playing: false, onBattery: false, hour: 23) == nil
                && MaintenancePlanner.pauseReason(settings, playing: false, onBattery: false, hour: 3) == nil)
        check("a folder never scanned is due", MaintenancePlanner.isDue(lastScan: nil, minutes: 30, now: 0))
        check("a folder scanned a minute ago is not", !MaintenancePlanner.isDue(lastScan: 0, minutes: 30, now: 60))

        // --- snapshots ------------------------------------------------------------------

        let snap = MaintenancePlanner.snapshot([(path: "/m/a.mp4", size: 1), (path: "/m/sub/b.mp4", size: 2),
                                                (path: "/m/secret.mp4", size: 3), (path: "/other/c.mp4", size: 4)],
                                               under: "/m", hidden: hidden)
        check("a snapshot is relative, hidden and foreign files left out", snap == ["a.mp4": 1, "sub/b.mp4": 2], "\(snap)")

        // --- surviving a quit -----------------------------------------------------------

        let dir = NSTemporaryDirectory() + "fvp-maint-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var file = MaintenanceFile()
        file.settings = settings
        file.known = ["/m": snap]
        file.lastScan = ["/m": 99]
        file.queue = queue
        file.failed = ["/m/bad.mp4": "unreadable"]
        check("the upkeep file saves", file.save(to: dir + "/maintenance.json"))
        check("...and reads back whole, queue and all", MaintenanceFile.load(at: dir + "/maintenance.json") == file)
        check("an absent file is the default: nothing opted in",
              MaintenanceFile.load(at: dir + "/none.json").settings.folders.isEmpty)
        check("the default work is the cheap work only",
              MaintenanceSettings().work == [.posters, .metadata])

        print(failures == 0 ? "\nall maintenance checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
