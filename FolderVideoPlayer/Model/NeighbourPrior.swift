import Foundation

/// How much the videos shot *around* this one agree about a tag.
///
/// ## Why this exists
///
/// A personal library is shot in **bursts**. One holiday, one party, one shoot
/// produces a run of files within hours of each other, and they nearly always
/// share tags. Nothing in the suggester knows that: `TagSuggester.suggest` is
/// handed frame vectors and nothing else, so a clip that is visually ambiguous
/// — a dark interior, a close-up, a pan of nothing — gets no help from the six
/// clips around it that are all `Iceland`.
///
/// This measures that agreement and hands back a small per-tag bonus the
/// suggester adds to its ranking key, next to `TagPriors`.
///
/// ## What it is not
///
/// - **Not a candidate source.** It only moves tags that some source already
///   offered. Offering `Beach` because yesterday's clip was `Beach` is a guess
///   about content made from a timestamp, which is exactly the wrong-chip class
///   `TagSuggester.vocabularyMargin` was raised to stop. A tag with no bonus
///   entry scores zero; a tag nobody offered is never added.
/// - **Not a change to any stored number.** Like `TagPriors`, this reorders.
///   Every `confidence` still means what it always meant, so an old
///   `suggestions.json` stays readable and the parity fixtures still compare
///   like for like.
/// - **Not a clustering pass.** A cluster boundary makes the bonus jump: two
///   clips ten minutes apart can land in different clusters and get wildly
///   different advice. A window is continuous in behaviour and can be explained
///   in one sentence in the Why panel.
///
/// ## The number
///
///     neighbours = videos within ±window of this one, or on the same day
///     support    = how many of them carry the tag
///     share      = support / neighbours
///     bonus      = weight * share * min(1, support / saturationCount)
///
/// `share` rather than raw support, because a folder of four hundred files all
/// tagged `Home Video` would otherwise hand that tag an unbeatable bonus on
/// every one of them. Share asks "is this tag unusually common *among the
/// neighbours*" — the same question `TagPriors` asks of the whole library.
///
/// The saturation term kills the one-neighbour case: a single neighbour gives
/// `share == 1.0`, which is a coincidence and not evidence. At
/// `saturationCount == 3` one neighbour is worth a third of the bonus and three
/// or more the lot.
///
/// ## The dates are creation dates, and that is a known hazard
///
/// The caller reads `Library.addedOn`, which is `.creationDate` falling back to
/// `.modificationDate`. On a NAS a batch **copy** rewrites creation dates, so a
/// folder restored from backup can have four hundred files "created" inside one
/// minute, all mutually neighbouring.
///
/// Two things blunt it, and neither needs a second decode:
///
/// - `share` makes a flattened neighbourhood self-cancelling. If every
///   neighbour carries the same tags, every tag gets a similar bonus, so the
///   bonus is close to a constant and the ORDER barely moves — which is the
///   only thing this affects.
/// - `maxNeighbours` caps the pool at the nearest-in-time few dozen, so a
///   copy-flattened folder is compared against a bounded sample rather than
///   against the whole batch.
///
/// Reading the real shot date out of the container would be better and is
/// deliberately not done here: it is an AVFoundation load per neighbour, and
/// this runs on every video change.
struct NeighbourPrior: Equatable {

    /// Tag → bonus, precomputed for ONE video. Empty means "no opinion", which
    /// is the correct answer for a video with no date, no neighbours, or a
    /// cold date cache — and it makes the whole feature a no-op by default.
    private(set) var bonus: [String: Double] = [:]

    /// How many neighbours were in range. Carried for the Why panel, which has
    /// to be able to say "4 of the 9 videos within 6 hours of this one" — a
    /// bonus the user cannot see the reason for is the invisible magic this app
    /// keeps having to remove.
    private(set) var neighbours: Int = 0

    /// Per tag, how many of those neighbours carried it. Same audience.
    private(set) var support: [String: Int] = [:]

    // MARK: - the constants

    /// ±6 hours. Wide enough to hold a day's shooting either side of a gap,
    /// narrow enough not to sweep in an unrelated evening. Not tuned — the
    /// sweep belongs in the eval script, against judged suggestions.
    static let windowSeconds: Double = 6 * 3600

    /// Below this many supporting neighbours the bonus is scaled down. Three is
    /// "a burst", one is "a coincidence".
    static let saturationCount = 3

    /// The whole tuning knob. A third of `TagSuggester.vocabularyMargin`
    /// (0.01 since the SigLIP 2 swap, 0.06 before it): a perfect neighbourhood
    /// should lift a tag a couple of places, never overturn a strong visual
    /// signal, and never outrank a face — a face match is a measurement of a
    /// person, and `TagSuggester` step 4b already takes the tag over outright.
    ///
    /// Spelled out rather than computed because `run_neighbour_prior.sh`
    /// compiles this file without `TagSuggester`; `Tests/test_neighbour_prior`
    /// asserts it stays under the bar, which is what stops it lifting a tag on
    /// its own.
    static let weight = 0.0033

    /// The nearest-in-time neighbours considered, at most. See the batch-copy
    /// hazard above.
    static let maxNeighbours = 40

    /// Fewer than this many neighbours and there is no neighbourhood to speak
    /// of, so the prior declines to have an opinion rather than reading one
    /// file as a trend.
    static let minNeighbours = 2

    // MARK: - the lookup

    /// The bonus for one tag, or zero. Zero is the right default in both
    /// directions: an unseen tag has no neighbourhood evidence, and a tag the
    /// neighbours never carry should not be penalised either — that would be a
    /// different claim, and one the frames have already answered.
    func bonus(tag: String) -> Double { bonus[tag] ?? 0 }

    var isEmpty: Bool { bonus.isEmpty }

    // MARK: - building

    /// Measure the neighbourhood of one video.
    ///
    /// Everything is handed in — `dated` and `tagsFor` rather than a library
    /// reference — for the same reason `TagPriors.measure` takes `hashes`: this
    /// must be pure arithmetic a fixture can drive, with no FileManager, no
    /// actor and no way to stat a sleeping share from inside a ranking.
    ///
    /// **The caller must pass only dates it already knows.** `Library.addedOn`
    /// is a cached read that never stats; `Library.stats(for:)` is a round trip
    /// per file. Building this from the latter would be one SMB round trip per
    /// neighbour, on every video change — the spinning-wheel class of bug the
    /// performance notes exist to document. A cold cache yields an empty
    /// prior, which is a no-op, which is correct.
    ///
    /// - Parameters:
    ///   - date: this video's date, epoch seconds. `<= 0` means the stat failed
    ///     and yields an empty prior — a run of failed stats must never be read
    ///     as a cluster of videos all shot at the epoch.
    ///   - dated: the pool, `(key, epochSeconds)`. The caller filters out hidden
    ///     videos before this: hidden is excluded from everything the AI does.
    ///   - tagsFor: the tags on one pool key.
    ///   - excluding: this video's own key, so it cannot support itself.
    static func measure(for date: Double,
                        dated: [(key: String, when: Double)],
                        tagsFor: (String) -> [String],
                        excluding: String,
                        calendar: Calendar = .current,
                        window: Double = NeighbourPrior.windowSeconds,
                        weight: Double = NeighbourPrior.weight,
                        maxNeighbours: Int = NeighbourPrior.maxNeighbours,
                        saturationCount: Int = NeighbourPrior.saturationCount,
                        minNeighbours: Int = NeighbourPrior.minNeighbours)
        -> NeighbourPrior {

        guard date > 0, weight > 0, saturationCount > 0 else { return NeighbourPrior() }
        let mine = Date(timeIntervalSince1970: date)

        // In range, nearest in time first, then capped. Sorting BEFORE the cap
        // is the point: an arbitrary forty of a flattened batch would be a
        // different answer on every run, and a suggestion list that reorders
        // itself between two runs of the same video is indefensible.
        var near: [(key: String, gap: Double)] = []
        for entry in dated {
            guard entry.key != excluding, entry.when > 0 else { continue }
            let gap = abs(entry.when - date)
            let sameDay = calendar.isDate(Date(timeIntervalSince1970: entry.when),
                                          inSameDayAs: mine)
            guard gap <= window || sameDay else { continue }
            near.append((entry.key, gap))
        }
        guard near.count >= minNeighbours else { return NeighbourPrior() }

        // Ties broken by key so the cap is deterministic: two files copied in
        // the same second have identical gaps, and a dictionary order would
        // decide which of them got in.
        near.sort { $0.gap == $1.gap ? $0.key < $1.key : $0.gap < $1.gap }
        let pool = Array(near.prefix(maxNeighbours))

        var counts: [String: Int] = [:]
        for entry in pool {
            // A video tagged the same thing twice must not count twice.
            for tag in Set(tagsFor(entry.key)) { counts[tag, default: 0] += 1 }
        }
        guard !counts.isEmpty else {
            var out = NeighbourPrior()
            out.neighbours = pool.count
            return out
        }

        var out = NeighbourPrior()
        out.neighbours = pool.count
        out.support = counts
        let total = Double(pool.count)
        for (tag, count) in counts {
            let share = Double(count) / total
            let saturate = min(1, Double(count) / Double(saturationCount))
            out.bonus[tag] = weight * share * saturate
        }
        return out
    }

    // MARK: - the switch

    /// `FVP_NEIGHBOUR_PRIOR=on`, or `neighbours=on` in the dev override file
    /// (`~/.fvp-engine`) — the same ladder `TagPriors` uses, and for the same
    /// reason: Xcode rewrites anything stored in the scheme.
    ///
    /// Default OFF in code. The parity gates compare against `engine.py`, which
    /// has no neighbour prior at all, and the gain has not been measured on
    /// judged suggestions yet.
    static var enabled: Bool {
        enabled(environment: ProcessInfo.processInfo.environment["FVP_NEIGHBOUR_PRIOR"],
                override: DevOverride.values)
    }

    /// Pure, so the gate can check the precedence without an environment it
    /// cannot unset: the environment wins, then the file, then off.
    static func enabled(environment: String?, override: [String: String]) -> Bool {
        if let raw = environment?.lowercased(), !raw.isEmpty {
            return raw == "on" || raw == "1" || raw == "yes"
        }
        let value = (override["neighbours"] ?? "").lowercased()
        return value == "on" || value == "1" || value == "yes"
    }
}
