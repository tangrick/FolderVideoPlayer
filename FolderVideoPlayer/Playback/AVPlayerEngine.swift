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
    /// Which `load` is the current one. A load is now asynchronous, so a user
    /// pressing Next twice quickly has two in flight, and the first must not
    /// hand its item to the player after the second has handed over its own.
    private var loadGeneration = 0

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

    /// Open a video.
    ///
    /// The asset is inspected BEFORE it is handed to the player, and off this
    /// thread. Handing over an untouched `AVPlayerItem(url:)` makes AVKit
    /// inspect it itself, on the main dispatch queue, in AVKit's own
    /// `_prepareAssetForInspectionIfNeeded` — which over SMB is however long
    /// the share takes to answer. Measured at launch on the maintainer's
    /// Diskstation, 2026-09-20: 7.0 s of main thread parked in `__psynch_cvwait`
    /// under that call, which macOS draws as a spinning wheel. Loading
    /// `duration` and `isPlayable` first means AVKit finds them already there.
    ///
    /// The error is deliberately NOT acted on: an unreadable file must still
    /// reach the player, because the `.failed` branch below is what turns it
    /// into a message and a skip. Refusing to hand it over would leave a black
    /// rectangle and no explanation — the thing this engine exists to avoid.
    func load(_ url: URL, startAt: Double) {
        watchers.removeAll()
        pendingStart = startAt
        loadGeneration &+= 1
        let generation = loadGeneration
        // Nothing should be drawing the video being left behind while the next
        // one is inspected.
        player.replaceCurrentItem(with: nil)
        player.volume = Float(max(0, min(100, volume))) / 100
        let asset = AVURLAsset(url: url)
        // Explicitly user-initiated: this is the video somebody is waiting to
        // see, and it is competing for the share with the folder scan, which
        // issues thousands of metadata calls of its own. At the default
        // priority it queued behind them.
        Task(priority: .userInitiated) { [weak self] in
            _ = try? await asset.load(.isPlayable, .duration)
            guard let self, generation == self.loadGeneration else { return }
            self.attach(AVPlayerItem(asset: asset))
        }
    }

    /// Hand the inspected item to the player and start watching it.
    private func attach(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)

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
        // Bumped so a load still being inspected cannot hand its item over
        // after the window has gone and put a video back on a stopped player.
        loadGeneration &+= 1
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
