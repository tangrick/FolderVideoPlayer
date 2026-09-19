import SwiftUI

/// What was said, in order, with a search box over the whole profile.
///
/// The panel reads; it never writes transcript lines. Search asks the store's
/// own index rather than filtering in memory, so a hit here is a hit anywhere.
/// Lines are read back from the profile's store when the panel opens, so a film
/// transcribed last week still shows its words — the last transcription run in
/// this session is not the source of truth.
struct TranscriptPanel: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var journal: EvidenceJournal
    let playback: PlaybackController

    @State private var typed = ""
    @State private var lines: [TranscriptLine] = []
    @State private var hits: [TranscriptLine] = []

    private var path: String? { playback.currentPath }
    private var query: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searching: Bool { !query.isEmpty }
    private var shown: [TranscriptLine] { searching ? hits : lines }
    private var transcribingThis: Bool { path != nil && app.transcribingPath == path }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14)
        .task(id: path) { reload() }
        .onChange(of: typed) { _, _ in search() }
        .onChange(of: app.transcriptLines) { _, _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Transcript").font(.headline)
            if transcribingThis, let progress = app.transcribeProgress {
                Text(progress.label)
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if !lines.isEmpty {
                Text("\(lines.count) lines")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search what was said", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
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
    }

    private func isSpeaking(_ line: TranscriptLine) -> Bool {
        playback.position >= line.start && playback.position < line.end
    }

    private var emptyMessage: String {
        if searching { return "Nothing matches “\(query)”." }
        if transcribingThis { return "Transcribing this video — lines appear as they are written." }
        return "No transcript for this video yet. Press Transcribe above to make one."
    }

    private func reload() {
        guard let path else { lines = []; hits = []; return }
        lines = journal.transcript(for: path)
        if searching { search() } else { hits = [] }
    }

    private func search() {
        hits = searching ? journal.transcriptMatches(query) : []
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
