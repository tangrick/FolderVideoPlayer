import Foundation

/// A saved set of folders the duplicate finder works over.
struct DupeScan: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folders: [String]
    var ran: Double = 0
    var seen: Int = 0
    var groups: Int = 0
}

/// What was playing when the app last quit.
struct Session: Codable, Hashable {
    var mode: String = ""       // a PlayMode raw value
    var root: String?
    var path: String = ""
    var tag: String?
    /// Kept so a v1.1.1 session (a `.rated` star playlist) still decodes; no
    /// new code writes it — a star playlist is a tag playlist now.
    var stars: Int?
}

/// What a playlist is a list OF. Stored in `Session` by raw value, so it lives
/// with the other saved shapes rather than beside the controller that switches
/// between them — `Library` has to be able to name the Hidden case when it
/// decides what a Resume row may offer, and the library is the model layer.
enum PlayMode: String {
    case folder, tag, favorites
    /// The Hidden view: only hidden videos, and only reachable through the
    /// password. Not resumable across launches — a relaunch is locked.
    case hidden
    /// Every video in the profile where some words are spoken — a transcript
    /// search from the library panel. Never written as the session: it is a
    /// look through the library, so leaving it (or relaunching) returns to
    /// the folder or tag it was opened from.
    case said
    /// `.favorites` remains a valid raw value so an old session still decodes
    /// — it resumes into nothing, never a crash. The former `.rated` mode is
    /// gone outright: star playlists are tag playlists, and a stored "rated"
    /// raw value decodes to nil and falls through to `.folder` (no root, so
    /// it declines to resume).
}

enum PlayOrder: String, Codable, CaseIterable, Identifiable {
    case all, one, shuffle, once
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        case .shuffle: return "Shuffle"
        case .once: return "Play Once"
        }
    }
}

enum PlaylistSort: String, Codable, CaseIterable, Identifiable {
    case folder, name, date, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folder: return "Folder Order"
        case .name: return "Name"
        case .date: return "Date Added"
        case .size: return "File Size"
        }
    }
    /// Which way each sort points when first chosen — Finder's habits: A to Z
    /// by name, but newest and largest first.
    var defaultDescending: Bool {
        switch self {
        case .date, .size: return true
        default: return false
        }
    }
}

/// A grid of poster frames, or a sortable list. Finder's other two — columns
/// and gallery — earned their space in Finder and not here.
///
/// Anything else in `state.json`, including the "gallery" an older build wrote,
/// loads as the list.
enum PlaylistStyle: String, Codable, CaseIterable, Identifiable {
    case icons, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icons: return "as Icons"
        case .list: return "as List"
        }
    }
    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// Everything the app remembers between launches, bar the tags themselves.
///
/// Nothing here is checked against the filesystem on the way in: a folder on
/// an unmounted NAS would stat slowly, or hang, and that would show up as a
/// stall on every launch. Dead entries are dropped when something tries to
/// use them.
struct PersistedState: Codable {
    var recent: [String] = []
    var progress: [String: Double] = [:]
    /// When each position was last touched, so trimming keeps the newest.
    /// Python kept dictionary insertion order for this; Swift dictionaries
    /// have none, so the stamps are written down.
    var progressSeen: [String: Double] = [:]
    var session: Session?
    var repeatMode: String?
    var speed: Double?
    var favoritesMigrated: Bool?
    var person: String?
    /// Folders the user pinned in the sidebar. Recent forgets, pinned does
    /// not — it is the short list that survives the sliding window.
    ///
    /// Read at launch and then left alone: pinned folders belong to a tag
    /// profile now, and live in `pinnedByProfile`. This is what an older
    /// version wrote, and it seeds the profile in force the first time.
    var pinned: [String]?
    /// Pinned folders per tag profile, keyed by profile slug. A profile is
    /// one person's library, and the folders they keep to hand are part of
    /// it — switching profile swaps these the way it swaps the tags.
    var pinnedByProfile: [String: [String]]?
    /// Recently opened folders per tag profile, keyed by profile slug.
    ///
    /// Same rule as `pinnedByProfile`, and for the same reason: a profile is
    /// one person's library, and where they have been is part of it. A new
    /// profile has been nowhere, so its list starts empty rather than showing
    /// somebody else's folders. The flat `recent` above is what an older
    /// version wrote and seeds the profile in force once.
    var recentByProfile: [String: [String]]?
    /// The tag profiles this Mac knows of, whether or not a share is mounted.
    var profiles: [String]?
    /// The profiles opened most recently, newest first — what File ▸ Open
    /// Recent Profile offers. A profile is a document now, so the shortest way
    /// back to the one you were working in is worth keeping across a quit.
    /// By name rather than slug: it is shown to the person who chose it.
    var recentProfiles: [String]?
    /// Profiles forgotten here, so share discovery does not offer them back.
    var hiddenProfiles: [String]?
    var askProfileAtStartup: Bool?
    /// The machine this device id was made on, so a settings folder copied to
    /// a second Mac does not have both writing the same file on the share.
    var deviceHost: String?
    var device: String?
    var lastMerge: Double?
    var thumbnails: Bool?
    var playlistStyle: String?
    var playlistWidth: Double?
    var librarySidebarWidth: Double?
    var playlistSort: String?
    var sortDescending: Bool?
    var volume: Int?
    var discardFolders: [String: String]?
    var watchDupes: Bool?
    /// Whether face recognition runs at all. Absent means on, so an existing
    /// settings file keeps the behaviour it had before the switch existed.
    var facesEnabled: Bool?
    /// Whether the app works on the video being played: the classification
    /// pass AND the tag-idea pass, which are one feature to the person
    /// watching. Absent means on, for the same reason as `facesEnabled`.
    ///
    /// The stored key stays `classifyWhilePlaying` — it was written before the
    /// switch had a control, and renaming it would strand the value in every
    /// existing settings file. Nothing else depends on the old name.
    var autoWorkWhilePlaying: Bool?
    var verifyDupes: Bool?
    var sparedDupes: [String]?
    /// Videos hidden from the app, share-relative exactly like tags so a
    /// remount or another device sees the same list. Optional so a library
    /// written before this feature loads as "nothing hidden" (pitfall 7).
    /// A visibility flag only — nothing on disk is touched.
    var hidden: [String]?
    var scans: [DupeScan]?
    var scan: String?
    /// How far the skip buttons jump. Absent means the old hard-coded 15s.
    var skipSeconds: Int?
    /// Whether the middle of a video is remembered and resumed. Absent means on.
    var resumeEnabled: Bool?
    /// How many recent folders the sidebar keeps. Absent means the old 8.
    var recentLimit: Int?
    /// Star ratings per video, keyed like tags — what a v1.1.1 library
    /// wrote. Read once for the one-time migration into star tags; never
    /// written again (the tags file carries the stars now).
    var ratings: [String: Int]?
    /// Whether the facts read off the files have been moved out of the tag
    /// store into `metadata.json`. Absent means not yet: a library tagged by a
    /// build from before the split still holds `2016` / `1080p` / `iPhone 16
    /// Plus` among its tags, and the one-time migration moves them. Written
    /// true once it has run, so it cannot run twice — the second run would
    /// otherwise find nothing to move and still be harmless, but a flag is how
    /// the app can say it happened.
    var metadataSeparated: Bool?

    enum CodingKeys: String, CodingKey {
        case recent, progress, progressSeen, session, speed, person, device, pinned
        case pinnedByProfile, recentByProfile
        case profiles, hiddenProfiles, askProfileAtStartup, deviceHost
        case recentProfiles
        case lastMerge, thumbnails, playlistStyle, playlistWidth, librarySidebarWidth
        case playlistSort, sortDescending
        case volume, discardFolders, watchDupes, verifyDupes, sparedDupes
        case hidden
        case facesEnabled
        /// The stored key is the old name; see `autoWorkWhilePlaying`.
        case autoWorkWhilePlaying = "classifyWhilePlaying"
        case scans, scan
        case skipSeconds, resumeEnabled, recentLimit
        /// Still decoded: a v1.1.1 state file's ratings feed the one-time
        /// migration into star tags. Never encoded again.
        case ratings
        case metadataSeparated
        case repeatMode = "repeat"
        case favoritesMigrated
    }
}
