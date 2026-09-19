// Verifies AICapability reports honestly when the machine is bare.
//
// The whole point of the capability layer is the DMG-on-a-stranger's-Mac case,
// which cannot be tested by running the app here — this Mac has everything.
// So the probe's logic is exercised against a scratch support dir with no
// models in it, and against candidate lists that are deliberately wrong.

import Foundation

// Mirrors AICapability's shape closely enough to test the decision logic
// without pulling the whole app in. Kept in step by hand; if AICapability
// grows a feature this must too.
func check(_ name: String, _ cond: Bool) {
    print(cond ? "ok   \(name)" : "FAIL \(name)")
    if !cond { exit(1) }
}

let fm = FileManager.default
let scratch = NSTemporaryDirectory() + "fvp-ai-probe-\(UUID().uuidString)"
try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: scratch) }

// --- first executable of a list -----------------------------------------
func firstExecutable(_ paths: [String]) -> String? {
    paths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

check("a list of nonexistent pythons finds nothing",
      firstExecutable(["/nope/python3", "/also/nope"]) == nil)
check("a real executable is found",
      firstExecutable(["/nope/python3", "/bin/sh"]) == "/bin/sh")

// --- model presence ------------------------------------------------------
let modelsDir = scratch + "/models"
try? fm.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)

func hasVisionModel(_ dir: String) -> Bool {
    let hf = (dir as NSString).appendingPathComponent("hf")
    return ((try? fm.contentsOfDirectory(atPath: hf)) ?? []).isEmpty == false
}

check("no hf directory means no vision model", !hasVisionModel(modelsDir))

try? fm.createDirectory(atPath: modelsDir + "/hf", withIntermediateDirectories: true)
check("an EMPTY hf directory still means no vision model", !hasVisionModel(modelsDir))

fm.createFile(atPath: modelsDir + "/hf/model.bin", contents: Data("x".utf8))
check("a populated hf directory means the model is there", hasVisionModel(modelsDir))

// --- face models are all-or-nothing -------------------------------------
func hasFaceModels(_ dir: String) -> Bool {
    for file in ["face_detection_yunet_2023mar.onnx",
                 "face_recognition_sface_2021dec.onnx"] {
        if !fm.fileExists(atPath: (dir as NSString).appendingPathComponent(file)) {
            return false
        }
    }
    return true
}

check("no face models", !hasFaceModels(modelsDir))
fm.createFile(atPath: modelsDir + "/face_detection_yunet_2023mar.onnx",
              contents: Data("x".utf8))
check("ONE face model is not enough — both are needed", !hasFaceModels(modelsDir))
fm.createFile(atPath: modelsDir + "/face_recognition_sface_2021dec.onnx",
              contents: Data("x".utf8))
check("both face models present", hasFaceModels(modelsDir))

// --- footprint ------------------------------------------------------------
func footprint(_ dir: String) -> Int64 {
    let url = URL(fileURLWithPath: dir)
    guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in walker {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    return total
}

check("footprint counts the files we made", footprint(modelsDir) == 3)
check("footprint of a missing directory is zero", footprint(scratch + "/gone") == 0)

print("\nALL PASS")
