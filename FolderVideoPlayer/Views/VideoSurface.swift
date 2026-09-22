import AVKit
import SwiftUI

/// The picture itself. AVPlayerView draws it with the system's own layer —
/// with its controls off, because the app draws its own bar underneath.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    /// Quarter turns clockwise, from `VideoRotation`. Display only.
    var quarterTurns = 0

    func makeNSView(context: Context) -> RotatingPlayerView {
        let holder = RotatingPlayerView()
        let view = holder.playerView
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        // Live Text / Visual Look Up on paused frames. AVKit's default is YES:
        // every pause runs Vision over the frame hunting for text, objects and
        // people, and builds VisionKit's panel to offer them — which is where
        // the `VKCActionInfoView` / `VKFlippedGlassContainerView` constraint
        // conflicts in the console come from. Apple's views, Apple's bug, and
        // AppKit recovers, but the analysis itself is work this app does not
        // ask for: it already runs its own model over the frames of whatever
        // is playing, and a second unrelated pass on every pause competes with
        // it for the same cores.
        //
        // The cost of switching it off is real and deliberate: no selecting
        // text out of a paused frame, no right-click look-up of something on
        // screen. Turned off at the maintainer's request, 2026-09-17.
        view.allowsVideoFrameAnalysis = false
        holder.quarterTurns = quarterTurns
        return holder
    }

    func updateNSView(_ holder: RotatingPlayerView, context: Context) {
        if holder.playerView.player !== player { holder.playerView.player = player }
        holder.quarterTurns = quarterTurns
    }
}

/// Holds the player view and turns it. A sideways turn lays the player out
/// with width and height swapped, then rotates it about its centre, so the
/// picture is fitted to the space it actually ends up occupying.
final class RotatingPlayerView: NSView {
    let playerView = AVPlayerView()

    var quarterTurns = 0 {
        didSet { if quarterTurns != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(playerView)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func layout() {
        super.layout()
        let turns = ((quarterTurns % 4) + 4) % 4
        let sideways = turns % 2 == 1
        let size = sideways ? NSSize(width: bounds.height, height: bounds.width) : bounds.size
        playerView.frameCenterRotation = 0
        playerView.frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height)
        // AppKit's positive angle is anticlockwise; a turn here is clockwise.
        playerView.frameCenterRotation = -CGFloat(turns * 90)
    }
}
