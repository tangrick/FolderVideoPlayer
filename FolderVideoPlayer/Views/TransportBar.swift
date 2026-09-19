import SwiftUI

/// The scrubber on its own row above the buttons, the way the AppKit build
/// laid it out once AVKit stopped drawing one.
struct TransportBar: View {
    @ObservedObject var playback: PlaybackController
    /// Observed here and nowhere else — see `Playhead`.
    @ObservedObject var head: Playhead
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0

    private var length: Double { max(head.duration, 0) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(clock(scrubbing ? scrubPosition : head.position))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
                Slider(value: Binding(
                    get: { scrubbing ? scrubPosition : min(head.position, max(length, 0.01)) },
                    set: { scrubPosition = $0 }
                ), in: 0...max(length, 0.01), onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { playback.seek(to: scrubPosition) }
                })
                .disabled(length <= 0)
                .accessibilityLabel("Position")
                .accessibilityValue("\(clock(head.position)) of \(clock(length))")
                Text(clock(length))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .leading)
            }

            HStack(spacing: 10) {
                if !app.fullScreen {
                    Button { app.showLibrary.toggle() } label: {
                        Label("Library", systemImage: "sidebar.leading")
                    }
                    .help("Show or hide the library (⌘N)")
                    .accessibilityLabel(app.showLibrary ? "Hide library" : "Show library")
                }

                Button {
                    app.showTranscriptPanel = false
                    app.showTagPanel.toggle()
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                .help("Tag what is playing (⌘T)")
                .accessibilityLabel(app.showTagPanel ? "Close the tag panel" : "Tag this video")

                // What was said, and where — reads the profile's store, so it
                // shows a transcript made in any session, not just this one.
                Button {
                    app.showTagPanel = false
                    app.showTranscriptPanel.toggle()
                } label: {
                    Label("Transcript", systemImage: "captions.bubble")
                }
                .help("Read and search what was said")
                .accessibilityLabel(app.showTranscriptPanel ? "Close the transcript" : "Read the transcript")

                // Stars: 1–5 on what is playing, click the lit star again
                // to clear. The same rating the row menus and the Tags menu
                // set, and the sidebar's Stars section lists.
                StarRatingControl(current: currentRating) { stars in
                    if let path = playback.currentPath { library.setRating(stars, for: path) }
                }
                .disabled(playback.currentPath == nil)
                .help("Rate this video")

                Spacer(minLength: 8)

                Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous video (↑)")
                    .accessibilityLabel("Previous video")
                Button { playback.skip(-Double(library.skipSeconds)) } label: {
                    Image(systemName: Self.skipSymbol(library.skipSeconds, forward: false))
                }
                .help("Back \(library.skipSeconds)s (←)")
                .accessibilityLabel("Back \(library.skipSeconds) seconds")
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: head.playing ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(head.playing ? "Pause (space)" : "Play (space)")
                .accessibilityLabel(head.playing ? "Pause" : "Play")
                Button { playback.skip(Double(library.skipSeconds)) } label: {
                    Image(systemName: Self.skipSymbol(library.skipSeconds, forward: true))
                }
                .help("Forward \(library.skipSeconds)s (→)")
                .accessibilityLabel("Forward \(library.skipSeconds) seconds")
                Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                    .help("Next video (↓)")
                    .accessibilityLabel("Next video")

                Spacer(minLength: 8)

                Picker("", selection: Binding(
                    get: { library.order },
                    set: { library.order = $0; if $0 == .shuffle { playback.reshuffle(after: playback.index) } }
                )) {
                    ForEach(PlayOrder.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                .help("What happens at the end of a video")
                .accessibilityLabel("Play order")

                Picker("", selection: Binding(
                    get: { library.speed },
                    set: { playback.setSpeed($0) }
                )) {
                    ForEach(Tuning.speeds, id: \.self) { speed in
                        Text(speed == 1 ? "1×" : "\(speed.formatted())×").tag(speed)
                    }
                }
                .labelsHidden()
                .frame(width: 74)
                .help("Playback speed")
                .accessibilityLabel("Playback speed")

                HStack(spacing: 4) {
                    Image(systemName: library.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(library.volume) },
                        set: { playback.setVolume(Int($0)) }
                    ), in: 0...100)
                    .frame(width: 90)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(library.volume) percent")
                }
                .help("Volume — \(library.volume)%")

                // The playlist's own switch, at the end of the bar nearest
                // the panel it opens — as the library's sits nearest that one.
                // Full screen has no panels, and gets the way out instead.
                Button {
                    if app.fullScreen { app.toggleFullScreen() } else { app.showPlaylist.toggle() }
                } label: {
                    Label(app.fullScreen ? "Leave Full Screen" : "Playlist",
                          systemImage: app.fullScreen
                              ? "arrow.down.right.and.arrow.up.left" : "sidebar.trailing")
                }
                .help(app.fullScreen ? "Leave full screen (⌘F)" : "Show or hide the playlist (⌘L)")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The SF Symbol for a skip step. 15, 30 and 60 have their own
    /// glyphs; 5 and 10 do not, so they take the nearest one that does —
    /// the button's tooltip always carries the real number.
    static func skipSymbol(_ seconds: Int, forward: Bool) -> String {
        switch seconds {
        case 15: return forward ? "goforward.15" : "gobackward.15"
        case 30: return forward ? "goforward.30" : "gobackward.30"
        case 60: return forward ? "goforward.60" : "gobackward.60"
        default: return forward ? "goforward" : "gobackward"
        }
    }

    private var currentRating: Int {
        playback.currentPath.map { library.rating($0) } ?? 0
    }
}
