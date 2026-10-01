import SwiftUI

/// Triage mode's strip under the picture: how many are left, the video in
/// view, the numbered chips that keys 1 to 9 answer to, and a field for any
/// other tag.
///
/// Every key has a button here, so the mode works with the mouse and with
/// VoiceOver; the keys themselves are `AppModel.triageKey`.
struct TriageBar: View {
    @ObservedObject var session: TriageSession
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: Library
    @EnvironmentObject var suggestions: SuggestionStore
    @State private var typed = ""
    @FocusState private var typing: Bool

    /// When the engine last produced suggestions for the video in view. A change
    /// means some have just landed, and join the end of the strip.
    private var suggestedAt: Date? {
        session.current.flatMap { suggestions.entry($0)?.suggestedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let path = session.current {
                videoLine(path)
                strip
                entryRow(path)
                legend
            } else {
                finished
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: AppModel.triageFocusFieldNotification)) { _ in
            if session.current != nil { typing = true }
        }
        .onChange(of: session.current) { _, _ in typed = ""; typing = false }
        .onChange(of: suggestedAt) { _, _ in session.refreshSuggestions() }
        // A tag filter or a tag playlist can gain or lose the video just
        // answered; the list is asked once per answer, as the tag panel does.
        .onChange(of: session.steps.count) { _, _ in playback.refreshMembership() }
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Label("Triage", systemImage: "tag.square")
                .font(.headline)
            Text(progress)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Show", selection: Binding(
                    get: { session.queue.filter },
                    set: { app.setTriageFilter($0) })) {
                    ForEach(TriageFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(session.queue.filter.title)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which videos to go through")
            Button {
                app.endTriage()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Leave triage (esc)")
            .accessibilityLabel("Leave triage")
        }
    }

    /// "14 left · 3 skipped · 212 in this list".
    private var progress: String {
        var parts = ["\(session.left) left"]
        if !session.queue.skipped.isEmpty { parts.append("\(session.queue.skipped.count) skipped") }
        parts.append("\(session.queue.total) in this list")
        return parts.joined(separator: " · ")
    }

    // MARK: - the video in view

    @ViewBuilder
    private func videoLine(_ path: String) -> some View {
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let has = library.tagsFor(path)
        HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(folder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if playback.triageMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Muted for this session (M)")
            }
            if !has.isEmpty {
                Text("Has: " + has.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - the numbered strip

    private var strip: some View {
        ChipFlow(spacing: 6) {
            ForEach(Array(session.strip.entries.enumerated()), id: \.offset) { index, entry in
                chip(entry, key: session.strip.key(at: index))
            }
            if session.strip.entries.isEmpty {
                Text("Nothing to offer yet. Type a tag, or press T.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ entry: TriageStrip.Entry, key: Int?) -> some View {
        let applied = session.isApplied(entry)
        let refused = session.isRejected(entry)
        let suggestion = entry.kind == .suggestion
        return HStack(spacing: 3) {
            Button {
                session.toggle(entry)
            } label: {
                HStack(spacing: 4) {
                    if let key {
                        Text("\(key)")
                            .font(.caption2.monospaced().weight(.bold))
                            .padding(.horizontal, 4)
                            .background(Color.primary.opacity(0.12), in: .rect(cornerRadius: 3))
                    }
                    // A guess must never look like a tag somebody vouched for:
                    // sparkle and a dashed border, as in the tag panel.
                    if suggestion && !applied {
                        Image(systemName: "sparkles").font(.caption2)
                    }
                    Text(entry.tag)
                        .font(.caption)
                        .strikethrough(refused)
                    if applied {
                        Image(systemName: "checkmark").font(.caption2.weight(.bold))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(applied ? Color.white : (refused ? Color.secondary : Color.primary))
                .background(applied ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1,
                                                         dash: suggestion && !applied ? [3, 2] : []))
                        .foregroundStyle(applied ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(chipHelp(entry, key: key, applied: applied))
            .accessibilityLabel(chipLabel(entry, key: key, applied: applied, refused: refused))

            // The no, as a button of its own like the tag panel's ✕: the key
            // is ⌥ and the number.
            if suggestion && !applied && !refused {
                Button {
                    session.reject(entry)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Not “\(entry.tag)” — records a negative example for training"
                      + (key.map { " (⌥\($0))" } ?? ""))
                .accessibilityLabel("Not \(entry.tag)")
            }
        }
    }

    private func chipHelp(_ entry: TriageStrip.Entry, key: Int?, applied: Bool) -> String {
        let press = key.map { " (\($0))" } ?? ""
        if applied { return "Take “\(entry.tag)” off\(press)" }
        return entry.kind == .suggestion
            ? "Suggested from the picture. Add “\(entry.tag)”\(press)"
            : "Add “\(entry.tag)”\(press)"
    }

    private func chipLabel(_ entry: TriageStrip.Entry, key: Int?, applied: Bool, refused: Bool) -> String {
        let number = key.map { "\($0), " } ?? ""
        let kind = entry.kind == .suggestion ? "suggested" : "your tag"
        let state = applied ? "added" : (refused ? "refused" : "not added")
        return "\(number)\(entry.tag), \(kind), \(state)"
    }

    // MARK: - typing, and the buttons

    private func entryRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            TextField("Another tag (T)", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .focused($typing)
                .onSubmit { commit() }
                .onKeyPress(.tab) {
                    guard let first = completions.first else { return .ignored }
                    typed = completing(typed, with: first)
                    return .handled
                }
            ForEach(completions.prefix(4), id: \.self) { name in
                Button(name) {
                    typed = completing(typed, with: name)
                    commit()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
            Button("Accept All") { session.acceptAll() }
                .disabled(!session.strip.entries.contains { $0.kind == .suggestion })
                .help("Add every suggestion shown, then move on (A)")
            Button("Back") { session.back() }
                .disabled(!session.queue.canGoBack)
                .help("The video before this one (↑)")
            Button("Skip") { session.skip() }
                .help("Leave this one for later (↓)")
            Button("Done") { session.done() }
                .buttonStyle(.borderedProminent)
                .help("Finished with this video (Return). With no tag on it, it is set aside as having nothing to tag.")
            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo)
            .help("Undo the last answer (⌘Z)")
            .accessibilityLabel("Undo")
        }
        .controlSize(.small)
    }

    private func commit() {
        let text = typed
        typed = ""
        typing = false
        session.addTyped(text)
    }

    /// Tags already in the library that begin with what is being typed, for the
    /// last name in a comma-separated list; not those the video already has.
    private var completions: [String] {
        let word = (typed.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, let path = session.current else { return [] }
        let have = Set(library.tagsFor(path).map { $0.lowercased() })
        return library.knownTags().filter {
            $0.lowercased().hasPrefix(word.lowercased()) && !have.contains($0.lowercased())
                && !isStarTag($0)
        }
    }

    private func completing(_ text: String, with name: String) -> String {
        var names = text.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if names.isEmpty { return name }
        names[names.count - 1] = name
        return names.joined(separator: ", ")
    }

    private var legend: some View {
        Text("1–9 add or remove · ⌥1–9 not this · A accept all · Return done · ↓ skip · ↑ back · "
             + "T type a tag · M mute · ⌘Z undo · esc leave")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
    }

    // MARK: - nothing in view

    private var finished: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finishedHeadline)
                .font(.callout.weight(.semibold))
            Text(finishedDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if session.queue.onlySkippedLeft {
                    Button("Go Through Them Again") { session.revisitSkipped() }
                        .buttonStyle(.borderedProminent)
                }
                if session.canUndo {
                    Button("Undo") { session.undo() }
                        .help("Take the last answer back (⌘Z)")
                }
                Button("Leave Triage") { app.endTriage() }
                    .help("esc")
            }
            .controlSize(.small)
        }
    }

    private var finishedHeadline: String {
        if session.queue.onlySkippedLeft {
            let n = session.queue.skipped.count
            return "\(n) skipped"
        }
        return session.queue.finished.isEmpty
            ? "Nothing in this list needs an answer"
            : "That is all of them"
    }

    private var finishedDetail: String {
        if session.queue.onlySkippedLeft {
            return "Everything else is done. The skipped ones have had nothing recorded."
        }
        return session.queue.finished.isEmpty
            ? "Try another filter from the menu above, or leave triage."
            : "\(session.queue.finished.count) finished this session."
    }
}
