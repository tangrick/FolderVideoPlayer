// Reading a Core ML output array whatever its layout — the face models' reader.
//
// 2026-09-25: an M1 Mac on macOS 27 found no faces in videos that two Macs on
// macOS 26.6 found them in. `FaceDetector.floats` read every float32 output as
// one packed block; Core ML may pad rows for alignment, and a padded `[1, N, 1]`
// score output read that way is one real score followed by padding, so every
// face falls under the threshold and nothing says why.
//
//   1. a padded float32 array reads its real values, in logical order;
//   2. a packed float32 array still takes the fast path and reads the same;
//   3. float16 reads correctly;
//   4. `isPacked` ignores the stride of a size-1 dimension and catches padding.
//
// Run: Tests/run_face_output_layout.sh

@testable import FVPModel
import CoreML
import Foundation

@main
struct FaceOutputLayoutTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   \(what)" : "FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        let rows = 4, pad = 16
        let expected: [Float] = [0.25, 0.5, 0.75, 1.0]

        // 1. Rows padded to 16 elements, padding filled with junk.
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: rows * pad)
        padded.initialize(repeating: -99, count: rows * pad)
        for r in 0..<rows { padded[r * pad] = expected[r] }
        let a = try! MLMultiArray(dataPointer: padded, shape: [1, 4, 1], dataType: .float32,
                                  strides: [NSNumber(value: rows * pad), NSNumber(value: pad), 1])
        check(!FaceDetector.isPacked(a), "a padded [1,4,1] array is not packed")
        check(FaceDetector.floats(a) == expected, "a padded array reads its real values, not the padding")

        // 2. The same values, packed.
        let packed = try! MLMultiArray(shape: [1, 4, 1], dataType: .float32)
        for i in 0..<rows { packed[i] = NSNumber(value: expected[i]) }
        check(FaceDetector.isPacked(packed), "a freshly made array is packed")
        check(FaceDetector.floats(packed) == expected, "a packed array reads the same values")

        // 3. float16.
        let half = try! MLMultiArray(shape: [4], dataType: .float16)
        for i in 0..<rows { half[i] = NSNumber(value: expected[i]) }
        check(FaceDetector.floats(half) == expected, "float16 reads correctly")

        // 4. A size-1 dimension may carry any stride.
        let loose = try! MLMultiArray(dataPointer: padded, shape: [1, 1, 4], dataType: .float32,
                                      strides: [999, 999, 1])
        check(FaceDetector.isPacked(loose), "a size-1 dimension's stride does not matter")

        print(failures == 0 ? "ALL PASS face output layout" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
