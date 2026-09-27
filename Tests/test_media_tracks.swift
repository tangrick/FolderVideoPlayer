// Audio and subtitle tracks, the parts that are decisions rather than playback:
// SRT and VTT parsing (lenient where readers are, strict about times), finding
// the subtitle files beside a video, and resolving a saved choice against what
// THIS file has — with a fallback that says why.
//
// Run: Tests/run_media_tracks.sh

@testable import FVPModel
import Foundation

@main
struct MediaTracksTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print(cond ? "ok   \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !cond { failures += 1 }
        }

        // --- timestamps -------------------------------------------------------------

        check("an SRT timestamp", SubtitleFile.timestamp("01:02:03,450") == 3723.45)
        check("a VTT timestamp", SubtitleFile.timestamp("01:02:03.450") == 3723.45)
        check("a short VTT timestamp", SubtitleFile.timestamp("02:03.5") == 123.5)
        check("nonsense is not a time",
              ["", "1", "aa:bb", "00:61:00,000", "-1:00", "1:2:3:4"].allSatisfy { SubtitleFile.timestamp($0) == nil })
        check("a timing line with VTT settings",
              SubtitleFile.timingLine("00:01.000 --> 00:02.500 line:90% align:start")! == (1, 2.5))
        check("a reversed timing line is refused", SubtitleFile.timingLine("00:05.000 --> 00:02.000") == nil)

        // --- SRT --------------------------------------------------------------------

        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i> there\r\n\r\n\r\n"
            + "2\r\n00:00:03.000 --> 00:00:04,000\r\nTwo lines\r\nof text &amp; more\r\n\r\n"
            + "00:00:05,000 --> 00:00:06,000\r\n{\\an8}No counter, 日本語\r\n"
        do {
            let cues = try SubtitleFile.parse(srt, extension: "srt")
            check("SRT cues are read, BOM, CRLF and extra blank lines and all", cues.count == 3, "\(cues)")
            check("markup is stripped", cues.first?.text == "Hello there")
            check("a multi-line cue keeps its lines, entities decoded", cues[1].text == "Two lines\nof text & more")
            check("a cue without its counter still reads, Unicode intact",
                  cues[2].text == "No counter, 日本語" && cues[2].start == 5)
            check("times are right", cues[0].start == 1 && cues[0].end == 2.5 && cues[1].start == 3)
        } catch {
            check("SRT parses", false, "\(error)")
        }
        do {
            _ = try SubtitleFile.parse("1\n00:00:01,000 -> 00:00:02,000\nbroken\n", extension: "srt")
            check("a broken timing line is reported", false)
        } catch {
            check("a broken timing line is reported with its line", error as? SubtitleFile.Failure == .malformed(line: 2),
                  "\(error)")
        }
        do {
            _ = try SubtitleFile.parse("\n\n", extension: "srt")
            check("an empty file is reported", false)
        } catch {
            check("an empty file is reported", error as? SubtitleFile.Failure == .empty)
        }
        let cp1252 = Data("1\n00:00:01,000 --> 00:00:02,000\nCaf".utf8) + Data([0xE9]) + Data("\n".utf8)
        check("an old Windows-encoded file is read",
              (try? SubtitleFile.parse(data: cp1252, extension: "srt"))?.first?.text == "Café")

        // --- VTT --------------------------------------------------------------------

        let vtt = """
        WEBVTT - a title

        NOTE this is a comment
        that runs on

        STYLE
        ::cue { color: yellow }

        intro
        00:01.000 --> 00:02.000 align:start
        <v Anna>Hi &lt;there&gt;</v>

        00:00:03.000 --> 00:00:04.000
        Second
        """
        do {
            let cues = try SubtitleFile.parse(vtt, extension: "VTT")
            check("VTT skips NOTE and STYLE blocks and reads cues", cues.count == 2, "\(cues)")
            check("a cue identifier is not text, voice tags are stripped",
                  cues.first?.text == "Hi <there>", cues.first?.text ?? "")
        } catch {
            check("VTT parses", false, "\(error)")
        }
        check("a VTT without its header is refused",
              (try? SubtitleFile.parse("00:01.000 --> 00:02.000\nx\n", extension: "vtt")) == nil)

        // --- the round trip with the exporter ------------------------------------------

        let lines = [TranscriptLine(path: "/v.mp4", start: 1.25, end: 2, text: "a <b> & c"),
                     TranscriptLine(path: "/v.mp4", start: 3661, end: 3662.5, text: "two\nlines")]
        let viaSRT = try? SubtitleFile.parse(TranscriptExport.srt(lines), extension: "srt")
        let viaVTT = try? SubtitleFile.parse(TranscriptExport.vtt(lines), extension: "vtt")
        check("what the exporter writes as SRT reads back",
              viaSRT?.map(\.start) == [1.25, 3661] && viaSRT?[1].text == "two\nlines", "\(String(describing: viaSRT))")
        check("what the exporter writes as VTT reads back, escaped text restored",
              viaVTT?.first?.text == "a <b> & c", "\(String(describing: viaVTT))")

        // --- discovery ----------------------------------------------------------------

        let listing = ["Clip.mp4", "clip.SRT", "clip.en.srt", "clip.pt-BR.vtt", "clip.final.cut.srt",
                       "clip2.srt", "other.srt", "clip.txt", "clip.en.srt.bak"]
        let found = SubtitleFile.sidecars(for: "/m/Clip.mp4", in: listing)
        check("subtitle files beside a video are found, the bare name first",
              found == ["clip.SRT", "clip.en.srt", "clip.pt-BR.vtt"], "\(found)")
        check("a language suffix is labelled", SubtitleFile.label(for: "clip.pt-BR.vtt", video: "/m/Clip.mp4") == "PT-BR (.vtt)")
        check("the bare name is labelled plainly", SubtitleFile.label(for: "clip.SRT", video: "/m/Clip.mp4") == "Subtitle file (.srt)")

        // --- choices --------------------------------------------------------------------

        for choice in [SubtitleChoice.off, .automatic, .transcript, .embedded("2"), .sidecar("a:b.srt")] {
            check("\(choice.stored) round-trips", SubtitleChoice(stored: choice.stored) == choice)
        }
        check("an unknown stored choice is nil", SubtitleChoice(stored: "later") == nil)

        let french = TrackOption(id: "1", title: "Français", language: "fr")
        let resolvedMissing = TrackPlan.resolve(saved: .embedded("1"), embedded: [], sidecars: [], hasTranscript: false)
        check("an embedded choice the file lacks falls back to Automatic, and says so",
              resolvedMissing.choice == .automatic && resolvedMissing.note != nil)
        check("an embedded choice the file has is kept",
              TrackPlan.resolve(saved: .embedded("1"), embedded: [french], sidecars: [], hasTranscript: false).choice == .embedded("1"))
        check("a subtitle file that has gone falls back",
              TrackPlan.resolve(saved: .sidecar("x.srt"), embedded: [], sidecars: ["y.srt"], hasTranscript: true).note != nil)
        check("a file picked from elsewhere is kept as chosen",
              TrackPlan.resolve(saved: .sidecar("/elsewhere/x.srt"), embedded: [], sidecars: [], hasTranscript: false).choice
                == .sidecar("/elsewhere/x.srt"))
        check("the transcript without one falls back",
              TrackPlan.resolve(saved: .transcript, embedded: [], sidecars: [], hasTranscript: false).choice == .automatic)
        check("nothing saved is Automatic", TrackPlan.resolve(saved: nil, embedded: [], sidecars: [], hasTranscript: true).choice == .automatic)

        check("Automatic prefers the file's own tracks",
              TrackPlan.source(for: .automatic, embedded: [french], sidecars: ["a.srt"], hasTranscript: true) == .embedded(nil))
        check("...then a subtitle file",
              TrackPlan.source(for: .automatic, embedded: [], sidecars: ["a.srt"], hasTranscript: true) == .sidecar("a.srt"))
        check("...then the transcript",
              TrackPlan.source(for: .automatic, embedded: [], sidecars: [], hasTranscript: true) == .transcript)
        check("...then nothing", TrackPlan.source(for: .automatic, embedded: [], sidecars: [], hasTranscript: false) == .none)
        check("Off is off even with everything available",
              TrackPlan.source(for: .off, embedded: [french], sidecars: ["a.srt"], hasTranscript: true) == .none)

        let cues = [SubtitleCue(start: 1, end: 3, text: "a"), SubtitleCue(start: 2, end: 4, text: "b")]
        check("the cue on screen is the latest started", TrackPlan.cue(at: 2.5, in: cues)?.text == "b")
        check("between cues nothing shows", TrackPlan.cue(at: 4.5, in: cues) == nil)

        print(failures == 0 ? "\nall media track checks passed" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
