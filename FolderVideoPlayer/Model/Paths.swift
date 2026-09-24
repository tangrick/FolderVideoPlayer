import Foundation

/// A file-based override for running this Mac in another engine mode.
///
/// ## Why a file, when there is already an environment variable
///
/// Because Xcode OWNS the scheme file and re-serialises it from its own memory
/// whenever it feels like it, silently reverting hand-written environment
/// variables. A Core ML session becomes a Python one with nothing on screen
/// admitting it — that cost a whole test session on 2026-09-12 ("everytime i
/// launch the app using xcode i still end using the old python one"), and the
/// scheme's checkbox state was rewritten three times while being set from
/// outside. A file at a fixed path outside the project cannot be rewritten.
///
/// Format — one `key=value` per line, `#` comments and blank lines ignored:
///
///     mode=python
///     support=~/fvp-coreml-test
///
/// Environment variables still WIN over the file, so the test harnesses
/// (`setenv`) and any CLI launch are unaffected.
///
/// ## The default is Core ML, and this file opts OUT of it
///
/// A bundled app runs the in-process Core ML engine unless this file says
/// `mode=python`: that is the engine a downloaded DMG must run, because the Mac
/// it lands on has no Python, no torch and no ffmpeg. The Python path —
/// `engine.py`, the child process, the 768-dim ViT-L/14 space — is kept for
/// development, and this line is how it is selected:
///
///     mode=python                 # the child, against the default library
///     support=/path/to/scratch    # ...or against a test library
///
/// `support` is independent of the mode. It is how a test rig points the app at
/// a scratch library, and it is read the same way in both engines.
enum DevOverride {
    /// Not inside `Paths.support` — that is the very thing it may be setting.
    static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".fvp-engine")

    /// Read once per process: this describes how the app was LAUNCHED, so a
    /// change mid-run would only ever apply to half a session. Not private —
    /// `CoreMLClassifier.mode(environment:override:)` takes it as a parameter so
    /// the gate can drive the decision without a file on disk.
    ///
    /// Empty in anything that is not a bundled app. Without that guard the file
    /// leaks into the test binaries the moment it carries a `rank=` line, and
    /// the gates start ranking by priors they never asked for (one did exactly
    /// that, 2026-09-12: `FAIL and ranked strongest first`).
    static let values: [String: String] = {
        guard inUse else { return [:] }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { out[key] = value }
        }
        return out
    }()

    static func string(_ key: String) -> String? { values[key.lowercased()] }

    /// Whether this process is a real app launch rather than a test binary.
    ///
    /// The gates compile the model layer with `swiftc` and run from a temp
    /// directory with `Paths.support` pointed at their own scratch dir. Letting
    /// them read this file would mean a stray `~/.fvp-engine` could redirect a
    /// test into another library mid-gate — so only a bundled app obeys it.
    static var inUse: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// A support directory, with `~` expanded so the file reads naturally.
    static var support: String? {
        guard inUse, var value = string("support") else { return nil }
        if value == "~" { value = NSHomeDirectory() }
        else if value.hasPrefix("~/") {
            value = (NSHomeDirectory() as NSString).appendingPathComponent(String(value.dropFirst(2)))
        }
        return value
    }
}

/// Where everything lives, and the two path forms the app moves between.
enum Paths {
    static let appName = "FolderVideoPlayer"

    /// Where macOS hangs mounted shares. Stripping it is what makes a tag mean
    /// the same thing here and on any other device reaching the same NAS.
    static var volumes = "/Volumes/"

    /// Redirectable, so a test run never touches a real media library.
    /// Precedence: environment, then the dev override file, then the default.
    static var support = ProcessInfo.processInfo.environment["FVP_SUPPORT"]
        ?? DevOverride.support
        ?? (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/" + appName)

    /// Which tag profile is in force. `Library` is the only writer — it keeps
    /// this in step with `person` — and it exists so a per-profile file can
    /// find its own name without every store being handed the profile at
    /// construction (a `@StateObject` cannot see the library that outlives it).
    static var activeProfile: String = slug(NSUserName())

    static var stateFile: String { (support as NSString).appendingPathComponent("state.json") }

    /// The tags of the profile in force.
    ///
    /// Inside the profile's own bundle since 2026-09-17. It used to be
    /// `support/tags.json` — a single file at the root "the PyObjC build reads",
    /// which was true when that build existed and stopped being the reason once
    /// it was retired: the only readers left were this app's own load and save,
    /// the pre-scan backup, and the Settings export. See `ProfileBundle`.
    static var tagsFile: String { profileFile(activeProfile) }
    /// What kind of thing each tag names. Kept out of `tagsFile` because that
    /// one is published to the other devices verbatim — a heading is this Mac's
    /// filing, not part of the tag itself.
    ///
    /// Per profile since 2026-09-17, at the maintainer's request: the tags are
    /// one person's, so the way they are filed is too. It lives in the profile
    /// folder rather than in a slug-keyed dictionary because the folder is
    /// already moved by a rename and removed by a delete, so those cases need
    /// no code of their own.
    static func tagGroupsFile(in profile: String) -> String {
        (profileDir(profile) as NSString)
            .appendingPathComponent(ProfileBundle.headingsName)
    }

    static var tagGroupsFile: String { tagGroupsFile(in: activeProfile) }

    /// Where the headings lived when every profile shared them. Read once to
    /// seed the profile in force, never written.
    static var sharedTagGroupsFile: String {
        (support as NSString).appendingPathComponent("tag-groups.json")
    }
    /// Which tags were read off the file rather than guessed from the picture.
    /// Kept out of `tagsFile` for the same reason as the groups above: that one
    /// is published to the other devices verbatim, and where a tag came from is
    /// this Mac's knowledge, not part of the tag.
    static var tagProvenanceFile: String { (support as NSString).appendingPathComponent("tag-provenance.json") }
    /// The facts the app READ off the files — the capture date, the resolution,
    /// the camera, the place from GPS. Kept out of `tagsFile` because that one
    /// is published to the other devices verbatim, and because a reading is not
    /// a judgement: the tag system (training, suggestions, Tag Profiles, the
    /// hand-tagging chips) must never see these as tags. Local to this Mac —
    /// every device reads the same facts out of the same files.
    /// The profile in force's readings, inside its bundle.
    ///
    /// It used to be `support/metadata.json` — a device-level file, on the
    /// reasoning that a reading is the same whoever is looking. The reasoning
    /// held for the values and not for the storage: a profile is now one folder,
    /// and leaving the active profile's readings outside it would mean the
    /// bundle was not the whole profile. Inactive profiles' readings have always
    /// lived inside their folder, so this only unifies the two cases.
    static var metadataFile: String { profileFactsFile(activeProfile) }
    /// The facts as they were before the last destructive edit, so an Undo
    /// survives a quit or a crash, exactly like `tagsBackup`.
    static var factsBackup: String {
        (support as NSString).appendingPathComponent("metadata.previous.json")
    }
    /// What the one-time separation of facts out of the tags did, written once
    /// it has run — the only edit in the app that takes names away unasked, and
    /// so the only one that reports itself.
    static var separationReportFile: String {
        (support as NSString).appendingPathComponent("metadata-separation.json")
    }
    static var favoritesFile: String { (support as NSString).appendingPathComponent("favorites.json") }
    static var fingerprintFile: String { (support as NSString).appendingPathComponent("fingerprints.json") }
    static var durationFile: String { (support as NSString).appendingPathComponent("durations.json") }
    /// The machine's reading of each video: its phase, its NSFW verdict and the
    /// raw frame scores. Shared by every profile on purpose — it is arithmetic
    /// on the video, so it says the same thing whoever is asking, and deriving
    /// it per profile would mean re-classifying the library for each one. What
    /// a HUMAN decided about a video lives apart, per profile (`marksFile`).
    static var analysisFile: String { (support as NSString).appendingPathComponent("analysis.json") }
    static var thumbCache: String { (support as NSString).appendingPathComponent("thumbs") }

    /// Fitted AI artifacts that are the app's own, not the encoder's: the
    /// logistic heads. Kept apart from `tags/`, which holds downloaded model
    /// files — a model can be removed and reinstalled, a head is the user's.
    static var modelsDir: String { (support as NSString).appendingPathComponent("models") }

    // MARK: - what a profile owns
    //
    // A profile is one person's judgement — their tags, their accept/reject
    // decisions, their Safe/NSFW marks, their people, the heads fitted from all
    // of it. All of that lives under `profiles/<slug>/`, so training one person
    // never changes what another is offered, and a profile that has never been
    // used starts genuinely blank.
    //
    // What is NOT here is the machine's own work, and that is deliberate: the
    // frame vector cache and the downloaded models are computed from the videos
    // and carry nobody's opinion. Sharing them is what makes a second profile
    // cheap instead of a second full encode.

    /// A profile's folder name. Exposed so a caller whose own parameter is
    /// already called `slug` can reach the global `slug(_:)` without shadowing it.
    static func profileFolder(_ profile: String) -> String { slug(profile) }

    /// Everything one profile owns: its own bundle under `profiles/`.
    static func profileDir(_ profile: String) -> String {
        ProfileBundle.dir(profile)
    }

    /// One file per encoder slug, named after the engine's `.npz` of the same
    /// thing so the two are never mistaken for each other: a head fitted on one
    /// embedding space says nothing about another.
    static func trainedHeadsFile(_ encoderSlug: String, in profile: String) -> String {
        ProfileBundle.file(in: profile,
                           ProfileBundle.headsRelative(encoderSlug, "_trained_heads.json"))
    }

    /// Its own file per profile: a head fitted for one person's tags.
    static func trainedHeadsFile(_ encoderSlug: String) -> String {
        trainedHeadsFile(encoderSlug, in: activeProfile)
    }

    /// The per-library priors, measured from the cache — kept per profile
    /// because a prior is a reading of that profile's library, not of the video.
    static func tagPriorsFile(_ encoderSlug: String, in profile: String) -> String {
        ProfileBundle.file(in: profile,
                           ProfileBundle.headsRelative(encoderSlug, "_tag_priors.json"))
    }

    /// The per-profile job ledger: what was explicitly asked for, what
    /// finished, and what a crash interrupted. One file per profile — a job
    /// belongs to the judgement that asked for it, and a foreign job id has no
    /// record here (see `JobLedger`).
    static func jobsFile(in profile: String) -> String {
        (profileDir(profile) as NSString).appendingPathComponent("jobs.json")
    }

    /// The versioned evidence store: timed evidence and the searchable
    /// transcript, one SQLite file per profile, beside the ledger and the
    /// profile's own document. `root` is threaded through so tests get a
    /// temporary home and nothing above the store knows the path.
    static func evidenceFile(in profile: String, root: String = support) -> String {
        ProfileBundle.file(in: profile, "evidence.sqlite", root: root)
    }

    /// Machine tag suggestions and the user's accept/reject decisions.
    /// Deliberately separate from `tagsFile`: that one holds the user's own
    /// tags and syncs to other devices, and must never carry unconfirmed guesses.
    static func suggestionsFile(in profile: String) -> String {
        (profileDir(profile) as NSString).appendingPathComponent("suggestions.json")
    }

    static var suggestionsFile: String { suggestionsFile(in: activeProfile) }

    /// What a human decided about each video: the Safe/NSFW label and the
    /// corrections behind it. The per-profile half of `analysisFile`.
    static func marksFile(in profile: String) -> String {
        (profileDir(profile) as NSString).appendingPathComponent("marks.json")
    }

    /// The face-recognition person registry: {name: [faceHash...]}. Written by
    /// the engine's name_face command; the app reads it to offer one-click
    /// "this is <name>" choices instead of retyping a name every time. Per
    /// profile, because a name bound to a face is a judgement about a person.
    static func facesFile(in profile: String) -> String {
        (profileDir(profile) as NSString).appendingPathComponent("faces.json")
    }

    static var facesFile: String { facesFile(in: activeProfile) }

    /// The directory every profile's own folder lives in.
    ///
    /// Named lowercase deliberately: macOS filesystems are case-insensitive, so
    /// `Profiles` would be this same directory under a second spelling.
    static let profilesFolderName = "profiles"

    static var profilesDir: String {
        (support as NSString).appendingPathComponent(profilesFolderName)
    }

    /// The tag set as it was before the last destructive edit, so an Undo is
    /// still there after a crash or a quit.
    static var tagsBackup: String {
        (support as NSString).appendingPathComponent("tags.previous.json")
    }

    /// What this Mac remembers of each share's shared tag file for a profile.
    static func sharedSyncFile(_ name: String) -> String {
        (profileDir(name) as NSString).appendingPathComponent("shared-sync.json")
    }

    static func profileFile(_ name: String) -> String {
        (profileDir(name) as NSString).appendingPathComponent(ProfileBundle.tagsName)
    }

    /// Where a profile keeps the readings taken off its files — the
    /// counterpart of `profileFile` above, and now the same file for the
    /// profile in force as for any other (`metadataFile` points here).
    ///
    /// It lives BESIDE the tags, inside the profile's own folder, and always
    /// has for a profile that is not in force: while the tags were at the
    /// support root a single `metadata.json` sat there with them, and the two
    /// files that were not the profile's own were the two that made the bundle
    /// a document rather than a convention.
    static func profileFactsFile(_ name: String) -> String {
        (profileDir(name) as NSString).appendingPathComponent(ProfileBundle.readingsName)
    }

    /// Where a share keeps copies of the tags for other devices to read.
    /// The scan skips dot-directories, so none of this turns up as media.
    static let shareDir = ".FolderVideoPlayer"
    static let legacyTags = shareDir + "/tags.json"
    static let deviceTags = "tags-%@.json"
    static let posterDir = shareDir + "/thumbs"

    /// What a tagged video is filed under: share-relative for anything on a
    /// mounted share, absolute otherwise. A video in a home folder is not
    /// portable and pretending otherwise would lose tags rather than move them.
    static func tagKey(_ path: String) -> String {
        path.hasPrefix(volumes) ? String(path.dropFirst(volumes.count)) : path
    }

    /// Back to something this Mac can actually open.
    static func tagPath(_ key: String) -> String {
        key.hasPrefix("/") ? key : volumes + key
    }

    /// The mount a file lives on, so each volume is only asked about once.
    static func volumeOf(_ path: String) -> String {
        guard path.hasPrefix(volumes) else { return "/" }
        let rest = path.dropFirst(volumes.count)
        return volumes + (rest.split(separator: "/").first.map(String.init) ?? "")
    }

    /// The mounted volumes that are actually shares.
    ///
    /// `mountedShares` is every volume under /Volumes — external disks and
    /// disk images included — which is the wrong audience for anything that
    /// *creates* something. A tag profile is a thing other devices read over
    /// the network, so claiming a name and looking for other people happen
    /// here and not on somebody's backup drive.
    static func networkShares() -> [String] {
        mountedShares().filter { name in
            let url = URL(fileURLWithPath: (volumes as NSString).appendingPathComponent(name))
            let local = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
            return local == false
        }
    }

    /// Every mounted volume. Used where the job is to find or clean up what is
    /// already there, which can include a local disk this app has written to.
    static func mountedShares() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: volumes)) ?? []
        return names.filter { name in
            var dir: ObjCBool = false
            let full = (volumes as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: full, isDirectory: &dir) && dir.boolValue
        }.sorted()
    }
}

extension Notification.Name {
    /// Posted when a different tag profile is put in force, carrying the new
    /// profile's slug. The stores that keep a profile's own decisions —
    /// suggestions, marks, people — listen and reload from its folder, so the
    /// app never shows one person's judgement under another's name.
    static let fvpProfileChanged = Notification.Name("FolderVideoPlayer.profileChanged")

    /// Posted when a share sync brought named people or transcripts in from
    /// another Mac, carrying the profile's slug. See `SharedExtras`.
    static let fvpSharedExtrasArrived = Notification.Name("FolderVideoPlayer.sharedExtrasArrived")
}

/// What the app will list and try to play. VLCKit played everything here;
/// AVFoundation manages the first few and reports the rest as broken, which
/// the player surfaces rather than hiding.
let videoExtensions: Set<String> = [
    "mp4", "m4v", "mov", "flv", "webm", "avi", "mkv", "wmv", "mpg", "mpeg",
    "m2ts", "ts", "rm", "rmvb", "3gp", "ogv", "divx", "vob", "asf", "f4v",
]

/// What AVFoundation will open for a poster frame. The rest are skipped rather
/// than stalling a list on them.
///
/// `.avi` is a container rather than a codec: a camera's Motion JPEG opens,
/// a DivX or Xvid file does not. It is worth trying because a great many home
/// videos are the former — and a frame that cannot be made is remembered, so
/// the ones that fail are asked once rather than on every scroll.
let fastExtensions: Set<String> = ["mp4", "m4v", "mov", "avi"]

enum Tuning {
    static let skipSeconds = 15.0
    static let progressTick = 5.0       // seconds between samples of the playhead
    static let progressFlush = 6        // ...and samples between writes to disk
    static let resumeMin = 30.0         // a video barely started just starts over
    static let resumeTail = 30.0        // ...and so does one that was all but finished
    static let recentMax = 8
    static let progressMax = 500        // newest positions win; older ones age out

    static let fpChunk = 64 * 1024      // read from each end for a fingerprint
    static let hashBlock = 4 * 1024 * 1024
    static let fpMax = 40_000           // older entries age out before the file does

    static let posterSize = CGSize(width: 480, height: 270)
    static let thumbSize = CGSize(width: 64, height: 36)
    static let gallerySize = CGSize(width: 160, height: 90)
    static let posterQuality = 0.8

    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    static let normalSpeed = 1.0
}

/// Star ratings ARE tags. "Favorite" stays the 5-star mark — the Apple TV
/// favourites with that exact tag, so keeping the name keeps the TV working
/// with no change on its side — and the lower ratings get their own tags.
/// Being tags, the stars share, publish, filter, bulk-tag and follow a moved
/// file through the one store, with no second bookkeeping to keep in step.
let favoriteTag = "Favorite"

/// The tag name for a star rating, 1–5. Five is the old Favorite mark; the
/// rest are words of their own ("1 Star" singular, the rest plural).
func starTag(_ stars: Int) -> String {
    switch stars {
    case 5: return favoriteTag
    case 4: return "4 Stars"
    case 3: return "3 Stars"
    case 2: return "2 Stars"
    case 1: return "1 Star"
    default: return ""
    }
}

/// The star rating a tag name stands for, or nil when it is not one of the
/// five. Case-insensitive, so a hand-typed "4 stars" is still a star row.
func starsOf(_ tag: String) -> Int? {
    for stars in 1...5 where starTag(stars).caseInsensitiveCompare(tag) == .orderedSame {
        return stars
    }
    return nil
}

/// Whether a tag is one of the five star marks. The UI keeps them out of the
/// generic tag lists — they have their own section, rating controls, and a
/// rename would silently unhook the Apple TV's favourite tag.
func isStarTag(_ tag: String) -> Bool { starsOf(tag) != nil }
