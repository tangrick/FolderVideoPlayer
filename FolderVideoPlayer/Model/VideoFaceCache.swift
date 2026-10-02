import Foundation

/// The people found in each video, kept so that looking is paid for once.
///
/// Finding them means decoding forty frames and running two models over every
/// one, and the Add Faces sheet used to do that each time it opened — for the
/// same video, to show the same five faces, once per person being named. What
/// it found is a fact about the file, so it is written down beside the file's
/// identity and read back until the file changes.
///
/// Shared by every profile, like the face vectors themselves and for the same
/// reason: which faces are IN a video is the same for everyone. Whose faces
/// they are is the registry's business, and that stays per profile.
struct VideoFaceCache: Codable, Equatable {

    struct Entry: Codable, Equatable {
        /// The file the faces were found in. A re-encode or a different video
        /// moved over the path is another video, and is looked at again.
        var revision: SourceRevision
        /// One face hash per person, most prominent first. Empty means the
        /// video was looked at and nobody was found — which is an answer, and
        /// is kept like any other.
        var faces: [String]
    }

    private(set) var byPath: [String: Entry] = [:]

    /// What was found in this video, or nil when it has not been looked at —
    /// or has changed since it was.
    func faces(for path: String) -> [String]? {
        guard let entry = byPath[path], entry.revision.matches(path) else { return nil }
        return entry.faces
    }

    /// `revision` is the file as it was BEFORE the pass, handed in rather than
    /// read here: a file that changed while it was being looked at must not be
    /// filed under the identity it has now.
    mutating func record(_ faces: [String], for path: String, revision: SourceRevision) {
        byPath[path] = Entry(revision: revision, faces: faces)
    }

    static func load(_ file: String) -> VideoFaceCache {
        JSONStore.load(file, fallback: VideoFaceCache())
    }

    func save(_ file: String) {
        _ = JSONStore.saveCompact(file, self)
    }
}
