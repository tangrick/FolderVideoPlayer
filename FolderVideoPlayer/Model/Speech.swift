import Foundation


/// One timed line of speech, in the app's own terms.
struct SpeechSegment: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum SpeechError: Error, Equatable {
    /// The pack is not installed, or half-installed.
    case modelsMissing(String)
    /// Nothing came out: silence, or a file with no speech in it at all.
    case emptyAudio
    case failed(String)

    var sentence: String {
        switch self {
        case .modelsMissing:
            return "The speech model is not downloaded. Install it in Settings \u{25B8} AI."
        case .emptyAudio:
            return "No speech was found in this file."
        case .failed(let why):
            return "Transcribing stopped: \(why)"
        }
    }
}

/// The seam the job talks to. tests inject a fake: the real one needs a 646 MB
/// pack and minutes of compute, so the job's behaviour (progress, cancel,
/// writes) is exercised without a model, and the real transcriber is run
/// opt-in against the installed pack.
protocol SpeechTranscribing: AnyObject {
    /// Which model produced this, stored with every line: a transcript from
    /// another runtime is a different claim.
    var source: String { get }
    /// `onWindow` fires as each 30-second window is decoded, with that window's
    /// index — so the progress the panel shows is measured, not animated.
    func transcribe(samples: [Float],
                    language: String?,
                    onWindow: ((Int) -> Void)?) async throws -> (segments: [SpeechSegment], language: String)

    /// Stop as soon as the model finishes the window it is on, and report the
    /// pass as cancelled rather than returning what it heard so far. Half a
    /// transcript is not a transcript.
    ///
    /// The design asks for cancellation to be acknowledged within a second.
    /// Task cancellation alone cannot promise that: the model is inside a call
    /// that does not look at it. This flag is what the model's window callback
    /// reads, so the stop happens at the next window — seconds, not minutes.
    func cancel()

    func unload() async
}

/// A flag the model's callback can read from its own thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock(); raised = true; lock.unlock()
    }

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }
        return raised
    }
}

/// What the panel shows while a transcription runs.
struct SpeechProgress: Equatable {
    /// "Reading the audio" or "Transcribing" — said plainly, because a bar with
    /// no words leaves the user guessing whether it is stuck.
    var stage: String
    /// Seconds of audio reached, and the file's length, so the panel can show
    /// a real position rather than a spinner.
    var done: Double
    var total: Double
    var lines: Int
}

extension SpeechProgress {
    /// What the panel says while this is what it knows. The position is where
    /// the model has actually got to, so it only moves once per window — a
    /// smoother number would be invented, and this app does not invent numbers.
    var label: String {
        guard total > 0 else { return stage + "…" }
        return stage + "… " + Self.clock(done) + " / " + Self.clock(total)
    }

    /// A length of audio as a person reads it: mm:ss, or h:mm:ss for a film.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        guard whole >= 3600 else {
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
    }
}
