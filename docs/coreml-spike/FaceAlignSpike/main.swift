// Task 6.2a — what does Vision actually give us for a face?
//
// The whole face feature now rests on one substitution: YuNet + `cv2.alignCrop`
// becomes Vision detection + landmarks + our own similarity transform. Phase 0
// measured Vision's *detection* (25–47 fps, comparable to YuNet); nobody has
// measured its *landmarks*, and landmarks are what the alignment is made of.
//
// So this writes them out raw and lets the Python side decide. It deliberately
// does NOT align anything: the landmark ordering (which of Vision's eye regions
// is the image-left one, and which outer-lip points are the corners) is exactly
// what is unresolved, and guessing it here would bury the question.
//
// Output: <work>/vision.json
//   frames[]: name, width, height
//     faces[]: box [x, y, w, h] in IMAGE PIXELS, top-left origin
//              confidence, landmarks { region: [[x, y], ...] }
//
// Every point is in image pixels with the origin at the TOP-LEFT, matching the
// frames as read — Vision reports normalised coordinates inside a normalised,
// bottom-left bounding box, and converting once here keeps the Python side from
// having to know that.
//
// Build & run:
//   swiftc -O -o /tmp/facealign docs/coreml-spike/FaceAlignSpike/main.swift \
//     -framework Vision -framework ImageIO -framework CoreGraphics
//   /tmp/facealign ~/fvp-coreml-models/face_align

import CoreGraphics
import Foundation
import ImageIO
import Vision

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: facealign <work-dir>   (reads <work>/frames/frame_*.png)")
    exit(2)
}
let work = URL(fileURLWithPath: arguments[1])
let framesDir = work.appendingPathComponent("frames")

guard let names = try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)
else {
    print("no frames at \(framesDir.path)")
    exit(2)
}
let frameNames = names.filter { $0.hasPrefix("frame_") && $0.hasSuffix(".png") }.sorted()
guard !frameNames.isEmpty else {
    print("no frame_*.png at \(framesDir.path)")
    exit(2)
}

/// A 2D point, serialised as a two-element array.
func json(_ point: CGPoint) -> [Double] { [Double(point.x), Double(point.y)] }

var output: [[String: Any]] = []

for name in frameNames {
    let url = framesDir.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("cannot read \(name)\n".data(using: .utf8)!)
        continue
    }
    let width = Double(image.width)
    let height = Double(image.height)

    let request = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        FileHandle.standardError.write("vision failed on \(name): \(error)\n".data(using: .utf8)!)
        continue
    }

    var faces: [[String: Any]] = []
    for observation in (request.results ?? []) {
        // Vision's box is normalised with the origin at the BOTTOM-left; the
        // frame is addressed from the top-left, so y is flipped here.
        let box = observation.boundingBox
        let x = box.minX * width
        let y = (1.0 - box.maxY) * height
        let w = box.width * width
        let h = box.height * height

        var regions: [String: Any] = [:]
        if let landmarks = observation.landmarks {
            // Vision normalises landmark points INSIDE the face box (0...1,
            // y up). Map them through the box, then through the image.
            func toImage(_ points: [CGPoint]) -> [[Double]] {
                points.map { p in
                    let px = (box.minX + p.x * box.width) * width
                    let py = (1.0 - (box.minY + p.y * box.height)) * height
                    return [px, py]
                }
            }
            func add(_ key: String, _ region: VNFaceLandmarkRegion2D?) {
                guard let region else { return }
                regions[key] = toImage(region.normalizedPoints)
            }
            add("leftEye", landmarks.leftEye)
            add("rightEye", landmarks.rightEye)
            add("leftPupil", landmarks.leftPupil)
            add("rightPupil", landmarks.rightPupil)
            add("nose", landmarks.nose)
            add("noseCrest", landmarks.noseCrest)
            add("medianLine", landmarks.medianLine)
            add("outerLips", landmarks.outerLips)
            add("innerLips", landmarks.innerLips)
            add("leftEyebrow", landmarks.leftEyebrow)
            add("rightEyebrow", landmarks.rightEyebrow)
            add("faceContour", landmarks.faceContour)
        }

        faces.append([
            "box": [x, y, w, h],
            "confidence": Double(observation.confidence),
            "roll": observation.roll.map { Double($0.doubleValue) } ?? 0,
            "yaw": observation.yaw.map { Double($0.doubleValue) } ?? 0,
            "regions": regions,
        ])
    }

    output.append(["name": name, "width": width, "height": height, "faces": faces])
    print(String(format: "%@  %dx%d  %d face(s)", name, image.width, image.height, faces.count))
}

let data = try JSONSerialization.data(withJSONObject: ["frames": output],
                                      options: [.sortedKeys])
let out = work.appendingPathComponent("vision.json")
try data.write(to: out)
print("wrote \(out.path)")
