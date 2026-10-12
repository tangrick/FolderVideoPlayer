import Foundation

/// The videos taken within a few days of one video, nearest day first.
///
/// A row's "Find Taken Around the Same Time" opens these as a playlist: the
/// rest of the day's shooting, then the day either side, and so on out to
/// `days`. It is the question a burst-shot library gets asked while tagging —
/// what else is from this trip — answered from dates alone.
///
/// Calendar days, not hours apart: a clip from 23:50 and one from 00:10 are a
/// day apart to whoever is looking at the Date column, and the headings say
/// days. Within a day the order is the order they were shot in.
///
/// The dates are the caller's `Library.addedOn` — the file's creation date,
/// with the hazard `NeighbourPrior` documents: a batch copy can stamp a whole
/// folder with one day.
///
/// Pure arithmetic, like `NeighbourPrior.measure`: dates are handed in, nothing
/// here stats a file.
enum ShotNearby {

    /// How far either side of the video counts as "around the same time".
    /// The default; the list's banner takes any number up to `maxDays`.
    static let days = 3
    static let maxDays = 365

    /// "the same day", "1 day", "5 days" — how a reach is said.
    static func reach(_ days: Int) -> String {
        switch days {
        case 0: return "the same day"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    struct Hit: Equatable {
        let key: String
        /// Whole calendar days from the video's own day; 0 is the same day.
        let days: Int
        let when: Double
    }

    /// Everything in `dated` within `days` calendar days of `date`: the same
    /// day first, then a day away, and so on; in shooting order within each.
    /// Empty for a video whose date is not known, and an entry with no date is
    /// never a neighbour — a run of failed stats is not a shoot at the epoch.
    static func around(date: Double, dated: [(key: String, when: Double)], excluding: String,
                       days: Int = ShotNearby.days, calendar: Calendar = .current) -> [Hit] {
        guard date > 0, days >= 0 else { return [] }
        let mine = calendar.startOfDay(for: Date(timeIntervalSince1970: date))
        // Nothing further than this many seconds can be in range, whatever the
        // calendar says — a cheap cut before the per-entry calendar arithmetic,
        // with a day's slack for a daylight-saving change.
        let reach = Double(days + 2) * 86_400
        var hits: [Hit] = []
        for entry in dated {
            guard entry.key != excluding, entry.when > 0, abs(entry.when - date) <= reach else { continue }
            let theirs = calendar.startOfDay(for: Date(timeIntervalSince1970: entry.when))
            guard let apart = calendar.dateComponents([.day], from: mine, to: theirs).day,
                  abs(apart) <= days else { continue }
            hits.append(Hit(key: entry.key, days: abs(apart), when: entry.when))
        }
        // The key breaks ties, so two files copied in the same second keep one
        // order from run to run.
        return hits.sorted {
            if $0.days != $1.days { return $0.days < $1.days }
            if $0.when != $1.when { return $0.when < $1.when }
            return $0.key < $1.key
        }
    }

    /// What a group of the list is called.
    static func heading(days: Int) -> String {
        switch days {
        case 0: return "Same day"
        case 1: return "1 day apart"
        default: return "\(days) days apart"
        }
    }
}
