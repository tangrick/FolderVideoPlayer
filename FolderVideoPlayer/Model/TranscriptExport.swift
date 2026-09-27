import Foundation

/// A saved transcript, written out in a format another program reads.
///
/// Every format is rendered from the same `[TranscriptLine]` — the saved,
/// corrected revision the store holds — so TXT, SRT, VTT, CSV and JSON of one
/// video always say the same thing. Pure: the caller chooses where the bytes
/// go (and confirms any overwrite); this only decides what they are.
enum TranscriptExport {

    enum Format: String, CaseIterable, Identifiable {
        case txt, srt, vtt, csv, json

        var id: String { rawValue }
        var fileExtension: String { rawValue }

        /// Named for what the file is for, not for its extension alone.
        var label: String {
            switch self {
            case .txt: return "Plain Text (.txt)"
            case .srt: return "SubRip Subtitles (.srt)"
            case .vtt: return "WebVTT Captions (.vtt)"
            case .csv: return "Spreadsheet (.csv)"
            case .json: return "FolderVideoPlayer Transcript (.json)"
            }
        }
    }

    /// The identifier and version written into a JSON export, so a reader can
    /// tell this file from any other JSON and a later version can be told apart.
    static let jsonFormat = "FolderVideoPlayer.transcript"
    static let jsonVersion = 1

    static func render(_ lines: [TranscriptLine], as format: Format, videoName: String = "") -> String {
        switch format {
        case .txt: return text(lines)
        case .srt: return srt(lines)
        case .vtt: return vtt(lines)
        case .csv: return csv(lines)
        case .json: return json(lines, videoName: videoName)
        }
    }

    /// The words alone, one line each.
    static func text(_ lines: [TranscriptLine]) -> String {
        lines.map { oneLine($0.text) }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// SubRip: numbered cues, comma before the milliseconds. A blank line ends a
    /// cue, so blank lines inside a line's text are closed up.
    static func srt(_ lines: [TranscriptLine]) -> String {
        lines.enumerated().map { i, line in
            "\(i + 1)\n\(clock(line.start, ",")) --> \(clock(line.end, ","))\n\(cueText(line.text))\n"
        }.joined(separator: "\n")
    }

    /// WebVTT: the header, then cues with a full stop before the milliseconds.
    /// `&`, `<` and `>` are markup in a cue and are escaped, which also keeps a
    /// literal `-->` in the words from reading as a timing line.
    static func vtt(_ lines: [TranscriptLine]) -> String {
        var out = "WEBVTT\n"
        for line in lines {
            let words = cueText(line.text)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            out += "\n\(clock(line.start, ".")) --> \(clock(line.end, "."))\n\(words)\n"
        }
        return out
    }

    /// start, end (seconds, to the millisecond) and text, quoted as RFC 4180
    /// says: a field with a comma, quote or line break is quoted, and a quote
    /// inside it is doubled.
    static func csv(_ lines: [TranscriptLine]) -> String {
        var rows = ["start,end,text"]
        for line in lines {
            rows.append("\(seconds(line.start)),\(seconds(line.end)),\(csvField(line.text))")
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// The lossless form: every field the store keeps for a line.
    ///
    /// ```json
    /// { "format": "FolderVideoPlayer.transcript", "version": 1,
    ///   "video": "clip.mp4",
    ///   "lines": [ { "start": 1.5, "end": 3.25, "text": "…",
    ///                "language": "en", "source": "whisper-…" } ] }
    /// ```
    ///
    /// Times are seconds as numbers. Keys are sorted so two exports of the same
    /// transcript are byte-identical.
    static func json(_ lines: [TranscriptLine], videoName: String) -> String {
        let document = JSONDocument(format: jsonFormat, version: jsonVersion, video: videoName,
                                    lines: lines.map {
                                        .init(start: $0.start, end: $0.end, text: $0.text,
                                              language: $0.language, source: $0.source)
                                    })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document) else { return "" }
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    /// Read a JSON export back. Nil for a file that is not one, or a version
    /// newer than this build writes.
    static func parseJSON(_ data: Data, path: String) -> [TranscriptLine]? {
        guard let document = try? JSONDecoder().decode(JSONDocument.self, from: data),
              document.format == jsonFormat, document.version <= jsonVersion else { return nil }
        return document.lines.map {
            TranscriptLine(path: path, start: $0.start, end: $0.end, text: $0.text,
                           language: $0.language, source: $0.source)
        }
    }

    struct JSONDocument: Codable {
        struct Line: Codable {
            var start: Double
            var end: Double
            var text: String
            var language: String
            var source: String
        }
        var format: String
        var version: Int
        var video: String
        var lines: [Line]
    }

    /// The name offered in the save panel: the video's own name, the new
    /// extension.
    static func suggestedName(for videoPath: String, format: Format) -> String {
        let base = ((videoPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return (base.isEmpty ? "Transcript" : base) + "." + format.fileExtension
    }

    // MARK: - pieces

    /// HH:MM:SS,mmm (or with `.`): rounded to the millisecond, never negative.
    static func clock(_ seconds: Double, _ separator: String) -> String {
        let ms = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d",
                      ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", max(0, value.isFinite ? value : 0))
    }

    private static func cueText(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
