import Foundation

/// Audio and subtitle tracks: what a file carries, the subtitle files beside
/// it, and the choice the user made — resolved against what THIS file has, so
/// a choice made for one video is never silently applied to another that lacks
/// it.
///
/// Pure: parsing, discovery and resolution are decisions about text and names.
/// Reading the directory, loading the tracks and drawing the words are the
/// engine's and the views' business.

/// One subtitle: when it shows, when it goes, and what it says.
struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// A track the file itself carries, as a menu shows it.
struct TrackOption: Equatable, Identifiable {
    /// Stable for a given file: the option's position in its group.
    let id: String
    let title: String
    let language: String?
}

/// Which subtitles to show.
enum SubtitleChoice: Equatable, Hashable {
    case off
    /// Embedded tracks by the system's caption preferences; otherwise a
    /// subtitle file beside the video; otherwise the transcript.
    case automatic
    case embedded(String)
    /// A subtitle file: a name in the video's folder, or an absolute path for
    /// one the user picked from elsewhere.
    case sidecar(String)
    case transcript

    /// How it is remembered.
    var stored: String {
        switch self {
        case .off: return "off"
        case .automatic: return "auto"
        case .embedded(let id): return "embedded:" + id
        case .sidecar(let name): return "sidecar:" + name
        case .transcript: return "transcript"
        }
    }

    init?(stored: String) {
        switch stored {
        case "off": self = .off
        case "auto": self = .automatic
        case "transcript": self = .transcript
        default:
            if stored.hasPrefix("embedded:") { self = .embedded(String(stored.dropFirst(9))) }
            else if stored.hasPrefix("sidecar:") { self = .sidecar(String(stored.dropFirst(8))) }
            else { return nil }
        }
    }
}

/// Where the words on screen actually come from, once a choice is resolved.
enum SubtitleSource: Equatable {
    case none
    /// AVFoundation draws the selected embedded track itself. Nil id: let it
    /// choose by the system's preferences.
    case embedded(String?)
    case sidecar(String)
    case transcript
}

enum SubtitleFile {

    static let extensions: Set<String> = ["srt", "vtt"]

    enum Failure: Error, Equatable, LocalizedError {
        case unreadable
        case malformed(line: Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "the file could not be read as text"
            case .malformed(let line): return "line \(line) is not a subtitle timing"
            case .empty: return "it holds no subtitles"
            }
        }
    }

    // MARK: - discovery

    /// The subtitle files that belong to a video, from its folder's listing:
    /// the same name (`clip.srt`), or the same name with a language between
    /// (`clip.en.srt`, `clip.pt-BR.vtt`). Case-insensitive, sorted, the bare
    /// name first.
    static func sidecars(for video: String, in names: [String]) -> [String] {
        let base = ((video as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let found = names.filter { name in
            let lower = name.lowercased()
            let ext = (lower as NSString).pathExtension
            guard extensions.contains(ext) else { return false }
            let stem = (lower as NSString).deletingPathExtension
            if stem == base { return true }
            guard stem.hasPrefix(base + ".") else { return false }
            let tag = stem.dropFirst(base.count + 1)
            return !tag.isEmpty && !tag.contains(".") && tag.count <= 12
        }
        return found.sorted { a, b in
            let bareA = (a.lowercased() as NSString).deletingPathExtension == base
            let bareB = (b.lowercased() as NSString).deletingPathExtension == base
            if bareA != bareB { return bareA }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// How a subtitle file is named in a menu: its language when the name
    /// carries one, and its kind — "EN (.srt)", or the name itself.
    static func label(for file: String, video: String) -> String {
        let base = ((video as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let name = (file as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        if stem.lowercased() == base { return "Subtitle file (.\(ext))" }
        if stem.lowercased().hasPrefix(base + ".") {
            return "\(stem.dropFirst(base.count + 1).uppercased()) (.\(ext))"
        }
        return name
    }

    // MARK: - parsing

    static func parse(_ text: String, extension ext: String) throws -> [SubtitleCue] {
        let cues = ext.lowercased() == "vtt" ? try parseVTT(text) : try parseSRT(text)
        guard !cues.isEmpty else { throw Failure.empty }
        return cues
    }

    static func parse(data: Data, extension ext: String) throws -> [SubtitleCue] {
        // UTF-8 first; Windows-1252 is what most older .srt files are.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252) else { throw Failure.unreadable }
        return try parse(text, extension: ext)
    }

    /// SubRip: blocks of an optional counter, a timing line and text lines,
    /// separated by blank lines. Lenient about what readers are lenient about
    /// (a missing counter, a dot for the comma, extra blank lines, a BOM);
    /// strict about the timing line, because a cue with a wrong time is worse
    /// than a reported error.
    static func parseSRT(_ text: String) throws -> [SubtitleCue] {
        try blocks(of: text).compactMap { block in
            var rows = block.rows
            if let first = rows.first, first.text.trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber),
               rows.count > 1 {
                rows.removeFirst()
            }
            guard let timing = rows.first else { return nil }
            guard let (start, end) = timingLine(timing.text) else { throw Failure.malformed(line: timing.number) }
            let words = rows.dropFirst().map(\.text).joined(separator: "\n")
            return SubtitleCue(start: start, end: end, text: clean(words))
        }
    }

    /// WebVTT: the header, then cues (an optional identifier line, the timing
    /// line — settings after it are ignored — and text). NOTE, STYLE and
    /// REGION blocks are skipped; markup is stripped and entities decoded.
    static func parseVTT(_ text: String) throws -> [SubtitleCue] {
        let all = try blocks(of: text)
        guard let header = all.first, header.rows.first?.text.hasPrefix("WEBVTT") == true else {
            throw Failure.malformed(line: 1)
        }
        return try all.dropFirst().compactMap { block in
            var rows = block.rows
            guard let first = rows.first else { return nil }
            if ["NOTE", "STYLE", "REGION"].contains(where: { first.text.hasPrefix($0) }) { return nil }
            if !first.text.contains("-->") { rows.removeFirst() }
            guard let timing = rows.first else { return nil }
            guard let (start, end) = timingLine(timing.text) else { throw Failure.malformed(line: timing.number) }
            let words = rows.dropFirst().map(\.text).joined(separator: "\n")
            return SubtitleCue(start: start, end: end, text: clean(words))
        }
    }

    private struct Block { var rows: [(number: Int, text: String)] }

    private static func blocks(of text: String) throws -> [Block] {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var out: [Block] = []
        var current: [(Int, String)] = []
        for (i, line) in body.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { out.append(Block(rows: current)); current = [] }
            } else {
                current.append((i + 1, line))
            }
        }
        if !current.isEmpty { out.append(Block(rows: current)) }
        return out
    }

    /// "00:01:02,500 --> 00:01:04,000" (SRT) or "01:02.500 --> 01:04.000 line:90%"
    /// (VTT). Nil for anything else, or an end before the start.
    static func timingLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard let start = timestamp(startText), let end = timestamp(endText), end >= start else { return nil }
        return (start, end)
    }

    /// hh:mm:ss,mmm, hh:mm:ss.mmm or mm:ss.mmm.
    static func timestamp(_ text: String) -> Double? {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            guard let value = last ? Double(part) : Double(Int(part) ?? -1), value >= 0, value.isFinite
            else { return nil }
            if i > 0 && value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Markup out (`<i>`, `<c.yellow>`, `{\an8}`), the common entities decoded.
    private static func clean(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TrackPlan {

    /// A saved choice, checked against what this file has. A choice the file
    /// cannot honour falls back to Automatic, and the note says so — a French
    /// subtitle picked for one film is not quietly swapped for "whatever" on
    /// the next.
    static func resolve(saved: SubtitleChoice?, embedded: [TrackOption], sidecars: [String],
                        hasTranscript: Bool) -> (choice: SubtitleChoice, note: String?) {
        guard let saved else { return (.automatic, nil) }
        switch saved {
        case .off, .automatic:
            return (saved, nil)
        case .embedded(let id):
            if embedded.contains(where: { $0.id == id }) { return (saved, nil) }
            return (.automatic, "The subtitle track chosen before is not in this file, so Automatic is used.")
        case .sidecar(let name):
            if name.hasPrefix("/") || sidecars.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return (saved, nil)
            }
            return (.automatic, "“\(name)” is no longer beside this video, so Automatic is used.")
        case .transcript:
            if hasTranscript { return (saved, nil) }
            return (.automatic, "This video has no transcript, so Automatic is used.")
        }
    }

    /// What a resolved choice shows.
    static func source(for choice: SubtitleChoice, embedded: [TrackOption], sidecars: [String],
                       hasTranscript: Bool) -> SubtitleSource {
        switch choice {
        case .off: return .none
        case .embedded(let id): return .embedded(id)
        case .sidecar(let name): return .sidecar(name)
        case .transcript: return .transcript
        case .automatic:
            if !embedded.isEmpty { return .embedded(nil) }
            if let first = sidecars.first { return .sidecar(first) }
            return hasTranscript ? .transcript : .none
        }
    }

    /// The cue on screen at `time`: the latest one that has started and not
    /// ended. Cues are few per video; a scan is fine at four ticks a second.
    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        cues.last { $0.start <= time && time < $0.end }
    }
}
