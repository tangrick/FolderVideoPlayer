// The library overview: which videos each section lists, in what order, and
// that a hidden video is in none of them. Pure — plain values in, lists out.
//
// Run: Tests/run_library_overview.sh

@testable import FVPModel
import Foundation

@main
struct LibraryOverviewTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let now = 10_000_000.0, day = 86_400.0
        let keys = ["/m/a.mp4", "/m/b.mp4", "/m/c.mp4", "/m/d.mp4", "/m/secret.mp4"]
        let states: [String: WatchLog.State] = ["/m/a.mp4": .inProgress, "/m/b.mp4": .watched,
                                                "/m/c.mp4": .inProgress, "/m/secret.mp4": .inProgress]
        let played: [String: Double] = ["/m/a.mp4": now - 50, "/m/b.mp4": now - 10, "/m/secret.mp4": now]
        let buckets: [String: AnalysisBucket] = ["/m/a.mp4": .failed, "/m/b.mp4": .queued, "/m/c.mp4": .safe,
                                                 "/m/secret.mp4": .failed]
        let input = LibraryOverview.Input(
            known: keys, hidden: ["/m/secret.mp4"],
            watch: { states[$0] ?? .unwatched },
            lastPlayed: { played[$0] },
            progressSeen: ["/m/a.mp4": now - 100, "/m/c.mp4": now - 5, "/m/secret.mp4": now, "/m/b.mp4": now],
            addedOn: ["/m/a.mp4": now - 40 * day, "/m/b.mp4": now - 2 * day, "/m/d.mp4": now - day,
                      "/m/secret.mp4": now],
            hasPendingSuggestions: { $0 == "/m/d.mp4" || $0 == "/m/secret.mp4" },
            needsTags: { $0 != "/m/b.mp4" },
            analysis: { buckets[$0] ?? .unseen },
            now: now)
        let overview = LibraryOverview.build(input)

        check("continue watching is the unfinished ones, newest first",
              overview.paths(.continueWatching) == ["/m/c.mp4", "/m/a.mp4"], "\(overview.paths(.continueWatching))")
        check("a finished video with a stale resume stamp is not continued",
              !overview.paths(.continueWatching).contains("/m/b.mp4"))
        check("recently added is the last 30 days, newest first",
              overview.paths(.recentlyAdded) == ["/m/d.mp4", "/m/b.mp4"], "\(overview.paths(.recentlyAdded))")
        check("recently watched is by last play", overview.paths(.recentlyWatched) == ["/m/b.mp4", "/m/a.mp4"])
        check("unwatched is what has not been played", overview.paths(.unwatched) == ["/m/d.mp4"])
        check("awaiting review is the videos with pending suggestions", overview.paths(.awaitingReview) == ["/m/d.mp4"])
        check("needs tags is what the rule says, in library order, hidden left out",
              overview.paths(.needsTags) == ["/m/a.mp4", "/m/c.mp4", "/m/d.mp4"], "\(overview.paths(.needsTags))")
        check("the sections about tagging say which triage filter works through them",
              LibraryOverview.Kind.needsTags.triageFilter == .needsTags
                && LibraryOverview.Kind.awaitingReview.triageFilter == .hasSuggestions
                && LibraryOverview.Kind.unwatched.triageFilter == nil)
        check("needs tags says it only counts what the app has seen; others say nothing",
              LibraryOverview.Kind.needsTags.coverage != nil && LibraryOverview.Kind.unwatched.coverage == nil)
        check("analysis trouble is failed and unfinished", overview.paths(.analysisTrouble) == ["/m/a.mp4", "/m/b.mp4"])
        check("a hidden video is in no section",
              LibraryOverview.Kind.allCases.allSatisfy { !overview.paths($0).contains("/m/secret.mp4") })
        check("every section says how it fills when empty",
              LibraryOverview.Kind.allCases.allSatisfy { !$0.emptyNote.isEmpty })

        print(failures == 0 ? "\nall library overview checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
