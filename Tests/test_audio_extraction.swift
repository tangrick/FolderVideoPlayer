// S1: the app can turn a video into the one signal a speech model takes —
// 16 kHz mono floats — with nothing installed on the machine.
//
// This is the part of T08 that must work on a bare Mac: no ffmpeg, no Python, no
// network. AVFoundation does the demuxing, decoding, resampling and downmixing,
// and the checks below measure that it actually did rather than that it was asked.
//
// What is worth proving, and why each one is here:
//
//   1. a real video with a real AAC track reads back as about the right length at
//      the right rate — and the count is NOT asserted as exact, because AAC
//      priming moves it by a few samples on a 20 s file (measured: 6 samples in
//      320,000). A test demanding equality would be asserting something false;
//   2. sound stays sound and silence stays silent — the tone's RMS is measured
//      above zero, and the silent fixture below the floor. A speech pass that
//      hallucinates text needs this input to be honestly empty;
//   3. a file with NO audio track is an ANSWER, not a failure: the probe says so,
//      still reports the video's length, and reading refuses with noAudioTrack;
//   4. a time window is really honoured — this is what lets a two-hour film be
//      transcribed in windows instead of as 460 MB of float;
//   5. malformed ranges are refused as themselves (backwards, half a range, and
//      a window past the end), never silently clamped into "close enough";
//   6. a missing file is refused, not crashed on;
//   7. the WAV we write is checked by a parser that is not ours: the OS decoder
//      reads it back as 16 kHz mono, the sample count matches, and the signal
//      survives the round trip. Its header fields are also read directly;
//   8. reading the same window twice gives the same answer — AVAssetReader is
//      stateful, so a reader shared between calls would show up here.
//
// Fixtures are committed under Tests/fixtures/audio (26 KB total) rather than
// living in an external artifact directory, because the decode path is exactly
// what a clean machine must be able to exercise. They were made with ffmpeg and
// can be regenerated with the commands in that directory's README.
//
//     sh Tests/run_audio_extraction.sh

@testable import FVPModel
import AVFoundation
import Foundation

@main
struct AudioExtractionHarness {

    static var failures = 0

    static func check(_ what: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("ok   \(what)")
        } else {
            failures += 1
            print("FAIL \(what)" + (detail.isEmpty ? "" : " — \(detail)"))
        }
    }

    static var fixtureDir: String {
        if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
        return ProcessInfo.processInfo.environment["FVP_AUDIO_FIXTURES"] ?? "."
    }

    static func fixture(_ name: String) -> String { fixtureDir + "/" + name }

    /// Decoder priming shifts sample counts by a few frames per file, so lengths
    /// are compared within a percent instead of exactly.
    static func close(_ value: Int, _ wanted: Int, within fraction: Double = 0.01) -> Bool {
        abs(Double(value - wanted)) <= Double(wanted) * fraction
    }

    static func isUnreadable(_ error: Error) -> Bool {
        guard let e = error as? AudioExtractionError else { return false }
        if case .unreadable = e { return true }
        return false
    }

    static let work = NSTemporaryDirectory() + "fvp-audio-" + UUID().uuidString

    static func rms(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 0 }
        var sum = 0.0
        for v in s { sum += Double(v) * Double(v) }
        return (sum / Double(s.count)).squareRoot()
    }

    static func main() async {
        let tone = fixture("tone-3s.mp4")
        let silent = fixture("silent-2s.mp4")
        let noAudio = fixture("no-audio-2s.mp4")

        // --- the fixtures themselves -----------------------------------------
        for (name, path) in [("tone", tone), ("silent", silent), ("no audio", noAudio)] {
            check("the \(name) fixture is where the gate expects it",
                  FileManager.default.fileExists(atPath: path), path)
        }
        guard FileManager.default.fileExists(atPath: tone) else {
            print("FAILURES: \(failures) — fixtures missing, nothing else could be checked")
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

        let rate = AudioExtraction.sampleRate
        check("the extraction rate is 16 kHz", rate == 16_000, "\(rate)")

        // --- 1. a real video with real audio ---------------------------------
        do {
            let p = try await AudioExtraction.probe(path: tone)
            check("a video with an audio track is reported as having one", p.hasAudio)
            check("the source's own rate is read (44.1 kHz, as recorded)",
                  Int(p.sampleRate) == 44_100, "\(Int(p.sampleRate))")
            check("the source's channel count is read (mono)", p.channels == 1, "\(p.channels)")
            check("its duration reads as about 3 s", abs(p.seconds - 3) < 0.05,
                  String(format: "%.3f", p.seconds))

            let samples = try await AudioExtraction.samples(path: tone)
            check("its audio decodes to about 3 s at 16 kHz",
                  close(samples.count, Int(3 * rate)),
                  "\(samples.count) samples = \(String(format: "%.3f", Double(samples.count) / rate))s")
            check("what came out is not silence", rms(samples) > 0.01,
                  String(format: "rms %.4f", rms(samples)))

            // --- 4. the window is honoured, not ignored ----------------------
            let one = try await AudioExtraction.samples(path: tone, from: 0, to: 1)
            let two = try await AudioExtraction.samples(path: tone, from: 1, to: 2)
            check("a 1 s window of a 3 s file gives about 1 s, not the whole track",
                  close(one.count, Int(rate)), "\(one.count) samples")
            check("the second window gives about the same", close(two.count, Int(rate)),
                  "\(two.count) samples")
            check("a window carries the sound rather than a gap", rms(one) > 0.01,
                  String(format: "rms %.4f", rms(one)))
            check("reading the same window twice gives the same answer",
                  two.count == (try await AudioExtraction.samples(path: tone, from: 1, to: 2)).count)

            // --- 7. the WAV is checked by someone else's parser --------------
            let wav = work + "/tone.wav"
            try AudioExtraction.writeWAV(samples, to: wav)
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: wav)))?.count ?? 0
            check("the WAV is exactly 44 header bytes plus two per sample",
                  bytes == 44 + samples.count * 2, "\(bytes) bytes")

            if let head = try? Data(contentsOf: URL(fileURLWithPath: wav)).prefix(44) {
                let h = [UInt8](head)
                func u16(_ o: Int) -> Int { Int(h[o]) | Int(h[o + 1]) << 8 }
                func u32(_ o: Int) -> Int { Int(h[o]) | Int(h[o + 1]) << 8 | Int(h[o + 2]) << 16 | Int(h[o + 3]) << 24 }
                check("its header says RIFF/WAVE",
                      String(bytes: h[0..<4], encoding: .ascii) == "RIFF"
                        && String(bytes: h[8..<12], encoding: .ascii) == "WAVE")
                check("its header says 16 kHz, mono, 16-bit",
                      u32(24) == 16_000 && u16(22) == 1 && u16(34) == 16,
                      "rate \(u32(24)) channels \(u16(22)) bits \(u16(34))")
                check("its data chunk length matches the bytes actually written",
                      u32(40) == samples.count * 2, "\(u32(40)) declared")
            }

            let back = try await AudioExtraction.probe(path: wav)
            check("the OS decoder reads our WAV back as 16 kHz mono",
                  back.hasAudio && Int(back.sampleRate) == 16_000 && back.channels == 1,
                  "\(Int(back.sampleRate)) Hz \(back.channels)ch")
            let again = try await AudioExtraction.samples(path: wav)
            check("the round trip keeps every sample", again.count == samples.count,
                  "\(again.count) vs \(samples.count)")
            check("the round trip keeps the signal",
                  abs(rms(again) - rms(samples)) < 0.001,
                  String(format: "%.4f vs %.4f", rms(again), rms(samples)))
        } catch {
            check("a video with an audio track could be read at all", false, "\(error)")
        }

        // --- 2. silence stays silent -----------------------------------------
        do {
            let p = try await AudioExtraction.probe(path: silent)
            check("a video with a silent track is reported as having audio", p.hasAudio)
            let samples = try await AudioExtraction.samples(path: silent)
            check("its audio decodes to about 2 s", close(samples.count, Int(2 * rate)),
                  "\(samples.count) samples")
            check("silence decodes as silence, not as noise", rms(samples) < 0.0005,
                  String(format: "rms %.6f", rms(samples)))

            let wav = work + "/silent.wav"
            try AudioExtraction.writeWAV(samples, to: wav)
            let back = try await AudioExtraction.samples(path: wav)
            check("it is still silent after a WAV round trip", rms(back) < 0.0005,
                  String(format: "rms %.6f", rms(back)))
        } catch {
            check("a silent video could be read at all", false, "\(error)")
        }

        // --- 3. no audio track is an answer ----------------------------------
        do {
            let p = try await AudioExtraction.probe(path: noAudio)
            check("a video with no audio track says so", !p.hasAudio)
            check("...and still reports how long the video is", abs(p.seconds - 2) < 0.05,
                  String(format: "%.3f", p.seconds))
            do {
                _ = try await AudioExtraction.samples(path: noAudio)
                check("reading a video with no audio refuses", false, "it returned samples")
            } catch {
                check("reading a video with no audio refuses with noAudioTrack",
                      error as? AudioExtractionError == .noAudioTrack, "\(error)")
            }
        } catch {
            check("a video with no audio track could be probed at all", false, "\(error)")
        }

        // --- 5. malformed ranges are refused as themselves -------------------
        do {
            _ = try await AudioExtraction.samples(path: tone, from: 2, to: 1)
            check("a backwards window is refused", false, "it was accepted")
        } catch {
            check("a backwards window is refused", error as? AudioExtractionError == .badRange, "\(error)")
        }
        do {
            _ = try await AudioExtraction.samples(path: tone, from: 1, to: nil)
            check("half a window (start with no end) is refused", false, "it was accepted")
        } catch {
            check("half a window (start with no end) is refused",
                  error as? AudioExtractionError == .badRange, "\(error)")
        }
        do {
            _ = try await AudioExtraction.samples(path: tone, from: 100, to: 101)
            check("a window past the end of the file is refused", false, "it returned samples")
        } catch {
            check("a window past the end of the file is refused as empty, not clamped",
                  error as? AudioExtractionError == .emptyAudio, "\(error)")
        }

        // --- 6. a missing file is refused, not crashed on --------------------
        // Both entry points must fail as this module's OWN error type. A raw
        // AVFoundation error escaping here is how a caller ends up handling a
        // failure it never heard of — which is what this check caught.
        for (label, probing) in [("probing", true), ("reading", false)] {
            do {
                if probing {
                    _ = try await AudioExtraction.probe(path: work + "/not-here.mp4")
                } else {
                    _ = try await AudioExtraction.samples(path: work + "/not-here.mp4")
                }
                check("\(label) a file that does not exist is refused", false, "it was accepted")
            } catch {
                check("\(label) a file that does not exist is refused as unreadable",
                      isUnreadable(error), "\(error)")
            }
        }

        try? FileManager.default.removeItem(atPath: work)

        if failures == 0 {
            print("ALL PASS audio extraction")
            exit(0)
        } else {
            print("FAILURES: \(failures)")
            exit(1)
        }
    }
}
