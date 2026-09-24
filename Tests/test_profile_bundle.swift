// A tag profile as one document — the bundle layout, the manifest, and the
// one-time move of the legacy files into it.
//
// The migration is the risky half of this change and it is invisible when it
// goes right, so each way of getting it wrong gets a check of its own: a
// migration that MOVED the old files (leaving nothing behind to roll back to),
// one that ran twice and quietly rebuilt a profile the user had deleted, one
// that preferred a stale copy of a profile over the tags actually in hand, one
// that reset a live bundle's manifest, and one whose idea of where a profile
// lives disagrees with `Paths` — which is the layout every other file in the
// app reads.
//
// Real files in a scratch directory and nothing else: no model, no engine.py,
// no Xcode. Milliseconds.
//
// Run: Tests/run_profile_bundle.sh

@testable import FVPModel
import Foundation

@main
struct ProfileBundleTest {
    static func main() {
        var failures = 0

        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }

        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "fvp-profile-bundle-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: scratch) }
        try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        Paths.support = scratch
        Paths.activeProfile = "quincy"

        /// The layout as it was before bundles: the profile in force at the
        /// root, everyone else in `profiles/`, and their AI state in a folder
        /// beside their tag file.
        func writeLegacyTree(activeTags: [String: [String]] = ["/v/a.mp4": ["Iceland"]],
                             staleCopy: [String: [String]]? = nil) {
            try? fm.removeItem(atPath: scratch)
            try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
            JSONStore.save(Paths.stateFile, ["person": "Quincy"])
            JSONStore.save((scratch as NSString).appendingPathComponent("tags.json"), activeTags)
            JSONStore.save((scratch as NSString).appendingPathComponent("metadata.json"),
                           ["/v/a.mp4": ["2015"]])
            // A copy of the profile in force, left behind the last time it was
            // switched away from. The root file is the newer of the two.
            if let staleCopy {
                JSONStore.save((scratch as NSString).appendingPathComponent("profiles/quincy.json"),
                               staleCopy)
            }
            JSONStore.save((scratch as NSString).appendingPathComponent("profiles/guest.json"),
                           ["/v/b.mp4": ["Beach"]])
            let guest = (scratch as NSString).appendingPathComponent("profiles/guest")
            try? fm.createDirectory(atPath: guest, withIntermediateDirectories: true)
            JSONStore.save((guest as NSString).appendingPathComponent("tag-groups.json"),
                           ["Place": ["Iceland"]])
            JSONStore.save((guest as NSString).appendingPathComponent("faces.json"),
                           ["Ann": ["hash1"]])
            // An encoder's fitted heads, named the way the engine names them.
            JSONStore.save((guest as NSString).appendingPathComponent("clip_trained_heads.json"),
                           ["version": 1])
        }

        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

        print("— the bundle's shape —")

        checkEqual("a bundle is the profile's own folder, with the extension on it",
                   ProfileBundle.relativeDir("quincy"), "profiles/quincy.fvpprofile")
        checkEqual("...and the slug comes back off a bundle's name",
                   ProfileBundle.slug(fromBundleName: "quincy.fvpprofile"), "quincy")
        // `JobLedger` parses its own file's parent directory this way, so a
        // name that is not a bundle must come back untouched — otherwise every
        // job of an owning profile reads as a foreign one and is refused.
        checkEqual("...while a name that is not a bundle is left alone",
                   ProfileBundle.slug(fromBundleName: "quincy"), "quincy")
        checkEqual("...including one that merely mentions the extension",
                   ProfileBundle.slug(fromBundleName: "quincy.fvpprofile.bak"),
                   "quincy.fvpprofile.bak")

        checkEqual("the tags of the profile in force live in its bundle",
                   Paths.tagsFile, ProfileBundle.file(in: "quincy", "tags.json"))
        checkEqual("...its readings too, not at the support root",
                   Paths.metadataFile, ProfileBundle.file(in: "quincy", "readings.json"))
        checkEqual("...and its headings",
                   Paths.tagGroupsFile,
                   ProfileBundle.file(in: "quincy", ProfileBundle.headingsName))
        checkEqual("another profile's tags live in that profile's bundle",
                   Paths.profileFile("Guest"), ProfileBundle.file(in: "Guest", "tags.json"))
        check("a fitted head gets a folder of its own inside the bundle",
              Paths.trainedHeadsFile("clip").hasSuffix(
                  "/profiles/quincy.fvpprofile/heads/clip_trained_heads.json"),
              Paths.trainedHeadsFile("clip"))
        check("...and so does the prior measured beside it",
              Paths.tagPriorsFile("clip", in: "Guest").hasSuffix(
                  "/profiles/guest.fvpprofile/heads/clip_tag_priors.json"),
              Paths.tagPriorsFile("clip", in: "Guest"))

        print("— the one-time migration —")

        writeLegacyTree()
        let first = ProfileBundle.migrateIfNeeded(activeProfile: "quincy",
                                                 names: ["quincy": "Quincy"],
                                                 device: "dev1", root: scratch)
        check("a migration reports that it ran", first.ran)
        checkEqual("...and which profiles it made bundles for",
                   first.created.sorted(), ["guest", "quincy"])

        checkEqual("the profile in force's tags arrive in its bundle",
                   JSONStore.load(ProfileBundle.file(in: "quincy", "tags.json"),
                                  fallback: [String: [String]]()),
                   ["/v/a.mp4": ["Iceland"]])
        checkEqual("...and its readings arrive beside them",
                   JSONStore.load(ProfileBundle.file(in: "quincy", ProfileBundle.readingsName),
                                  fallback: [String: [String]]()),
                   ["/v/a.mp4": ["2015"]])
        checkEqual("another profile's tag file arrives in ITS bundle",
                   JSONStore.load(ProfileBundle.file(in: "guest", "tags.json"),
                                  fallback: [String: [String]]()),
                   ["/v/b.mp4": ["Beach"]])
        checkEqual("a legacy heading map is renamed for what it holds",
                   JSONStore.load(ProfileBundle.file(in: "guest", ProfileBundle.headingsName),
                                  fallback: [String: [String]]()),
                   ["Place": ["Iceland"]])
        checkEqual("a legacy faces file arrives under the same name",
                   JSONStore.load(ProfileBundle.file(in: "guest", "faces.json"),
                                  fallback: [String: [String]]()),
                   ["Ann": ["hash1"]])
        check("a legacy head lands in the bundle's heads folder",
              exists(ProfileBundle.file(in: "guest", "heads/clip_trained_heads.json")))
        check("...named for its encoder, not loose beside the tags",
              !exists(ProfileBundle.file(in: "guest", "clip_trained_heads.json")))
        check("every bundle gets a manifest",
              ProfileBundle.manifest("quincy") != nil
                && ProfileBundle.manifest("guest") != nil)
        check("...carrying the person's own name rather than the slug",
              ProfileBundle.manifest("quincy")?.name == "Quincy",
              String(describing: ProfileBundle.manifest("quincy")?.name))
        check("...the format version this build writes",
              ProfileBundle.manifest("quincy")?.version == ProfileBundle.formatVersion)
        check("...and nothing published yet, which is not the same as just now",
              ProfileBundle.manifest("quincy")?.lastPublishedAt == 0)

        print("— what a migration must NOT do —")

        // Nothing moves. A migration that turns out badly is undone by deleting
        // the bundles, and that only works if the old files are still there.
        check("the root tag file is left where it was",
              exists((scratch as NSString).appendingPathComponent("tags.json")))
        check("...the readings too",
              exists((scratch as NSString).appendingPathComponent("metadata.json")))
        check("...and the legacy profile folder is copied, never emptied",
              exists((scratch as NSString).appendingPathComponent("profiles/guest/tag-groups.json")))
        check("...along with the loose tag file beside it",
              exists((scratch as NSString).appendingPathComponent("profiles/guest.json")))

        // A deleted profile must stay deleted. Without the marker, the legacy
        // files would rebuild it on the next launch — a profile the user had
        // deliberately thrown away, back with everything it held.
        try? fm.removeItem(atPath: ProfileBundle.dir("guest", root: scratch))
        let second = ProfileBundle.migrateIfNeeded(activeProfile: "quincy", root: scratch)
        check("a second migration does not run at all", !second.ran)
        check("...so a bundle that was deleted is not rebuilt",
              !exists(ProfileBundle.dir("guest", root: scratch)))
        check("...and the marker is what remembers that",
              exists(ProfileBundle.marker(root: scratch)))

        // The profile in force's own tags are the root file, so a stale copy of
        // the same profile left in `profiles/` must not win.
        writeLegacyTree(staleCopy: ["/v/a.mp4": ["Old"]])
        var third = ProfileBundle.Migration()
        do {
            // Same tree, marker removed: the migration runs again.
            try? fm.removeItem(atPath: ProfileBundle.marker(root: scratch))
            third = ProfileBundle.migrateIfNeeded(activeProfile: "quincy", root: scratch)
        }
        checkEqual("the tags in hand beat a stale copy of the same profile",
                   JSONStore.load(ProfileBundle.file(in: "quincy", "tags.json"),
                                  fallback: [String: [String]]()),
                   ["/v/a.mp4": ["Iceland"]])
        check("...and the run is reported as having happened", third.ran)

        print("— a live bundle is never reset —")

        ProfileBundle.ensure(profile: "quincy", name: "Quincy", device: "dev1", root: scratch)
        let created = ProfileBundle.manifest("quincy")?.created
        ProfileBundle.ensure(profile: "quincy", name: "Quincy", device: "dev1", root: scratch)
        checkEqual("asking for a bundle that exists keeps its created date",
                   ProfileBundle.manifest("quincy")?.created, created)
        // A rename corrects the name and nothing else.
        ProfileBundle.ensure(profile: "quincy", name: "Quincy Hale", root: scratch)
        checkEqual("...a rename corrects the name",
                   ProfileBundle.manifest("quincy")?.name, "Quincy Hale")
        checkEqual("...without touching the date it was made",
                   ProfileBundle.manifest("quincy")?.created, created)
        checkEqual("...or inventing a publish",
                   ProfileBundle.manifest("quincy")?.lastPublishedAt, 0)
        // The device name is what the profile publishes AS (`tags-<device>`),
        // so it is part of the document: recorded when one is given, kept when
        // a later call does not give one, and corrected when a later call
        // names a different one — the publish name is editable (Profile
        // Settings), and the manifest must say what the shares are already
        // being told. Only a call that names NO device leaves the record as
        // it stands.
        ProfileBundle.ensure(profile: "dana", name: "Dana", device: "dev9", root: scratch)
        checkEqual("a new bundle records the device it publishes as",
                   ProfileBundle.manifest("dana")?.device, "dev9")
        ProfileBundle.ensure(profile: "dana", name: "Dana", root: scratch)
        checkEqual("...and a later ask that names no device does not erase it",
                   ProfileBundle.manifest("dana")?.device, "dev9")
        ProfileBundle.ensure(profile: "dana", name: "Dana", device: "dev10", root: scratch)
        checkEqual("...while a later ask that names another corrects it",
                   ProfileBundle.manifest("dana")?.device, "dev10")
        // quincy's bundle pre-existed the dev1 ensure above (the migration
        // made it, with no device), so the dev1 ask corrected it too.
        checkEqual("...and an existing manifest takes a device when one is named",
                   ProfileBundle.manifest("quincy")?.device, "dev1")

        ProfileBundle.markPublished(profile: "quincy", at: 1_700_000_000, root: scratch)
        checkEqual("a publish is stamped on the bundle",
                   ProfileBundle.manifest("quincy")?.lastPublishedAt, 1_700_000_000)
        checkEqual("...and the manifest is otherwise left alone",
                   ProfileBundle.manifest("quincy")?.name, "Quincy Hale")
        // A profile with no bundle has nothing to stamp, and must not acquire
        // one by being published to — this is called from the publish path.
        ProfileBundle.markPublished(profile: "nobody", at: 1_700_000_000, root: scratch)
        check("stamping a profile that does not exist creates nothing",
              !exists(ProfileBundle.dir("nobody", root: scratch)))

        checkEqual("the bundles on disk are the ones with a folder",
                   ProfileBundle.slugs(root: scratch), ["dana", "guest", "quincy"])

        print("all profile bundle checks pass")
        if failures > 0 {
            print("\(failures) FAILED")
            exit(1)
        }
    }
}
