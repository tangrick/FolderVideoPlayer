import Foundation

/// A transcript being corrected by hand: the lines, every edit the editor
/// offers, an undo history for the session, and a verdict on whether what is
/// on screen may be saved.
///
/// Pure value type, no store: the editor holds one, the journal saves the
/// lines it hands back. Keeping it apart from the store is what lets every
/// edit be tested without SQLite and lets Cancel be "throw the draft away".
///
/// Two rules shape it:
///
/// - **User-entered times are never rewritten.** An overlap, a gap, a line
///   that now starts before the one above it — each is reported, none is
///   quietly fixed. A fix the user did not ask for is a second edit they have
///   to find.
/// - **Refusal leaves the draft as it was.** An edit that cannot be applied
///   (a shift that would put a line before zero, a split outside the line)
///   throws and changes nothing, so the undo history never holds a half-step.
struct TranscriptDraft: Equatable {

    struct Line: Equatable, Identifiable, Codable {
        var id = UUID()
        var start: Double
        var end: Double
        var text: String
    }

    /// Something wrong, or worth a look, about the lines as they stand.
    struct Issue: Equatable {
        enum Kind: Equatable {
            /// A time that is not a number, or is negative.
            case invalidTime
            /// The line ends before it starts.
            case endBeforeStart
            /// The line has no words; an empty cue is not a subtitle.
            case emptyText
            /// The line starts before the line above it ends — two lines on
            /// screen at once. Allowed (two speakers), but shown.
            case overlap(with: Line.ID)
            /// The line starts before the line above it starts: the order on
            /// screen is no longer the order in time.
            case outOfOrder
            /// Silence of at least `gapWarning` seconds before this line —
            /// often a mistyped time rather than a real pause.
            case gap(seconds: Double)
        }
        let line: Line.ID
        let kind: Kind

        /// Errors stop a save; the rest are for the user to judge.
        var isError: Bool {
            switch kind {
            case .invalidTime, .endBeforeStart, .emptyText, .outOfOrder: return true
            case .overlap, .gap: return false
            }
        }

        var message: String {
            switch kind {
            case .invalidTime: return "Times must be zero or later."
            case .endBeforeStart: return "This line ends before it starts."
            case .emptyText: return "This line has no text. Type something or delete the line."
            case .overlap: return "Overlaps the line above — both show at once."
            case .outOfOrder: return "Starts before the line above. Move its time, or the lines will play out of order."
            case .gap(let seconds): return "\(Int(seconds.rounded())) s of silence before this line."
            }
        }
    }

    enum Refusal: Error, Equatable, LocalizedError {
        case noSuchLine
        case splitOutsideLine
        case nothingToMerge
        case wouldStartBeforeZero
        case invalidTime

        var errorDescription: String? {
            switch self {
            case .noSuchLine: return "That line is no longer in the transcript."
            case .splitOutsideLine: return "The split point must fall inside the line."
            case .nothingToMerge: return "There is no line after this one to merge with."
            case .wouldStartBeforeZero: return "That shift would move a line before the start of the video."
            case .invalidTime: return "Times must be numbers of zero or more."
            }
        }
    }

    private(set) var lines: [Line]
    /// Carried onto every saved line: an edit does not change what language was
    /// spoken or which model first heard it.
    let language: String
    let source: String

    /// Silence at least this long before a line is flagged. Speech pauses are
    /// normal; ten seconds of nothing between two lines is usually a typo.
    var gapWarning: Double = 10

    private var undoStack: [[Line]] = []
    private var redoStack: [[Line]] = []
    /// Consecutive text edits to one line are one undo step, not one per
    /// keystroke. Any other edit ends the run.
    private var coalescing: Line.ID?

    init(_ transcript: [TranscriptLine]) {
        lines = transcript.map { Line(start: $0.start, end: $0.end, text: $0.text) }
        language = transcript.first?.language ?? ""
        source = transcript.first?.source ?? ""
    }

    init(lines: [Line], language: String = "", source: String = "") {
        self.lines = lines
        self.language = language
        self.source = source
    }

    static func == (a: Self, b: Self) -> Bool {
        a.lines == b.lines && a.language == b.language && a.source == b.source
    }

    // MARK: - history

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(lines)
        lines = previous
        coalescing = nil
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(lines)
        lines = next
        coalescing = nil
    }

    private mutating func record(coalesce: Line.ID? = nil) {
        if let coalesce, coalesce == coalescing { return }
        undoStack.append(lines)
        redoStack = []
        coalescing = coalesce
    }

    // MARK: - edits

    func index(of id: Line.ID) -> Int? { lines.firstIndex { $0.id == id } }

    mutating func setText(_ id: Line.ID, _ text: String) throws {
        guard let i = index(of: id) else { throw Refusal.noSuchLine }
        guard lines[i].text != text else { return }
        record(coalesce: id)
        lines[i].text = text
    }

    /// Set one line's times exactly as typed. Only a non-number or a negative
    /// time is refused; an end before the start is kept and flagged, because
    /// the user may be halfway through fixing the other one.
    mutating func setTimes(_ id: Line.ID, start: Double, end: Double) throws {
        guard let i = index(of: id) else { throw Refusal.noSuchLine }
        guard start.isFinite, end.isFinite, start >= 0, end >= 0 else { throw Refusal.invalidTime }
        guard lines[i].start != start || lines[i].end != end else { return }
        record()
        lines[i].start = start
        lines[i].end = end
    }

    /// A new, empty line after `id` (or at the top when `id` is nil), timed into
    /// the silence that follows it — two seconds, or less when the next line
    /// comes sooner. Returns the new line's id so the editor can focus it.
    @discardableResult
    mutating func insert(after id: Line.ID?) throws -> Line.ID {
        let at: Int
        let start: Double
        if let id {
            guard let i = index(of: id) else { throw Refusal.noSuchLine }
            at = i + 1
            start = lines[i].end
        } else {
            at = 0
            start = 0
        }
        let limit = at < lines.count ? lines[at].start : start + 2
        let end = max(start, min(start + 2, limit))
        let line = Line(start: start, end: end, text: "")
        record()
        lines.insert(line, at: at)
        return line.id
    }

    /// A new, empty line before `id`, timed into the silence before it.
    @discardableResult
    mutating func insert(before id: Line.ID) throws -> Line.ID {
        guard let i = index(of: id) else { throw Refusal.noSuchLine }
        let end = lines[i].start
        let floor = i > 0 ? lines[i - 1].end : 0
        let start = max(0, max(floor, end - 2))
        let line = Line(start: min(start, end), end: end, text: "")
        record()
        lines.insert(line, at: i)
        return line.id
    }

    mutating func delete(_ ids: Set<Line.ID>) {
        guard lines.contains(where: { ids.contains($0.id) }) else { return }
        record()
        lines.removeAll { ids.contains($0.id) }
    }

    /// Split one line in two at `time`. The words go where `textOffset` says
    /// (a cursor position in the text, in characters); without one, they are
    /// divided at the word boundary nearest the same fraction of the line as
    /// `time` is of its span — speech is roughly even, and the user can move a
    /// word after.
    mutating func split(_ id: Line.ID, at time: Double, textOffset: Int? = nil) throws {
        guard let i = index(of: id) else { throw Refusal.noSuchLine }
        let line = lines[i]
        guard time.isFinite, time > line.start, time < line.end else { throw Refusal.splitOutsideLine }
        let cut = textOffset.map { max(0, min($0, line.text.count)) }
            ?? Self.wordBoundary(in: line.text,
                                 near: (time - line.start) / (line.end - line.start))
        let at = line.text.index(line.text.startIndex, offsetBy: cut)
        let head = line.text[..<at].trimmingCharacters(in: .whitespaces)
        let tail = line.text[at...].trimmingCharacters(in: .whitespaces)
        record()
        lines[i].end = time
        lines[i].text = head
        lines.insert(Line(start: time, end: line.end, text: tail), at: i + 1)
    }

    /// Join a line with the one after it: the earlier start, the later end, the
    /// words in order with one space between.
    mutating func mergeWithNext(_ id: Line.ID) throws {
        guard let i = index(of: id) else { throw Refusal.noSuchLine }
        guard i + 1 < lines.count else { throw Refusal.nothingToMerge }
        let next = lines[i + 1]
        record()
        lines[i].start = min(lines[i].start, next.start)
        lines[i].end = max(lines[i].end, next.end)
        lines[i].text = [lines[i].text, next.text]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        lines.remove(at: i + 1)
    }

    /// Move the given lines earlier (negative) or later (positive) by the same
    /// amount. Refused — nothing moves — when any line would start before zero.
    mutating func shift(_ ids: Set<Line.ID>, by offset: Double) throws {
        guard offset.isFinite else { throw Refusal.invalidTime }
        guard offset != 0, lines.contains(where: { ids.contains($0.id) }) else { return }
        if lines.contains(where: { ids.contains($0.id) && $0.start + offset < 0 }) {
            throw Refusal.wouldStartBeforeZero
        }
        record()
        for i in lines.indices where ids.contains(lines[i].id) {
            lines[i].start += offset
            lines[i].end += offset
        }
    }

    /// The whole transcript earlier or later — a consistent sync error.
    mutating func shiftAll(by offset: Double) throws {
        try shift(Set(lines.map(\.id)), by: offset)
    }

    // MARK: - verdict

    /// Everything worth telling the user, in line order.
    var issues: [Issue] {
        var found: [Issue] = []
        for (i, line) in lines.enumerated() {
            if !line.start.isFinite || !line.end.isFinite || line.start < 0 || line.end < 0 {
                found.append(Issue(line: line.id, kind: .invalidTime))
                continue
            }
            if line.end < line.start { found.append(Issue(line: line.id, kind: .endBeforeStart)) }
            if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(Issue(line: line.id, kind: .emptyText))
            }
            guard i > 0 else { continue }
            let above = lines[i - 1]
            guard above.start.isFinite, above.end.isFinite else { continue }
            if line.start < above.start {
                found.append(Issue(line: line.id, kind: .outOfOrder))
            } else if line.start < above.end {
                found.append(Issue(line: line.id, kind: .overlap(with: above.id)))
            } else if line.start - above.end >= gapWarning {
                found.append(Issue(line: line.id, kind: .gap(seconds: line.start - above.end)))
            }
        }
        return found
    }

    var canSave: Bool { !issues.contains(where: \.isError) }

    /// The lines as the store takes them.
    func transcriptLines(path: String) -> [TranscriptLine] {
        lines.map {
            TranscriptLine(path: path, start: $0.start, end: $0.end,
                           text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                           language: language, source: source)
        }
    }

    // MARK: - helpers

    /// A time as the editor shows it: m:ss.mmm, or h:mm:ss.mmm past an hour.
    static func formatTime(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, frac = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, frac)
                     : String(format: "%d:%02d.%03d", m, s, frac)
    }

    /// A typed time: plain seconds (`75.5`), m:ss(.mmm) or h:mm:ss(.mmm), with a
    /// comma accepted before the fraction the way SRT writes it. Nil for
    /// anything else, including a negative time — the editor then says so
    /// rather than guessing what was meant.
    static func parseTime(_ typed: String) -> Double? {
        let text = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, !text.hasPrefix("-"), !text.hasPrefix("+") else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            guard !part.isEmpty, let value = last ? Double(part) : Double(Int(part) ?? -1),
                  value >= 0, value.isFinite else { return nil }
            // Minutes and seconds under a larger unit stay under 60.
            if i > 0 && value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// A signed offset for a shift: `-1.5`, `+2`, `-0:01.250`.
    static func parseOffset(_ typed: String) -> Double? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-") { return parseTime(String(text.dropFirst())).map { -$0 } }
        if text.hasPrefix("+") { return parseTime(String(text.dropFirst())) }
        return parseTime(text)
    }

    /// The character offset of the space nearest `fraction` of the way through
    /// `text`, so a split lands between words. Text without spaces (Chinese,
    /// Japanese) is cut at the character nearest the fraction.
    static func wordBoundary(in text: String, near fraction: Double) -> Int {
        let characters = Array(text)
        guard !characters.isEmpty else { return 0 }
        let target = Int((Double(characters.count) * max(0, min(1, fraction))).rounded())
        let spaces = characters.indices.filter { characters[$0] == " " }
        guard let best = spaces.min(by: { abs($0 - target) < abs($1 - target) }) else { return target }
        return best
    }
}
