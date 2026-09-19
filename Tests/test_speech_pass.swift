// S4's gate: the speech pass — what it writes, what it refuses, and what it must
// never write.
//
// The real transcriber needs a 646 MB pack and minutes of compute, so this
// exercises the pass against a FAKE. What is under test is the pass's own
// behaviour — progress, the revision guard, replacement, and cancellation —
// none of which depends on which model produced the segments. The WhisperKit
// glue is verified by the app build and by Tests/check_speech_runtime.sh.
//
//     sh Tests/run_speech_pass.sh
//
// FVP_AUDIO_FIXTURES points at the committed audio fixtures (default
// Tests/fixtures/audio). Nothing here touches the network and nothing here
// loads a model.

import Foundation

/// A transcriber that answers instantly, so the pass can be measured without a
/// model. Every hook exists because a test needs to make something happen at a
/// definite moment inside the pass.
final class FakeTranscriber: SpeechTranscribing {
    let source = "fake-model-v1"
    var segments: [SpeechSegment] = [
        SpeechSegment(start: 0.5, end: 1.5, text: "the quick brown fox"),
        SpeechSegment(start: 2.0, end: 3.0, text: "jumped over the lazy dog"),
    ]
    var language = "en"
    /// Window indices to report. Deliberately more than the file's length is
    /// worth, to prove the pass clamps a position instead of trusting it.
    var windows = [0, 1, 2]
    /// Runs at the moment transcription starts — how a test makes the file
    /// change mid-pass.
    var duringTranscribe: (() -> Void)?
    var failure: Error?
    private(set) var calls = 0

    func transcribe(samples: [Float],
                    language: String?,
                    onWindow: ((Int) -> Void)?) async throws
        -> (segments: [SpeechSegment], language: String) {
        calls += 1
        duringTranscribe?()
        if let failure { throw failure }
        for (i, window) in windows.enumerated() {
            if cancelled { throw CancellationError() }
            onWindow?(window)
            if cancelOnFirstWindow, i == 0 { cancel() }
        }
        if cancelled { throw CancellationError() }
        return (segments, self.language)
    }

    /// The real model's contract: a cancel stops it at its next step.
    var cancelled = false
    var cancelOnFirstWindow = false

    func cancel() { cancelled = true }

    func unload() async {}
}

@main
struct SpeechPassHarness {
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

    static let work = NSTemporaryDirectory() + "fvp-speech-pass-" + UUID().uuidString

    static func copy(_ source: String, to name: String) -> String {
        let destination = work + "/" + name
        try? FileManager.default.removeItem(atPath: destination)
        try? FileManager.default.copyItem(atPath: source, toPath: destination)
        return destination
    }

    /// Make a file's identity different from what it was, the way a real edit
    /// would: more bytes on the end.
    static func grow(_ path: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(repeating: 0, count: 4096))
        handle.closeFile()
    }

    static func main() async {
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let root = work + "/store"
        let tone = fixture("tone-3s.mp4")
        let noAudio = fixture("no-audio-2s.mp4")

        guard let store = try? EvidenceStore(root: root, profile: "speech") else {
            check("the evidence store opens", false, root)
            print("\n1 FAILURES speech pass")
            exit(1)
        }
        check("the evidence store opens", true)

        // 1. a pass writes the lines, keeping the model's name and the language
        //    with them — a transcript from another runtime is a different claim.
        let fake = FakeTranscriber()
        var progress: [SpeechProgress] = []
        let pass = SpeechPass(transcriber: fake, store: store)
        do {
            let outcome = try await pass.run(path: tone) { progress.append($0) }
            check("a video with speech transcribes", outcome.lines == 2, "\(outcome.lines) lines")
            check("the language is kept", outcome.language == "en", outcome.language)
        } catch {
            check("a video with speech transcribes", false, "\(error)")
        }

        // 2. what it wrote is SEARCHABLE — the store's transcript index exists
        //    for exactly this, and this is the first thing to exercise it.
        do {
            let hits = try store.transcriptMatches("brown")
            check("the written lines are searchable", hits.count == 1, "\(hits.count) hits")
            check("each line names the model that produced it",
                  hits.first?.source == "fake-model-v1", hits.first?.source ?? "nil")
            check("each line carries the video it is about", hits.first?.path == tone,
                  hits.first?.path ?? "nil")
        } catch {
            check("the written lines are searchable", false, "\(error)")
        }

        // 3. progress is MEASURED and clamped. The fake reports three windows on
        //    a three-second file, so a position that trusted the model would
        //    claim to have read ninety seconds of a three-second video.
        let stages = progress.map(\.stage)
        check("progress starts by reading the audio", stages.first == "Reading the audio",
              stages.first ?? "nil")
        check("progress reports transcribing", stages.contains("Transcribing"))
        check("progress never claims to be past the end of the file",
              progress.allSatisfy { $0.done <= $0.total + 0.001 },
              progress.map { "\($0.done)/\($0.total)" }.joined(separator: " "))
        check("the last word on progress is what was written",
              progress.last?.lines == 2, "\(progress.last?.lines ?? -1)")

        // 4. a second pass REPLACES. Both the old lines and their index entries
        //    must go, or a search would return a line that no longer exists.
        fake.segments = [SpeechSegment(start: 1.0, end: 2.0, text: "a brand new sentence")]
        do {
            let outcome = try await pass.run(path: tone) { _ in }
            check("a second pass replaces rather than appends", outcome.lines == 1,
                  "\(outcome.lines) lines")
            let stale = try store.transcriptMatches("brown")
            let fresh = try store.transcriptMatches("brand")
            check("the replaced lines are gone from a search", stale.isEmpty,
                  "\(stale.count) stale hits")
            check("the new lines are searchable", fresh.count == 1, "\(fresh.count) hits")
        } catch {
            check("a second pass replaces rather than appends", false, "\(error)")
        }

        // 5. a cancelled pass writes NOTHING. This is the design's own wording:
        //    no post-cancel result writes.
        fake.failure = CancellationError()
        do {
            _ = try await pass.run(path: tone) { _ in }
            check("a cancelled pass stops", false, "it returned anyway")
        } catch {
            let survived = (try? store.transcriptMatches("brand"))?.count ?? -1
            check("a cancelled pass stops", error is CancellationError, "\(error)")
            check("a cancelled pass writes nothing", survived == 1, "\(survived) hits")
        }
        fake.failure = nil

        // 6. a file that changes while it is being read does NOT get a transcript
        //    describing bytes that no longer exist.
        let changed = copy(tone, to: "changed.mp4")
        fake.duringTranscribe = { grow(changed) }
        do {
            _ = try await pass.run(path: changed) { _ in }
            check("a file that changed mid-pass is refused", false, "it wrote anyway")
        } catch let refusal as SpeechPassRefusal {
            check("a file that changed mid-pass is refused", refusal == .changedWhileRunning,
                  "\(refusal)")
            let hits = (try? store.transcriptMatches("quick"))?.count ?? -1
            check("nothing is written for a changed file", hits == 0, "\(hits) hits")
        } catch {
            check("a file that changed mid-pass is refused", false, "\(error)")
        }
        fake.duringTranscribe = nil

        // 7. no audio track is an ANSWER: nothing to transcribe, nothing to retry.
        do {
            _ = try await pass.run(path: noAudio) { _ in }
            check("a video with no sound is refused as one", false, "it transcribed anyway")
        } catch let refusal as SpeechPassRefusal {
            check("a video with no sound is refused as one", refusal == .noAudioTrack, "\(refusal)")
        } catch {
            check("a video with no sound is refused as one", false, "\(error)")
        }

        // 8. a file that is not there is refused, not crashed on.
        do {
            _ = try await pass.run(path: work + "/nothing-here.mp4") { _ in }
            check("a missing file is refused", false, "it returned anyway")
        } catch {
            check("a missing file is refused", error is SpeechPassRefusal, "\(error)")
        }

        // 9. the cancel the UI actually sends: cancel() mid-transcription stops
        //    the model, and the store is not touched.
        let stopper = FakeTranscriber()
        stopper.cancelOnFirstWindow = true
        do {
            _ = try await SpeechPass(transcriber: stopper, store: store).run(path: tone) { _ in }
            check("a pass stopped by cancel() writes nothing", false, "it wrote anyway")
        } catch {
            let survived = (try? store.transcriptMatches("brand"))?.count ?? -1
            check("a pass stopped by cancel() writes nothing", error is CancellationError, "\(error)")
            check("the store is untouched by a cancelled run", survived == 1, "\(survived) hits")
        }

        // 10. the label the panel shows is that same measured number, formatted
        //     for a person — and an hour-long film must not print as 75:04.
        let running = SpeechProgress(stage: "Transcribing", done: 200, total: 725, lines: 0)
        check("a position reads as minutes and seconds",
              running.label == "Transcribing… 3:20 / 12:05", running.label)
        check("an hour-long film reads as hours",
              SpeechProgress.clock(4525) == "1:15:25", SpeechProgress.clock(4525))
        check("an unknown length is not printed as zero",
              SpeechProgress(stage: "Reading the audio", done: 0, total: 0, lines: 0).label
                == "Reading the audio…", "it guessed a length")
        check("a stage with a length still says what it is doing",
              running.label.hasPrefix("Transcribing…"), running.label)

        print(failures == 0 ? "\nALL PASS speech pass" : "\n\(failures) FAILURES speech pass")
        exit(failures == 0 ? 0 : 1)
    }
}
