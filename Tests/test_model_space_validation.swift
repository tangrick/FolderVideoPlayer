@testable import FVPModel
import Foundation
import CryptoKit

@main struct ModelSpaceValidationTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fvp-marker-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("tags"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let marker = URL(fileURLWithPath: ModelSpace.digestFile(root: root.path))
        var failures = 0
        func check(_ name: String, _ value: Bool) {
            print("\(value ? "ok" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        func refuses(_ data: Data) throws -> Bool {
            try data.write(to: marker)
            do { _ = try ModelSpace.readForInference(root: root.path); return false }
            catch { return (try? Data(contentsOf: marker)) == data }
        }
        check("absent marker preserves legacy installation", try ModelSpace.readForInference(root: root.path) == nil)
        let valid = ModelSpace(adapter: "siglip2-base-v1", digest: String(repeating: "a", count: 64), dim: 768,
                               preprocess: ModelSpace.declaredPreprocess)
        try JSONEncoder().encode(valid).write(to: marker)
        check("current adapter identity is accepted", try ModelSpace.readForInference(root: root.path) == valid)
        var legacy = valid
        legacy.preprocess = nil
        try JSONEncoder().encode(legacy).write(to: marker)
        check("older marker without preprocessing remains compatible", try ModelSpace.readForInference(root: root.path) == legacy)
        for text in ["", "{", "null", "{}"] {
            check("malformed marker is refused and preserved: \(text)", try refuses(Data(text.utf8)))
        }
        for digest in ["../other", String(repeating: "z", count: 64), String(repeating: "a", count: 63)] {
            var changed = valid; changed.digest = digest
            check("invalid digest is refused", try refuses(JSONEncoder().encode(changed)))
        }
        var wrong = valid; wrong.dim = 512
        check("wrong embedding width is refused", try refuses(JSONEncoder().encode(wrong)))
        wrong = valid; wrong.adapter = "yunet-sface-v1"
        check("another known adapter cannot impersonate the visual encoder", try refuses(JSONEncoder().encode(wrong)))
        wrong = valid; wrong.preprocess = "unsupported-resize"
        check("unsupported preprocessing is refused", try refuses(JSONEncoder().encode(wrong)))
        check("oversized marker is refused", try refuses(Data(repeating: 32, count: 65_537)))
        try fm.removeItem(at: marker)
        try fm.createSymbolicLink(atPath: marker.path, withDestinationPath: root.appendingPathComponent("missing").path)
        var rejectedLink = false
        do { _ = try ModelSpace.readForInference(root: root.path) } catch { rejectedLink = true }
        check("dangling marker link is not treated as absent", rejectedLink)
        let tower = root.appendingPathComponent("tower")
        try fm.createDirectory(at: tower, withIntermediateDirectories: true)
        let weights = Data(repeating: 173, count: 3_145_745)
        try weights.write(to: tower.appendingPathComponent("weights.bin"))
        var reference = SHA256()
        reference.update(data: Data("model-space-v1:weights.bin:\(weights.count)\n".utf8))
        reference.update(data: weights)
        let expected = reference.finalize().map { String(format: "%02x", $0) }.joined()
        check("chunked hashing preserves the existing identity across chunk boundaries",
              ModelSpace.digestOfDirectory(at: tower) == expected)
        check("missing model tree has no identity", ModelSpace.digestOfDirectory(at: root.appendingPathComponent("absent")) == nil)
        exit(failures == 0 ? 0 : 1)
    }
}
