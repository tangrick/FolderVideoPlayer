import Foundation

/// "Which other videos show this person?" — the look-alike search for a tag
/// that names someone in the face registry.
///
/// `LookAlikes` answers a different question with the same button. It ranks by
/// the WHOLE FRAME: a tag is prototyped from the mean CLIP vector of the videos
/// carrying it, and the library is ranked by margin over that prototype. For a
/// tag like Kite or Bench that is the only signal there is, and it works.
///
/// For a tag that names a PERSON it is the wrong signal, and measurably so
/// (2026-09-20, measured on a real library): a person tag sat on 22 videos, 20
/// of which were also tagged Waterfall and 19 Iceland. A face is a small patch
/// of a frame full of water and sky, so the prototype was mostly waterfall and
/// the search answered with waterfalls — the report was "a lot of the waterfall
/// and sea are flagged instead of purely using the faces". The frames really do
/// look alike. They are just not what was asked.
///
/// So a person tag is ranked here instead, on the face vectors alone, and the
/// two searches never blend: a blended score is what would let the waterfall
/// back in, at whatever weight, and the whole complaint is that scene
/// similarity is being allowed to speak for a person.
///
/// Contract, deliberately the same shape as `LookAlikes`:
///  - a video scores the BEST cosine of any face in it against any face bound
///    to the person, never a mean — a person photographed from several angles
///    has several distinct vectors, and one good sighting is the answer;
///  - the bar is `SFaceEmbedder.matchCosine`, the same 0.30 the per-video
///    suggestion pass already uses, so this search and the People chips agree
///    about who is in a video rather than disagreeing at the margin;
///  - a face with no readable vector is skipped, never zero-filled — the same
///    "not looked at" vs "not a match" distinction `LookAlikes` keeps;
///  - a video nobody has scanned for faces is COUNTED, never guessed at. It
///    cannot be scanned here either: the face pass is button-triggered (People
///    ▸ Scan), and nothing but the playing video may start work on its own.
enum FaceLookAlikes {

    static let defaultLimit = 30

    /// One ranked video. `score` is the best face cosine, four decimals, on the
    /// same scale the suggestion rows show.
    struct Candidate: Equatable {
        var key: String
        var score: Double
    }

    struct Result: Equatable {
        var person: String
        var candidates: [Candidate] = []
        /// Videos the caller offered that no face pass has looked at. They are
        /// not misses — nothing has ever asked whether this person is in them.
        var unscanned: Int = 0
        /// How many videos the ranking actually considered, so a thin answer
        /// can say what it was thin over.
        var scanned: Int = 0
        /// Why there are no candidates, in words a user can act on.
        var reason: String?
    }

    /// Rank videos by their best face cosine against `references`.
    ///
    /// `faceVideos` is the face→video index (`face_index.json`) already reduced
    /// to the keys worth offering: the caller drops hidden videos, videos
    /// already carrying the person's tag, and videos it has been told to
    /// reject. `analysed` is the wider set the coverage count is measured
    /// against — every video the app knows about, whether or not a face pass
    /// has been near it.
    ///
    /// `vector` is the only thing here that touches the disk, and it is asked
    /// once per distinct face rather than once per video: a face seen in eight
    /// videos is eight rows of the index and one read.
    static func rank(person: String,
                     references: [[Float]],
                     faceVideos: [String: [String]],
                     analysed: Set<String>,
                     vector: (String) -> [Float]?,
                     threshold: Double = SFaceEmbedder.matchCosine,
                     limit: Int = defaultLimit) -> Result {
        var out = Result(person: person)
        guard !references.isEmpty else {
            out.reason = "No face is bound to “\(person)” yet — add one from a video "
                       + "they appear in (People ▸ Add Face…), and the search can look for them."
            return out
        }

        var seen = Set<String>()            // videos a face pass has looked at
        var best: [String: Double] = [:]    // video key -> best cosine
        for (hash, keys) in faceVideos {
            seen.formUnion(keys)
            guard let candidate = vector(hash) else { continue }
            var score = -1.0
            for reference in references {
                score = max(score, SFaceEmbedder.cosine(candidate, reference))
            }
            guard score >= threshold else { continue }
            for key in keys {
                best[key] = max(best[key] ?? -1, score)
            }
        }
        out.scanned = seen.count
        out.unscanned = analysed.subtracting(seen).count

        // Ties broken by key, so the same library answers the same way twice.
        var scored: [Candidate] = []
        scored.reserveCapacity(best.count)
        for (key, score) in best {
            scored.append(Candidate(key: key, score: LookAlikes.round4(score)))
        }
        scored.sort { $0.score == $1.score ? $0.key < $1.key : $0.score > $1.score }
        out.candidates = Array(scored.prefix(limit))

        if out.candidates.isEmpty {
            out.reason = out.scanned == 0
                ? "No video has been scanned for faces yet — open People and scan, "
                + "and the search can look for “\(person)”."
                : "No other video shows a face matching “\(person)” among the "
                + "\(out.scanned) scanned for faces."
        }
        return out
    }
}
