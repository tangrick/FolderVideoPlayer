import Foundation

/// What a finished pass did.
struct SpeechOutcome: Equatable {
    var lines: Int
    var language: String
    var seconds: Double
}

/// Why a pass refused, in words the panel can show.
enum SpeechPassRefusal: Error, Equatable {
    /// No audio track: nothing to transcribe and nothing to retry.
    case noAudioTrack
    case modelsMissing(String)
    /// The file changed while the pass read it. The lines describe bytes that
    /// no longer exist, so they are NOT written.
    case changedWhileRunning
    case cancelled
    case failed(String)

    var sentence: String {
        switch self {
        case .noAudioTrack:
            return "This video has no sound."
        case .modelsMissing:
            return "The speech model is not downloaded. Install it in Settings \u{25B8} AI."
        case .changedWhileRunning:
            return "This video changed while it was being transcribed, so nothing was saved. Try again."
        case .cancelled:
            return "Transcribing was cancelled."
        case .failed(let why):
            return "Transcribing stopped: \(why)"
        }
    }
}


/// Transcribe one video into the evidence store.
///
/// Three rules this type exists to keep:
///  * nothing is written until the whole pass has succeeded, so a cancelled or
///    failed pass cannot leave half a transcript behind that reads like a whole
///    one;
///  * the write is guarded by the source revision taken BEFORE the audio was
///    read — a transcript of bytes that have since changed is a claim about a
///    video that no longer exists;
///  * cancellation is acknowledged at once and its result is discarded.
final class SpeechPass {
    private let transcriber: SpeechTranscribing
    private let store: EvidenceStore
    private let language: String?

    /// The model's own window length. Used only to turn a window index into a
    /// position — nothing here decides how the model chunks anything.
    static let windowSeconds: Double = 30

    init(transcriber: SpeechTranscribing, store: EvidenceStore, language: String? = nil) {
        self.transcriber = transcriber
        self.store = store
        self.language = language
    }

    func run(path: String,
             onProgress: @escaping (SpeechProgress) -> Void) async throws -> SpeechOutcome {
        // The identity of the bytes, taken before anything reads them: without
        // it there is nothing to check the file against afterwards.
        guard let before = SourceRevision.of(path) else {
            throw SpeechPassRefusal.failed("the file could not be read")
        }
        let started = TimedEvidence.SourceRevision(bytes: before.size,
                                                   modifiedAt: before.mtime)

        let probe: AudioProbe
        do {
            probe = try await AudioExtraction.probe(path: path)
        } catch {
            throw SpeechPassRefusal.failed("its audio could not be read")
        }
        // No audio track is an answer, not a failure: there is nothing to
        // retry and nothing to apologise for.
        guard probe.hasAudio else { throw SpeechPassRefusal.noAudioTrack }

        let total = max(probe.seconds, 0)
        onProgress(SpeechProgress(stage: "Reading the audio", done: 0, total: total, lines: 0))

        let samples: [Float]
        do {
            samples = try await AudioExtraction.samples(path: path)
        } catch {
            throw SpeechPassRefusal.failed("its audio could not be decoded")
        }

        // The point of no return: everything below happens in full or not at all.
        try Task.checkCancellation()

        let result = try await transcriber.transcribe(samples: samples,
                                                     language: language) { window in
            // A measured position: the window index times the model's own
            // window, clamped so it can never claim to be past the end.
            let done = min(total, Double(window + 1) * Self.windowSeconds)
            onProgress(SpeechProgress(stage: "Transcribing", done: done, total: total, lines: 0))
        }

        // The file must still be the file that was read. Checked BEFORE the
        // write, so a changed video never gets a transcript for old bytes.
        guard let after = SourceRevision.of(path),
              started.matches(TimedEvidence.SourceRevision(bytes: after.size,
                                                           modifiedAt: after.mtime)) else {
            throw SpeechPassRefusal.changedWhileRunning
        }

        // A cancel that arrived while the model worked must not write anything.
        try Task.checkCancellation()

        let lines = result.segments.map {
            TranscriptLine(path: path,
                           start: $0.start,
                           end: $0.end,
                           text: $0.text,
                           language: result.language,
                           source: transcriber.source)
        }

        let written: Int
        do {
            // Replace, never append: a second pass over one video is a new
            // answer, not more lines.
            _ = try store.deleteTranscript(for: path)
            written = try store.insertTranscript(lines, path: path, language: result.language)
        } catch {
            throw SpeechPassRefusal.failed("the transcript could not be saved")
        }

        onProgress(SpeechProgress(stage: "Done", done: total, total: total, lines: written))
        return SpeechOutcome(lines: written, language: result.language, seconds: total)
    }
}
