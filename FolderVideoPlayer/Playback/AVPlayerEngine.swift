import AVFoundation
import AppKit
import Combine

/// The AVFoundation engine.
///
/// Reads .mp4, .m4v and .mov properly, and reports the rest as broken rather
/// than sitting on a black rectangle — which the player turns into a visible
/// message and a skip to the next video.
@MainActor
final class AVPlayerEngine: NSObject, PlayerEngine, ObservableObject {
    let player = AVPlayer()

    var onEnded: (() -> Void)?
    var onTime: ((Double) -> Void)?
    var onFailed: ((String) -> Void)?

    private var timeObserver: Any?
    private var watchers: Set<AnyCancellable> = []
    private var pendingStart: Double = 0
    private var wantsPlaying = false

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.onTime?(time.seconds) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    var isPlaying: Bool { player.rate != 0 }

    var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    var rate: Double = 1.0 {
        didSet { if isPlaying { player.rate = Float(rate) } }
    }

    var volume: Int = 100 {
        didSet { player.volume = Float(max(0, min(100, volume))) / 100 }
    }

    func load(_ url: URL, startAt: Double) {
        watchers.removeAll()
        pendingStart = startAt
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.volume = Float(max(0, min(100, volume))) / 100

        // A resume point can only be honoured once the item knows how long it
        // is; seeking before that lands nowhere.
        item.publisher(for: \.status)
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch status {
                    case .readyToPlay:
                        if self.pendingStart > 0 {
                            let target = self.pendingStart
                            self.pendingStart = 0
                            self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        if self.wantsPlaying { self.player.rate = Float(self.rate) }
                    case .failed:
                        let why = item.error?.localizedDescription
                            ?? "this format is not one AVFoundation reads"
                        self.onFailed?(why)
                    default:
                        break
                    }
                }
            }
            .store(in: &watchers)

        NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnded?() }
            }
            .store(in: &watchers)
    }

    func play() {
        wantsPlaying = true
        player.rate = Float(rate)
    }

    func pause() {
        wantsPlaying = false
        player.pause()
    }

    func stop() {
        wantsPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        watchers.removeAll()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        onTime?(target)
    }
}
