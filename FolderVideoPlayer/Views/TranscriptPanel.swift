import SwiftUI

/// What was said in the video that is playing, in order, with a search box
/// over its lines.
///
/// Reading is the panel's usual job; Edit turns it into the transcript editor
/// in place (`TranscriptEditor`), and Done turns it back. It is about THIS video:
/// finding the videos a word is said in is the library panel's search
/// ("Find videos where it's said"), and while that search is the playlist this
/// panel opens already narrowed to the same words.
/// Lines are read back from the profile's store when the panel opens, so a film
/// transcribed last week still shows its words — the last transcription run in
/// this session is not the source of truth.
struct TranscriptPanel: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var journal: EvidenceJournal
    @EnvironmentObject private var moments: MomentStore
    let playback: PlaybackController

    /// The video whose transcript is being edited, or nil when reading.
    @State private var editing: String?
    @State private var typed = ""
    @State private var lines: [TranscriptLine] = []
    @State private var edited = false

    private var path: String? { playback.currentPath }
    private var query: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searching: Bool { !query.isEmpty }
    /// This video's lines containing every word typed, in any case. Filtered
    /// in memory: one video's transcript is small, and a substring match finds
    /// words inside Chinese text the way the store's search does.
    private var shown: [TranscriptLine] {
        guard searching else { return lines }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return lines.filter { line in
            let text = line.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
    private var transcribingThis: Bool { path != nil && app.transcribingPath == path }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let editing {
                TranscriptEditor(path: editing, playback: playback) { stopEditing() }
                    .id(editing)
            } else {
                header
                content
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .task(id: path) { reload() }
        .onChange(of: app.transcriptLines) { _, _ in reload() }
        .onChange(of: journal.transcriptEdits) { _, _ in reload() }
        .onAppear { takeEditRequest() }
        .onChange(of: app.transcriptEditTarget) { _, _ in takeEditRequest() }
        .onDisappear {
            // Closing the panel ends the edit. Unsaved work is not kept behind
            // a panel nobody can see.
            if editing != nil { stopEditing() }
        }
    }

    /// View ▸ Edit Transcript asks for the playing video; take it up if it has
    /// lines to edit.
    private func takeEditRequest() {
        guard let target = app.transcriptEditTarget else { return }
        app.transcriptEditTarget = nil
        guard editing == nil, !journal.transcript(for: target).isEmpty else {
            if editing == nil { app.jobNotice = "This video has no transcript to edit yet." }
            return
        }
        startEditing(target)
    }

    private func startEditing(_ target: String) {
        typed = ""
        editing = target
        app.transcriptEditing = true
    }

    private func stopEditing() {
        editing = nil
        app.transcriptEditing = false
        app.transcriptEditDirty = false
        reload()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Transcript").font(.headline)
            if transcribingThis, let progress = app.transcribeProgress {
                Text(progress.label)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if searching, !lines.isEmpty {
                Text("\(shown.count) of \(lines.count) lines")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if !lines.isEmpty {
                Text(edited ? "\(lines.count) lines · corrected" : "\(lines.count) lines")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(edited ? "This transcript has been corrected by hand" : "")
            }
            // Transcribing is never automatic — 646 MB of model and minutes of
            // compute should not start because a video was double-clicked — so
            // this is the way in. It lived beside the suggestion chips, which
            // hid it whenever a video had nothing suggested.
            if let path {
                if transcribingThis {
                    Button("Cancel") {
                        NotificationCenter.default.post(
                            name: AppModel.cancelTranscribeNotification, object: nil)
                    }
                    .controlSize(.small)
                    .help("Stop transcribing. Nothing is written for half a transcript.")
                } else {
                    if !lines.isEmpty {
                        Button("Edit") { startEditing(path) }
                        .controlSize(.small)
                        .help("Correct the words and times, split or merge lines, and export")
                        Menu("Export") {
                            ForEach(TranscriptExport.Format.allCases) { format in
                                Button(format.label) {
                                    TranscriptExporter.export(path: path, format: format,
                                                              journal: journal, app: app)
                                }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Save this transcript as subtitles, captions or text")
                    }
                    Button(lines.isEmpty ? "Transcribe" : "Transcribe Again") {
                        NotificationCenter.default.post(
                            name: AppModel.transcribeNotification, object: path)
                    }
                    .controlSize(.small)
                    .disabled(app.transcribingPath != nil || app.transcribeBatch != nil)
                    .help("Write down what is said in this video, with the times. The model runs on this Mac; nothing is uploaded.")
                }
            }
            Spacer(minLength: 12)
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search this video", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button { app.showTranscriptPanel = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close the transcript")
            .accessibilityLabel("Close the transcript")
        }
    }

    @ViewBuilder private var content: some View {
        if shown.isEmpty {
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
            }
            .frame(maxHeight: 190)
        }
    }

    private func row(_ line: TranscriptLine) -> some View {
        Button {
            playback.seek(to: line.start)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.clock(line.start))
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                Text(line.text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(isSpeaking(line) ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play from \(Self.clock(line.start))")
        .contextMenu {
            Button("Save as Moment") {
                guard let path else { return }
                let title = line.text.count > 60 ? String(line.text.prefix(60)) + "…" : line.text
                moments.add(path: path, at: line.start, end: line.end > line.start ? line.end : nil,
                            title: title, source: .transcript)
            }
        }
    }

    private func isSpeaking(_ line: TranscriptLine) -> Bool {
        playback.position >= line.start && playback.position < line.end
    }

    private var emptyMessage: String {
        if searching, !lines.isEmpty { return "“\(query)” is not said in this video." }
        if transcribingThis { return "Transcribing this video — lines appear as they are written." }
        return "No transcript for this video yet. Press Transcribe above to make one."
    }

    private func reload() {
        guard let path else { lines = []; edited = false; return }
        lines = journal.transcript(for: path)
        edited = journal.hasUserEdits(path)
        // A library search is the playlist: show this video's lines for it.
        if playback.mode == .said, let said = playback.saidQuery { typed = said }
    }

    /// h:mm:ss past an hour, m:ss below it — the shape the progress label uses
    /// while transcribing.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// The transcript line being spoken, drawn over the picture like a subtitle.
///
/// Observes the playhead itself rather than the controller, for the reason
/// `Playhead` exists: only views that need four ticks a second should get
/// them. Lines are read from the profile's store when the video changes and
/// again when a transcription run writes more, the same as `TranscriptPanel`.
struct SubtitleOverlay: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var journal: EvidenceJournal
    let path: String?
    @ObservedObject var head: Playhead
    /// What the subtitle menu resolved to. Embedded tracks are drawn by the
    /// player itself; this overlay draws a subtitle file's cues or the
    /// transcript, and nothing otherwise.
    var source: SubtitleSource = .transcript
    var cues: [SubtitleCue] = []

    @State private var lines: [TranscriptLine] = []

    private var speaking: String? {
        let now = head.position
        switch source {
        case .transcript: return lines.last { $0.start <= now && now < $0.end }?.text
        case .sidecar: return TrackPlan.cue(at: now, in: cues)?.text
        case .none, .embedded: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let text = speaking {
                Text(text)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
            }
        }
        // Never in the way of the click-to-pause on the picture beneath.
        .allowsHitTesting(false)
        .task(id: path) { reload() }
        .onChange(of: app.transcriptLines) { _, _ in reload() }
        .onChange(of: journal.transcriptEdits) { _, _ in reload() }
    }

    private func reload() {
        lines = path.map { journal.transcript(for: $0) } ?? []
    }
}
