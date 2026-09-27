import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Correcting a transcript by hand, beside the video it belongs to.
///
/// A window rather than a sheet, so the picture stays in view and playable
/// while times are adjusted against it: Play Line runs just that line (with a
/// breath either side) and stops, and Set Start / Set End take the playhead.
///
/// Nothing is written until Save. The draft is the whole editing session — its
/// undo history, the lines as they stand, the verdict on whether they may be
/// saved — and Cancel throws it away. Saved corrections become the transcript
/// search, the subtitle overlay and exports read; the machine's own lines are
/// kept aside for Restore Original Transcription.
struct TranscriptEditorWindow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var journal: EvidenceJournal

    /// The video this session is editing. Held apart from `app.transcriptEditTarget`
    /// so asking to edit another video never drops unsaved work on this one.
    @State private var path: String?
    @State private var draft = TranscriptDraft(lines: [])
    @State private var saved: [TranscriptDraft.Line] = []
    @State private var selection: Set<TranscriptDraft.Line.ID> = []
    @State private var message: String?
    @State private var shiftText = ""
    @State private var shiftingAll = false
    @State private var showShift = false
    @State private var confirmRestore = false
    @State private var confirmDiscard = false
    @State private var edited = false
    @State private var playing: Task<Void, Never>?

    private var playback: PlaybackController? { app.playback }
    private var dirty: Bool { draft.lines != saved }
    private var issues: [TranscriptDraft.Issue] { draft.issues }
    private var errors: [TranscriptDraft.Issue] { issues.filter(\.isError) }
    /// A hidden video's words stay out of sight while the hidden list is locked,
    /// the same as its name.
    private var hiddenAndLocked: Bool {
        path.map { library.isHidden($0) && !library.lock.isUnlocked } ?? false
    }
    private var selectedIndex: Int? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return draft.index(of: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let path, !hiddenAndLocked, library.profileOpen {
                header(path)
                Divider()
                toolbar
                Divider()
                list
                Divider()
                footer
            } else {
                placeholder
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { adopt(app.transcriptEditTarget) }
        .onChange(of: app.transcriptEditTarget) { _, target in adopt(target) }
        .onDisappear { playing?.cancel() }
        .confirmationDialog("Restore the original transcription?", isPresented: $confirmRestore) {
            Button("Restore Original", role: .destructive) { restore() }
        } message: {
            Text("Every saved correction to this transcript is replaced by what the speech model first wrote. Unsaved edits are discarded too.")
        }
        .confirmationDialog("Discard your unsaved edits?", isPresented: $confirmDiscard) {
            Button("Discard Edits", role: .destructive) { load(path) }
        } message: {
            Text("The transcript goes back to how it was last saved.")
        }
    }

    // MARK: - pieces

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(hiddenAndLocked ? "This video is hidden."
                 : !library.profileOpen ? "No profile is open."
                 : "No transcript is being edited.")
                .font(.headline)
            Text(hiddenAndLocked
                 ? "Unlock hidden videos (View ▸ Show Hidden Videos…) to edit its transcript."
                 : "Open the transcript under a video and choose Edit.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func header(_ path: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent).font(.headline).lineLimit(1)
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { draft.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!draft.canUndo)
                .help("Undo the last change to the transcript")
            Button { draft.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!draft.canRedo)
                .help("Redo the change you just undid")
            Menu("Export") {
                ForEach(TranscriptExport.Format.allCases) { format in
                    Button(format.label) { TranscriptExporter.export(path: path, format: format, journal: journal, app: app) }
                }
            }
            .fixedSize()
            .disabled(saved.isEmpty)
            .help(dirty ? "Exports the last SAVED transcript. Save first to include your edits."
                        : "Write this transcript to a file")
            Button("Restore Original…") { confirmRestore = true }
                .disabled(!edited)
                .help(edited ? "Go back to what the speech model first wrote"
                             : "This transcript has not been corrected")
            Button("Revert") { confirmDiscard = true }
                .disabled(!dirty)
                .help("Throw away edits made since the last save")
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty || !draft.canSave)
                .help(draft.canSave ? "Save the corrected transcript"
                                    : "Fix the lines marked in red before saving")
        }
        .padding(12)
    }

    private var statusLine: String {
        var parts = ["\(draft.lines.count) lines"]
        if edited { parts.append("corrected by hand") }
        if dirty { parts.append("unsaved changes") }
        return parts.joined(separator: " · ")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            PlayheadReadout(head: playback?.head)
            Button { playback?.togglePlayPause() } label: {
                Image(systemName: "playpause.fill")
            }
            .help("Play or pause the video")
            .accessibilityLabel("Play or pause")
            Divider().frame(height: 18)
            Button("Play Line") { playSelected() }
                .disabled(selectedIndex == nil || playback?.currentPath != path)
                .help("Play the selected line with half a second either side, then pause")
            Button("Set Start") { setFromPlayhead(start: true) }
                .disabled(selectedIndex == nil || playback?.currentPath != path)
                .help("Start the selected line at the playhead")
            Button("Set End") { setFromPlayhead(start: false) }
                .disabled(selectedIndex == nil || playback?.currentPath != path)
                .help("End the selected line at the playhead")
            Divider().frame(height: 18)
            Menu("Line") {
                Button("Insert Line Above") { perform { id in try draft.insert(before: id) } }
                    .disabled(selectedIndex == nil)
                Button("Insert Line Below") { insertBelow() }
                Button("Split at Playhead") { splitAtPlayhead() }
                    .disabled(selectedIndex == nil || playback?.currentPath != path)
                Button("Merge with Next Line") { perform { try draft.mergeWithNext($0) } }
                    .disabled(selectedIndex == nil || selectedIndex == draft.lines.count - 1)
                Divider()
                Button("Delete", role: .destructive) { deleteSelected() }
                    .disabled(selection.isEmpty)
            }
            .fixedSize()
            Button("Shift…") { shiftingAll = selection.isEmpty; showShift = true }
                .help(selection.isEmpty ? "Move every line earlier or later"
                                        : "Move the selected lines earlier or later")
                .popover(isPresented: $showShift, arrowEdge: .bottom) { shiftPopover }
            Spacer()
            if let message {
                Text(message).font(.callout).foregroundStyle(.red).lineLimit(2)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var shiftPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Lines", selection: $shiftingAll) {
                Text("Selected (\(selection.count))").tag(false)
                Text("All \(draft.lines.count)").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(selection.isEmpty)
            HStack {
                TextField("seconds, e.g. -1.5 or +0:02", text: $shiftText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(applyShift)
                Button("Shift", action: applyShift)
                    .disabled(TranscriptDraft.parseOffset(shiftText) == nil)
            }
            Text("Negative moves earlier, positive later.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var list: some View {
        let byLine = Dictionary(grouping: issues, by: \.line)
        return List(selection: $selection) {
            ForEach(Array(draft.lines.enumerated()), id: \.element.id) { i, line in
                TranscriptEditorRow(
                    number: i + 1,
                    line: line,
                    issues: byLine[line.id] ?? [],
                    onText: { text in apply { try draft.setText(line.id, text) } },
                    onTimes: { start, end in apply { try draft.setTimes(line.id, start: start, end: end) } },
                    onSeek: { playback?.seek(to: line.start) },
                    canSeek: playback?.currentPath == path)
                .tag(line.id)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if errors.isEmpty {
                let warnings = issues.count
                Image(systemName: warnings == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(warnings == 0 ? Color.secondary : Color.orange)
                Text(warnings == 0 ? "Every line has valid times and text."
                     : "\(warnings) overlap\(warnings == 1 ? "" : "s") or gap\(warnings == 1 ? "" : "s") marked — allowed, but worth a look.")
            } else {
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text("\(errors.count) line\(errors.count == 1 ? "" : "s") must be fixed before saving. First: line \((draft.index(of: errors[0].line) ?? 0) + 1) — \(errors[0].message)")
                    .lineLimit(2)
                Button("Show") { selection = [errors[0].line] }.controlSize(.small)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - actions

    /// Take on a new target. Unsaved work on another video is never dropped:
    /// the window keeps it and says so.
    private func adopt(_ target: String?) {
        guard target != path else { return }
        if dirty, path != nil {
            message = "Save or revert this transcript before editing another."
            return
        }
        load(target)
    }

    private func load(_ target: String?) {
        playing?.cancel()
        path = target
        message = nil
        selection = []
        guard let target else {
            draft = TranscriptDraft(lines: [])
            saved = []
            edited = false
            return
        }
        draft = TranscriptDraft(journal.transcript(for: target))
        saved = draft.lines
        edited = journal.hasUserEdits(target)
    }

    private func save() {
        guard let path, draft.canSave else { return }
        do {
            try journal.saveEdited(draft.transcriptLines(path: path), path: path,
                                   language: draft.language)
            load(path)
            app.jobNotice = "Transcript saved."
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func restore() {
        guard let path else { return }
        do {
            try journal.restoreOriginal(path)
            load(path)
            app.jobNotice = "Original transcription restored."
        } catch {
            message = "Could not restore: \(error.localizedDescription)"
        }
    }

    /// Run one edit, showing its refusal instead of throwing it away.
    private func apply(_ edit: () throws -> Void) {
        do {
            try edit()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// An edit on the one selected line.
    private func perform(_ edit: (TranscriptDraft.Line.ID) throws -> Void) {
        guard let i = selectedIndex else { return }
        apply { try edit(draft.lines[i].id) }
    }

    private func insertBelow() {
        apply {
            let anchor = selectedIndex.map { draft.lines[$0].id } ?? draft.lines.last?.id
            let new = try draft.insert(after: anchor)
            selection = [new]
        }
    }

    private func deleteSelected() {
        draft.delete(selection)
        selection = []
    }

    private func splitAtPlayhead() {
        guard let playback else { return }
        perform { try draft.split($0, at: playback.position) }
    }

    private func setFromPlayhead(start: Bool) {
        guard let i = selectedIndex, let playback else { return }
        let line = draft.lines[i]
        let now = playback.position
        apply {
            try draft.setTimes(line.id, start: start ? now : line.start, end: start ? line.end : now)
        }
    }

    private func applyShift() {
        guard let offset = TranscriptDraft.parseOffset(shiftText) else { return }
        apply {
            if shiftingAll { try draft.shiftAll(by: offset) } else { try draft.shift(selection, by: offset) }
            showShift = false
        }
    }

    /// Play the selected line with half a second either side, then pause —
    /// enough to hear whether the words land on the times.
    private func playSelected() {
        guard let i = selectedIndex, let playback else { return }
        let line = draft.lines[i]
        playing?.cancel()
        playback.seek(to: max(0, line.start - 0.5))
        if !playback.head.playing { playback.togglePlayPause() }
        let stopAt = line.end + 0.5
        playing = Task { @MainActor in
            while !Task.isCancelled, playback.head.playing, playback.position < stopAt {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled, playback.head.playing { playback.togglePlayPause() }
        }
    }
}

/// One line of the editor: its number, its times (typed, checked when the
/// field is left), its words, and what is wrong with it.
private struct TranscriptEditorRow: View {
    let number: Int
    let line: TranscriptDraft.Line
    let issues: [TranscriptDraft.Issue]
    let onText: (String) -> Void
    let onTimes: (Double, Double) -> Void
    let onSeek: () -> Void
    let canSeek: Bool

    @State private var start = ""
    @State private var end = ""
    @State private var text = ""
    @State private var badTime = false

    private var hasError: Bool { badTime || issues.contains(where: \.isError) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            timeField("Start", $start)
            Text("–").foregroundStyle(.secondary)
            timeField("End", $end)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Text", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onChange(of: text) { _, typed in if typed != line.text { onText(typed) } }
                    .accessibilityLabel("Line \(number) text")
                if badTime {
                    Text("Type a time like 1:05.250 or 65.25.").font(.caption).foregroundStyle(.red)
                }
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message).font(.caption)
                        .foregroundStyle(issue.isError ? Color.red : Color.orange)
                }
            }
            Spacer(minLength: 0)
            Button(action: onSeek) { Image(systemName: "arrow.right.to.line") }
                .buttonStyle(.borderless)
                .disabled(!canSeek)
                .help("Move the playhead to this line's start")
                .accessibilityLabel("Go to line \(number)")
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if hasError { Rectangle().fill(.red).frame(width: 3).offset(x: -6) }
        }
        .onAppear(perform: sync)
        .onChange(of: line) { _, _ in sync() }
    }

    private func timeField(_ label: String, _ value: Binding<String>) -> some View {
        TextField(label, text: value)
            .font(.callout.monospacedDigit())
            .textFieldStyle(.roundedBorder)
            .frame(width: 92)
            .onSubmit(commitTimes)
            .onChange(of: value.wrappedValue) { _, _ in badTime = false }
            .accessibilityLabel("Line \(number) \(label.lowercased()) time")
            .onExitCommand(perform: sync)
            .onDisappear(perform: commitIfChanged)
    }

    private func sync() {
        start = TranscriptDraft.formatTime(line.start)
        end = TranscriptDraft.formatTime(line.end)
        if text != line.text { text = line.text }
        badTime = false
    }

    private func commitIfChanged() {
        if start != TranscriptDraft.formatTime(line.start) || end != TranscriptDraft.formatTime(line.end) {
            commitTimes()
        }
    }

    private func commitTimes() {
        guard let s = TranscriptDraft.parseTime(start), let e = TranscriptDraft.parseTime(end) else {
            badTime = true
            return
        }
        badTime = false
        onTimes(s, e)
    }
}

/// The playhead as a clock, observed on its own so four ticks a second do not
/// redraw the list.
private struct PlayheadReadout: View {
    @ObservedObject var head: Playhead

    init(head: Playhead?) { self.head = head ?? Playhead() }

    var body: some View {
        Text(TranscriptDraft.formatTime(head.position))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 88, alignment: .leading)
            .accessibilityLabel("Playhead at \(TranscriptDraft.formatTime(head.position))")
    }
}

/// Writing a saved transcript to a file the user chooses. The save panel is
/// the confirmation: it asks before replacing a file that is already there.
@MainActor
enum TranscriptExporter {
    static func export(path: String, format: TranscriptExport.Format,
                       journal: EvidenceJournal, app: AppModel) {
        let lines = journal.transcript(for: path)
        guard !lines.isEmpty else {
            app.say("Nothing to export", "This video has no transcript yet.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.message = format.label
        panel.nameFieldStringValue = TranscriptExport.suggestedName(for: path, format: format)
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = TranscriptExport.render(lines, as: format,
                                           videoName: (path as NSString).lastPathComponent)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            app.jobNotice = "Exported \(lines.count) lines to \(url.lastPathComponent)."
        } catch {
            app.say("Could not export the transcript", error.localizedDescription)
        }
    }
}
