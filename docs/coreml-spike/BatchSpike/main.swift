// Task 0.1 — how fast is MobileCLIP-S2 through Core ML, from Swift?
//
// The gate: a 10-minute video (~120 frames at the 5s cadence) must embed in
// under 5 seconds. The Python+MPS engine does roughly this today, and
// MobileCLIP-S2 is ~15x smaller than ViT-L/14, so it ought to be far quicker.
// If it is not, the whole migration needs rethinking — hence this runs before
// any app code is written.
//
// Measures three things separately, because they fail for different reasons:
//   1. model load (paid once per run)
//   2. frame sampling through AVAssetImageGenerator (disk + decode)
//   3. embedding, one-at-a-time vs batched (the number that matters)
//
// Build:
//   swiftc -O -o /tmp/batchspike docs/coreml-spike/BatchSpike/main.swift \
//     -framework CoreML -framework AVFoundation -framework CoreImage
//   /tmp/batchspike <model.mlpackage> <video> [frameCount]

import AVFoundation
import CoreImage
import CoreML
import Foundation

// MARK: - arguments

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: batchspike <model.mlpackage> <video> [frameCount]")
    exit(2)
}
let modelPath = args[1]
let videoPath = args[2]
let wantFrames = args.count > 3 ? Int(args[3]) ?? 120 : 120

func seconds(_ block: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try block()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
}

// MARK: - 1. load the model

print("model: \((modelPath as NSString).lastPathComponent)")
let compiledURL: URL
do {
    compiledURL = try MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
} catch {
    print("FAIL compile: \(error)")
    exit(1)
}

let config = MLModelConfiguration()
config.computeUnits = .all        // CPU + GPU + Neural Engine

var model: MLModel!
let loadTime = try! seconds {
    model = try MLModel(contentsOf: compiledURL, configuration: config)
}
print(String(format: "load:    %.3f s", loadTime))

// What does it actually want?
let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "final_emb_1"
guard let imageConstraint = model.modelDescription
    .inputDescriptionsByName[inputName]?.imageConstraint else {
    print("FAIL: model input '\(inputName)' is not an image")
    exit(1)
}
let side = imageConstraint.pixelsWide
print("input:   \(inputName) \(imageConstraint.pixelsWide)x\(imageConstraint.pixelsHigh)")
print("output:  \(outputName)")

// MARK: - 2. sample frames the way the app will

let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 512, height: 512)
// Tolerance is what makes this fast: an exact seek per frame is far slower
// and pointless for a uniform sample.
generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

let semaphore = DispatchSemaphore(value: 0)
var duration: Double = 0
Task {
    duration = try await CMTimeGetSeconds(asset.load(.duration))
    semaphore.signal()
}
semaphore.wait()
print(String(format: "video:   %.1f s", duration))

// The app's cadence: one frame every 5 s, capped, with the short-clip clamp.
let interval = min(5.0, max(duration / 4.0, 0.2))
var times: [CMTime] = []
var t = 0.0
while t < duration && times.count < wantFrames {
    times.append(CMTime(seconds: t, preferredTimescale: 600))
    t += interval
}
print("frames:  \(times.count) wanted (every \(String(format: "%.1f", interval))s)")

var images: [CGImage] = []
let sampleTime = seconds {
    let group = DispatchGroup()
    let lock = NSLock()
    group.enter()
    generator.generateCGImagesAsynchronously(forTimes: times.map(NSValue.init)) {
        _, image, _, result, _ in
        if result == .succeeded, let image {
            lock.lock(); images.append(image); lock.unlock()
        }
        lock.lock()
        let done = images.count
        lock.unlock()
        if done >= times.count { group.leave() }
    }
    _ = group.wait(timeout: .now() + 120)
}
guard !images.isEmpty else {
    print("FAIL: no frames came out of the video")
    exit(1)
}
print(String(format: "sample:  %.3f s for %d frames (%.1f fps)",
             sampleTime, images.count, Double(images.count) / sampleTime))

// MARK: - scale into the buffers Core ML wants

let ciContext = CIContext(options: [.useSoftwareRenderer: false])

func pixelBuffer(from image: CGImage, side: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                              kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                              &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    let ci = CIImage(cgImage: image)
    let scale = CGAffineTransform(scaleX: CGFloat(side) / ci.extent.width,
                                  y: CGFloat(side) / ci.extent.height)
    ciContext.render(ci.transformed(by: scale), to: buffer)
    return buffer
}

var buffers: [CVPixelBuffer] = []
let prepTime = seconds {
    buffers = images.compactMap { pixelBuffer(from: $0, side: side) }
}
print(String(format: "prepare: %.3f s for %d buffers", prepTime, buffers.count))

// MARK: - 3a. one at a time

final class Single: MLFeatureProvider {
    let name: String
    let buffer: CVPixelBuffer
    init(_ name: String, _ buffer: CVPixelBuffer) { self.name = name; self.buffer = buffer }
    var featureNames: Set<String> { [name] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == name ? MLFeatureValue(pixelBuffer: buffer) : nil
    }
}

var firstVector: [Float] = []
let oneByOne = try! seconds {
    for (i, buffer) in buffers.enumerated() {
        let out = try model.prediction(from: Single(inputName, buffer))
        if i == 0, let array = out.featureValue(for: outputName)?.multiArrayValue {
            firstVector = (0..<array.count).map { Float(truncating: array[$0]) }
        }
    }
}
print(String(format: "\nONE BY ONE: %.3f s  (%.1f frames/s, %.1f ms/frame)",
             oneByOne, Double(buffers.count) / oneByOne,
             oneByOne / Double(buffers.count) * 1000))

// MARK: - 3b. batched

let batchProvider = MLArrayBatchProvider(
    array: buffers.map { Single(inputName, $0) })

var batched = 0.0
var batchVector: [Float] = []
do {
    batched = try seconds {
        let results = try model.predictions(from: batchProvider,
                                            options: MLPredictionOptions())
        if results.count > 0,
           let array = results.features(at: 0)
               .featureValue(for: outputName)?.multiArrayValue {
            batchVector = (0..<array.count).map { Float(truncating: array[$0]) }
        }
    }
    print(String(format: "BATCHED:    %.3f s  (%.1f frames/s, %.1f ms/frame)",
                 batched, Double(buffers.count) / batched,
                 batched / Double(buffers.count) * 1000))
} catch {
    print("batch prediction failed: \(error)")
}

// The two paths must agree, or the fast one is not the same computation.
if !firstVector.isEmpty && !batchVector.isEmpty {
    let drift = zip(firstVector, batchVector).map { abs($0 - $1) }.max() ?? 0
    print(String(format: "agreement:  max element drift %.6f  (dim %d)",
                 drift, firstVector.count))
}

// MARK: - the verdict

let perFrame = min(oneByOne, batched == 0 ? oneByOne : batched) / Double(buffers.count)
let tenMinuteFrames = 120.0
let projected = perFrame * tenMinuteFrames
let sampleProjected = (sampleTime / Double(images.count)) * tenMinuteFrames

print(String(format: """

=== GATE: a 10-minute video (120 frames) ===
embedding:  %.2f s
sampling:   %.2f s
total:      %.2f s   %@
""", projected, sampleProjected, projected + sampleProjected,
     (projected + sampleProjected) < 5.0 ? "PASS (under 5 s)" : "OVER 5 s — investigate"))
