// Hidden videos — the password, the filter, and the one invariant that
// matters: hiding changes NOTHING else about a video.
//
// The feature is app-only by decision: no rename, no flag, no move, no
// encryption. That makes two things worth proving rather than assuming:
//
//   1. the password really is a credential — not stored in the clear, checked
//      in constant time, and a file that cannot be read locks the app instead
//      of opening it (a broken record must never read as "no password");
//   2. hiding is only a visibility flag — tags, the favourite mark and the
//      resume position all survive a hide/unhide round trip, and the file on
//      disk is byte-for-byte where it was.
//
// It also pins the share-relative keying, because a hidden set that means
// something different after a remount is a hidden set that quietly forgets.
//
// Scratch root only: `Paths.support` is redirected before any store is built,
// so nothing here can reach a real library.
//
// `@main` rather than top-level code, because this file compiles alongside the
// app's model layer and only main.swift may carry top-level statements.

import Foundation

@main
struct HiddenTest {
    /// Wrapped rather than `throws`, so a thrown error prints the checks that
    /// already ran instead of losing them to the runtime's top-level abort.
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            print("\nFAIL the harness threw: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-hidden-\(UUID().uuidString)"
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        // Never the real library. Set before any store is built.
        Paths.support = scratch

        let recordPath = scratch + "/hidden.json"

        // --- 1. the credential -------------------------------------------------
        let lock = HiddenLock(root: scratch)
        check("a fresh install has no password", !lock.hasPassword)
        check("a fresh install is locked", !lock.isUnlocked)
        check("a fresh install has no trouble", lock.trouble == nil)

        try await lock.setPassword("hunter2", iterations: 5_000)
        check("setting a password records it", lock.hasPassword)
        check("the person who set it is not asked again this session", lock.isUnlocked)
        check("the record is on disk", fm.fileExists(atPath: recordPath))

        let raw = try String(contentsOfFile: recordPath, encoding: .utf8)
        check("the password is not stored in the clear", !raw.contains("hunter2"))
        check("no plaintext field carries it", !raw.lowercased().contains("password"))
        check("the record names its own format version", raw.contains("\"version\""))

        lock.lock()
        check("locking closes the session", !lock.isUnlocked)
        check("the right password opens it", await lock.unlock("hunter2"))
        lock.lock()
        check("a wrong password does not", !(await lock.unlock("hunter3")))
        check("a wrong password leaves it locked", !lock.isUnlocked)
        check("an empty password does not open it", !(await lock.unlock("")))

        // A second instance is a relaunch: the password is remembered, the
        // session is not.
        let reloaded = HiddenLock(root: scratch)
        check("a relaunch still knows a password exists", reloaded.hasPassword)
        check("a relaunch is locked", !reloaded.isUnlocked)
        check("the stored record verifies", await reloaded.unlock("hunter2"))

        try await lock.changePassword(from: "hunter2", to: "correct horse")
        lock.lock()
        check("the new password works", await lock.unlock("correct horse"))
        lock.lock()
        check("the old password no longer works", !(await lock.unlock("hunter2")))
        var refused = false
        do { try await lock.changePassword(from: "wrong", to: "x") } catch { refused = true }
        check("changing needs the current password", refused)

        check("removing reports the file it took", lock.removePassword() != nil)
        check("after removing there is no password", !lock.hasPassword)
        check("after removing it stays locked", !lock.isUnlocked)
        check("the record file is gone", !fm.fileExists(atPath: recordPath))
        check("a fresh reader agrees", !HiddenLock(root: scratch).hasPassword)

        // --- 2. a broken record is a LOCKED app, never an open one -------------
        try Data("{\"version\":1,\"iterations\":".utf8)
            .write(to: URL(fileURLWithPath: recordPath))
        let broken = HiddenLock(root: scratch)
        check("a truncated record is reported", broken.trouble != nil)
        check("a truncated record still counts as protected", broken.hasPassword)
        check("a truncated record is not unlocked", !broken.isUnlocked)

        let future = #"{"version":99,"iterations":1000,"salt":"AAAA","hash":"AAAA"}"#
        try Data(future.utf8).write(to: URL(fileURLWithPath: recordPath))
        let newer = HiddenLock(root: scratch)
        check("a newer record is refused, not guessed at", newer.trouble == .tooNew(99))
        check("a newer record still locks", !newer.isUnlocked)
        try? fm.removeItem(atPath: recordPath)

        // --- 3. the filter, in all three modes ---------------------------------
        let a = "/Volumes/share/clips/a.mp4"
        let b = "/Volumes/share/clips/b.mp4"
        let c = "/Volumes/share/clips/c.mp4"
        let hidden: Set<String> = [Paths.tagKey(b)]

        let omit = HiddenFilter.omit(hidden)
        check("omit drops the hidden video", omit.apply(to: [a, b, c]) == [a, c])
        check("omit knows what it hides", omit.hides(b) && !omit.hides(a))
        check("omit with nothing hidden is a no-op",
              HiddenFilter.omit([]).apply(to: [a, b]) == [a, b])

        let only = HiddenFilter.only(hidden)
        check("only keeps the hidden video", only.apply(to: [a, b, c]) == [b])
        check("only with nothing hidden is empty",
              HiddenFilter.only([]).apply(to: [a, b]) == [])

        check("all keeps everything", HiddenFilter.all.apply(to: [a, b, c]) == [a, b, c])
        check("all hides nothing", !HiddenFilter.all.hides(b))

        // Share-relative keying, so a remount means the same thing.
        check("a share path keys share-relative", Paths.tagKey(a) == "share/clips/a.mp4")
        check("the key maps back to an openable path", Paths.tagPath("share/clips/a.mp4") == a)
        check("a folder's hidden count counts its videos",
              HiddenFilter.hiddenCount(under: "/Volumes/share/clips", hidden: hidden) == 1)
        check("a sibling folder is not counted",
              HiddenFilter.hiddenCount(under: "/Volumes/share/other", hidden: hidden) == 0)
        check("nothing hidden counts as nothing",
              HiddenFilter.hiddenCount(under: "/Volumes/share/clips", hidden: []) == 0)

        // --- 4. hiding is ONLY a visibility flag -------------------------------
        let media = scratch + "/media"
        try fm.createDirectory(atPath: media, withIntermediateDirectories: true)
        let video = media + "/one.mp4"
        try Data(repeating: 7, count: 4096).write(to: URL(fileURLWithPath: video))

        let lib = Library()
        lib.setTags(["Trip"], for: video)
        lib.setRating(4, for: video)
        lib.note(position: 42, total: 100, for: video)
        lib.saveTags()
        lib.save()

        check("the tagged video is in the tag list", lib.taggedWith("Trip").contains(video))
        check("the rated video carries 4 stars", lib.rating(video) == 4)
        check("its progress is remembered", lib.resumePoint(video) == 42)
        check("the tag counts one video", lib.count(of: "Trip") == 1)

        check("hiding reports how many it hid", lib.hide([video]) == 1)
        check("hiding again is a no-op", lib.hide([video]) == 0)
        check("the video is hidden", lib.isHidden(video))

        check("it drops out of the tag's list", !lib.taggedWith("Trip").contains(video))
        check("it drops out of the 4-star list", !lib.rated(4).contains(video))
        check("the tag count follows it out", lib.count(of: "Trip") == 0)
        check("the ordinary filter omits it", lib.hiddenFilter.apply(to: [video]).isEmpty)
        check("the hidden list names it", lib.hiddenPaths() == [video])

        // The invariant: hiding is not deleting. Everything else survived.
        // (The 4-star rating rides in the tag list — stars are tags now.)
        check("its tags are still there", lib.tagsFor(video) == ["Trip", "4 Stars"])
        check("its rating is still there", lib.rating(video) == 4)
        check("its progress is still there", lib.resumePoint(video) == 42)

        // --- the left panel may not NAME a hidden video ------------------------
        // The Resume row prints a file name in the sidebar, on screen while the
        // app is locked, so it is the one place a hidden video could be read
        // out without the password.
        check("a hidden video is not offered to Resume",
              lib.resumable(Session(mode: "folder", root: media, path: video, tag: nil)) == nil)
        check("a session left by the Hidden view is not offered",
              lib.resumable(Session(mode: PlayMode.hidden.rawValue, root: nil,
                                    path: video, tag: nil)) == nil)
        check("an ordinary session is still offered",
              lib.resumable(Session(mode: "folder", root: media, path: a, tag: nil)) == a)
        check("no session is nothing to offer", lib.resumable(nil) == nil)
        check("a session with no path is nothing to offer",
              lib.resumable(Session(mode: "folder", root: media, path: "", tag: nil)) == nil)

        // The file on disk was not touched at all.
        check("the file still exists where it was", fm.fileExists(atPath: video))
        let attrs = try fm.attributesOfItem(atPath: video)
        check("the file was neither renamed nor resized",
              (attrs[.size] as! NSNumber).intValue == 4096)

        // --- 5. the hidden set survives a relaunch, and unhiding restores ------
        let relaunch = Library()
        check("a relaunch still has it hidden", relaunch.isHidden(video))
        check("a relaunch still hides it from the tag list",
              !relaunch.taggedWith("Trip").contains(video))

        check("unhiding reports how many came back", relaunch.unhide([video]) == 1)
        check("unhiding again is a no-op", relaunch.unhide([video]) == 0)
        check("it is back in the tag's list", relaunch.taggedWith("Trip").contains(video))
        check("the tag counts it again", relaunch.count(of: "Trip") == 1)
        check("its tags survived the round trip",
              relaunch.tagsFor(video) == ["Trip", "4 Stars"])
        check("its rating survived the round trip", relaunch.rating(video) == 4)
        check("its progress survived the round trip", relaunch.resumePoint(video) == 42)
        check("nothing is left hidden", relaunch.hiddenPaths().isEmpty)
        check("unhiding offers it to Resume again",
              relaunch.resumable(Session(mode: "folder", root: media,
                                         path: video, tag: nil)) == video)

        print("")
        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("hidden videos — all checks passed")
    }
}
