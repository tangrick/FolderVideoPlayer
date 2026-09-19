import AVKit
import SwiftUI

/// The picture itself. AVPlayerView draws it with the system's own layer —
/// with its controls off, because the app draws its own bar underneath.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
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
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
