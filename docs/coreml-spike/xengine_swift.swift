// Cross-engine check, part 2 (Swift side).
//
// Embeds the same four PNGs the Python script wrote, through the real
// VisionEmbedder + EmbeddingCache path, then reads Python's vectors and
// prints cosines. Gate: every cosine >= 0.999.
//
// Run: xengine_swift <model.mlpackage> <supportDir>

import Foundation
import AVFoundation
import CoreML

@main
struct XEngine {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: xengine_swift <model.mlpackage> <supportDir>")
            exit(2)
        }
        let modelPath = args[1], support = args[2]
        Paths.support = support
        let spike = "/tmp/mobileclip_spike/xengine"

        // Compile + install where VisionEmbedder expects it.
        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: modelPath))
        let dest = VisionEmbedder.modelURL(root: support)
        try? FileManager.default.createDirectory(atPath: dest.deletingLastPathComponent().path,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: compiled, to: dest)

        let embedder = try VisionEmbedder(root: support)

        // Load the PNGs as CGImages — the same type FrameSampler hands over.
        let names = try String(contentsOfFile: spike + "/names.txt", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        var swiftVecs: [String: [Float]] = [:]
        for name in names {
            let url = URL(fileURLWithPath: spike + "/\(name).png")
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            let frame = FrameSampler.SampledFrame(index: 0, time: 0, image: img)
            let out = try await embedder.embed([frame])
            swiftVecs[name] = out[0].vector
        }

        // Read Python's vectors: raw little-endian float64, [4,512], row
        // order = names order.
        let raw = try Data(contentsOf: URL(fileURLWithPath: spike + "/python_vecs.f64"))
        let doubles = raw.withUnsafeBytes { buf -> [Double] in
            let n = buf.count / 8
            return (0..<n).map { buf.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) }
        }
        precondition(doubles.count == names.count * 512,
                     "expected \(names.count * 512) doubles, got \(doubles.count)")
        var ok = true
        print("name     cosine    maxΔ")
        for (i, name) in names.enumerated() {
            let py = Array(doubles[(i*512)..<(i*512+512)])
            let sw = swiftVecs[name]!
            // cosine
            var dot = 0.0, n1 = 0.0, n2 = 0.0
            for j in 0..<512 {
                dot += Double(py[j]) * Double(sw[j]); n1 += Double(py[j])*Double(py[j]); n2 += Double(sw[j])*Double(sw[j])
            }
            let cos = dot / (n1.squareRoot() * n2.squareRoot())
            var maxd = 0.0
            for j in 0..<512 { maxd = max(maxd, abs(Double(py[j]) - Double(sw[j]))) }
            let pass = cos >= 0.999
            ok = ok && pass
            print("\(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%.5f", cos))  \(String(format: "%.5f", maxd)) \(pass ? "ok" : "FAIL")")
        }
        print(ok ? "ALL PASS" : "FAILURES")
        exit(ok ? 0 : 1)
    }
}
