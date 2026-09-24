// The profile as a document: closing it, reopening it, and the honest title.
//
// P2/P3 of docs/plans/2026-09-17-profile-documents.md. The migration's own
// rules have their suite (test_profile_bundle.swift); this one covers what the
// File menu does — Close empties the tagging surfaces without touching the
// player's device-level state, a reopen reads the same tags back, a publish
// stamps the manifest and clears Edited only when every share took it, and the
// device name a profile publishes under can be changed without touching the
// share folder.
//
// Real files in a scratch directory and nothing else: no model, no engine.py,
// no Xcode. Milliseconds.
//
// Run: Tests/run_profile_document.sh

import Foundation

@main
struct ProfileDocumentTest {
    /// All of it on the main actor: `Library` is main-actor-isolated, and every
    /// await inside is against scratch storage on this machine.
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
        let scratch = NSTemporaryDirectory() + "fvp-profile-document-\(UUID().uuidString)"
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        // Never the real library. Set before any store is built.
        Paths.support = scratch
        Paths.volumes = scratch + "/share/"
        let video = Paths.volumes + "media/a.mp4"

        // — a profile with one tagged video, exactly as a session would leave it —
        Paths.activeProfile = "quincy"
        let library = Library()
        library.profiles = ["Quincy"]
        library.person = "Quincy"
        library.setTags(["Beach"], for: video)
        library.pinned = [scratch + "/pinned"]
        library.recent = [scratch + "/recent"]
        library.setFacts(["2026"], for: video)
        library.saveFacts()

        // MARK: publish state

        check("a fresh session starts clean", library.publishedClean)
        check("a fresh session has never published", library.lastPublishedAt == 0)

        // MARK: close

        library.closeProfile()
        check("closing empties the tags", library.tags.isEmpty)
        check("closing empties the headings", library.groups.isEmpty)
        check("closing empties the readings", library.facts.byKey.isEmpty)
        check("closing empties pinned folders", library.pinned.isEmpty)
        check("closing empties recent folders", library.recent.isEmpty)
        check("closing clears the undo slot", library.undoable == nil)
        check("the closed state says so", !library.profileOpen)
        check("closing clears derived fact counts", library.factCounts.isEmpty)
        check("closing keeps empty names out of recents", !library.recentProfiles.contains(""))

        // MARK: the closed state writes nothing

        library.setTags(["Sneaky"], for: video)
        check("a tag set while closed is not kept", library.tags.isEmpty)
        check("...and writes no stray bundle",
              !fm.fileExists(atPath: ProfileBundle.dir("")))
        library.setGroup("Place", for: ["Beach"])
        check("closed headings stay empty in memory", library.groups.isEmpty)
        check("headings set while closed go nowhere",
              !fm.fileExists(atPath: ProfileBundle.dir("")))

        // MARK: the bundle survives the close intact

        let bundle = ProfileBundle.dir("quincy")
        // On disk the tags are keyed share-relative — the same shape the
        // shares get, which is what makes a publish a copy rather than a
        // translation.
        let kept: [String: [String]] = JSONStore.load(bundle + "/tags.json", fallback: [:])
        check("the closed profile's tags are in its bundle",
              kept["media/a.mp4"]?.first?.lowercased() == "beach", "\(kept)")
        check("the bundle still has its manifest",
              ProfileBundle.manifest("quincy") != nil)

        // MARK: reopen

        await library.openProfile("Quincy")
        check("reopening says open again", library.profileOpen)
        check("reopening restores pinned folders", library.pinned == [scratch + "/pinned"])
        check("reopening restores recent folders", library.recent == [scratch + "/recent"])
        check("reopening brings the tags back",
              library.tagsFor(video) == ["Beach"],
              "\(library.tagsFor(video))")
        check("reopening puts the profile back in force",
              Paths.activeProfile == "quincy")
        library.setTags(["Beach", "Holiday"], for: video)

        // MARK: publish state transitions

        check("an edit breaks the clean state", !library.publishedClean)
        check("an edit does not invent a publish time", library.lastPublishedAt == 0)
        // Publish with no shares mounted: nothing is written, so nothing is
        // stamped — the NAS-asleep case the title must not lie about.
        let outcome = await library.publishTags()
        check("a publish to no shares writes nothing", outcome.written.isEmpty)
        check("...and stamps nothing", library.lastPublishedAt == 0)
        // A fake share: the writer checks `Paths.volumes + <share key>`, and
        // the share key comes from the tag key's first path component —
        // "media/a.mp4" publishes to a mount named "media".
        let fakeShare = scratch + "/share/media"
        try fm.createDirectory(atPath: fakeShare, withIntermediateDirectories: true)
        Paths.volumes = scratch + "/share/"
        let written = await library.publishTags()
        check("a publish to a mounted share writes it",
              written.written.contains(where: { $0.0 == "media" }), "\(written.written)")
        check("a real write stamps the manifest", library.lastPublishedAt > 0)
        check("...and the manifest on disk agrees",
              (ProfileBundle.manifest("quincy")?.lastPublishedAt ?? 0) > 0)
        check("a fully accepted publish is clean", library.publishedClean)

        // MARK: the shared file, through the library

        let sharedFolder = fakeShare + "/.FolderVideoPlayer/quincy"
        func sharedOnDisk() -> SharedTagFile? {
            if case let .file(file, _) = SharedTagDisk.read(folder: sharedFolder) { return file }
            return nil
        }
        check("the publish wrote tags.json on the share",
              sharedOnDisk()?.videos["a.mp4"] == ["Beach", "Holiday"],
              "\(sharedOnDisk()?.videos ?? [:])")
        // Another device tags a video this Mac has never seen tagged.
        fm.createFile(atPath: fakeShare + "/b.mp4", contents: Data())
        var theirs = sharedOnDisk()!
        theirs.videos["b.mp4"] = ["From TV"]
        _ = SharedTagDisk.write(theirs, folder: sharedFolder, device: "appletv-1")
        let heard = await library.mergeShared()
        let other = Paths.volumes + "media/b.mp4"
        check("another device's edit comes in", library.tagsFor(other) == ["From TV"],
              "\(library.tagsFor(other))")
        check("...counted as one change from elsewhere", heard == 1, "\(heard)")
        check("...without breaking the published state", library.publishedClean)
        // Undo of an edit made here must not take back what came from elsewhere.
        library.rememberForUndo("test edit")
        library.setTags(["Beach"], for: video)
        library.saveTags()
        await library.publishTags()
        var later = sharedOnDisk()!
        later.videos["b.mp4"] = ["From TV", "Later"]
        _ = SharedTagDisk.write(later, folder: sharedFolder, device: "appletv-1")
        _ = await library.mergeShared()
        library.undoTagChange()
        await library.publishTags()
        check("undo puts back this Mac's edit",
              sharedOnDisk()?.videos["a.mp4"] == ["Beach", "Holiday"],
              "\(sharedOnDisk()?.videos ?? [:])")
        check("...and keeps what another device changed since",
              library.tagsFor(other) == ["From TV", "Later"]
              && sharedOnDisk()?.videos["b.mp4"] == ["From TV", "Later"],
              "\(library.tagsFor(other))")
        // A move here reaches the file as a move.
        let moved = Paths.volumes + "media/moved/b.mp4"
        library.moveTags(from: other, to: moved)
        await library.publishTags()
        check("a move here reaches the file as a move",
              sharedOnDisk()?.videos["moved/b.mp4"] == ["From TV", "Later"]
              && sharedOnDisk()?.videos["b.mp4"] == nil
              && sharedOnDisk()?.gone["b.mp4"]?.to == "moved/b.mp4",
              "\(sharedOnDisk()?.videos ?? [:])")
        check("...and nothing is left waiting to be sent", library.sharedTagsInLine())

        // MARK: the device name

        let before = library.publishDeviceName
        library.setPublishDeviceName("Studio Mac")
        check("the device name changes", library.publishDeviceName != before)
        check("the device name is slugified", library.publishDeviceName == "studio-mac",
              library.publishDeviceName)
        check("the manifest carries the device",
              ProfileBundle.manifest("quincy")?.device == "studio-mac")
        library.setPublishDeviceName("   ")
        check("an empty device name is refused", library.publishDeviceName == "studio-mac")
        library.setPublishDeviceName("a/b")
        check("a path-shaped device name is refused", library.publishDeviceName == "studio-mac")

        // MARK: switching while closed goes through the same door

        library.closeProfile()
        check("closing again is calm", !library.profileOpen)
        library.switchProfile(to: "Quincy")
        check("switching from closed reopens in force",
              library.profileOpen && library.isActive("Quincy"))
        check("...with the tags it left with",
              library.tagsFor(video) == ["Beach", "Holiday"])

        // A writer that completes after an edit must not claim those newer tags reached the share.
        library.applyTags(["Before"], to: [video])
        _ = await library.publishTags { inputs in
            let outcome = await Library.syncAsync(inputs)
            await MainActor.run { library.applyTags(["After"], to: [video]) }
            return outcome
        }
        check("an edit during publication stays edited", !library.publishedClean)
        check("the manifest preserves edits made during publication",
              ProfileBundle.manifest("Quincy")?.publishedClean == false)

        // The same async boundary with a different profile in force.
        _ = await library.publishTags { inputs in
            let outcome = await Library.syncAsync(inputs)
            await MainActor.run { library.createProfile("Other") }
            return outcome
        }
        check("late publication leaves the incoming profile unstamped", library.lastPublishedAt == 0)
        check("late publication does not stamp the incoming bundle",
              ProfileBundle.manifest("Other")?.lastPublishedAt == 0)
        check("late publication stamps only the original bundle",
              (ProfileBundle.manifest("Quincy")?.lastPublishedAt ?? 0) > 0)
        check("profile switch clears the old publishing indicator", !library.isPublishing)

        // A request waiting behind an older publish must be invalidated by close.
        library.publishQueue = Task { @MainActor in library.closeProfile() }
        let cancelled = await library.publishTags()
        check("queued publication after close writes nothing", cancelled.written.isEmpty)
        check("queued publication creates no closed-state bundle",
              !fm.fileExists(atPath: ProfileBundle.dir("")))
        library.switchProfile(to: "Quincy")
        library.applyTags(["Still edited"], to: [video])
        let relaunched = Library()
        check("unpublished edits remain edited after relaunch", !relaunched.publishedClean)

        // Closing is not a profile named "unknown". Existing data under that
        // valid name must neither be exposed nor overwritten by closed stores.
        ProfileBundle.ensure(profile: "unknown")
        let unknownSuggestions = SuggestionStore(profile: "unknown")
        unknownSuggestions.decide(video, tag: "Private", verdict: .accepted)
        unknownSuggestions.flush()
        let unknownAnalysis = AnalysisStore(profile: "unknown")
        unknownAnalysis.mark(.nsfw, on: [video])
        JSONStore.save(Paths.facesFile(in: "unknown"), ["Private person": ["hash"]])
        let suggestionBytes = try Data(contentsOf: URL(fileURLWithPath: Paths.suggestionsFile(in: "unknown")))
        let markBytes = try Data(contentsOf: URL(fileURLWithPath: Paths.marksFile(in: "unknown")))
        unknownSuggestions.reload(profile: "")
        check("closed suggestions never read an unknown-named profile", unknownSuggestions.byVideo.isEmpty)
        unknownSuggestions.decide(video, tag: "Intruder", verdict: .accepted)
        unknownSuggestions.flush()
        unknownAnalysis.reload(profile: "")
        check("closed analysis never reads another profile's marks",
              unknownAnalysis.analysis(for: video)?.userLabel == nil)
        unknownAnalysis.mark(.safe, on: [video])
        check("closed suggestion flush preserves another profile's bytes",
              try Data(contentsOf: URL(fileURLWithPath: Paths.suggestionsFile(in: "unknown"))) == suggestionBytes)
        check("closed human marking preserves another profile's bytes",
              try Data(contentsOf: URL(fileURLWithPath: Paths.marksFile(in: "unknown"))) == markBytes)
        let closedFaces = FaceStore(profile: "")
        check("closed faces never read another profile's people", closedFaces.people.isEmpty)

        // MARK: a profile row with no name

        // A blank row: a name that never got written. Nothing in the app can
        // make one — every path that takes a name refuses an empty one — so it
        // arrives from a hand-edited or half-written state file, and until now
        // it could be neither named nor deleted. The rename only ever renamed
        // the profile in force, and a blank row can never BE in force; the
        // delete confirmation is "type the profile's name", and `ask` hands
        // back nil for an empty field, so it could never be satisfied.
        library.save()
        let statePath = scratch + "/state.json"
        var state = (try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: statePath))) as? [String: Any]) ?? [:]
        state["profiles"] = ["Quincy", "Other", ""]
        state["hiddenProfiles"] = []
        try JSONSerialization.data(withJSONObject: state)
            .write(to: URL(fileURLWithPath: statePath))
        let blanks = Library()
        check("a blank row loads into the list",
              blanks.profiles.contains(where: { blanks.isNameless($0) }))
        check("an empty name is nameless", blanks.isNameless(""))
        check("a name of spaces only is nameless too", blanks.isNameless("   "))
        check("a real name is not nameless", !blanks.isNameless("Quincy"))

        // Its own folder, as a nameless profile in force would have left it.
        let junk = ProfileBundle.dir("")
        try fm.createDirectory(atPath: junk, withIntermediateDirectories: true)
        JSONStore.save(junk + "/readings.json", ["media/a.mp4": ["2026"]])
        check("the blank row's folder is named for its slug",
              junk.hasSuffix("unknown.fvpprofile"), junk)

        // A profile actually CALLED "unknown" is the same slug — and therefore
        // the same folder. While one is listed, the blank row may not take that
        // folder with it.
        blanks.profiles = ["Quincy", "Other", "", "unknown"]
        let realUnknown = try Data(contentsOf: URL(fileURLWithPath: Paths.suggestionsFile(in: "unknown")))
        let guarded = await blanks.deleteProfile("")
        check("a blank row goes from the list", !blanks.profiles.contains(""))
        check("...while a profile called unknown keeps its folder",
              fm.fileExists(atPath: ProfileBundle.dir("unknown")))
        check("...and its own files are untouched",
              try Data(contentsOf: URL(fileURLWithPath: Paths.suggestionsFile(in: "unknown"))) == realUnknown)
        check("...and that name is not hidden for good", !blanks.hiddenProfiles.contains("unknown"))
        check("...and nothing is reported cleared",
              guarded.cleared.isEmpty && guarded.failed.isEmpty)

        // With no such profile listed, the blank row's own folder goes with it.
        blanks.profiles = ["Quincy", "Other", ""]
        _ = await blanks.deleteProfile("")
        check("a blank row is deletable without a name to type", !blanks.profiles.contains(""))
        check("...and its folder goes too", !fm.fileExists(atPath: junk))
        check("...and a real profile's bundle is left alone",
              fm.fileExists(atPath: ProfileBundle.dir("Quincy")))
        check("...and nothing is hidden under its slug", !blanks.hiddenProfiles.contains("unknown"))
        check("...and no empty name is offered to File ▸ Open Recent",
              !blanks.allProfiles().contains(""))

        // Naming it is the other half: the row keeps everything it holds and
        // everything it holds moves under the new name.
        blanks.profiles = ["Quincy", "Other", ""]
        try fm.createDirectory(atPath: junk, withIntermediateDirectories: true)
        JSONStore.save(junk + "/readings.json", ["media/a.mp4": ["2026"]])
        check("a blank row can be named", blanks.nameNamelessProfile(to: "Recovered"))
        check("...and leaves the list", !blanks.profiles.contains(""))
        check("...and is listed under its new name", blanks.profiles.contains("Recovered"))
        check("...and its bundle moves with it",
              fm.fileExists(atPath: ProfileBundle.dir("Recovered")) && !fm.fileExists(atPath: junk))
        let carried: [String: [String]] = JSONStore.load(Paths.profileFactsFile("Recovered"),
                                                         fallback: [:])
        check("...and its readings come with it", carried["media/a.mp4"] != nil, "\(carried)")
        check("...and its manifest says what it is called",
              ProfileBundle.manifest("Recovered")?.name == "Recovered")
        check("a name already in use is refused", !blanks.nameNamelessProfile(to: "Quincy"))
        check("a blank new name is refused", !blanks.nameNamelessProfile(to: "   "))
        blanks.profiles = ["Quincy", "Other"]
        check("naming needs a blank row to name", !blanks.nameNamelessProfile(to: "Anything"))

        // MARK: the title

        // The title claims Published only from a real timestamp, Edited from
        // the clean flag, and nothing at all when no profile is open.
        check("a closed profile contributes no title",
              PlayerWindowTitle.profilePart(name: "Quincy", open: false, publishing: false,
                                            publishedClean: true,
                                            lastPublishedAt: 1_700_000_000) == nil)
        check("an empty name contributes no title",
              PlayerWindowTitle.profilePart(name: "", open: true, publishing: false,
                                            publishedClean: true, lastPublishedAt: 0) == nil)
        check("publishing says so",
              PlayerWindowTitle.profilePart(name: "Quincy", open: true, publishing: true,
                                            publishedClean: false,
                                            lastPublishedAt: 0) == "Quincy — Publishing…")
        check("edited beats published",
              PlayerWindowTitle.profilePart(name: "Quincy", open: true, publishing: false,
                                            publishedClean: false,
                                            lastPublishedAt: 1_700_000_000)
              == "Quincy — Edited")
        check("never-published shows the bare name",
              PlayerWindowTitle.profilePart(name: "Quincy", open: true, publishing: false,
                                            publishedClean: true, lastPublishedAt: 0)
              == "Quincy")
        let words = PlayerWindowTitle.profilePart(name: "Quincy", open: true,
                                                  publishing: false, publishedClean: true,
                                                  lastPublishedAt: 1_700_000_000,
                                                  now: 1_700_000_000 + 130)
        check("a real timestamp reads as words", words == "Quincy — Published 2 min ago",
              words ?? "nil")
        check("a closed profile's manifest stamp survives the close",
              (ProfileBundle.manifest("quincy")?.lastPublishedAt ?? 0) > 0)

        print(failures == 0 ? "\nall profile document checks pass"
              : "\n\(failures) profile document check(s) FAILED")
        if failures > 0 { exit(1) }
    }
}
