import CoreGraphics
import CoreML
import Foundation

/// An aligned 112×112 crop → a unit-normalised 128-dim identity vector.
///
/// The model is SFace (OpenCV Zoo, Apache-2.0), rebuilt in PyTorch from its ONNX
/// graph because `coremltools` no longer imports ONNX, and converted at
/// float16: **18 MB**, and **6.5e-04** from the ONNX model's own cosines — an
/// order of magnitude inside the ±0.01 the gate asks for, with every one of the
/// 44 same/different decisions at the 0.30 threshold identical
/// (`docs/phase6-sface-spike.md`).
///
/// Two facts about the converted model are load-bearing:
///
///   - **The normalisation is inside the graph.** The ONNX begins with
///     `Sub(127.5)` and `Mul(1/128)`, so the Core ML image input has scale 1 and
///     no bias: hand it raw 0-255 pixels. Normalising on the way in would
///     normalise twice, and the first attempt at this very task got the model's
///     *colour order* wrong for exactly this kind of reason (BGR leaves a 0.099
///     cosine error where RGB leaves 6e-07 — 200× the gate).
///   - **The output is un-normalised.** The engine stores unit vectors in
///     `faces/<hash>.f32` and `_face_matches` compares them with a plain dot
///     product, so this normalises on the way out and callers never see a raw
///     embedding. A cosine over unit vectors is a dot product; if one side were
///     un-normalised the comparison would silently become a scaled dot product
///     and the 0.30 threshold would mean something else.
actor SFaceEmbedder {

    static let slug = "sface"
    static let dim = 128
    /// The model was converted for this crop size, and the alignment produces
    /// exactly it. A model at another size is refused at load rather than
    /// resized into a shape the weights were not trained for.
    static let inputSide = 112
    static let outputName = "embedding"

    private let model: MLModel
    private let inputName: String

    static func modelURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/sface.mlmodelc"))
    }

    nonisolated static func isInstalled(root: String) -> Bool {
        let p = modelURL(root: root).path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    init(root: String) throws {
        let url = Self.modelURL(root: root)
        guard Self.isInstalled(root: root) else { throw SFaceError.notInstalled(url.path) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: config)
        guard let input = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw SFaceError.noInput(url.path)
        }
        self.inputName = input
        if let constraint = model.modelDescription.inputDescriptionsByName[input]?.imageConstraint {
            guard constraint.pixelsWide == Self.inputSide,
                  constraint.pixelsHigh == Self.inputSide else {
                throw SFaceError.wrongInputSize(constraint.pixelsWide, constraint.pixelsHigh)
            }
        }
        guard let output = model.modelDescription
            .outputDescriptionsByName[Self.outputName]?.multiArrayConstraint else {
            throw SFaceError.noOutput(url.path)
        }
        guard output.shape.last?.intValue == Self.dim else {
            throw SFaceError.wrongWidth(output.shape.map { $0.intValue })
        }
    }

    /// One crop, unit-normalised. Nil when the model produced nothing usable.
    func embed(_ crop: CGImage) throws -> [Float] {
        let constraint = model.modelDescription
            .inputDescriptionsByName[inputName]?.imageConstraint
        let buffer = try VisionEmbedder.pixelBuffer(from: crop, constrain: constraint)
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let result = try model.prediction(from: provider, options: MLPredictionOptions())
        guard let array = result.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw SFaceError.noOutput(Self.outputName)
        }
        return Self.unit(FaceDetector.floats(array))
    }

    /// Several crops, in the order handed over. The crop is 112×112 and the
    /// model is 18 MB, so a whole video's faces are cheap — the four-face cap
    /// in the picker is about the UI, not about this.
    func embed(_ crops: [CGImage]) throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(crops.count)
        for crop in crops {
            try Task.checkCancellation()
            out.append(try embed(crop))
        }
        return out
    }

    /// L2-normalise, leaving a zero vector alone rather than dividing by zero.
    nonisolated static func unit(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        for x in vector { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// The comparison the whole feature rests on, in one place: a cosine over
    /// two unit vectors is a plain dot product.
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var sum: Double = 0
        for i in 0..<a.count { sum += Double(a[i]) * Double(b[i]) }
        return sum
    }

    /// The cosine at which two faces are the same person — `engine.FACE_MATCH_COSINE`,
    /// not a re-derived number.
    ///
    /// It lives beside `cosine(_:_:)` on purpose: the threshold and the
    /// quantity it is compared against are the same decision, and the only
    /// reason 0.30 is still 0.30 is that the alignment did not move the crops
    /// (pitfall 28 — the whole margin is 0.026, so a drifted crop silently
    /// turns it into a different threshold). `Tests/test_face_engine.swift`
    /// reads the value out of a fixture that took it from `engine.py`, so a
    /// stray edit here fails the gate rather than quietly re-tuning faces.
    static let matchCosine = 0.30

    enum SFaceError: Error, LocalizedError, CustomStringConvertible {
        case notInstalled(String)
        case noInput(String)
        case noOutput(String)
        case wrongInputSize(Int, Int)
        case wrongWidth([Int])

        var description: String {
            switch self {
            case .notInstalled(let p):
                return "the face recognition model is not installed at \(p)"
            case .noInput(let p):
                return "the face recognition model at \(p) has no image input"
            case .noOutput(let p):
                return "the face recognition model produced no \(p)"
            case .wrongInputSize(let w, let h):
                return "the face recognition model takes \(w)×\(h) crops; the alignment "
                    + "produces \(SFaceEmbedder.inputSide)×\(SFaceEmbedder.inputSide)"
            case .wrongWidth(let shape):
                return "the face recognition model outputs \(shape) — it must be "
                    + "\(SFaceEmbedder.dim) wide"
            }
        }

        var errorDescription: String? { description }
    }
}
