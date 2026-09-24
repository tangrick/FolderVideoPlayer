// The face engine, checked against the Python-era one it replaces.
//
// Face recognition shipped on `cv2.FaceDetectorYN` (detect) + `cv2.alignCrop`
// (align) + `cv2.FaceRecognizerSF` (embed), all ONNX through a child process.
// Phase 6 ports all three to Core ML — but the only reason the port is allowed
// to exist is that `FACE_MATCH_COSINE = 0.30` was calibrated on crops made the
// YuNet way (pitfall 28: the whole margin is 0.026). Vision's landmarks were
// measured, rejected and are not used, precisely because they move the crop.
//
// So this test refuses to check "the vectors are close". It checks, in order:
//
//   1. **the transform** — Umeyama onto the ArcFace template, to float64, so a
//      sign flip or a reflection cannot pass as rounding;
//   2. **the padding** — frames go in at their own size padded up to /32, the
//      OpenCV rule that is easy to get wrong and costs 178 px of box error;
//   3. **the NMS** — on INTEGER boxes, because the truncation changes which
//      boxes survive near the threshold;
//   4. **the detections** — boxes, landmarks and scores against cv2's own;
//   5. **the crop** — pixels against the crop cv2 actually wrote;
//   6. **the vectors** — cosines against onnxruntime's, and the same decision
//      at 0.30 for every pair.
//
// The fixture (`docs/coreml-spike/face_engine_fixture.py`) carries the frames,
// the reference detections, the reference crops and the reference vectors, and
// takes its `match_cosine` from `engine.py` itself — so the threshold the app
// compares against is checked against the one the engine ships, not a copy.
//
// Run: Tests/run_face_engine.sh

@testable import FVPModel
import Foundation

import CoreGraphics
import CoreML
import ImageIO

@main
struct FaceEngineTest {

    struct ReferenceFace {
        let frame: String
        let values: [Double]            // x, y, w, h, 10 landmarks, score — cv2's layout
        let cropIndex: Int

        var score: Double { values[14] }
        var box: [Double] { Array(values[0..<4]) }
        /// Right eye, left eye, nose, right mouth, left mouth — the model's own
        /// order, which is the order the template is paired against.
        var landmarks: [CGPoint] {
            (0..<5).map { CGPoint(x: values[4 + 2 * $0], y: values[5 + 2 * $0]) }
        }
    }

    static func main() async throws {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "ok   \(name)" : "FAIL \(name)")
            if !cond { failures += 1 }
        }
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }
        func checkClose(_ name: String, _ got: Double, _ want: Double, _ tol: Double) {
            let ok = abs(got - want) <= tol
            print(ok ? "ok   \(name)" : "FAIL \(name) — got \(got), want \(want)")
            if !ok { failures += 1 }
        }
        func skips(_ reason: String) -> Never {
            print("SKIP face engine — \(reason)")
            exit(failures == 0 ? 0 : 1)
        }

        // --- 1. the transform, with no model and no fixture in the way -------

        let expectedTemplate: [CGPoint] = [
            CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
            CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
            CGPoint(x: 70.7299, y: 92.2041),
        ]
        check("the template is the ArcFace five points",
              FaceAlignment.template.count == 5
                  && zip(FaceAlignment.template, expectedTemplate).allSatisfy {
                      abs($0.x - $1.x) < 1e-4 && abs($0.y - $1.y) < 1e-4
                  })
        checkEqual("the crop side is the one the embedder declares",
                   FaceAlignment.side, SFaceEmbedder.inputSide)
        checkEqual("the embedder's dimension is SFace's", SFaceEmbedder.dim, 128)
        checkEqual("the match threshold is the engine's", SFaceEmbedder.matchCosine, 0.30)

        // An off-centre, asymmetric, slightly rotated set: a reflection or a
        // transposed rotation shows up here and nowhere else.
        let synthetic = [CGPoint(x: 40, y: 60), CGPoint(x: 95, y: 58),
                         CGPoint(x: 68, y: 86), CGPoint(x: 48, y: 116),
                         CGPoint(x: 92, y: 114)]
        // docs/coreml-spike/face_align_parity.py's own umeyama(), to float64.
        let wanted = (a: 0.69127516, b: 0.02570467, c: -0.02570467,
                      d: 0.69127516, tx: 10.835849651741285, ty: 10.134755547263666)
        if let m = FaceAlignment.matrix(landmarks: synthetic) {
            let worst = [abs(Double(m.a) - wanted.a), abs(Double(m.b) - wanted.b),
                         abs(Double(m.c) - wanted.c), abs(Double(m.d) - wanted.d),
                         abs(Double(m.tx) - wanted.tx), abs(Double(m.ty) - wanted.ty)].max()!
            // Not zero: the two implementations sum the covariance in a
            // different order, so float64 rounding differs in the last digits.
            check("the similarity transform matches the Python Umeyama (max |Δ| \(worst))",
                  worst < 1e-7)
            check("the transform carries no reflection (det \(Double(m.a) * Double(m.d) - Double(m.b) * Double(m.c)))",
                  Double(m.a) * Double(m.d) - Double(m.b) * Double(m.c) > 0)
        } else {
            check("the similarity transform matches the Python Umeyama", false)
        }
        check("five points that are not five points produce no transform",
              FaceAlignment.matrix(landmarks: [CGPoint(x: 1, y: 2)]) == nil)

        // --- 2. the padding ---------------------------------------------------

        let padCases: [(Int, Int)] = [(1, 32), (31, 32), (32, 32), (33, 64),
                                      (576, 576), (577, 608), (640, 640), (641, 672),
                                      (1024, 1024), (1600, 1600)]
        check("a frame is padded up to a multiple of 32",
              padCases.allSatisfy { FaceDetector.padded($0.0) == $0.1 })
        check("...and never beyond it",
              [32, 64, 96, 320, 576, 608, 1024].allSatisfy { FaceDetector.padded($0) == $0 })
        checkEqual("OpenCV's score threshold is the ported one",
                   FaceDetector.scoreThreshold, 0.7)
        checkEqual("OpenCV's NMS threshold is the ported one",
                   FaceDetector.nmsThreshold, 0.3)

        // --- 3. NMS on integer boxes -----------------------------------------

        func face(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                  _ score: Double) -> DetectedFace {
            DetectedFace(x: x, y: y, width: w, height: h, landmarks: [], score: score)
        }
        let overlapping = FaceDetector.nonMaximumSuppression(
            [face(0, 0, 10, 10, 0.9), face(1, 1, 10, 10, 0.8)], threshold: 0.3)
        checkEqual("NMS drops the weaker of two overlapping boxes",
                   overlapping.count, 1)
        check("...and keeps the stronger one", overlapping.first?.score == 0.9)
        let apart = FaceDetector.nonMaximumSuppression(
            [face(0, 0, 10, 10, 0.9), face(50, 50, 10, 10, 0.5)], threshold: 0.3)
        checkEqual("NMS keeps a box that barely overlaps", apart.count, 2)
        // float IoU 0.30298 (suppressed) vs integer IoU 0.29891 (kept). Getting
        // this pair backwards is how "NMS on floats" looks like a working port.
        let straddling = FaceDetector.nonMaximumSuppression(
            [face(1.5, 0, 63.5, 60, 0.9), face(31.4, 0, 72, 67.5, 0.8)], threshold: 0.3)
        checkEqual("NMS truncates boxes before measuring overlap (2, not 1)",
                   straddling.count, 2)

        // --- 4. the fixture ---------------------------------------------------

        let args = CommandLine.arguments
        let fixturePath = args.count > 1 ? args[1] : defaultFixture()
        let modelsDir = args.count > 2 ? args[2] : defaultModelsDir()

        guard let raw = FileManager.default.contents(atPath: fixturePath),
              let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let frames = root["frames"] as? [[String: Any]],
              let cropRows = root["crops"] as? [[String: Any]] else {
            skips("no fixture at \(fixturePath)\n     build it with: "
                  + "/opt/anaconda3/bin/python3 docs/coreml-spike/face_engine_fixture.py")
        }
        let fixtureDir = (fixturePath as NSString).deletingLastPathComponent

        // The threshold the fixture recorded is engine.py's, so a drifting
        // Swift constant fails here instead of silently re-tuning faces.
        checkEqual("the fixture's match cosine is the ported constant",
                   SFaceEmbedder.matchCosine, (root["match_cosine"] as? NSNumber)?.doubleValue ?? -1)
        checkEqual("the fixture's crop side is the ported one",
                   FaceAlignment.side, (root["alignment_side"] as? NSNumber)?.intValue ?? -1)
        checkEqual("the fixture's score threshold is the ported one",
                   FaceDetector.scoreThreshold,
                   (root["score_threshold"] as? NSNumber)?.doubleValue ?? -1)
        checkEqual("the fixture's NMS threshold is the ported one",
                   FaceDetector.nmsThreshold,
                   (root["nms_threshold"] as? NSNumber)?.doubleValue ?? -1)

        // Reference vectors, unit-normalised by the Python side.
        var referenceVectors: [Int: [Float]] = [:]
        var referenceCrops: [Int: String] = [:]
        var vectorsOK = false
        for (i, row) in cropRows.enumerated() {
            guard let file = row["file"] as? String,
                  let b64 = row["vector"] as? String,
                  let data = Data(base64Encoded: b64), data.count % 4 == 0 else { continue }
            var vector = [Float](repeating: 0, count: data.count / 4)
            _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            referenceVectors[i] = vector
            referenceCrops[i] = file
        }
        vectorsOK = referenceVectors.count == cropRows.count && !cropRows.isEmpty
        check("the fixture carries a vector for every crop (\(referenceVectors.count))", vectorsOK)
        check("...each the model's width",
              referenceVectors.values.allSatisfy { $0.count == SFaceEmbedder.dim })

        var reference: [ReferenceFace] = []
        for frame in frames {
            let name = frame["file"] as? String ?? ""
            for row in (frame["faces"] as? [Any]) ?? [] {
                let values = ((row as? [NSNumber]) ?? []).map { $0.doubleValue }
                guard values.count == 15 else { continue }
                reference.append(ReferenceFace(frame: name, values: values,
                                               cropIndex: reference.count))
            }
        }
        check("the fixture describes the faces it detected (\(reference.count))",
              reference.count == cropRows.count)

        // --- models: compile the packages into a scratch root -----------------

        guard let yunet = packagePath(modelsDir, "yunet"),
              let sface = packagePath(modelsDir, "sface") else {
            skips("no face models in \(modelsDir)\n     need yunet.mlpackage + sface.mlpackage "
                  + "(build them with docs/coreml-spike/convert_yunet.py and convert_sface_torch.py)")
        }
        let scratch = NSTemporaryDirectory() + "fvp-face-engine-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch + "/tags",
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        for package in [yunet, sface] {
            let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: package))
            let name = (package as NSString).lastPathComponent
                .replacingOccurrences(of: ".mlpackage", with: ".mlmodelc")
            let dest = URL(fileURLWithPath: (scratch + "/tags/" + name))
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: compiled, to: dest)
        }
        check("the detector is installed where it is looked for",
              FaceDetector.isInstalled(root: scratch))
        check("the embedder is installed where it is looked for",
              SFaceEmbedder.isInstalled(root: scratch))

        let detector = try FaceDetector(root: scratch)
        let embedder = try SFaceEmbedder(root: scratch)

        // --- 5. detection, crop, vectors --------------------------------------

        var countMismatches: [String] = []
        var maxBox = 0.0, maxLandmark = 0.0, maxScore = 0.0
        var maxCropDelta = 0.0, worstCrop = ""
        var minAlignedCosine = 1.0, worstAligned = ""
        var minPipelineCosine = 1.0, worstPipeline = ""
        var swiftVectors: [Int: [Float]] = [:]
        var perFace: [String] = []

        for frame in frames {
            let name = frame["file"] as? String ?? ""
            let path = (fixtureDir as NSString).appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                countMismatches.append("\(name) (unreadable)")
                continue
            }

            let wanted = reference.filter { $0.frame == name }.sorted { $0.score > $1.score }
            let found = try await detector.detect(image).sorted { $0.score > $1.score }
            if wanted.count != found.count {
                countMismatches.append("\(name) (cv2 \(wanted.count), Core ML \(found.count))")
                continue
            }

            for (i, want) in wanted.enumerated() {
                let got = found[i]
                // cv2 sorts nothing, so pairing is by score rank on both sides.
                guard let j = reference.firstIndex(where: { $0.frame == name
                    && $0.values == want.values }) else { continue }
                let cropIndex = reference[j].cropIndex

                maxBox = max(maxBox, max(abs(got.x - want.box[0]), abs(got.y - want.box[1]),
                                         abs(got.width - want.box[2]), abs(got.height - want.box[3])))
                for (k, point) in want.landmarks.enumerated() {
                    maxLandmark = max(maxLandmark, abs(Double(got.landmarks[k].x) - Double(point.x)))
                    maxLandmark = max(maxLandmark, abs(Double(got.landmarks[k].y) - Double(point.y)))
                }
                maxScore = max(maxScore, abs(got.score - want.score))

                // (a) the crop cv2 wrote, re-made from cv2's own landmarks —
                // alignment alone, with the embedder out of the loop.
                guard let wantVector = referenceVectors[cropIndex],
                      let cropName = referenceCrops[cropIndex],
                      let aligned = FaceAlignment.crop(image, landmarks: want.landmarks) else {
                    countMismatches.append("\(name) face \(i) (no crop)")
                    continue
                }
                let alignedVector = try await embedder.embed(aligned)
                let alignedCosine = SFaceEmbedder.cosine(alignedVector, wantVector)

                if alignedCosine < minAlignedCosine {
                    minAlignedCosine = alignedCosine
                    worstAligned = "\(name) face \(i)"
                }

                // (b) pixels against the crop on disk. cv2 wrote it as a JPEG,
                // so this cannot be exact — but a rotated crop is ~40, not ~3.
                var delta = 0.0
                let jpeg = (fixtureDir as NSString).appendingPathComponent(cropName)
                if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: jpeg) as CFURL, nil),
                   let stored = CGImageSourceCreateImageAtIndex(src, 0, nil),
                   let a = bitmap(aligned), let b = bitmap(stored) {
                    delta = zip(a, b).map { abs(Double($0) - Double($1)) }.reduce(0, +)
                        / Double(a.count)
                    if delta > maxCropDelta {
                        maxCropDelta = delta
                        worstCrop = "\(name) face \(i)"
                    }
                }
                perFace.append("\(cropIndex)  \(name) face \(i)  cosine \(alignedCosine)  "
                    + "pixels \(delta)")

                // (c) the whole port end to end: our landmarks, our crop, our vector.
                if let own = FaceAlignment.crop(image, landmarks: got.landmarks) {
                    let ownVector = try await embedder.embed(own)
                    swiftVectors[cropIndex] = ownVector
                    let pipelineCosine = SFaceEmbedder.cosine(ownVector, wantVector)
                    if pipelineCosine < minPipelineCosine {
                        minPipelineCosine = pipelineCosine
                        worstPipeline = "\(name) face \(i)"
                    }
                }
            }
        }

        check("detection finds the same faces in every frame\(countMismatches.isEmpty ? "" : " — \(countMismatches)")",
              countMismatches.isEmpty)
        checkClose("detection boxes match cv2 (max |Δ| \(maxBox) px)", maxBox, 0, 0.01)
        checkClose("detection landmarks match cv2 (max |Δ| \(maxLandmark) px)", maxLandmark, 0, 0.01)
        checkClose("detection scores match cv2 (max |Δ| \(maxScore))", maxScore, 0, 1e-4)
        // 4.0 mean |Δ| over 255 is where cv2's JPEG compression of its own crop
        // lands (~1.2–1.7 here). A rotated, mirrored or half-pixel-shifted crop
        // is 40+, so the bar is far tighter than the failure it has to catch.
        check("the aligned crop reproduces cv2's pixels (worst mean |Δ| \(maxCropDelta) at \(worstCrop))",
              maxCropDelta < 4.0)
        // The bar follows the model, not the other way round: the shipped
        // float16 package's own distance from the ONNX reference was measured
        // at 1.237e-03 cosine on 24 real crops (convert_sface_torch.py prints
        // it as max|delta cos|), i.e. a floor of 0.99876 for ANY correct
        // caller — so a 0.9995 bar is unreachable, not strict. It failed here
        // first on frame_000 face 0 (0.99939), the face whose crop pixels agree
        // with cv2's best of all ten (mean |Δ| 0.914): that is how the gap is
        // known to be float16 rounding and not a crop defect. 0.9980 leaves
        // ~7e-04 of headroom over the floor, while every crop defect measured
        // here costs ≥0.015 (a half-pixel offset 0.015, Core Graphics' kernel
        // 0.017, a reflection more), so a real defect still misses by ~50×.
        check("...and embeds to cv2's vector (min cosine \(minAlignedCosine) at \(worstAligned))",
              minAlignedCosine >= 0.9980)
        check("the whole port — detect, align, embed — matches (min cosine \(minPipelineCosine) at \(worstPipeline))",
              minPipelineCosine >= 0.9980)

        // --- 5b. the cache key, and the registry that reads it --------------
        //
        // Everything above is resampled and therefore only *close* to cv2. The
        // cache key is not allowed to be close: a hash that differs by a stride
        // or a channel means re-scanning a library mints a second copy of every
        // face it has already seen. The fixture carries one crop where the
        // transform is a pure integer translation — no fractional weights
        // anywhere — so this is an equality, not a tolerance.
        Paths.support = scratch
        Paths.activeProfile = "gated"
        let faces = FaceRegistry(root: scratch, profile: "gated")

        let exactBlock = root["exact"] as? [String: Any]
        if let exact = exactBlock,
           let sourceFile = exact["source"] as? String,
           let points = exact["points"] as? [[NSNumber]],
           let wantHash = exact["hash"] as? String {
            let path = (fixtureDir as NSString).appendingPathComponent(sourceFile)
            let image = FaceRegistry.loadImage(path)
            let aligned = image.flatMap {
                FaceAlignment.align($0, landmarks: points.map {
                    CGPoint(x: $0[0].doubleValue, y: $0[1].doubleValue)
                })
            }
            check("the fixture's exact-crop case aligns", aligned != nil)
            checkEqual("the cache key is engine.py's own hash, byte for byte",
                       aligned.map { FaceRegistry.hash(of: $0.bgr) }, wantHash)
            checkEqual("...which is the engine's 32-character key", wantHash.count, 32)
        } else {
            check("the fixture carries an exact-crop case", false)
        }

        // Store → read back, and the thumbnail beside it. This is the pair of
        // writes every scan makes, and a vector that reads back at the wrong
        // length (or a `.f32` that is not 512 bytes) makes a bound face
        // unmatchable while looking perfectly installed.
        let sampleVector = (0..<FaceRegistry.dim).map { Float($0) / Float(FaceRegistry.dim) }
        let firstFrame = FaceRegistry.loadImage((fixtureDir as NSString)
            .appendingPathComponent(frames[0]["file"] as? String ?? ""))
        let sampleCrop = firstFrame.flatMap {
            FaceAlignment.align($0, landmarks: (frames[0]["faces"] as? [[NSNumber]] ?? [])
                .first.map { row in
                    (0..<5).map { CGPoint(x: row[4 + 2 * $0].doubleValue,
                                          y: row[5 + 2 * $0].doubleValue) }
                } ?? [])
        }
        check("a reference face can be re-cropped for the store round trip",
              sampleCrop != nil)
        if let sampleCrop {
            await faces.store(hash: "gatedface", vector: sampleVector, crop: sampleCrop.image)
            checkEqual("a stored vector reads back at the model's width",
                       faces.vector(for: "gatedface")?.count, FaceRegistry.dim)
            checkEqual("...with every value intact",
                       faces.vector(for: "gatedface"), sampleVector)
            check("a stored face has a thumbnail beside it",
                  faces.thumbnailExists("gatedface"))
        }
        check("a face that was never stored reads as absent, not as zeros",
              faces.vector(for: "nosuchface") == nil)

        // --- 5c. the whole registry path on real frames ----------------------

        let framePath = (fixtureDir as NSString)
            .appendingPathComponent(frames[0]["file"] as? String ?? "")
        do {
            let choices = try await faces.detectFaces(path: framePath)
            let detections = (frames[0]["faces"] as? [Any])?.count ?? 0
            check("detectFaces gives one choice per person, capped "
                  + "(\(choices.count) for \(detections) detections)",
                  !choices.isEmpty && choices.count <= min(detections, FaceRegistry.maxChoices))
            check("...each choice is a real cached face",
                  choices.allSatisfy { faces.vector(for: $0) != nil })
            check("...with a thumbnail to show the user",
                  choices.allSatisfy { faces.thumbnailExists($0) })
            check("...and no duplicates", Set(choices).count == choices.count)

            // set_photo is "here is a picture of them": the biggest face in it
            // becomes the person's thumbnail, which is what makes a People row
            // show a face at all.
            let photo = try await faces.setPhoto(name: "Gated Person", path: framePath)
            check("setPhoto finds a face in a frame that has one", photo != nil)
            if let photo {
                checkEqual("...and it leads that person's list",
                           faces.registry()["Gated Person"]?.first, photo)
                check("it has a thumbnail, or the row would draw a blank circle",
                      faces.thumbnailExists(photo))
                check("the person is then listed with one face",
                      faces.people().contains { $0.name == "Gated Person" && $0.faces == 1 })
            }

            // An image with nobody in it must leave the registry alone rather
            // than re-point the person's thumbnail at nothing.
            if let blank = exactBlock?["source"] as? String {
                let nobody = try await faces.setPhoto(
                    name: "Gated Person",
                    path: (fixtureDir as NSString).appendingPathComponent(blank))
                checkEqual("a picture with no face in it changes nothing", nobody, nil)
                checkEqual("...and the person still has their face",
                           faces.registry()["Gated Person"], [photo].compactMap { $0 })
            }

            var refused = false
            do {
                _ = try await faces.setPhoto(name: "Nobody At All", path: fixturePath)
            } catch { refused = true }
            check("a file that is not an image is refused, not guessed at", refused)
            checkEqual("...and no person was invented",
                       faces.registry()["Nobody At All"], nil)
        } catch {
            check("the registry path runs on a real frame — \(error)", false)
        }

        // --- 5d. where the bundle must put the models -------------------------
        //
        // The app finds these two packages at one path each, and the catalogue
        // tells the installer a different path per asset. Nothing in the
        // compiler connects the two, and until 6.5 nothing failed when they
        // disagreed: the bundle would install cleanly, `isInstalled` would keep
        // answering false, and the Faces row would offer Install forever — a
        // download that lands where the app never looks.
        //
        // The literals are checked on every run; the packed catalogue is checked
        // when one is on disk (it is build output, so a fresh clone has none).

        let detectorRelative = "tags/yunet.mlmodelc"
        let embedderRelative = "tags/sface.mlmodelc"
        check("the detector is read from \(detectorRelative)",
              FaceDetector.modelURL(root: "/root").path == "/root/" + detectorRelative)
        check("the embedder is read from \(embedderRelative)",
              SFaceEmbedder.modelURL(root: "/root").path == "/root/" + embedderRelative)

        if let path = ProcessInfo.processInfo.environment["FVP_BUNDLES"],
           let raw = FileManager.default.contents(atPath: path) {
            do {
                let manifest = try JSONDecoder().decode(AIBundleManifest.self, from: raw)
                let faces = manifest.bundles.filter { $0.capabilityFeature == .faces }
                check("the catalogue offers exactly one faces bundle", faces.count == 1)
                if let bundle = faces.first {
                    checkEqual("the faces bundle installs the two models the app reads",
                               bundle.assets.map(\.install).sorted(),
                               [detectorRelative, embedderRelative].sorted())
                    check("both faces assets are Core ML packages",
                          bundle.assets.allSatisfy { $0.kind == .coreMLPackage })
                    check("every faces asset carries a real digest and size",
                          bundle.assets.allSatisfy {
                              $0.sha256.count == 64
                                  && $0.sha256.allSatisfy(\.isHexDigit)
                                  && $0.bytes > 0
                          })
                    check("the faces bundle is the download the row reports "
                          + "(\(bundle.bytes) bytes)", bundle.bytes > 0)
                }
                // One bundle per feature: two rows claiming `faces` would make
                // which one Install fetches depend on array order.
                let features = manifest.bundles.compactMap(\.capabilityFeature)
                check("no two bundles claim the same feature",
                      Set(features).count == features.count)
            } catch {
                check("the packed catalogue parses — \(error)", false)
            }
        } else {
            skips("no packed catalogue to check\n     set FVP_BUNDLES to a dist/ai-bundles.json "
                  + "(pack one with docs/coreml-spike/pack_bundles.sh)")
        }

        // --- 6. every threshold decision --------------------------------------

        print("""

        per face — cosine to cv2's vector, then crop pixels against cv2's JPEG:
          \(perFace.joined(separator: "\n  "))
        """)

        check("the port produced a vector for every face (\(swiftVectors.count))",
              swiftVectors.count == cropRows.count)
        var pairs = 0, disagreements: [String] = []
        let indices = swiftVectors.keys.sorted()
        for i in indices {
            for j in indices where j > i {
                guard let wantA = referenceVectors[i], let wantB = referenceVectors[j],
                      let gotA = swiftVectors[i], let gotB = swiftVectors[j] else { continue }
                pairs += 1
                let want = SFaceEmbedder.cosine(wantA, wantB) >= SFaceEmbedder.matchCosine
                let got = SFaceEmbedder.cosine(gotA, gotB) >= SFaceEmbedder.matchCosine
                if want != got {
                    disagreements.append("\(i)-\(j): cv2 \(want ? "same" : "different"), "
                        + "Core ML \(got ? "same" : "different")")
                }
            }
        }
        check("every pair was compared (\(pairs))", pairs == cropRows.count * (cropRows.count - 1) / 2)
        check("the 0.30 decision is the same for every pair"
              + (disagreements.isEmpty ? "" : " — \(disagreements.joined(separator: "; "))"),
              disagreements.isEmpty)

        // --- report -----------------------------------------------------------

        print("""

        \(reference.count) faces in \(frames.count) frames ·
          max |Δ| box \(maxBox) px · landmarks \(maxLandmark) px · score \(maxScore)
          min cosine, alignment only  \(minAlignedCosine)
          min cosine, whole port      \(minPipelineCosine)
          crop pixels vs cv2          \(maxCropDelta) mean |Δ|
          \(pairs) pairs, \(disagreements.count) threshold disagreements
        """)

        if failures > 0 {
            print("\(failures) FAILED")
            exit(1)
        }
        exit(0)
    }

    // MARK: - helpers

    /// The fixture's own two candidate locations, because this workspace nests
    /// the scratch dirs under a second `fvp/` and the older scripts do not.
    static func firstExisting(_ candidates: [String]) -> String {
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return candidates[0]
    }

    static func defaultFixture() -> String {
        let home = NSHomeDirectory()
        let relative = "/face_engine/face_engine_fixture.json"
        let candidates = [home + "/fvp-coreml-models" + relative,
                          home + "/fvp/fvp-coreml-models" + relative]
        var path = firstExisting(candidates)
        if !path.hasSuffix(".json") {
            path += relative
        }
        return path
    }

    static func defaultModelsDir() -> String {
        let home = NSHomeDirectory()
        return firstExisting([home + "/fvp-coreml-models", home + "/fvp/fvp-coreml-models"])
    }

    /// The `.mlpackage` for a model, wherever the rig keeps it.
    static func packagePath(_ dir: String, _ name: String) -> String? {
        let path = (dir as NSString).appendingPathComponent("\(name).mlpackage")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// A CGImage as straight BGRX bytes, so two images can be compared without
    /// either one's colour space winning. Channel order is irrelevant as long as
    /// both sides go through this — which they do.
    static func bitmap(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The alpha byte is skipped: `premultipliedFirst` puts it in the way.
        return (0..<(width * height * 4)).compactMap { $0 % 4 == 3 ? nil : bytes[$0] }
    }
}
