import Foundation
import WhisperKit

/// WhisperKit, loading ONLY from the installed pack.
///
/// `download: false` plus a model folder is the whole safety story: nothing can
/// quietly fetch a model the catalogue never named, and no user is asked for a
/// token to read a file on their own disk.
final class WhisperKitTranscriber: SpeechTranscribing {
    /// Raised by `cancel()`, read by the model's own callback thread.
    private var cancelFlag = CancelFlag()
    let source: String
    private let modelsRoot: URL
    private var kit: WhisperKit?

    init(modelsRoot: URL, source: String = WhisperKitTranscriber.defaultSource) {
        self.modelsRoot = modelsRoot
        self.source = source
    }

    /// Matches the adapter the catalogue's pack descriptor names.
    static let defaultSource = "whisperkit-large-v3-turbo-v1"

    private func loaded() async throws -> WhisperKit {
        if let kit { return kit }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelsRoot.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw SpeechError.modelsMissing(modelsRoot.path)
        }

        // Argument order matters in Swift and every parameter here has a
        // default, so this stays in the declared order of WhisperKitConfig.
        let config = WhisperKitConfig(model: nil,
                                      modelFolder: modelsRoot.path,
                                      verbose: false,
                                      prewarm: true,
                                      load: true,
                                      download: false)
        do {
            let made = try await WhisperKit(config)
            kit = made
            return made
        } catch {
            throw SpeechError.failed("the speech model could not be loaded")
        }
    }

    func transcribe(samples: [Float],
                    language: String?,
                    onWindow: ((Int) -> Void)?)
        async throws -> (segments: [SpeechSegment], language: String) {
        guard !samples.isEmpty else { throw SpeechError.emptyAudio }
        try Task.checkCancellation()

        // Fresh per run: a cancel from the last run must not abort this one.
        cancelFlag = CancelFlag()
        let kit = try await loaded()

        // Set the knobs after construction rather than in the initialiser:
        // DecodingOptions' parameters all have defaults and its argument order
        // is not this file's to depend on.
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = (language == nil)
        options.skipSpecialTokens = true

        // WhisperKit reports each 30-second window as it is decoded, which is
        // the only honest source of a position for the panel: windowId x 30 is
        // where the pass has actually reached.
        //
        // `flag` is taken as a local on purpose: the callback runs on the
        // model's own thread, so it must not reach back into `self`.
        let flag = cancelFlag
        let callback: TranscriptionCallback = { progress in
            // Returning false IS the stop: WhisperKit raises its early-stop
            // flag and abandons the window it is in, which is what buys the
            // one-second acknowledgement the design asks for.
            if flag.isRaised { return false }
            onWindow?(progress.windowId)
            return true
        }

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: samples,
                                              decodeOptions: options,
                                              callback: callback)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechError.failed("transcription failed")
        }

        // An aborted run returns what it heard so far, which is NOT a
        // transcript. Say so here, before the empty check can call it silence.
        if cancelFlag.isRaised { throw CancellationError() }

        let segments = results
            .flatMap { $0.segments }
            .map { SpeechSegment(start: Double($0.start), end: Double($0.end), text: $0.text) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Silence is not a failure of the model: it is an answer. But an empty
        // transcript must never be written as if speech had been found.
        guard !segments.isEmpty else { throw SpeechError.emptyAudio }

        return (segments, results.first?.language ?? language ?? "")
    }

    /// Stop at the model's next step. Not `Task.cancel()`: the model is inside
    /// a call that does not look at the task, so the flag is what it reads.
    func cancel() {
        cancelFlag.raise()
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}
