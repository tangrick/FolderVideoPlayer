// Run: Tests/run_face_scan_progress.sh
// Real decoding verifies progress, a bounded whole-video sample, and cancellation.
import Foundation

@main
struct FaceScanProgressTest {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var updates: [(Int, Int)] = []
        let frames = try await FrameSampler.sample(url: url, maxFrames: 2) { done, total in
            updates.append((done, total))
        }
        precondition(!frames.isEmpty && frames.count <= 2)
        precondition(updates.first?.0 == 0)
        precondition(updates.last?.0 == updates.last?.1)
        precondition(updates.map { $0.0 } == Array(0...updates.last!.1))
        precondition(updates.allSatisfy { $0.1 == updates.first!.1 })
        precondition(frames.last!.time >= 5, "Sampling must reach beyond the beginning")
        print("ok progress counts decoded frames and sampling spans the video")

        let cancelled = Task {
            try await FrameSampler.sample(url: url) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await cancelled.value
            fatalError("Cancelled decoding returned results")
        } catch is CancellationError {
            print("ok cancellation interrupts decoding instead of returning partial results")
        }

        do {
            _ = try await FrameSampler.sample(url: url.appendingPathExtension("missing"))
            fatalError("Missing source returned faces")
        } catch {
            print("ok unreadable sources throw an error")
        }
    }
}
