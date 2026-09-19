// Task 0.3b — what can Vision do for faces on its own?
//
// SFace could not be converted directly (coremltools dropped its ONNX path),
// so before treating that as a Phase 5 risk, find out what macOS already ships.
//
// Two separate questions, and they have different answers:
//   DETECTION  — does Vision find the same faces YuNet finds?
//   IDENTITY   — can Vision tell two people apart?
//
// Vision has VNDetectFaceRectanglesRequest (detection, excellent) and
// VNGenerateFaceprintRequest… which is PRIVATE API. The public identity story
// is landmarks only. So this measures detection, and reports honestly on what
// identity would need.
//
// Build:
//   swiftc -O -o /tmp/facespike docs/coreml-spike/FaceSpike/main.swift \
//     -framework Vision -framework AVFoundation -framework CoreImage
//   /tmp/facespike <video> [video...]

import AVFoundation
import CoreImage
import Foundation
import Vision

let videos = Array(CommandLine.arguments.dropFirst())
guard !videos.isEmpty else {
    print("usage: facespike <video> [video...]")
    exit(2)
}

// Is the private faceprint API reachable? If it is, it is still not shippable
// — App Review rejects private API — but it is worth knowing.
print("VNGenerateFaceprintRequest available: "
      + (NSClassFromString("VNGenerateFaceprintRequest") != nil ? "yes (PRIVATE — unusable)" : "no"))
print("VNFaceObservation landmarks: public")
print("")

let ciContext = CIContext()

for path in videos {
    let name = (path as NSString).lastPathComponent
    guard FileManager.default.fileExists(atPath: path) else { continue }

    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let semaphore = DispatchSemaphore(value: 0)
    var duration = 0.0
    Task {
        duration = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        semaphore.signal()
    }
    semaphore.wait()
    guard duration > 0 else { continue }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1024, height: 1024)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

    // Stride across the WHOLE video — pitfall 29: stopping at the first N
    // frames misses everyone who appears later, which is the normal case.
    let interval = min(5.0, max(duration / 4.0, 0.2))
    var times: [CMTime] = []
    var t = 0.0
    while t < duration && times.count < 24 {
        times.append(CMTime(seconds: t, preferredTimescale: 600))
        t += interval
    }

    var faceCount = 0
    var framesWithFaces = 0
    var totalFrames = 0
    var areas: [Double] = []
    let start = DispatchTime.now().uptimeNanoseconds

    for time in times {
        guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
        totalFrames += 1
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let faces = request.results ?? []
        if !faces.isEmpty { framesWithFaces += 1 }
        faceCount += faces.count
        for face in faces {
            // Normalised box -> pixel area, the ranking the app uses to pick
            // the "5 biggest faces" (pitfall 36).
            let w = face.boundingBox.width * Double(image.width)
            let h = face.boundingBox.height * Double(image.height)
            areas.append(w * h)
        }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

    print(String(format: "%@", name))
    print(String(format: "  %.1fs · %d frames · %d faces in %d frames · %.2fs (%.1f fps)",
                 duration, totalFrames, faceCount, framesWithFaces,
                 elapsed, Double(totalFrames) / max(elapsed, 0.001)))
    if !areas.isEmpty {
        let sorted = areas.sorted(by: >)
        print(String(format: "  biggest face: %.0f px²   smallest: %.0f px²",
                     sorted.first!, sorted.last!))
    }
}
