import Foundation

/// How strongly each tag fires **across this library**, so a suggestion can be
/// judged against that tag's own habit instead of against a flat bar.
///
/// ## Why this exists
///
/// The zero-shot margin asks "does this tag's best phrasing beat the bland
/// background pool?" — which rewards *broad* prompts. Measured on the maintainer's
/// rig (2026-09-12), the chronic winners were the tags he rejected every single
/// time, while the ones he accepted sat below them:
///
/// | tag         | offered | mean margin | accepted |
/// |-------------|---------|-------------|----------|
/// | Speech      | 14/15   | 0.081       | **0 / 8** |
/// | Dining      | 13/15   | 0.074       | **0 / 7** |
/// | Portrait    | 13/15   | 0.075       | **0 / 7** |
/// | Outdoors    | 10/15   | 0.059       | **6 / 6** |
/// | Sightseeing |  4/15   | 0.057       | **2 / 3** |
///
/// "Speech" wins on any footage with a person in it; it is not evidence about
/// *this* video. Subtracting each tag's own average turns the score into "did
/// this tag fire unusually strongly here", which is the question worth asking.
///
/// Scored on his 62 judged suggestions, leave-one-video-out (each video's prior
/// built from the others, never itself):
///
/// | ranking            | top-1 | in top-3 | median rank of first accepted tag |
/// |--------------------|-------|----------|-----------------------------------|
/// | raw margin (today) | 0 / 6 | 0 / 6    | 5.5                               |
/// | minus per-tag mean | 1 / 6 | **4 / 6**| **2.0**                           |
///
/// Six videos is a small sample and it is one user's taste, which is exactly
/// why this ships **off** and why the prior is built from the user's own cache
/// rather than from anything measured here.
///
/// ## What it is not
///
/// - **Not shipped.** Priors are computed on the user's machine from their own
///   cached frame vectors. Nothing derived from the maintainer's library goes in the
///   bundle — the clean-start rule in the migration plan.
/// - **Not a change to any stored number.** This reorders candidates; every
///   `confidence` still means what it always meant, so an old `suggestions.json`
///   stays readable and the parity fixtures still compare like for like.
struct TagPriors: Codable, Equatable {

    /// Mean best-margin per tag over the sampled library frames.
    var mean: [String: Double] = [:]

    /// How many frames the means were built from. Below `minFrames` the priors
    /// are not trustworthy and `rank` falls back to the raw margin, so a fresh
    /// library behaves exactly as it does today.
    var frames: Int = 0

    /// The cache namespace these were measured in, mirroring
    /// `TrainedHeads.defaultSlug` — spelled out rather than read from
    /// `VisionEmbedder` so the pure-arithmetic gates do not have to compile a
    /// CoreML actor to rank a list. `Tests/test_tag_suggester.swift` asserts the
    /// two stay equal.
    static let defaultSlug = "siglip2_base"

    /// The embedding space these were measured in. A prior from another space
    /// is meaningless; `load` refuses it rather than silently mis-ranking.
    var model: String = TagPriors.defaultSlug

    /// Below this many frames, one or two videos would define the average and
    /// the "unusual" test becomes noise. Chosen to be a few videos' worth of
    /// frames, not tuned — there is not enough data to tune it honestly.
    static let minFrames = 40

    var isUsable: Bool { frames >= Self.minFrames && !mean.isEmpty }

    // MARK: - the ranking key

    /// The value candidates are ordered by: how far above its own habit this
    /// tag scored. A tag with no prior keeps its raw margin, which is the right
    /// default — an unseen tag has no habit to beat.
    func rankingKey(tag: String, confidence: Double) -> Double {
        guard isUsable else { return confidence }
        guard let mu = mean[tag] else { return confidence }
        return confidence - mu
    }

    // MARK: - building

    /// Measure every tag's average best-margin over the cached frame vectors.
    ///
    /// `hashes` is deliberately a parameter rather than a directory walk: the
    /// caller already has `TagPrototypes.hashes(inCache:slug:)`, and a test must
    /// be able to hand in a fixture without writing a cache tree.
    static func measure(table: PromptTable,
                        hashes: [String],
                        read: (String) -> [Float]?) -> TagPriors {
        var sums: [String: Double] = [:]
        var seen = 0
        for hash in hashes {
            guard let vector = read(hash), vector.count == table.dim else { continue }
            seen += 1
            // `tagMargins` already subtracts the background pool, so this is the
            // same number the suggester compares against SUGGEST_MARGIN — the
            // prior must be measured on the identical quantity or the
            // subtraction is meaningless.
            for (tag, margin) in table.tagMargins(vector: vector) {
                sums[tag, default: 0] += Double(margin)
            }
        }
        guard seen > 0 else { return TagPriors() }
        var out = TagPriors()
        out.frames = seen
        out.model = TagPriors.defaultSlug
        for (tag, total) in sums { out.mean[tag] = total / Double(seen) }
        return out
    }

    // MARK: - disk

    /// Per profile: a prior is a reading of ONE library's tags, so measuring it
    /// against another person's library would rank their suggestions by
    /// somebody else's taste.
    static func file(root: String = Paths.support,
                     slug: String = TagPriors.defaultSlug,
                     profile: String = Paths.activeProfile) -> String {
        ProfileBundle.file(in: profile,
                           ProfileBundle.headsRelative(slug, "_tag_priors.json"),
                           root: root)
    }

    /// Read the cached priors, or an empty (unusable) set. A file from another
    /// embedding space is ignored rather than trusted.
    static func load(root: String = Paths.support,
                     slug: String = TagPriors.defaultSlug,
                     profile: String = Paths.activeProfile) -> TagPriors {
        let path = file(root: root, slug: slug, profile: profile)
        guard let data = FileManager.default.contents(atPath: path),
              let priors = try? JSONDecoder().decode(TagPriors.self, from: data),
              priors.model == slug
        else { return TagPriors() }
        return priors
    }

    func save(root: String = Paths.support,
              slug: String = TagPriors.defaultSlug,
              profile: String = Paths.activeProfile) throws {
        let path = Self.file(root: root, slug: slug, profile: profile)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - the switch

    /// `FVP_SUGGEST_RANK=normalized` turns this on, or `rank=normalized` in the
    /// dev override file (`~/.fvp-engine`) — the same file that carries the
    /// engine mode, because Xcode rewrites anything stored in the scheme.
    ///
    /// Default OFF in code: the raw margin is what every parity gate compares
    /// against engine.py. It is switched on for a session from the file.
    static var enabled: Bool {
        enabled(environment: ProcessInfo.processInfo.environment["FVP_SUGGEST_RANK"],
                override: DevOverride.values)
    }

    /// Pure, so the gate can check the precedence without an environment it
    /// cannot unset: the environment wins, then the file, then off.
    static func enabled(environment: String?, override: [String: String]) -> Bool {
        if let raw = environment?.lowercased(), !raw.isEmpty { return raw == "normalized" }
        return (override["rank"] ?? "").lowercased() == "normalized"
    }
}
