import CoreGraphics
import CoreML
import Foundation

/// One face, in the exact shape `cv2.FaceDetectorYN` hands the Python engine:
/// a top-left box in image pixels, five landmarks in the model's own order, and
/// a score. Keeping the layout identical is deliberate — the rest of the face
/// pipeline (`_faces_in_frame`, `_face_matches`, the alignment) reads those
/// positions, and the alignment is what the 0.30 threshold is calibrated on.
struct DetectedFace: Equatable {
    let x: Double, y: Double, width: Double, height: Double
    /// Right eye, left eye, nose tip, right mouth corner, left mouth corner —
    /// the model's order, which is the order `cv2.alignCrop` consumes and the
    /// order `FaceAlignment` expects.
    let landmarks: [CGPoint]
    let score: Double

    var box: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    /// Pixel area of the detection box, the ranking the app uses to pick the
    /// biggest faces (pitfall 36).
    var area: Double { width * height }
}

/// YuNet in Core ML: detection and the five landmarks the crop is aligned from.
///
/// **Why this model and not Vision.** Task 6.2 was written as "detection via
/// Vision", and Phase 0 had already measured Vision's detections as fine. Its
/// *landmarks* are not: against `cv2.alignCrop`'s crops they drift by a scale sd
/// of 6.6% and a rotation sd of 7.4°, because Vision's eye regions are eyelid
/// contours and a contour centroid is noise under rotation and blur. That is
/// enough to invalidate `FACE_MATCH_COSINE = 0.30`, which was tuned on
/// YuNet-aligned crops and whose whole margin is 0.026 (pitfall 28). Porting the
/// detector keeps the crops identical, so the threshold keeps its meaning —
/// and the measurement, the rejection and the numbers are in
/// `docs/phase6-detector-spike.md`.
///
/// **Three things here are load-bearing and were derived from OpenCV's source,
/// not assumed** (`cv2.FaceDetectorYN` is the oracle; `yunet_parity.py`
/// reproduces it to 0.0001 px):
///
///   1. **The input is the frame at its own size, zero-padded right/bottom to a
///      multiple of 32.** There is no resize and no letterbox. The ONNX declares
///      640×640, but every `Reshape` in it targets `[1, -1, k]`, so the network
///      is fully convolutional and runs at any multiple of 32 — which is why
///      the converted model takes a dynamic height and width.
///   2. **BGR, raw 0-255.** SFace wants RGB; YuNet wants BGR, the
///      `blobFromImage` default. With the geometry right this is unambiguous:
///      RGB leaves a 25 px mean error where BGR leaves 0.000.
///   3. **NMS runs on integer boxes.** OpenCV converts each float box to
///      `Rect2i` before measuring overlap, so every coordinate is truncated, and
///      that decides which boxes survive near the threshold.
actor FaceDetector {

    static let slug = "yunet"
    static let inputSide = 32                 // the divisor the frame is padded to
    static let strides = [8, 16, 32]
    /// `cv2.FaceDetectorYN.create(...)` in engine.py: score 0.7, NMS 0.3.
    static let scoreThreshold = 0.7
    static let nmsThreshold = 0.3
    /// Onnxruntime refuses anything but the declared 640×640; the converted
    /// model is asked for the real freedom OpenCV takes, within a sane range.
    static let minimumSide = 32
    static let maximumSide = 1600

    private let model: MLModel
    private let inputName: String

    static func modelURL(root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).appendingPathComponent("tags/yunet.mlmodelc"))
    }

    /// Is the detector installed? Cheap — one directory check, no model load,
    /// so the capability layer can ask without paying for a load.
    nonisolated static func isInstalled(root: String) -> Bool {
        let p = modelURL(root: root).path
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    init(root: String) throws {
        let url = Self.modelURL(root: root)
        guard Self.isInstalled(root: root) else { throw DetectorError.notInstalled(url.path) }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: config)
        guard let input = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw DetectorError.noInput(url.path)
        }
        self.inputName = input
        // Every output the decode needs must exist, or the failure belongs at
        // load rather than halfway through a video.
        let outputs = model.modelDescription.outputDescriptionsByName.keys
        for stride in Self.strides {
            for prefix in ["cls", "obj", "bbox", "kps"] {
                let name = "\(prefix)_\(stride)"
                if !outputs.contains(name) { throw DetectorError.missingOutput(name) }
            }
        }
    }

    /// Detect every face in one frame, in image pixel coordinates.
    ///
    /// The caller decides *which* frames to show this to: `FaceScanner` strides
    /// across the whole video (pitfall 29) and caps the count as a safety net,
    /// never as an early exit.
    func detect(_ image: CGImage) throws -> [DetectedFace] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }
        guard width <= Self.maximumSide, height <= Self.maximumSide else {
            throw DetectorError.tooLarge(width, height)
        }
        let paddedWidth = Self.padded(width)
        let paddedHeight = Self.padded(height)

        let buffer = try Self.paddedPixelBuffer(from: image, width: paddedWidth,
                                                height: paddedHeight)
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let result = try model.prediction(from: provider, options: MLPredictionOptions())

        return Self.decode(result: result, paddedWidth: paddedWidth,
                           paddedHeight: paddedHeight)
    }

    /// Round up to the next multiple of 32 — OpenCV's `padW`/`padH`.
    nonisolated static func padded(_ side: Int) -> Int {
        ((side - 1) / inputSide + 1) * inputSide
    }

    /// The frame drawn into a zero-padded 32-bit buffer, BGR, raw 0-255.
    ///
    /// `kCVPixelFormatType_32BGRA` is BGRA in memory, which is the BGR channel
    /// order YuNet's blob expects; Core ML does not reorder it. The padding is
    /// written by the buffer itself (zeroed first) rather than by the drawing,
    /// so a frame that needs no padding is drawn edge to edge.
    nonisolated static func paddedPixelBuffer(from image: CGImage, width: Int,
                                              height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw DetectorError.pixelBuffer(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DetectorError.noContext
        }
        memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw DetectorError.noContext
        }
        ctx.interpolationQuality = .high
        // The image goes at the TOP of the padded canvas, because that is where
        // OpenCV puts it — `yunet_parity.pad_to_divisor` copies into
        // `canvas[:h, :w]`, so the zeros are on the right and bottom only. A
        // bitmap context's y axis points UP while its rows run top-down, so
        // y = 0 is the BOTTOM of the buffer: drawing at the origin pads the top
        // instead, which shifts the frame by up to 31 px, moves every box and
        // flips which of two faces scores higher. Measured on 962×540 frames
        // (padded 992×544): origin-drawn gives score 0.7083 where cv2 gives
        // 0.7357, and on the 3-face frame it reorders all three; drawn at
        // paddedHeight - height every box and score matches cv2 exactly. A
        // frame that needs no padding is unaffected either way (y offset 0),
        // which is why the parity fixture only catches this on odd sizes.
        ctx.draw(image, in: CGRect(x: 0, y: height - image.height,
                                   width: image.width, height: image.height))
        return buffer
    }

    // MARK: - the decode

    /// Raw per-anchor tensors → faces, then NMS. Mirrors `yunet_parity.py`.
    nonisolated static func decode(result: MLFeatureProvider, paddedWidth: Int,
                                   paddedHeight: Int) -> [DetectedFace] {
        var rows: [DetectedFace] = []
        for stride in strides {
            guard let cls = result.featureValue(for: "cls_\(stride)")?.multiArrayValue,
                  let obj = result.featureValue(for: "obj_\(stride)")?.multiArrayValue,
                  let bbox = result.featureValue(for: "bbox_\(stride)")?.multiArrayValue,
                  let kps = result.featureValue(for: "kps_\(stride)")?.multiArrayValue
            else { continue }

            let columns = paddedWidth / stride
            let count = cls.count
            let clsValues = floats(cls)
            let objValues = floats(obj)
            let boxes = floats(bbox)
            let points = floats(kps)

            for index in 0..<count {
                // score = sqrt(clamp(cls) * clamp(obj)) — OpenCV clamps both to
                // 0...1 before the product, so a model that overshoots cannot
                // score above 1.
                let clsScore = Double(min(max(clsValues[index], 0), 1))
                let objScore = Double(min(max(objValues[index], 0), 1))
                let score = (clsScore * objScore).squareRoot()
                if score < scoreThreshold { continue }

                let row = index / columns
                let column = index % columns
                let scale = Double(stride)
                let cx = (Double(column) + Double(boxes[index * 4])) * scale
                let cy = (Double(row) + Double(boxes[index * 4 + 1])) * scale
                let w = exp(Double(boxes[index * 4 + 2])) * scale
                let h = exp(Double(boxes[index * 4 + 3])) * scale

                var landmarks: [CGPoint] = []
                landmarks.reserveCapacity(5)
                for k in 0..<5 {
                    let lx = (Double(points[index * 10 + 2 * k]) + Double(column)) * scale
                    let ly = (Double(points[index * 10 + 2 * k + 1]) + Double(row)) * scale
                    landmarks.append(CGPoint(x: lx, y: ly))
                }
                rows.append(DetectedFace(x: cx - w / 2, y: cy - h / 2,
                                         width: w, height: h,
                                         landmarks: landmarks, score: score))
            }
        }
        return nonMaximumSuppression(rows, threshold: nmsThreshold)
    }

    /// `dnn::NMSBoxes` — on **integer** boxes, because the truncation is part of
    /// the specification: near the threshold it changes which boxes survive.
    nonisolated static func nonMaximumSuppression(_ faces: [DetectedFace],
                                                   threshold: Double) -> [DetectedFace] {
        let ordered = faces.enumerated().sorted { $0.element.score > $1.element.score }
        var kept: [DetectedFace] = []
        var remaining = ordered
        while let first = remaining.first {
            kept.append(first.element)
            remaining.removeFirst()
            let a = first.element
            let ax = Int(a.x), ay = Int(a.y)
            let aw = Int(a.width), ah = Int(a.height)
            remaining = remaining.filter { candidate in
                let b = candidate.element
                let bx = Int(b.x), by = Int(b.y)
                let bw = Int(b.width), bh = Int(b.height)
                let overlapWidth = min(ax + aw, bx + bw) - max(ax, bx)
                let overlapHeight = min(ay + ah, by + bh) - max(ay, by)
                let intersection = Double(max(overlapWidth, 0) * max(overlapHeight, 0))
                let union = Double(aw * ah + bw * bh) - intersection
                let iou = union > 0 ? intersection / union : 0
                return iou <= threshold
            }
        }
        return kept
    }

    /// A multi-array as floats.
    ///
    /// The package is converted at float32, so the fast path is a pointer read.
    /// The `NSNumber` path exists because a re-converted package at float16
    /// would otherwise be reinterpreted two bytes at a time — the same trap
    /// `NSFWClassifier.probabilities` documents, and the same reason it reads
    /// through `NSNumber`.
    nonisolated static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        if array.dataType == .float32 {
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }
        return (0..<count).map { array[$0].floatValue }
    }

    enum DetectorError: Error, LocalizedError, CustomStringConvertible {
        case notInstalled(String)
        case noInput(String)
        case missingOutput(String)
        case tooLarge(Int, Int)
        case pixelBuffer(CVReturn)
        case noContext

        var description: String {
            switch self {
            case .notInstalled(let p):
                return "the face detector is not installed at \(p)"
            case .noInput(let p):
                return "the face detector at \(p) has no image input"
            case .missingOutput(let name):
                return "the face detector does not produce \(name) — it is not the ported YuNet"
            case .tooLarge(let w, let h):
                return "the frame is \(w)×\(h); the detector accepts at most "
                    + "\(FaceDetector.maximumSide) on a side"
            case .pixelBuffer(let s):
                return "CVPixelBufferCreate failed: \(s)"
            case .noContext:
                return "could not create a drawing context for the detector input"
            }
        }

        /// So a missing model reaches the UI as a sentence, not a code.
        var errorDescription: String? { description }
    }
}
