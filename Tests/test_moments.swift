// Moments: bookmarks in a video, with an optional range.
//
//   1. validation — finite, non-negative times; an end after the start; a title;
//   2. sorting by time, then by when each was made;
//   3. a round trip to disk, a newer file read for what is understood, and an
//      edit that keeps its creation time;
//   4. a moved file takes its moments; forgetting a file drops them;
//   5. the store: per profile, refused edits change nothing, delete and undo.
//
// Run: Tests/run_moments.sh

@testable import FVPModel
import Foundation

@main
struct MomentsTest {
    @MainActor
    static func main() async {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        func moment(_ key: String, _ start: Double, end: Double? = nil, title: String = "m", made: Double = 0) -> Moment {
            Moment(key: key, start: start, end: end, title: title, createdAt: made, modifiedAt: made)
        }

        // --- 1. validation -----------------------------------------------------------

        check("a point is valid", moment("a", 5).problem == nil)
        check("a range is valid", moment("a", 5, end: 9).problem == nil)
        check("a negative time is refused", moment("a", -1).problem == .invalidTime)
        check("a time that is not a number is refused", moment("a", .nan).problem == .invalidTime)
        check("an end before the start is refused", moment("a", 5, end: 4).problem == .endNotAfterStart)
        check("an end at the start is refused", moment("a", 5, end: 5).problem == .endNotAfterStart)
        check("an infinite end is refused", moment("a", 5, end: .infinity).problem == .invalidTime)
        check("a blank title is refused", moment("a", 5, title: "  ").problem == .emptyTitle)
        check("a default title names the time", Moment.defaultTitle(at: 83) == "Moment at 1:23"
                && Moment.defaultTitle(at: 3723) == "Moment at 1:02:03")

        // --- 2. sorting -------------------------------------------------------------------

        var book = MomentBook()
        try? book.upsert(moment("a", 30, title: "later", made: 1))
        try? book.upsert(moment("a", 10, title: "second made", made: 5))
        try? book.upsert(moment("a", 10, title: "first made", made: 2))
        try? book.upsert(moment("b", 1, title: "other video", made: 3))
        check("a video's moments are in time order, then creation order",
              book.moments(for: "a").map(\.title) == ["first made", "second made", "later"])
        check("another video's moments are its own", book.moments(for: "b").map(\.title) == ["other video"])

        var refused = book
        do {
            try refused.upsert(moment("a", 5, end: 2))
            check("an invalid moment is refused", false)
        } catch {
            check("an invalid moment is refused", refused == book)
        }

        // --- 3. disk ------------------------------------------------------------------------

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-moments-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        let file = scratch + "/nested/moments.json"
        check("a book saves", book.save(to: file))
        check("a book round-trips", MomentBook.load(at: file) == book)
        let newer = """
        {"version": 4, "future": [1], "moments": [{"id": "\(UUID().uuidString)", "key": "k", "start": 2,
          "title": "from the future", "note": "", "createdAt": 1, "modifiedAt": 1, "source": "manual",
          "colour": "red"}]}
        """
        try? newer.write(toFile: file, atomically: true, encoding: .utf8)
        check("a newer file is read for what is understood",
              MomentBook.load(at: file).moments(for: "k").first?.title == "from the future")

        var edited = book.moments(for: "a")[2]
        let created = edited.createdAt
        edited.title = "renamed"
        edited.note = "a note"
        edited.end = 45
        try? book.upsert(edited, now: 99)
        let after = book.moment(edited.id)
        check("an edit keeps when the moment was made and records when it changed",
              after?.createdAt == created && after?.modifiedAt == 99 && after?.title == "renamed"
                && after?.note == "a note" && after?.end == 45)

        // --- 4. moves ------------------------------------------------------------------------

        check("a move reports how many moved", book.move(from: "a", to: "a2") == 3)
        check("a moved file keeps its moments", book.moments(for: "a").isEmpty && book.moments(for: "a2").count == 3)
        book.forget("b")
        check("forgetting a file drops its moments", book.moments(for: "b").isEmpty)

        // --- 5. the store ---------------------------------------------------------------------

        let store = MomentStore(root: scratch)
        store.reload(profile: "alice")
        let video = "/media/clip.mp4"
        let added = store.add(path: video, at: 83)
        check("a moment is added at the playhead, titled by its time",
              added?.title == "Moment at 1:23" && store.moments(for: video).count == 1)
        let fromLine = store.add(path: video, at: 10, end: 14, title: "hello there", source: .transcript)
        check("a transcript line becomes a ranged moment", fromLine?.isRange == true && fromLine?.source == .transcript)
        var bad = added!
        bad.end = 1
        check("an invalid edit is refused", !store.update(bad) && store.problem != nil)
        check("...and changes nothing", store.moments(for: video).first { $0.id == bad.id }?.end == nil)
        store.delete(added!.id)
        check("delete removes it", store.moments(for: video).count == 1 && store.lastDeleted?.id == added!.id)
        store.undoDelete()
        check("undo puts it back", store.moments(for: video).count == 2 && store.lastDeleted == nil)
        store.move(from: video, to: "/media/moved/clip.mp4")
        check("the store carries a moved file's moments",
              store.moments(for: video).isEmpty && store.moments(for: "/media/moved/clip.mp4").count == 2)

        let reread = MomentStore(root: scratch)
        reread.reload(profile: "alice")
        check("moments survive a relaunch", reread.moments(for: "/media/moved/clip.mp4").count == 2)
        reread.reload(profile: "bob")
        check("another profile has none of them", reread.moments(for: "/media/moved/clip.mp4").isEmpty)
        reread.reload(profile: "")
        check("a closed profile holds nothing and adds nothing",
              reread.add(path: video, at: 1) == nil && reread.book == MomentBook())

        print(failures == 0 ? "\nall moment checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
