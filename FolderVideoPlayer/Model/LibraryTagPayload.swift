import Foundation

/// The library-tag payload the engine expects: `{tag: {videoKey: [frameHash]}}`.
///
/// ## Why this is a Model file and not a private view helper
///
/// It used to live inside `PlayerWindow`, where nothing could test it — and it
/// hid a bug for the entire life of the feature. The line was:
///
///     hashes = analysis.frameScores.map(\.hash).prefix(10) as? [String]
///
/// `prefix` returns an `ArraySlice`, and `as? [String]` on an ArraySlice
/// **always fails** (Swift warns "cast from 'Array<String>.SubSequence' to
/// unrelated type '[String]' always fails"). So the guard failed for every
/// video, the payload was always empty, and the `library` source — the one that
/// suggests the user's OWN tags by look-alike — never fired once in 558 videos.
/// Nothing said anything; the chips just never appeared.
///
/// The lesson worth keeping: a helper that feeds a silent, invisible feature
/// must be reachable from a test, and `as?` between collection types is a
/// conversion, not a cast — it fails rather than converting.
enum LibraryTagPayload {

    /// - Parameters:
    ///   - current: the video being suggested for; its own tags are excluded
    ///     (never offer a tag the video already carries).
    ///   - tags: the tag store, `videoKey -> [tag name]`.
    ///   - frameHashes: the cached frame hashes for a video key. A video that
    ///     has never been analysed has none and cannot contribute a prototype.
    static func build(current: String,
                      tags: [String: [String]],
                      frameHashes: (String) -> [String],
                      maxVideosPerTag: Int = 8,
                      maxFramesPerVideo: Int = 10) -> [String: [String: [String]]] {
        let own = Set(tags[current] ?? [])
        var out: [String: [String: [String]]] = [:]
        for (key, names) in tags where key != current {
            let wanted = names.filter { !own.contains($0) }
            guard !wanted.isEmpty else { continue }
            // `Array(...)` is load-bearing: without it this is an ArraySlice and
            // every video is skipped. See the note above.
            let hashes = Array(frameHashes(key).prefix(maxFramesPerVideo))
            guard !hashes.isEmpty else { continue }
            for name in wanted {
                var videos = out[name] ?? [:]
                if videos.count >= maxVideosPerTag { continue }
                videos[key] = hashes
                out[name] = videos
            }
        }
        return out
    }
}
