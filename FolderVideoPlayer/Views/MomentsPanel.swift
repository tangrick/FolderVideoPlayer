import SwiftUI

/// The moments marked in the video that is playing: jump to one, name it, note
/// it, turn it into a stretch, export that stretch as a clip, or let it go.
///
/// Shares the bottom slot with the tag and transcript panels. Everything here
/// is about THIS video; the markers on the scrubber show the same moments.
struct MomentsPanel: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var moments: MomentStore
    @Environment(\.openWindow) private var openWindow
    let playback: PlaybackController

    private var path: String? { playback.currentPath }
    private var list: [Moment] { path.map { moments.moments(for: $0) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Moments").font(.headline)
                if !list.isEmpty {
                    Text("\(list.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Add Moment") { addHere() }
                    .controlSize(.small)
                    .disabled(path == nil)
                    .help("Mark the playhead (⌘B)")
                if let gone = moments.lastDeleted {
                    Button("Undo Delete") { moments.undoDelete() }
                        .controlSize(.small)
                        .help("Bring back “\(gone.title)”")
                }
                if let problem = moments.problem {
                    Text(problem).font(.callout).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Button { app.showMomentsPanel = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close moments")
                .accessibilityLabel("Close moments")
            }
            if list.isEmpty {
                Text(path == nil ? "Nothing is playing."
                     : "No moments in this video yet. Press Add Moment — or ⌘B — at a point worth coming back to.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(list) { moment in
                            MomentRow(moment: moment, playback: playback,
                                      exportClip: { exportClip(moment) })
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
    }

    private func addHere() {
        guard let path else { return }
        moments.add(path: path, at: playback.position)
    }

    /// A ranged moment as its own file: Prepare for Sharing, aimed at this
    /// video and already trimmed to the range — the same copy-never-change
    /// machinery, rather than a second exporter.
    private func exportClip(_ moment: Moment) {
        guard let path, let end = moment.end else { return }
        app.shareTrim = moment.start...end
        app.shareTargets = [path]
        openWindow(id: "share-prepare")
    }
}

/// One moment: its time (a jump), its title and note (edited in place), its
/// range, and what can be done with it.
private struct MomentRow: View {
    @EnvironmentObject private var moments: MomentStore
    let moment: Moment
    let playback: PlaybackController
    let exportClip: () -> Void

    @State private var title = ""
    @State private var note = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { playback.seek(to: moment.start) } label: {
                Text(timeLabel).font(.callout.monospacedDigit())
            }
            .buttonStyle(.link)
            .help("Play from \(momentClock(moment.start))")
            .accessibilityLabel("Go to \(timeLabel)")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .onSubmit(save)
                TextField("Note", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onSubmit(save)
            }
            Spacer(minLength: 4)
            if moment.source != .manual {
                Image(systemName: moment.source == .transcript ? "captions.bubble" : "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(moment.source == .transcript ? "Made from the transcript" : "Made from what the AI saw")
            }
            Menu {
                Button(moment.isRange ? "Set End at Playhead" : "End Here (Make a Range)") { setEnd() }
                if moment.isRange {
                    Button("Clear End") { var m = moment; m.end = nil; moments.update(m) }
                }
                Button("Start at Playhead") {
                    var m = moment
                    m.start = playback.position
                    moments.update(m)
                }
                Divider()
                Button("Export Clip…", action: exportClip)
                    .disabled(!moment.isRange)
                Divider()
                Button("Delete", role: .destructive) { moments.delete(moment.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Moment actions")
        }
        .padding(.vertical, 2)
        .onAppear { title = moment.title; note = moment.note }
        .onChange(of: moment) { _, new in title = new.title; note = new.note }
    }

    private var timeLabel: String {
        moment.end.map { "\(momentClock(moment.start))–\(momentClock($0))" } ?? momentClock(moment.start)
    }

    private func save() {
        var m = moment
        m.title = title
        m.note = note
        if !moments.update(m) { title = moment.title }
    }

    private func setEnd() {
        var m = moment
        m.end = playback.position
        moments.update(m)
    }
}

/// The moments of the playing video as ticks along the scrubber; a click
/// jumps to one. Drawn over the slider's track, never in the way of dragging it
/// except exactly on a tick.
struct MomentMarkers: View {
    let moments: [Moment]
    let length: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            // The slider's knob keeps its centre about 10pt inside each end.
            let inset: CGFloat = 10
            let width = max(proxy.size.width - inset * 2, 1)
            ForEach(moments) { moment in
                let x = inset + width * CGFloat(min(max(moment.start / length, 0), 1))
                if let end = moment.end {
                    let x2 = inset + width * CGFloat(min(max(end / length, 0), 1))
                    Capsule()
                        .fill(Color.orange.opacity(0.35))
                        .frame(width: max(x2 - x, 3), height: 4)
                        .position(x: (x + x2) / 2, y: proxy.size.height / 2 + 7)
                        .allowsHitTesting(false)
                }
                Button { seek(moment.start) } label: {
                    Capsule().fill(Color.orange).frame(width: 3, height: 10)
                        .padding(.horizontal, 3)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .position(x: x, y: proxy.size.height / 2 + 7)
                .help("\(moment.title) — \(momentClock(moment.start))")
                .accessibilityLabel("Moment: \(moment.title) at \(momentClock(moment.start))")
            }
        }
    }
}
