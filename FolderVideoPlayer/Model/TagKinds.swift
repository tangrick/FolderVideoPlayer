import Foundation

/// Works out what kind of thing a tag names, so 99 tags can be filed under a
/// handful of headings without the user sorting them by hand.
///
/// Every rule here is a guess offered for approval, never applied silently. The
/// guesses lean on evidence the app already holds — the system's own country
/// list, the face registry, the metadata tagger's own vocabulary — rather than
/// a hand-written list of words, because a hand-written list goes stale the
/// moment the user types a tag nobody thought of.
enum TagKinds {

    /// The headings offered. Deliberately few: a heading earns its place by
    /// collecting enough tags to shorten the list, and a dozen headings holding
    /// three tags each is just the flat list again with extra rows.
    static let place  = "Place"
    static let person = "Person"
    static let when   = "Date"
    static let event  = "Event"
    static let camera = "Camera & Quality"

    /// Countries and territories, from the system rather than a typed list, so
    /// it knows every name the OS knows and stays right as the world changes.
    private static let countries: Set<String> = {
        var out = Set<String>()
        for code in Locale.Region.isoRegions where code.identifier.count == 2 {
            if let name = Locale.current.localizedString(forRegionCode: code.identifier) {
                out.insert(name.lowercased())
            }
        }
        // Common short forms people actually type. The system answers "United
        // States" and "United Kingdom"; nobody types those into a tag box.
        for (short, _) in [("usa", "United States"), ("us", "United States"),
                           ("uk", "United Kingdom"), ("uae", "United Arab Emirates"),
                           ("holland", "Netherlands"), ("korea", "South Korea")] {
            out.insert(short)
        }
        return out
    }()

    /// Words that mark a tag as naming an occasion rather than a place or a
    /// person. Short on purpose — anything not recognised stays unfiled, which
    /// is honest, where a wrong heading is worse than none.
    private static let occasions: Set<String> = [
        "birthday", "party", "wedding", "christmas", "new year", "anniversary",
        "graduation", "funeral", "concert", "performance", "dance", "parade",
        "fireworks", "ndp", "festival", "holiday", "dining", "shopping",
        "driving", "whale watching", "home repair", "mahjong"
    ]

    /// Quality and speed marks the metadata tagger writes itself.
    private static let qualities: Set<String> = [
        "4k", "1080p", "720p", "480p", "hd", "sd", "slow-mo", "slow motion",
        "timelapse", "time-lapse", "portrait", "landscape"
    ]

    /// Camera makers. A tag naming a device is about the camera, not the
    /// subject — matched anywhere in the tag because these arrive as models
    /// ("iPhone 16 Plus", "Ray-Ban Meta Smart Glasses") rather than bare names.
    private static let makers: Set<String> = [
        "iphone", "ipad", "canon", "nikon", "sony", "gopro", "dji", "fujifilm",
        "panasonic", "olympus", "leica", "samsung", "pixel", "ray-ban", "insta360"
    ]

    /// Major cities, from the system time-zone database rather than a typed
    /// list. Every zone is `Region/City`, so the tail of each identifier is a
    /// real city name — several hundred of them, kept current by the OS.
    private static let cities: Set<String> = {
        var out = Set<String>()
        for zone in TimeZone.knownTimeZoneIdentifiers {
            guard let tail = zone.split(separator: "/").last else { continue }
            out.insert(tail.replacingOccurrences(of: "_", with: " ").lowercased())
        }
        return out
    }()

    /// Is this tag a bare year, or a month and year — the shape the metadata
    /// tagger writes? Parsed rather than pattern-matched on digits alone, so
    /// "2015" is a date but "1080p" and "4k" are not.
    static func isDateLike(_ tag: String) -> Bool {
        let t = tag.trimmingCharacters(in: .whitespaces)
        if t.count == 4, let n = Int(t), (1900...2100).contains(n) { return true }
        let parts = t.split(separator: " ")
        guard parts.count == 2, let n = Int(parts[1]), (1900...2100).contains(n) else { return false }
        // The month names come from the formatter the scan writes with, rather
        // than a second list typed out here that could go stale against it.
        return AutoTagCore.monthIn(String(parts[0])) != nil
    }

    static func isCountry(_ tag: String) -> Bool {
        countries.contains(tag.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// Is this tag a READING off the file rather than a judgement about the
    /// picture?
    ///
    /// Date, quality and camera are answerable from the name alone: `2016`,
    /// `May 2016`, `1080p`, `4K`, `Slow-mo`, `iPhone 16 Plus`, `canon` cannot
    /// plausibly be anything else, so `MetadataFacts` may take them on sight.
    ///
    /// **A place is deliberately NOT answerable here.** `Iceland` is a country
    /// name, a folder name and a tag the user means, and no rule on the string
    /// can tell those apart. A place becomes a fact only when the scan's own
    /// record says the scan wrote it. Keep this list short and defensible: a
    /// name wrongly taken for a reading is a tag silently removed from the
    /// user's vocabulary, which is worse than a fact left as a tag.
    static func isFileFact(_ tag: String) -> Bool {
        let t = tag.lowercased().trimmingCharacters(in: .whitespaces)
        if isDateLike(tag) { return true }
        if qualities.contains(t) { return true }
        if makers.contains(t) { return true }
        // Device names arrive whole ("iPhone 16 Plus", "Ray-Ban Meta Smart
        // Glasses"), so a maker anywhere in the name counts — split on spaces
        // only, or `ray-ban` is destroyed by its own hyphen.
        let words = Set(t.split(separator: " ").map(String.init))
        return !makers.isDisjoint(with: words)
    }

    /// Which heading a fact belongs under in the sidebar's "From the file"
    /// section — the existing headings, not a second vocabulary: a quality mark
    /// already files under `camera`, and a date under `when`.
    ///
    /// Anything not date- or camera-shaped is a `place`, because the only other
    /// way into the fact store is the scan's own record, and what the scan
    /// writes from a file's metadata that is not a date, a resolution or a
    /// camera is a place.
    static func kind(ofFact tag: String) -> String {
        let t = tag.lowercased().trimmingCharacters(in: .whitespaces)
        if isDateLike(tag) { return when }
        if qualities.contains(t) { return camera }
        let words = Set(t.split(separator: " ").map(String.init))
        if makers.contains(t) || !makers.isDisjoint(with: words) { return camera }
        return place
    }


    /// The best guess for one tag, or nil to leave it unfiled.
    ///
    /// - Parameters:
    ///   - known: names from the face registry. A person is whoever the user has
    ///     put a face to — far better evidence than guessing from capitals,
    ///     which would file "Gardens By the Bay" as a person.
    ///   - cities: places the metadata tagger wrote from GPS. It only ever
    ///     writes real place names, so anything it produced is a place.
    static func guess(_ tag: String,
                      knownPeople: Set<String>,
                      knownPlaces: Set<String>) -> String? {
        let t = tag.lowercased().trimmingCharacters(in: .whitespaces)
        if isDateLike(tag) { return when }
        if knownPeople.contains(t) { return person }
        if isCountry(tag) || cities.contains(t) || knownPlaces.contains(t) { return place }
        if qualities.contains(t) { return camera }
        // A device name anywhere in the tag: these arrive as full model names,
        // so "iPhone 16 Plus" and "Ray-Ban Meta Smart Glasses" both land here.
        let words = Set(t.split(separator: " ").map(String.init))
        if !makers.isDisjoint(with: words) || makers.contains(t) { return camera }
        if occasions.contains(t) { return event }
        // Judged on the LAST word, which is what the tag is actually about:
        // "Beach Party" is a party, "Sentosa Beach" is a beach. Occasions are
        // tested first so a party held at a beach files as an occasion.
        let lastWord = t.split(separator: " ").last.map(String.init) ?? t
        if occasions.contains(lastWord) { return event }
        // Anything ending in a place word is a place: "Sentosa Beach",
        // "Niagara Falls". Matched on the last word so "Beach Party" is not
        // caught — that is an occasion held at one.
        let placeWords: Set<String> = ["beach", "park", "lake", "falls", "island",
                                       "mountain", "mountains", "bay", "harbour",
                                       "harbor", "city", "airport", "hotel",
                                       "restaurant", "temple", "museum", "zoo"]
        if let last = t.split(separator: " ").last, placeWords.contains(String(last)) {
            return place
        }
        return nil
    }
}
