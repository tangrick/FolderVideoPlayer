// The transcript editor and its exports, without Xcode, a model or a network.
//
// What is proved, in order:
//
//   1. every edit the editor offers — text, times, insert, delete, split, merge,
//      shift selected, shift all — does what it says and nothing else;
//   2. undo and redo cover every one of them, and a run of typing into one line
//      is one undo step;
//   3. a refused edit changes nothing (and leaves no undo step);
//   4. validation flags invalid, reversed, empty and out-of-order lines as
//      errors, overlaps and long gaps as warnings, and never rewrites a time;
//   5. the store keeps the machine's lines on the first saved edit, keeps them
//      through a second edit, restores them, and a re-transcription drops them;
//   6. search and the per-video read see the corrected revision;
//   7. a moved file's transcript (corrections and original) follows it, and a
//      destination that already has one is left alone;
//   8. a store written before corrections existed opens and gains the table;
//   9. SRT, VTT, TXT, CSV and JSON say the same thing, escape what each format
//      needs escaped, keep Unicode, and JSON reads back losslessly.
//
// Run: Tests/run_transcript_edit.sh

@testable import FVPModel
import Foundation
import SQLite3

@main
struct TranscriptEditTest {

    static func main() {
        do {
            try run()
        } catch {
            print("FAIL the harness threw before finishing — \(error)")
            exit(1)
        }
    }

    static func run() throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        let video = "/library/holiday.mp4"
        func machine() -> [TranscriptLine] {
            [TranscriptLine(path: video, start: 0, end: 2, text: "hello there", language: "en", source: "whisper"),
             TranscriptLine(path: video, start: 2.5, end: 5, text: "general kenobi", language: "en", source: "whisper"),
             TranscriptLine(path: video, start: 6, end: 8, text: "你好 世界", language: "en", source: "whisper")]
        }

        // --- 1 & 2. edits and their undo ----------------------------------------

        var draft = TranscriptDraft(machine())
        let original = draft.lines
        let first = draft.lines[0].id, second = draft.lines[1].id, third = draft.lines[2].id

        try draft.setText(first, "hello t")
        try draft.setText(first, "hello th")
        try draft.setText(first, "hello there!")
        check("text edits land", draft.lines[0].text == "hello there!")
        draft.undo()
        check("a run of typing into one line is one undo step", draft.lines == original,
              draft.lines[0].text)
        draft.redo()
        check("redo puts the typing back", draft.lines[0].text == "hello there!")
        draft.undo()

        try draft.setTimes(second, start: 2.25, end: 4.5)
        check("times are set exactly as typed",
              draft.lines[1].start == 2.25 && draft.lines[1].end == 4.5)
        draft.undo()
        check("undo covers a time edit", draft.lines == original)

        let insertedAfter = try draft.insert(after: first)
        check("insert after lands between the lines",
              draft.lines.map(\.id) == [first, insertedAfter, second, third])
        let gapLine = draft.lines[1]
        check("an inserted line is timed into the silence after its neighbour",
              gapLine.start == 2 && gapLine.end == 2.5, "\(gapLine.start)…\(gapLine.end)")
        draft.undo()
        check("undo covers an insertion", draft.lines == original)

        let insertedBefore = try draft.insert(before: third)
        check("insert before lands above the line",
              draft.lines.map(\.id) == [first, second, insertedBefore, third])
        check("an inserted-before line fits the silence above",
              draft.lines[2].start == 5 && draft.lines[2].end == 6,
              "\(draft.lines[2].start)…\(draft.lines[2].end)")
        draft.undo()

        let atTop = try draft.insert(after: nil)
        check("insert with no anchor goes to the top", draft.lines.first?.id == atTop)
        draft.undo()

        draft.delete([second])
        check("delete removes only that line", draft.lines.map(\.id) == [first, third])
        draft.undo()
        check("undo covers a deletion", draft.lines == original)

        try draft.split(second, at: 3.75)
        check("split makes two lines meeting at the split time",
              draft.lines.count == 4 && draft.lines[1].end == 3.75 && draft.lines[2].start == 3.75
                && draft.lines[2].end == 5)
        check("split divides the words at a word boundary",
              draft.lines[1].text == "general" && draft.lines[2].text == "kenobi",
              "\(draft.lines[1].text) | \(draft.lines[2].text)")
        draft.undo()
        check("undo covers a split", draft.lines == original)

        try draft.split(second, at: 3, textOffset: 3)
        check("split honours a cursor position",
              draft.lines[1].text == "gen" && draft.lines[2].text == "eral kenobi",
              "\(draft.lines[1].text) | \(draft.lines[2].text)")
        draft.undo()

        try draft.split(third, at: 7)
        check("CJK text with a space is cut at the space",
              draft.lines[2].text == "你好" && draft.lines[3].text == "世界",
              "\(draft.lines[2].text) | \(draft.lines[3].text)")
        draft.undo()
        check("text with no spaces is cut by character",
              TranscriptDraft.wordBoundary(in: "你好世界", near: 0.5) == 2)

        try draft.mergeWithNext(first)
        check("merge joins text and spans both",
              draft.lines.count == 2 && draft.lines[0].text == "hello there general kenobi"
                && draft.lines[0].start == 0 && draft.lines[0].end == 5)
        draft.undo()
        check("undo covers a merge", draft.lines == original)

        try draft.shift([second, third], by: 1.5)
        check("shift moves only the chosen lines",
              draft.lines[0].start == 0 && draft.lines[1].start == 4 && draft.lines[2].end == 9.5)
        draft.undo()
        check("undo covers a shift", draft.lines == original)

        try draft.shiftAll(by: 0.5)
        check("shift all moves every line", draft.lines.map(\.start) == [0.5, 3, 6.5],
              "\(draft.lines.map(\.start))")
        draft.undo()

        // --- 3. refusals change nothing -----------------------------------------

        let before = draft
        var refused = 0
        do { try draft.shiftAll(by: -1) } catch { refused += 1 }
        do { try draft.split(first, at: 9) } catch { refused += 1 }
        do { try draft.mergeWithNext(third) } catch { refused += 1 }
        do { try draft.setTimes(first, start: .nan, end: 1) } catch { refused += 1 }
        do { try draft.setTimes(first, start: -1, end: 1) } catch { refused += 1 }
        do { try draft.setText(UUID(), "x") } catch { refused += 1 }
        check("each impossible edit is refused", refused == 6, "\(refused)")
        check("a refused edit changes nothing", draft == before)
        draft.undo()
        check("a refused edit leaves no undo step behind", draft.lines == original)

        var history = TranscriptDraft(machine())
        try history.setText(history.lines[0].id, "x")
        try history.setText(history.lines[0].id, "a")
        history.undo()
        history.delete([history.lines[1].id])
        check("a new edit after undo clears redo", !history.canRedo)

        // --- 4. validation -------------------------------------------------------

        var problems = TranscriptDraft(lines: [
            .init(start: 0, end: 2, text: "one"),
            .init(start: 1.5, end: 3, text: "overlaps"),
            .init(start: 20, end: 19, text: "reversed"),
            .init(start: 30, end: 31, text: "   "),
            .init(start: 25, end: 26, text: "out of order"),
        ])
        let issues = problems.issues
        func kinds(_ i: Int) -> [TranscriptDraft.Issue.Kind] {
            issues.filter { $0.line == problems.lines[i].id }.map(\.kind)
        }
        check("an overlap is flagged against the line above",
              kinds(1) == [.overlap(with: problems.lines[0].id)], "\(kinds(1))")
        check("an end before the start is flagged", kinds(2).contains(.endBeforeStart), "\(kinds(2))")
        check("a long silence is flagged as a gap",
              kinds(2).contains { if case .gap = $0 { return true }; return false }, "\(kinds(2))")
        check("an empty line is flagged", kinds(3).contains(.emptyText), "\(kinds(3))")
        check("a line starting before the one above is flagged", kinds(4) == [.outOfOrder], "\(kinds(4))")
        check("errors stop a save", !problems.canSave)
        check("an overlap alone does not stop a save",
              TranscriptDraft(lines: [.init(start: 0, end: 2, text: "a"),
                                      .init(start: 1, end: 3, text: "b")]).canSave)
        check("validation never rewrites a time",
              problems.lines[1].start == 1.5 && problems.lines[2].end == 19)
        problems.delete(Set(problems.lines.map(\.id)))
        check("an empty transcript has nothing to flag", problems.issues.isEmpty)

        // --- typed times --------------------------------------------------------

        check("a time shows as m:ss.mmm", TranscriptDraft.formatTime(75.5) == "1:15.500")
        check("a time past an hour shows its hours", TranscriptDraft.formatTime(3661.25) == "1:01:01.250")
        check("plain seconds parse", TranscriptDraft.parseTime("75.5") == 75.5)
        check("m:ss parses", TranscriptDraft.parseTime("1:15.5") == 75.5)
        check("h:mm:ss,mmm parses as SRT writes it", TranscriptDraft.parseTime("1:01:01,250") == 3661.25)
        check("a formatted time parses back to itself",
              [0, 0.001, 59.999, 75.5, 3661.25].allSatisfy {
                  TranscriptDraft.parseTime(TranscriptDraft.formatTime($0)) == $0 })
        check("nonsense, negatives and 60+ minutes under an hour are refused",
              ["", "abc", "-1", "1:75", "1::2", "nan", "inf", "1:2:3:4"]
                .allSatisfy { TranscriptDraft.parseTime($0) == nil })
        check("offsets take a sign", TranscriptDraft.parseOffset("-1.5") == -1.5
                && TranscriptDraft.parseOffset("+0:02") == 2 && TranscriptDraft.parseOffset("3") == 3)

        // --- 5 & 6. the store ----------------------------------------------------

        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "fvp-transcript-edit-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let store = try EvidenceStore(root: root, profile: "harness")
        try store.insertTranscript(machine(), path: video, language: "en")
        check("a fresh transcript has no user edits", try !store.hasUserEdits(video))

        var editing = TranscriptDraft(try store.transcript(for: video))
        try editing.setText(editing.lines[1].id, "general kenobi, you are a bold one")
        try editing.shiftAll(by: 0.25)
        try store.saveEditedTranscript(editing.transcriptLines(path: video), path: video, language: "en")
        check("saving an edit marks the transcript edited", try store.hasUserEdits(video))
        check("the edited set lists it", try store.editedTranscriptPaths() == [video])
        let saved = try store.transcript(for: video)
        check("the read returns the corrected revision",
              saved.map(\.text) == ["hello there", "general kenobi, you are a bold one", "你好 世界"]
                && saved.first?.start == 0.25, "\(saved.map(\.text))")
        check("a correction keeps language and source",
              saved.allSatisfy { $0.language == "en" && $0.source == "whisper" })
        check("search finds the corrected words",
              try store.transcriptMatches("bold", limit: 10).count == 1)
        check("search finds corrected CJK text by substring",
              try store.transcriptMatches("世界", limit: 10).count == 1)
        check("the original is kept aside",
              try store.originalTranscript(for: video).map(\.text) == machine().map(\.text))

        var again = TranscriptDraft(saved)
        try again.setText(again.lines[0].id, "HELLO")
        try store.saveEditedTranscript(again.transcriptLines(path: video), path: video, language: "en")
        check("a second edit keeps the machine's lines as the original, not the first edit",
              try store.originalTranscript(for: video).map(\.text) == machine().map(\.text))

        var bad = TranscriptDraft(saved)
        try bad.setText(bad.lines[0].id, "")
        let beforeBad = try store.transcript(for: video)
        do {
            try store.saveEditedTranscript(bad.transcriptLines(path: video), path: video, language: "en")
            check("an unstorable line is refused", false)
        } catch {
            check("an unstorable line is refused", true)
        }
        check("a refused save leaves the stored transcript alone",
              try store.transcript(for: video) == beforeBad)

        check("restore reports that it restored", try store.restoreOriginalTranscript(for: video))
        check("restore puts the machine's lines back",
              try store.transcript(for: video).map(\.text) == machine().map(\.text))
        check("restore clears the edited mark", try !store.hasUserEdits(video))
        check("search no longer finds the correction",
              try store.transcriptMatches("bold", limit: 10).isEmpty)
        check("search finds the restored words",
              try store.transcriptMatches("kenobi", limit: 10).count == 1)
        check("restore with nothing to restore changes nothing",
              try !store.restoreOriginalTranscript(for: video))

        try store.saveEditedTranscript(again.transcriptLines(path: video), path: video, language: "en")
        try store.deleteTranscript(for: video)
        try store.insertTranscript(machine(), path: video, language: "en")
        check("a re-transcription drops the kept original", try !store.hasUserEdits(video))

        // --- 7. moved files -----------------------------------------------------

        let moved = "/library/2026/holiday.mp4"
        try store.saveEditedTranscript(again.transcriptLines(path: video), path: video, language: "en")
        check("a move reports it moved", try store.moveTranscript(from: video, to: moved))
        check("the corrected lines follow the file",
              try store.transcript(for: moved).first?.text == "HELLO"
                && store.transcript(for: video).isEmpty)
        check("the original follows the file too", try store.hasUserEdits(moved) && !store.hasUserEdits(video))
        check("search reports the new path",
              try store.transcriptMatches("HELLO", limit: 10).first?.path == moved)

        let occupied = "/library/other.mp4"
        try store.insertTranscript([TranscriptLine(path: occupied, start: 0, end: 1, text: "its own")],
                                   path: occupied, language: "en")
        check("a destination with its own transcript refuses the move",
              try !store.moveTranscript(from: moved, to: occupied))
        check("...and keeps its own lines", try store.transcript(for: occupied).map(\.text) == ["its own"])
        check("...and the source keeps its lines", try store.transcript(for: moved).count == 3)
        store.close()

        // --- 8. a store from before corrections existed ---------------------------

        let legacyRoot = root + "/legacy"
        do {
            let legacy = try EvidenceStore(root: legacyRoot, profile: "harness")
            try legacy.insertTranscript(machine(), path: video, language: "en")
            legacy.close()
        }
        var handle: OpaquePointer?
        sqlite3_open(Paths.evidenceFile(in: "harness", root: legacyRoot), &handle)
        sqlite3_exec(handle, "DROP TABLE transcript_original", nil, nil, nil)
        sqlite3_close(handle)
        let reopened = try EvidenceStore(root: legacyRoot, profile: "harness")
        check("an older store opens without a schema bump",
              reopened.schemaVersion == EvidenceStore.currentSchema)
        check("...keeps its transcript", try reopened.transcript(for: video).count == 3)
        try reopened.saveEditedTranscript(TranscriptDraft(machine()).transcriptLines(path: video),
                                          path: video, language: "en")
        check("...and can take a correction", try reopened.hasUserEdits(video))
        reopened.close()

        // --- 9. exports ----------------------------------------------------------

        let lines = [
            TranscriptLine(path: video, start: 0, end: 1.5, text: "Hello, \"world\"", language: "en", source: "w"),
            TranscriptLine(path: video, start: 3661.0005, end: 3662.25, text: "a <b> & c --> d\n\nsecond", language: "en", source: "w"),
            TranscriptLine(path: video, start: 4000, end: 4001, text: "日本語 😀", language: "ja", source: "w"),
        ]

        let srt = TranscriptExport.render(lines, as: .srt)
        check("SRT numbers cues and uses a comma before milliseconds",
              srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nHello, \"world\"\n"), srt)
        check("SRT rounds to the millisecond past an hour",
              srt.contains("2\n01:01:01,001 --> 01:01:02,250\n"), srt)
        check("SRT closes up a blank line inside a cue",
              srt.contains("a <b> & c --> d\nsecond\n"), srt)
        check("SRT cues are separated by exactly one blank line",
              srt.components(separatedBy: "\n\n").count == 3, "\(srt.components(separatedBy: "\n\n").count)")
        check("SRT keeps Unicode", srt.contains("日本語 😀"))
        check("SRT passes the cue grammar", validSRT(srt), srt)

        let vtt = TranscriptExport.render(lines, as: .vtt)
        check("VTT starts with its header", vtt.hasPrefix("WEBVTT\n\n"))
        check("VTT uses a full stop before milliseconds", vtt.contains("01:01:01.001 --> 01:01:02.250"))
        check("VTT escapes markup and a literal arrow",
              vtt.contains("a &lt;b&gt; &amp; c --&gt; d\nsecond"), vtt)
        check("VTT keeps Unicode", vtt.contains("日本語 😀"))
        check("VTT passes the cue grammar", validVTT(vtt), vtt)

        let txt = TranscriptExport.render(lines, as: .txt)
        check("TXT is the words alone, one line each",
              txt == "Hello, \"world\"\na <b> & c --> d second\n日本語 😀\n", txt)

        let csv = TranscriptExport.render(lines, as: .csv)
        check("CSV has a header", csv.hasPrefix("start,end,text\r\n"))
        check("CSV quotes and doubles quotes", csv.contains("0.000,1.500,\"Hello, \"\"world\"\"\"\r\n"), csv)
        check("CSV quotes a field with a line break", csv.contains("\"a <b> & c --> d\n\nsecond\""), csv)
        check("CSV keeps Unicode", csv.contains("4000.000,4001.000,日本語 😀\r\n"), csv)

        let json = TranscriptExport.render(lines, as: .json, videoName: "holiday.mp4")
        let back = TranscriptExport.parseJSON(Data(json.utf8), path: video)
        check("JSON reads back losslessly", back == lines, "\(String(describing: back))")
        check("JSON names its format", json.contains("\"format\" : \"FolderVideoPlayer.transcript\""), json)
        check("JSON from something else is refused",
              TranscriptExport.parseJSON(Data("{\"lines\":[]}".utf8), path: video) == nil)

        let exported = TranscriptDraft(saved).transcriptLines(path: video)
        let texts = [TranscriptExport.text(exported)] + [TranscriptExport.Format.srt, .vtt, .csv, .json]
            .map { TranscriptExport.render(exported, as: $0) }
        check("every format carries every line",
              exported.allSatisfy { line in texts.allSatisfy { $0.contains(line.text) } })
        check("the suggested name follows the video",
              TranscriptExport.suggestedName(for: "/x/My Clip.final.mov", format: .srt) == "My Clip.final.srt")
        check("an empty transcript exports an empty but valid SRT",
              TranscriptExport.render([], as: .srt).isEmpty && TranscriptExport.render([], as: .vtt) == "WEBVTT\n")

        print(failures == 0 ? "\nall transcript edit checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// The SubRip grammar the exporter must satisfy: blocks of a counter, a
    /// timing line and at least one non-empty text line.
    static func validSRT(_ text: String) -> Bool {
        let timing = try! NSRegularExpression(
            pattern: #"^\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}$"#)
        let blocks = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n\n")
        for (i, block) in blocks.enumerated() {
            let rows = block.components(separatedBy: "\n")
            guard rows.count >= 3, rows[0] == String(i + 1),
                  timing.firstMatch(in: rows[1], range: NSRange(rows[1].startIndex..., in: rows[1])) != nil,
                  rows.dropFirst(2).allSatisfy({ !$0.isEmpty }) else { return false }
        }
        return true
    }

    /// WebVTT: the header, then cues whose timing line comes first and whose
    /// text never contains a raw `-->` or `<`.
    static func validVTT(_ text: String) -> Bool {
        guard text.hasPrefix("WEBVTT\n") else { return false }
        let timing = try! NSRegularExpression(
            pattern: #"^\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}$"#)
        let cues = text.dropFirst("WEBVTT\n".count).trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n\n")
        for cue in cues where !cue.isEmpty {
            let rows = cue.components(separatedBy: "\n")
            guard rows.count >= 2,
                  timing.firstMatch(in: rows[0], range: NSRange(rows[0].startIndex..., in: rows[0])) != nil,
                  rows.dropFirst().allSatisfy({ !$0.isEmpty && !$0.contains("-->") && !$0.contains("<") })
            else { return false }
        }
        return true
    }
}
