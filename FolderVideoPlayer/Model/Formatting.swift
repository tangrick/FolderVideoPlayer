import Foundation

/// Digit runs compare numerically, so clip2 sorts before clip10.
func naturalParts(_ s: String) -> [Either] {
    var out: [Either] = []
    var digits = ""
    var text = ""
    for ch in s {
        if ch.isNumber {
            if !text.isEmpty { out.append(.text(text.lowercased())); text = "" }
            digits.append(ch)
        } else {
            if !digits.isEmpty { out.append(.number(Int(digits) ?? 0)); digits = "" }
            text.append(ch)
        }
    }
    if !digits.isEmpty { out.append(.number(Int(digits) ?? 0)) }
    if !text.isEmpty { out.append(.text(text.lowercased())) }
    return out
}

enum Either {
    case number(Int)
    case text(String)
}

func naturalLess(_ a: String, _ b: String) -> Bool {
    naturalLess(naturalParts(a), naturalParts(b))
}

/// The same comparison over keys already split.
///
/// Sorting several thousand paths means tens of thousands of comparisons, and
/// splitting both strings inside each of them costs more than the sort: build
/// the key once per path and compare those.
func naturalLess(_ left: [Either], _ right: [Either]) -> Bool {
    for (l, r) in zip(left, right) {
        switch (l, r) {
        case let (.number(x), .number(y)):
            if x != y { return x < y }
        case let (.text(x), .text(y)):
            if x != y { return x < y }
        case (.number, .text):
            return true         // a digit run sorts before a word, as Python's does
        case (.text, .number):
            return false
        }
    }
    return left.count < right.count
}

/// Seconds as 4:07, or 1:02:30 once there is an hour to show.
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let (hours, rest) = total.quotientAndRemainder(dividingBy: 3600)
    let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

/// Bytes the way a Finder list says them: 643 B, 9.4 MB, 482 MB, 1.4 GB.
func humanSize(_ n: Int64) -> String {
    var size = Double(n)
    for unit in ["B", "KB", "MB", "GB"] {
        if size < 1000 {
            if unit == "B" { return String(format: "%d %@", Int(size), unit) }
            return String(format: size < 10 ? "%.1f %@" : "%.0f %@", size, unit)
        }
        size /= 1000
    }
    return String(format: "%.1f TB", size)
}

/// The larger, rounder form the duplicate results use for reclaimable space.
func humanBytes(_ count: Int64) -> String {
    var value = Double(count)
    for unit in ["bytes", "KB", "MB", "GB", "TB"] {
        if value < 1024 || unit == "TB" {
            return unit == "bytes" ? "\(Int(value)) bytes"
                                   : String(format: "%.1f %@", value, unit)
        }
        value /= 1024
    }
    return "\(count) bytes"
}

/// How long ago, in the words someone would actually use — a date is no use
/// for deciding whether a scan is worth re-running.
func whenWords(_ stamp: Double) -> String {
    let gap = Date().timeIntervalSince1970 - stamp
    if gap < 90 { return "just now" }
    let steps: [(Double, String, Double)] = [
        (60, "minute", 3600), (3600, "hour", 86400),
        (86400, "day", 86400 * 7), (86400 * 7, "week", 86400 * 63),
    ]
    for (size, unit, limit) in steps where gap < limit {
        let count = Int(gap / size)
        return "\(count) \(unit)\(count == 1 ? "" : "s") ago"
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "d MMM yyyy"
    return "on " + fmt.string(from: Date(timeIntervalSince1970: stamp))
}

/// The date column, in Finder's short form: the clock for something added
/// today, day and month for this year, the year as well once it is not.
func dateText(_ stamp: Double, now: Date = Date()) -> String {
    guard stamp > 0 else { return "" }
    let when = Date(timeIntervalSince1970: stamp)
    let cal = Calendar.current
    let fmt = DateFormatter()
    if cal.isDate(when, inSameDayAs: now) {
        fmt.dateFormat = "HH:mm"
    } else if cal.component(.year, from: when) == cal.component(.year, from: now) {
        fmt.dateFormat = "d MMM"
    } else {
        fmt.dateFormat = "d MMM yyyy"
    }
    return fmt.string(from: when)
}

/// Split what someone typed into clean tag names, in the order given. Commas
/// or semicolons separate, whitespace collapses, and a name repeated in a
/// different case counts once.
func parseTags(_ text: String) -> [String] {
    var seen = Set<String>()
    var names: [String] = []
    for part in text.replacingOccurrences(of: ";", with: ",").split(separator: ",") {
        let name = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !name.isEmpty && !seen.contains(name.lowercased()) {
            seen.insert(name.lowercased())
            names.append(name)
        }
    }
    return names
}

/// A filename-safe form of a name, so "Anne Marie" and "anne-marie" cannot
/// end up as two people.
func slug(_ text: String) -> String {
    let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let parts = String(cleaned).split(separator: "-").map(String.init)
    return parts.isEmpty ? "unknown" : parts.joined(separator: "-")
}

/// How many tag chips fit under a tile of `width`, over at most `lines`
/// lines — the rest are reported as a "+N" count.
///
/// Guessed from the text rather than measured: a layout cannot ask its own
/// children how many will fit before placing them, and a tile's width is
/// fixed and known. Roughly 5.2pt a character plus the capsule's padding.
/// At least one chip is always shown: a single long tag reads better
/// truncated than replaced by a bare count.
func chipsThatFit(_ names: [String], width: CGFloat, lines: Int = 2) -> Int {
    guard !names.isEmpty else { return 0 }
    let budget = width * CGFloat(max(lines, 1)) - 22   // room for the "+N"
    var used: CGFloat = 0
    var fitted = 0
    for name in names {
        let chip = CGFloat(name.count) * 5.2 + 11
        guard used + chip <= budget else { break }
        used += chip + 3
        fitted += 1
    }
    return max(fitted, 1)
}
