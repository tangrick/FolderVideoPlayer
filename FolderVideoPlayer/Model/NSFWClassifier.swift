import Foundation
import CoreML
import CoreGraphics

/// The shipped Safe/NSFW verdict: Falconsai's ViT-base, in Core ML.
///
/// 164 MB, Apache-2.0, float16. Phase 0 chose it on the evidence that matters —
/// on the 135 videos the user marked Safe by hand, the old Python engine wrongly
/// flagged 28 and Falconsai wrongly flagged 3. (The 0.888 "imitation" score it
/// also got is not a failure percentage: that test scores how well a model
/// copies the engine it is replacing.) Nothing here is fitted on anybody's
/// library: it is one downloaded model, and every user's own marks grow their
/// own correction head on top of it (`TrainedHeads.nsfw`, weight 0.25).
///
/// Three properties of the converted model are load-bearing, and all three are
/// checked here rather than assumed:
///
///   - **Softmax is folded in at conversion.** The output is a probability, not
///     a logit, so nothing in this file is tempted to re-apply one.
///   - **Column 1 is NSFW** (`id2label` is `{0: normal, 1: nsfw}`). The index is
///     named once, here, and validated at load: a model with fewer than two
///     columns refuses to load rather than scoring column 0 as "NSFW".
///   - **The input is fixed at 224×224**, which happens to match the vision
///     tower's geometry today (SigLIP 2 B/16 @224) after MobileCLIP's 256×256
///     — but nothing here may rely on that: each model declares its own input
///     constraint and each pass resizes the same `CGImage` to it, so the two
///     are independent by construction and a future tower of another size needs
///     no change in this file.
///
/// Aggregation stays **max across frames**, as it always has: one loud frame is
/// a verdict, and averaging would hide it.
///
/// The conversion that produced this file is
/// `docs/coreml-spike/convert_falconsai_ship.py` — re-run from a wrapper in
/// `.eval()` mode, which the Phase 0 conversion was not. It proves the two
/// packages agree with PyTorch before installing itself.
actor NSFWClassifier {

    /// What the app looks for at runtime, and where `ModelDownloader` will put
    /// it in Phase 5.
    static let slug = "falconsai"
    static let classifierID = "falconsai-nsfw-v1"
    /// This model's own name. Note the record does NOT store it as `modelID`:
    /// that field is the embedding space, because a frame's hash points into
    /// that namespace. This value is what the record carries as the classifier.
    static let modelID = "falconsai-vit-base"
    /// `probs[1]` — see the note above; validated at load.
    static let nsfwIndex = 1
    static let minimumColumns = 2
    static let inputSide = 224
    /// The per-frame bar a stored verdict counts `framesAbove` against, and the
    /// line the review window files Safe against NSFW (`AnalysisStore.bucket`).
    /// 0.5 is the cut every Phase 0 measurement used, so a probability from this
    /// model means at the review window exactly what it meant in the spike.
    static let threshold = 0.5
    /// The aggregation id stored beside the score: max across frames.
    static let aggregationID = "max-prob-v1"

    private let model: MLModel
    private let inputName: String

    static func modelURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/falconsai.mlmodelc"))
    }

    /// A compiled model is present and loadable? Cheap: one directory check, no
    /// model load, so the capability layer and the classifier can both ask.
    nonisolated static func isInstalled(root: String) -> Bool {
        let p = modelURL(root: root).path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    init(root: String) throws {
        let url = Self.modelURL(root: root)
        guard Self.isInstalled(root: root) else { throw ClassifierError.notInstalled(url.path) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: config)
        guard let input = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw ClassifierError.noInput(url.path)
        }
        self.inputName = input
        guard let outputs = model.modelDescription.outputDescriptionsByName.first,
              let constraint = outputs.value.multiArrayConstraint else {
            throw ClassifierError.noOutput(url.path)
        }
        guard Self.nsfwIndex < constraint.shape.last?.intValue ?? 0 else {
            throw ClassifierError.wrongColumns(constraint.shape.map { $0.intValue })
        }
    }

    /// Install a converted package where the app reads it.
    ///
    /// Kept here rather than in Phase 5's downloader because a dev install needs
    /// the same step, and because the naming is a trap: `MLModel.compileModel`
    /// names the output after the PACKAGE, so a package called
    /// `falconsai_any_other_name` compiles to a directory the app never looks
    /// in. This method owns the rename, so no caller has to remember it.
    @discardableResult
    nonisolated static func install(package: URL, root: String) throws -> URL {
        let compiled = try MLModel.compileModel(at: package)
        let destination = modelURL(root: root)
        let fm = FileManager.default
        try fm.createDirectory(atPath: destination.deletingLastPathComponent().path,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: compiled, to: destination)
        return destination
    }

    /// Per-frame NSFW probability, in the order the frames were handed over.
    ///
    /// Cancellation is checked between frames, and one unreadable or
    /// unscorable frame is dropped rather than failing the video — the same
    /// discipline `VisionEmbedder.embed` follows.
    func scores(_ frames: [FrameSampler.SampledFrame]) async throws -> [Int: Double] {
        guard !frames.isEmpty else { return [:] }
        let constrain = model.modelDescription
            .inputDescriptionsByName[inputName]?.imageConstraint
        var out: [Int: Double] = [:]
        out.reserveCapacity(frames.count)
        for frame in frames {
            try Task.checkCancellation()
            let buf = try VisionEmbedder.pixelBuffer(from: frame.image, constrain: constrain)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: buf)])
            let result = try await model.prediction(from: provider, options: MLPredictionOptions())
            guard let value = result.featureValue(for: "probs")?.multiArrayValue else {
                throw ClassifierError.noOutput("prediction \(frame.index)")
            }
            out[frame.index] = Self.probabilities(value)[Self.nsfwIndex]
        }
        return out
    }

    /// The output columns, whatever precision Core ML hands back.
    ///
    /// Read through `NSNumber` on purpose: the model is converted to float16,
    /// and a pointer read that assumed float32 would silently reinterpret two
    /// bytes per value. Two values per frame — the cost is nothing.
    nonisolated static func probabilities(_ array: MLMultiArray) -> [Double] {
        (0..<array.count).map { array[$0].doubleValue }
    }

    enum ClassifierError: Error, LocalizedError, CustomStringConvertible {
        case notInstalled(String)
        case noInput(String)
        case noOutput(String)
        case wrongColumns([Int])

        var description: String {
            switch self {
            case .notInstalled(let p):
                return "the Safe / NSFW model is not installed at \(p)"
            case .noInput(let p):
                return "the Safe / NSFW model at \(p) has no image input"
            case .noOutput(let p):
                return "the Safe / NSFW model at \(p) produced no usable output"
            case .wrongColumns(let shape):
                return "the Safe / NSFW model has shape \(shape) — it must output at "
                    + "least \(minimumColumns) class probabilities"
            }
        }

        /// So a broken model reaches the Analysis window as a sentence.
        var errorDescription: String? { description }
    }
}
