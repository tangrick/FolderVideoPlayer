import Foundation

/// What playback needs of an engine.
///
/// The app plays through AVFoundation, which is hardware accelerated and gives
/// the system's own fullscreen and Picture-in-Picture for free — but reads
/// only a handful of the formats this library holds. Everything the player
/// asks for goes through this protocol so a VLC-backed engine can be dropped
/// in beside it without the UI knowing.
@MainActor
protocol PlayerEngine: AnyObject {
    /// Playback reached the end of the current video by itself.
    var onEnded: (() -> Void)? { get set }
    /// The playhead moved; the argument is where it is now, in seconds.
    var onTime: ((Double) -> Void)? { get set }
    /// This video cannot be played, and why.
    var onFailed: ((String) -> Void)? { get set }

    var isPlaying: Bool { get }
    var position: Double { get }
    var duration: Double { get }
    var rate: Double { get set }
    /// 0…100, matching the volume slider and what gets saved.
    var volume: Int { get set }

    func load(_ url: URL, startAt: Double)
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double)
}
