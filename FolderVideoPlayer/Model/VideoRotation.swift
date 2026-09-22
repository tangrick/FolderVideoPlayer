import Foundation

/// How far to turn each video's picture, in quarter turns clockwise.
///
/// Display only: the file is never rewritten. Kept on this Mac, in
/// UserDefaults, not in the tags that publish to the Apple TV and the other
/// Macs — it is how this screen shows a clip filmed sideways, not a fact about
/// the clip.
@MainActor
final class VideoRotation: ObservableObject {
    private static let key = "videoRotations"

    @Published private(set) var turns: [String: Int]

    init() {
        turns = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
    }

    /// 0…3 quarter turns clockwise; 0 for a video never rotated.
    func quarterTurns(_ path: String) -> Int { turns[Paths.tagKey(path)] ?? 0 }

    func rotate(_ path: String, clockwise: Bool) {
        let key = Paths.tagKey(path)
        let next = ((turns[key] ?? 0) + (clockwise ? 1 : 3)) % 4
        if next == 0 { turns.removeValue(forKey: key) } else { turns[key] = next }
        UserDefaults.standard.set(turns, forKey: Self.key)
    }
}
