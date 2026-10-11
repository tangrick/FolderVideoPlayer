// The videos taken within a few days of one video — a row's "Find Taken Around
// the Same Time".
//
// The order is the feature: the same day first, then a day away, and so on,
// shooting order within each. Counted in calendar days on a fixed calendar, so
// the answer is not a function of where the suite runs.
//
// Pure: no FileManager, no library. Milliseconds.
//
// Run: Tests/run_shot_nearby.sh

@testable import FVPModel
import Foundation

@main
struct ShotNearbyTest {
    static func main() {
        var failures = 0
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
            utc.date(from: DateComponents(year: 2019, month: 3, day: day, hour: hour, minute: minute))!
                .timeIntervalSince1970
        }

        let mine = at(12, 14)
        let pool: [(key: String, when: Double)] = [
            ("after2", at(14, 9)),
            ("evening", at(12, 21)),
            ("before1", at(11, 23, 50)),
            ("morning", at(12, 8)),
            ("after1", at(13, 0, 10)),
            ("edge", at(15, 23, 59)),
            ("outside", at(16, 0, 1)),
            ("before3", at(9, 0, 0)),
            ("tooEarly", at(8, 23, 59)),
            ("undated", 0),
            ("self", mine),
        ]
        let hits = ShotNearby.around(date: mine, dated: pool, excluding: "self", calendar: utc)

        checkEqual("same day first, then by days away, shooting order within each",
                   hits.map(\.key),
                   ["morning", "evening", "before1", "after1", "after2", "before3", "edge"])
        checkEqual("days are calendar days, not hours apart",
                   hits.map(\.days), [0, 0, 1, 1, 2, 3, 3])
        checkEqual("the video itself is not its own neighbour",
                   hits.contains { $0.key == "self" }, false)
        checkEqual("a video with no date is never a neighbour",
                   hits.contains { $0.key == "undated" }, false)

        // 23:50 and 00:10 the next morning: twenty minutes, and a day apart.
        let late = ShotNearby.around(date: at(11, 23, 50), dated: [("next", at(12, 0, 10))],
                                     excluding: "", calendar: utc)
        checkEqual("across midnight is a day apart", late.map(\.days), [1])

        checkEqual("an unknown date has no neighbours",
                   ShotNearby.around(date: 0, dated: pool, excluding: "self", calendar: utc).isEmpty, true)
        checkEqual("a window of no days is the same day only",
                   ShotNearby.around(date: mine, dated: pool, excluding: "self", days: 0, calendar: utc)
                       .map(\.key), ["morning", "evening"])

        // Two files stamped in the same second keep one order between runs.
        let tied: [(key: String, when: Double)] = [("b", at(12, 9)), ("a", at(12, 9))]
        checkEqual("ties are broken by key",
                   ShotNearby.around(date: mine, dated: tied, excluding: "", calendar: utc).map(\.key),
                   ["a", "b"])

        checkEqual("headings", [0, 1, 3].map { ShotNearby.heading(days: $0) },
                   ["Same day", "1 day apart", "3 days apart"])

        print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
