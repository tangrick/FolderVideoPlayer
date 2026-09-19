import Foundation

/// The pure rules behind auto-tagging: everything that decides which tags a
/// video earns from its path, its dates and its metadata — with no file
/// access and no AVFoundation, so the rules are unit-testable and the scan
/// loop stays a thin shell around them.
enum AutoTagCore {

    // MARK: - folder names

    /// The folders between the scanned root (exclusive) and the video file
    /// (exclusive), innermost first:
    ///   folders(of: "/v/Cruise/2024/Day2/clip.mov", under: "/v/Cruise")
    ///   → ["Day2", "2024"]
    static func folders(of path: String, under root: String) -> [String] {
        var rel = path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if rel.hasPrefix(prefix) { rel = String(rel.dropFirst(prefix.count)) }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return [] }
        return Array(parts.dropLast().reversed())
    }

    /// The nearest folders become tags. A video sitting directly in the root
    /// earns the root's own name ("tag what I chose"); deeper ones earn their
    /// own parent folders, capped at `depth`.
    static func folderTags(of path: String, under root: String, depth: Int) -> [String] {
        var tags = folders(of: path, under: root)
        if tags.isEmpty {
            let name = (root as NSString).lastPathComponent
            if !name.isEmpty { tags = [name] }
        } else {
            tags = Array(tags.prefix(max(depth, 1)))
        }
        return tags
    }

    // MARK: - dates

    /// The year alone and the month: a clip from May 2024 earns "2024" and
    /// "May 2024" — enough to re-find it years later without knowing the day.
    static func dateTags(_ date: Date, calendar: Calendar = .current) -> [String] {
        yearTag(date, calendar: calendar).map { [$0] + monthTag(date, calendar: calendar) } ?? []
    }

    /// The year alone — one tag per year of your library, so a decade of
    /// clips is ten tags however many videos there are.
    static func yearTag(_ date: Date, calendar: Calendar = .current) -> String? {
        let year = calendar.component(.year, from: date)
        guard year > 1900 else { return nil }
        return "\(year)"
    }

    /// The year a name refers to, or nil when it refers to none.
    ///
    /// Catches a bare year (`2024`) and a name that carries one (`December
    /// 2022`), so both sort into the same group instead of scattering through
    /// the alphabet. The one reading of "what year is this" in the app: the
    /// sidebar used to parse years itself, which gave the tag list and the fact
    /// list two answers to the same question.
    static func yearIn(_ name: String) -> Int? {
        guard let match = name.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression)
        else { return nil }
        return Int(name[match])
    }

    /// The month a name refers to, 1…12, or nil for a bare year. English month
    /// names because that is what `monthTag` writes, read off the same formatter
    /// so the writer and the reader cannot drift apart.
    static func monthIn(_ name: String) -> Int? {
        let symbols = DateFormatter.monthYear.monthSymbols ?? []
        for word in name.lowercased().split(separator: " ") {
            if let index = symbols.firstIndex(where: { $0.lowercased() == word }) {
                return index + 1
            }
        }
        return nil
    }

    /// The month — "May 2024". Finer, and twelve times as many tags: worth
    /// having on a holiday library, not on ten years of everything.
    static func monthTag(_ date: Date, calendar: Calendar = .current) -> [String] {
        guard calendar.component(.year, from: date) > 1900 else { return [] }
        let month = DateFormatter.monthYear.string(from: date)
        return month.isEmpty ? [] : [month]
    }

    // MARK: - camera & quality

    /// "iPhone 15 Pro" out of Apple's make + model pair — Apple's own make is
    /// "Apple", which reads badly and is dropped; a real maker stays.
    static func cameraTag(make: String?, model: String?) -> String? {
        var parts: [String] = []
        if let make, !make.isEmpty, make != "Apple" { parts.append(make) }
        if let model, !model.isEmpty { parts.append(model) }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// The resolution ladder, by frame height — 4K / 1080p / 720p / 480p —
    /// plus Slow-mo from a frame rate well past broadcast. Height not width,
    /// so a vertical iPhone clip (1080 wide, 1920 tall) still reads 1080p.
    static func qualityTags(width: Int, height: Int, fps: Double) -> [String] {
        var out: [String] = []
        switch height {
        case 2160...:  out.append("4K")
        case 1080...:  out.append("1080p")
        case 720...:   out.append("720p")
        case 480...:   out.append("480p")
        default:       break
        }
        if fps > 60 { out.append("Slow-mo") }
        return out
    }

    // MARK: - GPS

    /// ISO 6709 as iPhone location metadata writes it: "+01.2897+103.8501/"
    /// (the trailing slash and the leading sign per part are the format, not
    /// dirt). Returns nil for anything that does not parse.
    static func parseISO6709(_ raw: String) -> (lat: Double, lon: Double)? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
        guard let lonStart = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }),
              lonStart != s.startIndex, lonStart != s.endIndex else { return nil }
        let latText = String(s[s.startIndex..<lonStart])
        let lonText = String(s[lonStart...])
        guard let lat = Double(latText), let lon = Double(lonText),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }

    // MARK: - merging

    /// Auto-tags never overwrite: existing tags keep their order and new ones
    /// are appended, deduplicated case-insensitively.
    static func merged(existing: [String], adding: [String]) -> [String] {
        var out = existing
        for tag in adding {
            let known = out.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            if !known { out.append(tag) }
        }
        return out
    }
}

private extension DateFormatter {
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}
