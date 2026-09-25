import Foundation
import CoreML
import CoreGraphics

/// CGImage → 768-dim unit vector, through the SigLIP 2 B/16 Core ML model.
///
/// This replaced MobileCLIP-S2, whose WEIGHTS are under Apple's research-only
/// "Apple Machine Learning Research Model" licence (its code is MIT; the weights
/// are not, and they forbid use in a product). SigLIP 2 is Apache-2.0 end to end
/// and better on the published metrics (78.2 vs 74.4 ImageNet zero-shot). The
/// price is measured, not assumed: 176 MB instead of 83, and 4.65 ms/frame
/// instead of 2.0 through the Python bridge (`convert_siglip2_image.py`).
///
/// Phase 0 measured the MobileCLIP path at 2.0 ms/frame single, 1.6 ms/frame
/// batched, with batched and single results bit-identical — so batching is an
/// optimisation, never a correctness question. Nothing here depends on the
/// tower's identity beyond `modelSlug`, `dim` and the file it loads, which is
/// why the swap was a rename rather than a rewrite.
actor VisionEmbedder {

    static let modelSlug = "siglip2_base"       // cache namespace; old ViT-L/14 and MobileCLIP vectors are never touched
    static let dim = 768

    private var model: MLModel?
    /// Read once at load: the engine's single output. A model with a
    /// different shape fails loudly in embed() instead of mis-reading here.
    private let outputName: String

    /// Where the downloaded bundle keeps the compiled model: the float32 or
    /// float16 build, whichever `ModelSpace.activeTower` picks.
    static func modelURL(root: String) -> URL {
        ModelSpace.towerDirectory(root: root)
    }

    /// A model file is present and loadable from `root`? Cheap check for the
    /// capability layer to call before any work is attempted.
    nonisolated static func isInstalled(root: String) -> Bool {
        let p = modelURL(root: root).path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    init(root: String) throws {
        let url = Self.modelURL(root: root)
        guard Self.isInstalled(root: root) else {
            throw EmbedderError.notInstalled(url.path)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: config)
        self.outputName = model!.modelDescription.outputDescriptionsByName.keys.first ?? "output"
    }

    struct Embedding {
        let vector: [Float]
        let index: Int          // position in the input frame list
    }

    /// Embed frames in order. Returned vectors are unit-normalised, matching
    /// the Python engine's post-embedding L2 normalisation, so cosine
    /// similarity code ports unchanged.
    func embed(_ frames: [FrameSampler.SampledFrame]) async throws -> [Embedding] {
        guard let model else { throw EmbedderError.notLoaded }
        guard !frames.isEmpty else { return [] }

        let inputName = model.modelDescription.inputDescriptionsByName.first!.key
        let constrain: MLImageConstraint? =
            model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint

        var out: [Embedding] = []
        out.reserveCapacity(frames.count)

        // One at a time is already 2 ms/frame; batching buys 1.24x and adds a
        // whole failure surface. Keep it simple; revisit only if sampling is
        // ever fixed enough to make embedding the bottleneck again.
        for frame in frames {
            try Task.checkCancellation()
            let buf = try Self.pixelBuffer(from: frame.image, constrain: constrain)
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: buf)])
            let result = try await model.prediction(from: provider, options: MLPredictionOptions())
            guard let arr = result.featureValue(for: outputName)?.multiArrayValue else {
                throw EmbedderError.noOutput
            }
            out.append(Embedding(vector: Self.l2(arr), index: frame.index))
        }
        return out
    }

    nonisolated static func l2(_ arr: MLMultiArray) -> [Float] {
        let n = arr.count
        // Core ML may return float16, float32, or double, with non-unit
        // strides. Its numeric accessor handles both storage type and layout.
        // Binding this buffer to Float corrupts float16 output before L2.
        var v = (0..<n).map { arr[$0].floatValue }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in 0..<n { v[i] /= norm } }
        return v
    }

    /// CGImage → CVPixelBuffer in the model's exact input geometry.
    nonisolated static func pixelBuffer(from image: CGImage,
                                        constrain: MLImageConstraint?) throws -> CVPixelBuffer {
        let w: Int, h: Int
        if let c = constrain {
            w = c.pixelsWide; h = c.pixelsHigh
        } else {
            w = image.width; h = image.height
        }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw EmbedderError.pixelBuffer(status)
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                            width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx else { throw EmbedderError.noContext }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    enum EmbedderError: Error, LocalizedError, CustomStringConvertible {
        case notInstalled(String)
        case notLoaded
        case noOutput
        case pixelBuffer(CVReturn)
        case noContext

        var description: String {
            switch self {
            case .notInstalled(let p): return "the vision model is not installed at \(p)"
            case .notLoaded:  return "embedder used before a model was loaded"
            case .noOutput:   return "model produced no usable output"
            case .pixelBuffer(let s): return "CVPixelBufferCreate failed: \(s)"
            case .noContext:  return "could not create drawing context"
            }
        }

        /// So a missing model reaches the Analysis window as a sentence.
        var errorDescription: String? { description }
    }
}
