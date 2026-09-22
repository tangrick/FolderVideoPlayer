import AppKit
import SwiftUI

/// The playlist, laid out the way Finder lays out a folder: a grid of poster
/// frames or a list, and in the list a header whose columns sort — a click
/// sorts by that column, a second click turns it around.
struct PlaylistSidebar: View {
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library
    @EnvironmentObject var media: MediaCache
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var suggestions: SuggestionStore
    @EnvironmentObject var journal: EvidenceJournal
    /// Find Duplicates opens a window of its own, from the Files menu.
    /// A sub-view does not inherit its parent's environment bindings, so the
    /// sidebar declares its own.
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Is the tag-filter cloud folded away? A library with year and person
    /// tags can offer thirty chips, which pushed the videos off the screen —
    /// so past a handful it starts folded, and remembers what you last did.
    @AppStorage("playlistTagsExpanded") private var tagsExpanded = true

    /// Where the drag on the edge started, so the width tracks the mouse
    /// rather than jumping by the delta each time.
    @State private var widthAtDragStart: Double?
    /// The cursor is on the drag edge, so the line shows itself.
    @State private var hoveringEdge = false
    /// Tag-review mode: when the playlist is a TAG (mode == .tag), the AI
    /// toggle appends candidate rows — videos from anywhere in the library
    /// that look like the ones already carrying this tag — so the user can
    /// accept the right ones and dismiss the wrong ones (each dismissal is a
    /// rejection lesson for that tag).
    @State private var aiSuggest = false
    @State private var aiCandidates: [(key: String, score: Double)] = []
    @State private var aiLoading = false
    @State private var aiNote: String?
    /// Whether the rows on screen were ranked by FACE rather than by the whole
    /// frame. Set by the search that produced them, read only by the words
    /// around them — a person's rows promise something different from a
    /// scene's, and saying "look like" over a face match is what made the
    /// waterfalls look like a correct answer.
    @State private var aiByFace = false
    /// The tag whose tagged videos the search is analysing for itself, so it
    /// knows to run again when that finishes. Without it the user presses Find
    /// Look-alikes, reads "Analysing 1 tagged video…", and nothing else ever
    /// happens — the work would be done and the answer never asked for.
    @State private var pendingSearchTag: String?
    /// Videos this session has already re-analysed to widen the search — once
    /// each, deliberately. A cache write is best-effort, so a video that comes
    /// back from a run with nothing on disk (a full disk, a share that went
    /// away) would otherwise be handed to the engine again by every search that
    /// follows, for as long as the app is open. After one attempt the honest
    /// answer is "it is still unreadable", not another pass over the same file.
    @State private var widened: Set<String> = []
    /// Keys the batch asked about and the disk said no: the file is no longer
    /// where it was cached. Held so they stop being offered — measured on the
    /// live library, a third of a 250-video batch was already gone (83 of 250),
    /// and re-checking them every pass would spend a third of every run on
    /// paths that cannot be analysed at all.
    @State private var gone: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // The hidden list is the one view whose state must be impossible
            // to mistake for the ordinary library, so the banner is always on
            // screen while it is up — with the way out on it.
            if playback.mode == .hidden {
                HiddenBanner()
                Divider()
            }
            // Only on screen when it has something to say. It used to sit
            // there permanently offering a Scan button, which is the
            // whole-playlist sweep the per-row "Find Missing File…" replaced;
            // idle, it was a bar of nothing above every playlist.
            if app.movedArmed || app.movedScan.phase != .idle || app.movedScan.hasFindings {
                MovedScanPanel(scan: app.movedScan, expanded: $app.movedExpanded)
                Divider()
            }
            // The action row sits DIRECTLY on the list, not up in the toolbar.
            // Select, AI and Files all act on the videos below them, and a
            // control that acts on a list belongs against that list — with the
            // search field and tag filter between them, the press and the thing
            // pressed were a whole panel apart.
            actionBand
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, showSelectionBar ? 4 : 6)
            // What to do with a selection appears only once there IS one worth
            // acting on. A single click always selects a row, so showing this
            // for one video would mean it never goes away.
            if showSelectionBar {
                selectionBar
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            content
            Divider()
            footer
        }
        .frame(width: library.playlistWidth)
        .background(.regularMaterial)
        // The drag zone and the line that marks it are drawn separately.
        // Chaining an overlay onto an already-.offset handle is ambiguous —
        // .offset does not move the layout frame, so the line landed 12 pt
        // inside the list while the grab zone sat on the edge. Anchoring the
        // line to the PANEL's own leading edge leaves nothing to guess at.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(hoveringEdge ? 0.55 : 0))
                .frame(width: 2)
                .animation(.easeOut(duration: 0.12), value: hoveringEdge)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) { resizeHandle }
        // A backstop, not the mechanism. The search asks itself again when the
        // run it started finishes (`runLookAlikeSearch`), because THIS never
        // fires on its own: the sidebar does not observe the engine — it reaches
        // it through `app.engine`, and `AppModel.engine` is not published — so
        // the view is not re-evaluated when the phase changes and `.onChange`
        // never sees it. It stays because a redraw for any other reason then
        // picks up a search left pending by something else.
        .onChange(of: app.engine.phase) { _, phase in
            guard case .idle = phase,
                  let tag = pendingSearchTag, aiSuggest,
                  playback.tagName == tag else { return }
            pendingSearchTag = nil
            runLookAlikeSearch()
        }
        // Candidates belong to ONE tag: moving to another tag with the toggle
        // still on must not leave the previous tag's rows under the new tag's
        // heading. Same rule as the selection — a new scope starts clean.
        .onChange(of: playback.tagName) { _, tag in
            guard aiSuggest else { return }
            pendingSearchTag = nil
            if tag == nil {
                aiCandidates = []
                aiNote = nil
            } else {
                runLookAlikeSearch()
            }
        }
    }

    // MARK: - the toolbar above it

    private var toolbar: some View {
        VStack(spacing: 6) {
            // Band 1 — looking: search the list, and choose how it is drawn.
            // The view switch belongs here rather than on a row of its own:
            // it changes how you SEE the list, exactly like the filter does.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name", text: $playback.nameFilter)
                    .textFieldStyle(.plain)
                if !playback.nameFilter.isEmpty {
                    Button { playback.nameFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the filter")
                    .accessibilityLabel("Clear the name filter")
                }
                Picker("", selection: $library.playlistStyle) {
                    ForEach(PlaylistStyle.allCases) { style in
                        Image(systemName: style.symbol)
                            .help(style.title)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 66)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))

            // Band 2 — narrowing. What the engine is busy with is not a band:
            // it is one line in the footer under the list, with the Stop that
            // belongs against it. The doing controls are not here either: they
            // moved down against the list they act on.
            tagStrip
        }
        .padding(8)
    }

    // MARK: - band 2: the named actions

    /// Whether several videos are picked, which is when the batch controls
    /// are worth the row they take up.
    private var showSelectionBar: Bool { app.selection.count > 1 }

    private var actionBand: some View {
        HStack(spacing: 6) {
            aiMenu
            filesMenu

            Spacer(minLength: 0)
            // The count steps aside while a batch is picked: the row below
            // carries "N selected", and two counts in two lines invite a
            // misread.
            if !showSelectionBar {
                Text(countLabel)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            lookAlikeToggle
            tagPanelToggle
        }
    }

    /// Look-alikes, as a toggle: the candidate rows under the tag's own videos
    /// are either on screen or they are not.
    ///
    /// It used to be a line inside AI ▾ — "Find Look-alikes for “X”" / "Hide
    /// …" — which meant opening a menu and reading a sentence to learn a state
    /// that a lit button says at a glance. The wand is the same one the AI
    /// SUGGESTED heading wears, so one glyph keeps one meaning, and it reads the
    /// same `aiSuggest` the rows are drawn from.
    ///
    /// Outside a tag it reads off and is disabled with the reason, never hidden:
    /// look-alikes are asked OF a tag ("more videos like these"), so there is
    /// nothing to ask of a folder, and a control that vanished when the mode
    /// changed would move the row under the cursor.
    private var lookAlikeToggle: some View {
        Toggle(isOn: Binding(get: { aiSuggest && playback.tagName != nil },
                             set: { _ in toggleAISuggest() })) {
            Image(systemName: "wand.and.stars")
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(playback.tagName == nil || !app.ai.works(.tags))
        .help(lookAlikeHelp)
    }

    private var lookAlikeHelp: String {
        guard let tag = playback.tagName else {
            return "Look-alikes are asked of one tag — open a tag on the left to find videos like it"
        }
        guard app.ai.works(.tags) else { return app.ai.reason(.tags) ?? "" }
        return aiSuggest
            ? "Hide the videos that look like “\(tag)”"
            : "Find videos anywhere in the library that look like “\(tag)”"
    }

    /// Tag, as a toggle: the panel is either on screen or it is not, and a
    /// control that says which cannot be mistaken for one that opens a dialog.
    ///
    /// It sits in this row rather than in the batch bar below, because that bar
    /// only exists once two rows are ticked — and the tag panel is worth opening
    /// with nothing ticked at all, where it describes the video playing. It
    /// writes the same state the panel's own ✕ and the transport bar's tag
    /// button write, so the three cannot disagree.
    private var tagPanelToggle: some View {
        Toggle(isOn: $app.showTagPanel) {
            Text("Tag")
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
        .help(app.showTagPanel ? "Hide the tag panel" : "Tag these videos")
    }

    /// What to do with several videos at once, shown against the top of the
    /// list it acts on.
    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(app.selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            Button("All") { app.selectAll(playback.visibleVideos) }
            Button("None") { app.selectNone() }
        }
        .buttonStyle(.link)
        .font(.caption)
        .help("⌘-click to add one, ⇧-click for a run")
    }

    /// Everything that asks the local engine to think, under one heading.
    ///
    /// Items are never hidden by state — they are disabled with a reason, so
    /// a control can't move out from under the cursor between presses. Each
    /// says how much work it is about to do.
    private var aiMenu: some View {
        Menu {
            if app.engine.isBusy {
                Button("Restart on These \(videos.count) Videos") { classifyVisible() }
                Button("Stop — \(app.engine.currentName ?? "working")") { app.stopAnalysis() }
            } else {
                let classified = videos.filter { path in
                    guard let record = app.analysis.analysis(for: path) else { return false }
                    return record.userLabel != nil || record.phase == .done
                }.count
                Button(Self.batchTitle("Classify", "Unclassified", total: videos.count,
                                       done: classified, finished: "Classified")) { classifyVisible() }
                    .disabled(videos.isEmpty || classified == videos.count || !app.ai.works(.classify))
                    .help(app.ai.reason(.classify)
                          ?? "Safe / NSFW, for the videos not classified yet. Already classified videos, and ones you marked yourself, are skipped.")
            }
            // Never hidden: a person has to be able to SEE that the feature
            // exists before they can decide to install it.
            if !app.ai.anythingWorks {
                Button("Set Up AI Features…") {
                    app.settingsTab = .ai          // land ON the page, not merely
                    openSettings()                 // inside the window
                }
                .help("Opens Settings → AI, where each feature says what it costs to download.")
            }
            Divider()
            // Explicit, like Classify above: nothing transcribes on its own.
            if app.transcribeBatch != nil {
                Button("Stop Transcribing") {
                    NotificationCenter.default.post(name: AppModel.cancelTranscribeNotification, object: nil)
                }
            } else {
                let transcribed = videos.filter { journal.transcribedPaths.contains($0) }.count
                Button(Self.batchTitle("Transcribe", "Untranscribed", total: videos.count,
                                       done: transcribed, finished: "Transcribed")) {
                    NotificationCenter.default.post(name: AppModel.transcribeBatchNotification,
                                                    object: videos)
                }
                .disabled(videos.isEmpty || transcribed == videos.count
                          || app.transcribingPath != nil || !app.ai.works(.speech))
                .help(app.ai.reason(.speech)
                      ?? "Write down what is said in each video, one after another. Videos that already have a transcript are skipped.")
            }
            Button("Train Tags from These \(videos.count)") { trainVisible() }
                .disabled(videos.isEmpty || app.engine.isBusy || !app.ai.works(.tags))
                .help(app.ai.reason(.tags) ?? "")
            // Find Look-alikes is NOT here any more: asking a menu what state
            // something is in is what a toggle is for, and it now sits in the
            // action band beside Tag (see `lookAlikeToggle`). Two controls for
            // one thing is how the batch bar's duplicate File menu happened.
            // Only offered when the app is allowed to look for faces at all.
            if library.facesEnabled {
                Divider()
                Button("Add Face…") { openWindow(id: "people") }
                    .disabled(!app.ai.works(.faces))
                    .help(app.ai.reason(.faces) ?? "")
            }
        } label: {
            Label("AI", systemImage: app.engine.isBusy ? "cpu.fill" : "cpu")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Classify, train, and find look-alikes with the local engine")
        .accessibilityLabel("AI menu")
    }

    /// A playlist-wide AI item that says how much it will actually do. Both
    /// runs skip what is already done, and "Classify These 1,200 Videos" read
    /// as if all 1,200 would run again.
    ///   "Classify These 12 Videos" · "Classify 40 Unclassified Videos (1,160 already done)"
    ///   · "All 1,200 Videos Classified"
    static func batchTitle(_ verb: String, _ adjective: String, total: Int, done: Int,
                           finished: String) -> String {
        func videos(_ n: Int) -> String { "\(n.formatted()) Video\(n == 1 ? "" : "s")" }
        let todo = total - done
        if total > 0 && todo == 0 { return "All \(videos(total)) \(finished)" }
        if done == 0 { return total == 1 ? "\(verb) This Video" : "\(verb) These \(videos(total))" }
        return "\(verb) \(todo.formatted()) \(adjective) \(todo == 1 ? "Video" : "Videos") (\(done.formatted()) already done)"
    }

    /// Everything that touches files on disk, under one heading.
    ///
    /// The playlist-wide "Find Moved or Missing Files Here" is deliberately
    /// not here any more: it asked the question of every video in the list
    /// when the question is nearly always about one red row. Right-click that
    /// row instead. The whole-playlist scan is still built and still runs —
    /// the panel's own Scan button reaches it — so widening it again later is
    /// a one-line change.
    private var filesMenu: some View {
        Menu {
            // The whole-playlist sweep, back where a person looks for it. The
            // per-row "Find Missing File…" is still the quick path for one red
            // row; this answers "what else have I lost?", which no row can.
            Button("Find Moved or Missing Files…") {
                // Clear any scope a previous right-click left behind, or this
                // would quietly scan one row while claiming the playlist.
                app.movedScan.scopePaths = nil
                app.movedScan.scopeRoot = nil
                app.movedScan.scopeLabel = nil
                app.movedArmed = true
                app.movedExpanded = true
            }
                .help("Check every video in the playlist for files that have moved or gone")
            Button("Find Duplicates…") { openWindow(id: "duplicates") }
            Divider()
            Button("Reveal in Finder") { revealSelectionOrCurrent() }
            Button(app.selection.isEmpty
                   ? "Move to Folder…" : "Move \(app.selection.count) to Folder…") {
                app.moveFiles(filesTarget())
            }
            .disabled(filesTarget().isEmpty)
            Button(app.selection.isEmpty
                   ? "Delete…" : "Delete \(app.selection.count)…") {
                app.trashFiles(filesTarget())
            }
            .disabled(filesTarget().isEmpty)
            Divider()
            // App-only, and reversible by design: nothing here touches the
            // file, so it can sit beside Move and Delete without sharing any
            // of their permanence.
            if !filesTarget().isEmpty, filesTarget().allSatisfy({ library.isHidden($0) }) {
                Button("Unhide") { app.unhideVideos(filesTarget()) }
            } else {
                Button("Hide") { app.hideVideos(filesTarget()) }
                    .disabled(filesTarget().isEmpty)
            }
            Button("Show Hidden Videos…") { app.showHiddenVideos() }
        } label: {
            Label("Files", systemImage: "folder")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("Find moved, missing or duplicate files, and move or delete what is selected")
        .accessibilityLabel("Files menu")
    }

    /// What Move/Delete act on: the ticked videos, or the one playing when
    /// nothing is ticked. Never the whole playlist — deleting 96 files from
    /// a menu press is not something to make easy.
    private func filesTarget() -> [String] {
        if !app.selection.isEmpty { return Array(app.selection) }
        if let path = playback.currentPath { return [path] }
        return []
    }

    private func revealSelectionOrCurrent() {
        let paths = filesTarget()
        guard !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Queue the whole visible playlist and hand it to the engine. Rows the
    /// user or the machine has already settled are skipped by the store, so
    /// this is always safe to press.
    ///
    /// Pressed while a run is active, this first stops that run — the engine
    /// is one worker and would refuse a second queue — then starts on the
    /// current scope once the drain lands.
    private func classifyVisible() {
        let paths = videos
        guard !paths.isEmpty else { return }
        // Says why and stops, rather than spawning an engine that cannot run.
        guard app.requireAI(.classify) else { return }
        let profile = Paths.activeProfile
        Task {
            if app.engine.isBusy {
                app.stopAnalysis()
                // The engine drains the in-flight video before it is idle;
                // run() refuses a second queue until then, so wait it out.
                while app.engine.isBusy {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard !Task.isCancelled, profile == Paths.activeProfile else { return }
            await app.classify(paths: paths)
        }
    }

    /// Train per-tag heads from THIS playlist's tagged videos.
    ///
    /// The playlist is the scope, exactly like Analyse: the videos you can
    /// see are the training set, so you decide how much the model learns from
    /// in one press. Same builder as Tag Profiles' whole-library pass — only
    /// the scope differs — and the engine MERGES heads rather than replacing
    /// them, so a playlist training never erases what the library pass fitted.
    private func trainVisible() {
        guard app.requireAI(.tags) else { return }
        let paths = videos
        guard !paths.isEmpty else { return }
        // Playlist rows speak absolute paths; the shared scope trainer maps
        // them to share-relative keys and reports every outcome as a notice
        // (busy, broken, nothing tagged, fitted) — never a silent no-op.
        app.trainScope(scopePaths: paths, scopeTitle: "from this playlist")
    }

    /// The tags carried by the videos in this playlist, as chips that filter
    /// it. Ticking one shows only the videos carrying it; ticking a second
    /// narrows to videos carrying both. Only tags actually in the list are
    /// offered, so a chip can never empty it for no visible reason.
    @ViewBuilder
    private var tagStrip: some View {
        let available = playback.tagsInPlaylist
        if !available.isEmpty {
            let filtering = !playback.tagFilter.isEmpty || !playback.tagExcluded.isEmpty
            // A filter in force is never hidden: folding it away would leave
            // the list mysteriously short with nothing on screen to explain
            // it. Otherwise the fold is the user's to keep.
            let open = tagsExpanded || filtering
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { tagsExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                            Text("Tags in this playlist (\(available.count))")
                                .font(.caption2)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Click a tag once to want it, twice to rule it out")

                    Spacer(minLength: 0)

                    // Only worth asking how tags combine once two are ticked;
                    // with one, All and Any mean the same thing.
                    if playback.tagFilter.count > 1 {
                        Picker("", selection: $playback.tagFilterMode) {
                            ForEach(PlaybackController.TagFilterMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.mini)
                        .frame(width: 76)
                        .help(playback.tagFilterMode.help)
                    }

                    if filtering {
                        Text("\(videos.count) of \(playback.playlist.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Clear") { playback.clearTagFilter() }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .help("Drop every tag filter")
                    }
                }
                if open {
                    ScrollView(.vertical, showsIndicators: false) {
                        ChipFlow(spacing: 4) {
                            ForEach(available, id: \.name) { entry in
                                tagChip(entry.name, entry.count)
                            }
                        }
                    }
                    .frame(maxHeight: 74)
                }
            }
        }
    }

    /// One filter chip, in one of three states: not asked about, wanted, or
    /// ruled out. Clicking cycles them.
    ///
    /// The styles are separate Buttons rather than a ternary between them: a
    /// conditional between two ButtonStyles defeats generic inference inside
    /// a layout builder (the same reason the tag panel's chips are written
    /// this way).
    @ViewBuilder
    private func tagChip(_ name: String, _ count: Int) -> some View {
        if playback.isTagFiltered(name) {
            Button {
                playback.toggleTagFilter(name)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                    Text(name).font(.caption2)
                    Text("\(count)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .help("Showing videos tagged “\(name)” — click to rule it out instead")
        } else if playback.isTagExcluded(name) {
            Button {
                playback.toggleTagFilter(name)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "nosign").font(.system(size: 7, weight: .bold))
                    Text(name).font(.caption2).strikethrough()
                    Text("\(count)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(.red)
            .help("Hiding videos tagged “\(name)” — click to stop")
        } else {
            Button {
                playback.toggleTagFilter(name)
            } label: {
                HStack(spacing: 3) {
                    Text(name).font(.caption2)
                    Text("\(count)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Show only videos tagged “\(name)”")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch library.playlistStyle {
        case .list: listView
        case .icons: iconsView
        }
    }

    // MARK: - the edge you drag

    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            // Wide, and genuinely straddling the edge.
            //
            // It used to be a 16-pt strip laid INSIDE the panel — an overlay
            // is bounded by its parent, so every point of the grab zone sat
            // to the RIGHT of the visible line and the cursor had to be
            // past the edge before it would take. Now it is 24 pt shifted
            // half its width outward, so 12 pt sit over the player and 12 pt
            // over the panel: aim anywhere near the line and it locks on.
            .frame(width: 24)
            .contentShape(.rect)
            .offset(x: -12)
            .onHover { inside in
                hoveringEdge = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // A line you can see while the cursor is on it — a drag target
            // that gives no sign it is a drag target reads as a dead edge.
            // The line itself is drawn by the panel, on the panel's own
            // leading edge; the handle only reports the hover.
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        let start = widthAtDragStart ?? library.playlistWidth
                        widthAtDragStart = start
                        // The panel is on the right, so dragging left widens it.
                        library.playlistWidth = min(max(start - drag.translation.width, 260), 900)
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                        library.save()
                    }
            )
    }

    // MARK: - AI suggestions in a tag playlist

    /// The divider and candidate rows under the user's own tagged videos.
    /// Each candidate is marked as an AI look-alike (never as something the
    /// user vouched for) and carries Accept / Dismiss — dismiss records a
    /// rejection for the tag, which is the training class tags like Kite lack.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text("AI SUGGESTED — not yet tagged by you")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if aiLoading { ProgressView().controlSize(.mini) }
                if !aiCandidates.isEmpty { acceptAllAIButton }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            Text(aiByFace
                 ? "Videos whose faces match “\(playback.tagName ?? "")”, from anywhere in your library. Nothing else about the picture was used. Accept the right ones; ✕ the wrong ones to teach it."
                 : "Candidates the AI believes look like “\(playback.tagName ?? "")” from anywhere in your library. Accept the right ones; ✕ the wrong ones to teach it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            aiReadiness
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            aiProcessing
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if aiCandidates.isEmpty && !aiLoading {
                Text(aiNote ?? "No candidates found above the confidence bar.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(aiCandidates, id: \.key) { cand in
                aiRow(cand)
            }
            if let note = aiNote, !aiCandidates.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
        }
        .background(Color.accentColor.opacity(0.04))
    }

    /// The candidate section, drawn for the poster-frame view: same heading,
    /// same promise, tiles instead of rows.
    @ViewBuilder
    private var aiGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text("AI SUGGESTED — not yet tagged by you")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if aiLoading { ProgressView().controlSize(.mini) }
                if !aiCandidates.isEmpty { acceptAllAIButton }
            }
            Text(aiByFace
                 ? "Face matches for “\(playback.tagName ?? "")” from anywhere in your library."
                 : "Look-alikes for “\(playback.tagName ?? "")” from anywhere in your library.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            aiReadiness
            aiProcessing
            if aiCandidates.isEmpty && !aiLoading {
                Text(aiNote ?? "No candidates found above the confidence bar.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                      spacing: 10) {
                ForEach(aiCandidates, id: \.key) { cand in
                    aiTile(cand)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .background(Color.accentColor.opacity(0.04))
    }

    /// How close this tag is to training, beside the rows that move it: the
    /// same counts and the same 4-and-4 rule as Tag Profiles ▸ Your Tags, so
    /// the two places can never disagree.
    @ViewBuilder
    private var aiReadiness: some View {
        if let tag = playback.tagName {
            let rejections = suggestions.byVideo.values.reduce(0) { sum, entry in
                sum + entry.verdicts.filter {
                    $0.value == .rejected && $0.key.caseInsensitiveCompare(tag) == .orderedSame
                }.count
            }
            let h = TagProfilesWindow.TagHealth(positives: library.count(of: tag),
                                                rejections: rejections)
            HStack(spacing: 4) {
                Text("\(h.positives)✓ \(h.rejections)✗")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if h.trainable {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Enough to train — run Train Tags to use them")
                        .foregroundStyle(.secondary)
                } else if let need = h.need {
                    Text("Needs \(need) to train — Accept is a yes, ✕ is a no")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .help("A tag needs 4 yes and 4 no before a head can be fitted")
        }
    }

    /// Said plainly while the search is waiting on the engine — classifying
    /// something else, or analysing this tag's videos first. An empty list
    /// then means "not yet", and the grey note below it was too quiet to say so.
    /// `pendingSearchTag` is the signal because every waiting path sets it.
    @ViewBuilder
    private var aiProcessing: some View {
        // Not when classifying is unavailable: the search still parks itself,
        // but nothing will ever run, and "check back later" would be a promise.
        if let tag = playback.tagName, pendingSearchTag == tag, app.ai.works(.classify) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(aiCandidates.isEmpty
                     ? "AI is still processing videos in the background — suggestions for “\(tag)” will appear here. Check back later."
                     : "AI is still processing videos in the background — more suggestions for “\(tag)” may appear. Check back later.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .help(aiNote ?? "The engine is busy; the search runs again when it is free.")
        }
    }

    /// The picture beside an AI candidate — or the wand mark when pictures are
    /// turned off. Same switch as the playlist rows, because one setting should
    /// mean one thing ("pictures in this list"), and the same poster view, for
    /// the same reason.
    ///
    /// A look-alike is judged by the frame, not by the filename: the whole
    /// question this section asks is "does this look like the tag?", which a
    /// name cannot answer. `width: nil` fills whatever the tile is given.
    @ViewBuilder
    private func aiThumb(_ path: String, previewing: Bool, width: CGFloat?,
                         height: CGFloat) -> some View {
        let corner: CGFloat = height > 40 ? 6 : 4
        if library.showThumbnails {
            PosterView(path: path, big: height > 40)
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: corner))
                .overlay {
                    // The "this one is playing" mark sits ON the frame: in a
                    // wall of posters the filename is too small to find.
                    if previewing {
                        ZStack {
                            Color.black.opacity(0.35)
                            Image(systemName: "play.fill")
                                .font(.system(size: height > 40 ? 18 : 9))
                                .foregroundStyle(.white)
                        }
                        .clipShape(.rect(cornerRadius: corner))
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.accentColor.opacity(previewing ? 0.35 : 0.15))
                .frame(width: width, height: height)
                .overlay(
                    Image(systemName: previewing
                          ? "play.fill" : "wand.and.stars.inverse")
                        .font(.system(size: height > 40 ? 16 : 10))
                        .foregroundStyle(Color.accentColor)
                )
        }
    }

    /// One candidate, as a tile you can preview, accept or dismiss.
    private func aiTile(_ cand: (key: String, score: Double)) -> some View {
        let path = Paths.tagPath(cand.key)
        let previewing = playback.previewPath == path
        return VStack(alignment: .leading, spacing: 4) {
            aiThumb(path, previewing: previewing, width: nil, height: 74)
            .overlay(alignment: .topTrailing) {
                Text(String(format: "%.0f%%", cand.score * 100))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: .rect(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
            }
            Text((path as NSString).lastPathComponent)
                .font(.caption2.weight(previewing ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Accept") { acceptAI(cand) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                Button("✕") { dismissAI(cand) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Not “\(playback.tagName ?? "")” — records a negative example")
            }
            .font(.caption2)
        }
        .contentShape(.rect)
        .onTapGesture { playback.preview(path) }
        .help("AI look-alike — click to preview it without leaving this playlist")
    }

    private func aiRow(_ cand: (key: String, score: Double)) -> some View {
        let path = Paths.tagPath(cand.key)
        // The row you clicked is the one previewing in the player. Without a
        // mark, a list of look-alikes gives no clue which one you are judging
        // — and judging is the whole point of the section.
        let previewing = playback.previewPath == path
        return HStack(spacing: 8) {
            aiThumb(path, previewing: previewing, width: 44, height: 25)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.caption.weight(previewing ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(previewing
                     ? String(format: "Previewing — %.0f%% match", cand.score * 100)
                     : String(format: "%@ — %.0f%% match",
                              aiByFace ? "Face match" : "AI look-alike", cand.score * 100))
                    .font(.caption2)
                    .foregroundStyle(previewing ? Color.accentColor : Color.secondary.opacity(0.7))
            }
            Spacer(minLength: 4)
            Button("Accept") { acceptAI(cand) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                dismissAI(cand)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Not this — records a rejection so the AI learns what this tag is NOT")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(previewing ? Color.accentColor.opacity(0.18) : .clear)
        // A bar on the leading edge, the same one the playing row wears, so
        // "this is the one" reads the same everywhere in the panel.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(previewing ? Color.accentColor : .clear)
                .frame(width: 3)
        }
        .contentShape(.rect)
        .onTapGesture { playback.preview(path) }
        .animation(.easeOut(duration: 0.12), value: previewing)
        .help("Click the row to preview it here — the playlist stays put")
    }

    /// Fetch the look-alike candidates for the current tag: the WHOLE
    /// analysed library (analysis store — every video with embeddings, tagged
    /// or not), minus videos already carrying the tag and minus ones already
    /// rejected for it (a dismissal must stick). The prototype comes from the
    /// videos the user tagged, so only those need the tag library.
    ///
    /// Two tagged videos are what the search needs (LookAlikes.minVideos), and
    /// the app takes that rule seriously in both directions: it never
    /// prototypes from one video, and it never makes a user who HAS two tagged
    /// videos go and run something. A tagged video with no embeddings yet is
    /// analysed right here — see `runLookAlikeSearch`.
    private func toggleAISuggest() {
        guard app.requireAI(.tags) else { return }
        aiSuggest.toggle()
        guard aiSuggest else { pendingSearchTag = nil; return }
        runLookAlikeSearch()
    }

    /// Wait until the engine has finished whatever else it is doing, and say
    /// whether the search is still the one the user is looking at.
    ///
    /// Polled, deliberately. The alternative is to observe `AnalysisEngine`
    /// from this view, and it publishes a status line, a running count and a
    /// file name several times per video — which would re-evaluate the whole
    /// playlist at that rate, the same cost that put the playhead in an object
    /// of its own. A 300 ms poll while a run the user can see is in progress is
    /// cheaper than that, and it stops the moment they toggle the search off or
    /// leave the tag.
    private func engineFree(for tag: String) async -> Bool {
        while app.engine.isBusy {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, aiSuggest, playback.tagName == tag else { return false }
        }
        return aiSuggest && playback.tagName == tag
    }

    /// The registry's own spelling of a tag that names a person, or nil.
    ///
    /// Asked of the people already in memory rather than of the file: this runs
    /// on every toggle and every tag change, and the answer is one the store
    /// keeps current. A tag matching a person case-insensitively IS that person
    /// — the tag and the registry key are the same name written twice, which is
    /// exactly what `nameCluster` and `addPerson` write.
    ///
    /// Nil while Face Recognition is switched off, so the setting decides
    /// whether faces are used for anything at all, and the scene search
    /// answers as it did before.
    private func namedPerson(_ tag: String) -> String? {
        guard library.facesEnabled else { return nil }
        return app.faceStore?.people
            .first { $0.name.caseInsensitiveCompare(tag) == .orderedSame }?.name
    }

    /// Find this person in videos that are not tagged with them yet, by face.
    ///
    /// Deliberately shorter than the scene search below, because it cannot do
    /// the two things that make that one long. It never re-analyses anything:
    /// the face pass is button-triggered (People ▸ Scan), and the hard rule is
    /// that nothing but the playing video starts work on its own — so a video
    /// nobody has scanned is COUNTED and named as such, not quietly queued. And
    /// it needs no prototype rule: one bound face is enough to search with,
    /// where a scene prototype needs two videos to have any direction at all.
    private func runFaceLookAlikeSearch(person: String) {
        aiByFace = true
        aiLoading = true
        aiNote = nil
        aiCandidates = []
        Task {
            defer { aiLoading = false }
            guard let analysis = app.analysis as AnalysisStore? else { return }

            // The index is `faceHash -> absolute paths`; everything the rows
            // are drawn from is a tag key. Reduced here, on the main actor,
            // because `library` and `suggestions` live here — and reduced to
            // what is worth OFFERING, so the ranking below never scores a video
            // the user has already settled.
            var offered: [String: [String]] = [:]
            for (hash, paths) in app.faceStore?.faceVideos ?? [:] {
                var keep: [String] = []
                for path in paths {
                    let key = Paths.tagKey(path)
                    if library.hidden.contains(key) { continue }
                    if (library.tags[key] ?? []).contains(where: {
                        $0.caseInsensitiveCompare(person) == .orderedSame
                    }) { continue }
                    // Case-insensitively, unlike the scene search's exact
                    // lookup: that one asks with the tag as the user sees it
                    // spelled, which is what `dismissAI` filed the verdict
                    // under. This one asks with the REGISTRY's spelling of the
                    // person, and the two can differ in case — an exact lookup
                    // would offer back a video the user has already rejected.
                    if let verdicts = suggestions.entry(key)?.verdicts,
                       verdicts.first(where: {
                           $0.key.caseInsensitiveCompare(person) == .orderedSame
                       })?.value == .rejected { continue }
                    keep.append(key)
                }
                if !keep.isEmpty { offered[hash] = keep }
            }
            // What the coverage count is measured against: every video the app
            // holds a record for. A video with a record but no faces indexed is
            // the one the user cannot see the absence of — it looks searched
            // and never was.
            var analysed = Set<String>()
            for (key, _) in analysis.records where !library.hidden.contains(key) {
                analysed.insert(key)
            }

            let profile = Paths.activeProfile
            let result = await Task.detached(priority: .userInitiated) { () -> FaceLookAlikes.Result in
                // Reads only: the registry file for this person's bound hashes,
                // then one `.f32` per distinct face. No model is loaded, which
                // is what lets this work on a Mac that never downloaded the
                // face bundle but has a cache from one that did.
                let registry = FaceRegistry(root: Paths.support, profile: profile)
                let bound = registry.registry()
                let key = FaceRegistry.existingKey(person, in: bound) ?? person
                let references = (bound[key] ?? []).compactMap { registry.vector(for: $0) }
                return FaceLookAlikes.rank(person: person,
                                           references: references,
                                           faceVideos: offered,
                                           analysed: analysed,
                                           vector: { registry.vector(for: $0) })
            }.value
            guard !Task.isCancelled, aiSuggest,
                  playback.tagName?.caseInsensitiveCompare(person) == .orderedSame else { return }

            // The same moved-file check the scene search makes, for the same
            // reason: a cached row whose file has gone cannot be played or
            // accepted, and carries the name of one that can.
            let ranked = result.candidates.map { LookAlikes.Candidate(key: $0.key, score: $0.score) }
            let checked = LookAlikes.live(ranked) { key in
                FileManager.default.fileExists(atPath: Paths.tagPath(key))
            }
            aiCandidates = checked.live.map { (key: $0.key, score: $0.score) }

            var notes: [String] = []
            if checked.live.isEmpty, let reason = result.reason { notes.append(reason) }
            if checked.gone > 0 {
                notes.append("\(checked.gone) candidate\(checked.gone == 1 ? "" : "s") skipped — "
                           + "the file has moved from the path the faces were cached under.")
            }
            // Said even when the answer is full, because it is the one thing
            // the user cannot see: a face search over a library that has barely
            // been scanned looks like a complete answer.
            if result.unscanned > 0 {
                let noun = result.unscanned == 1 ? "video has" : "videos have"
                notes.append("\(result.unscanned) \(noun) not been scanned for faces yet — "
                           + "open People and scan them to widen this search.")
            }
            aiNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        }
    }

    /// Run the search, analysing that tag's unanalysed videos first.
    ///
    /// This is one press that can take two passes: a tag's videos have to be
    /// embedded before they can be prototypes, and a video with no embedding is
    /// not one. So the tag's unanalysed videos are embedded here — all of them,
    /// in library order, not merely enough to clear `LookAlikes.minVideos` —
    /// and the search re-runs when that run ends. It asks ITSELF again, after
    /// the `classify` it awaited returns: the sidebar does not observe the
    /// engine, so a watcher on the phase is not woken by the run finishing, and
    /// the note stayed on screen with the work done and the answer never asked
    /// for. Nothing is re-embedded twice, and a video already carrying an
    /// answer is never touched.
    ///
    /// `afterAnalysis` marks that re-ask: the second pass never starts a third
    /// run, so a video that cannot be analysed says so instead of looping.
    ///
    /// Split from the toggle because that re-run needs the body without the
    /// flag flip — and because the tag changing while the toggle is on has to
    /// re-run it too, or the rows would describe the tag the user just left.
    private func runLookAlikeSearch(afterAnalysis: Bool = false) {
        guard let tag = playback.tagName else { return }
        // A tag that names someone in the face registry is a different
        // question, and `FaceLookAlikes` says why at length: ranking a person
        // by the whole frame answers with wherever they were standing. There is
        // no analyse-then-retry pass on this path — the face scan is
        // button-triggered, and nothing but the playing video may start work of
        // its own accord — so `afterAnalysis` has nothing to mark here.
        if let person = namedPerson(tag) {
            runFaceLookAlikeSearch(person: person)
            return
        }
        aiByFace = false
        aiLoading = true
        aiNote = nil
        aiCandidates = []
        Task {
            defer { aiLoading = false }
            guard let analysis = app.analysis as AnalysisStore? else { return }
            var tagged: [String: [String]] = [:]
            // Tagged videos the engine cannot read because an EARLIER vision
            // tower embedded them. Held apart from `pending` (which means never
            // analysed at all) because the remedy differs: these were analysed,
            // and only a re-analysis under the current model makes them usable.
            var stale: [String] = []
            // Tagged videos whose verdict describes bytes that no longer
            // exist — the file was re-encoded, re-saved, or replaced after it
            // was analysed. Kept apart from `stale` for the same reason that
            // list is kept apart from `unanalysed`: the remedy is the same
            // (re-analyse), but the honest sentence differs.
            var reencoded: [String] = []
            // Tagged videos with no verdict behind them at all — never
            // analysed, or analysed and failed. Deliberately NOT folded in with
            // `stale`: an earlier version of this note called all of them
            // "analysed with an earlier model", which is false for these, and
            // told the user their work had been thrown away when in fact it had
            // never been done. Both end in Classify, but the honest sentence
            // differs, and the user is the one who decides whether to spend it.
            var unanalysed: [String] = []
            // Tagged videos the engine has already given up on. Counted, never
            // re-queued: see the pending loop below.
            var failed: [String] = []
            // Records the engine running now cannot read at all: no frame
            // hashes, or vectors written by an earlier tower. The search cannot
            // see such a video, so it can neither offer it nor let the user
            // reject it — re-analysing it is the only thing that changes that,
            // and these keys are what the widening step below hands over.
            var unscored: [String] = []
            // The pool is EVERY analysed video — including the untagged ones
            // the search exists to find. library.tags only holds tagged
            // videos, so iterating it as the pool would search nothing.
            var pool: [String: [String]] = [:]

            // Staleness is the one question in the loop below that touches the
            // disk: it stats every file to compare size and mtime against the
            // verdict. On a library whose videos live on a share that is one
            // SMB round trip per record — and this whole pass runs on the main
            // actor, so the window froze for as long as it took (reported as a
            // spinning ball, 2026-09-18, on a library of ~11,700 records; the
            // note below measured 0.3 s over 4,136 when the answers were local
            // and cached).
            //
            // So the stats are taken OFF the main actor first, in parallel, and
            // the loop then asks a set in memory. Nothing else here does I/O.
            let recordsNow = analysis.records
            let staleKeys: Set<String> = await Task.detached(priority: .userInitiated) {
                var out: Set<String> = []
                for (key, record) in recordsNow where record.isStale(forPath: Paths.tagPath(key)) {
                    out.insert(key)
                }
                return out
            }.value
            guard !Task.isCancelled else { return }

            for (key, record) in recordsNow {
                // A verdict about bytes that no longer exist (a re-encode, a
                // different video moved over the path) is not an analysed
                // video of THIS file. Same remedy as a tower swap — the video
                // cannot steer or be scored by the search — but the record
                // still says Done, and its own reason is kept apart: the
                // honest sentence is "the file changed", not "an earlier
                // model analysed it".
                if staleKeys.contains(key) {
                    if record.phase != .failed { unscored.append(key) }
                    if (library.tags[key] ?? []).contains(where: {
                        $0.caseInsensitiveCompare(tag) == .orderedSame
                    }) { reencoded.append(key) }
                    continue
                }
                // A hidden video is invisible to the app, so it is not a
                // look-alike the search may offer back to the user.
                if library.hidden.contains(key) { continue }
                // A record written by another embedding space is not an
                // analysed video. Its hashes name files under
                // `frames/<old space>/`, which the engine running now will
                // never open — so counting it as ready answers a confident
                // "not enough tagged videos" to someone who tagged plenty,
                // and skips the re-analysis that would have fixed it. The
                // video falls through to `pending` below instead.
                let carriesTag = (library.tags[key] ?? []).contains {
                    $0.caseInsensitiveCompare(tag) == .orderedSame
                }
                guard record.isInCurrentSpace else {
                    // Tagged, but the engine running now cannot read its
                    // vectors, so it can neither steer the search nor be scored
                    // by it. Which of the two reasons it is decides the words:
                    // a verdict means a tower swap orphaned real work, no
                    // verdict means the work was never done. Both end in
                    // Classify, and the user is owed the count either way.
                    if carriesTag {
                        if record.prediction == nil { unanalysed.append(key) } else { stale.append(key) }
                    } else if record.phase != .failed {
                        unscored.append(key)
                    }
                    continue
                }

                let hashes = record.frameScores.prefix(10).map(\.hash)
                if hashes.isEmpty {
                    // A record with no frames at all cannot be scored either,
                    // tagged or not — the same widening job as one whose files
                    // are gone.
                    if record.phase != .failed { unscored.append(key) }
                    continue
                }
                // `carriesTag` again rather than a second lookup and scan: this
                // loop runs over every record in the library on the main actor,
                // so the cheap test is worth reusing (measured: the whole pass
                // is ~0.3 s over 4,136 records).
                if carriesTag {
                    tagged[key] = Array(hashes)
                } else if suggestions.entry(key)?.verdicts[tag] != .rejected {
                    pool[key] = Array(hashes)
                }
            }
            // Tagged is not the same as analysed. Only a video with embeddings
            // can be a prototype, and the loop above can only see the ones that
            // have them — so the rest are collected here rather than dropped.
            var pending: [String] = []
            for (key, names) in library.tags {
                guard !library.hidden.contains(key) else { continue }
                guard names.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }),
                      tagged[key] == nil else { continue }
                // A row the engine already gave up on is not waiting for
                // anything. Re-queueing it every time the search runs would
                // re-analyse the same broken file for as long as the tag exists,
                // and the search below would never be asked — the run ends, the
                // tag is asked again, the same file fails again.
                if analysis.records[key]?.phase == .failed { failed.append(key); continue }
                pending.append(key)
            }
            pending.sort()      // a dictionary has no order: library order by path
            let taggedTotal = tagged.count + pending.count + failed.count

            // Every video tagged with this tag that the engine cannot read yet
            // is analysed before the search — not just enough to clear the rule.
            //
            // The old arithmetic topped up to `minVideos`: the search needs two
            // directions, so two prototypes will do. That reasoning is sound and
            // the result was not. A tag holding 36 videos was searched with a
            // prototype drawn from 4 of them, so "what else looks like this"
            // answered from a tenth of what the user had taught it — and the
            // more videos they tagged, the further the answer drifted from the
            // one they asked for. They tagged these videos for exactly this, so
            // the whole tag is analysed and `pendingSearchTag` asks the search
            // again when the run ends.
            if !pending.isEmpty {
                let noun = pending.count == 1 ? "video" : "videos"
                // The run this search started has already been and gone, and
                // these are still unreadable — a refusal (the engine was taken
                // by something else) or a failure. Say so, in the engine's own
                // words when it has any, rather than starting the same run again.
                if afterAnalysis {
                    aiNote = app.jobNotice
                        ?? "\(pending.count) tagged \(noun) for “\(tag)” could not be analysed — "
                         + "try the search again once the engine is free."
                    return
                }
                pendingSearchTag = tag
                guard app.ai.works(.classify) else {
                    aiNote = "\(pending.count) tagged \(noun) for “\(tag)” still to analyse — "
                           + "the search starts the moment the engine is free."
                    return
                }
                if app.engine.isBusy {
                    aiNote = "\(pending.count) tagged \(noun) for “\(tag)” still to analyse — "
                           + "the search starts the moment the engine is free."
                    guard await engineFree(for: tag) else { return }
                }
                for path in pending { analysis.enqueue([path]) }
                aiNote = "Analysing \(pending.count) tagged \(noun) for “\(tag)” — "
                       + "the search runs as soon as that finishes."
                await app.classify(paths: pending)
                guard aiSuggest, playback.tagName == tag else { return }
                pendingSearchTag = nil
                runLookAlikeSearch(afterAnalysis: true)
                return
            }

            if tagged.count < LookAlikes.minVideos {
                // Fewer tagged videos than the rule needs, in numbers. Every
                // one of them has just been analysed by the run above (or the
                // engine gave up on it), so this is a shortage of TAG, not of
                // vectors. The note used to name the rule without the count and
                // read as "I have tagged enough" — tagging and classifying are
                // different acts, and the user is the one who tagged them.
                aiNote = "“\(tag)” has \(taggedTotal) tagged video\(taggedTotal == 1 ? "" : "s"). "
                       + "Two are needed before the AI can work out what the tag looks like — "
                       + "tag one more and try again."
                return
            }
            do {
                let res = try await app.engine.tagCandidates(tag: tag,
                                                             tagged: tagged,
                                                             pool: pool,
                                                             limit: 30)
                // Only offer what is still there. A moved folder leaves the old
                // key in the store with its vectors, and that ghost row carries
                // the same file name as the video the user may have just
                // rejected — which reads as the rejection not taking, when the
                // truth is that the search is offering a path that no longer
                // exists. A stat per offered row; the pool is not touched.
                let ranked = res.candidates.map { LookAlikes.Candidate(key: $0.key, score: $0.score) }
                let checked = LookAlikes.live(ranked) { key in
                    FileManager.default.fileExists(atPath: Paths.tagPath(key))
                }
                aiCandidates = checked.live.map { (key: $0.key, score: $0.score) }
                // The engine's own words for why a search came back empty.
                // Dropped, an empty list reads as "nothing looks like this
                // tag" when the truth may be "there is no baseline to compare
                // against yet".
                if checked.live.isEmpty, let reason = res.reason {
                    aiNote = reason
                } else if checked.gone > 0 {
                    aiNote = "\(checked.gone) candidate\(checked.gone == 1 ? "" : "s") skipped — "
                           + "the file has moved from the path the AI had cached it under."
                }
                // Said last and said plainly, because neither kind of video is
                // visible as missing from the user's side: they tagged it, the
                // row looks tagged, and the only symptom is a search that comes
                // back thin. The two counts are kept apart on purpose — one is
                // work a tower swap orphaned, the other is work never done, and
                // only the user can decide whether to spend the time.
                var reasons: [String] = []
                if !stale.isEmpty { reasons.append("\(stale.count) were analysed with an earlier model") }
                if !reencoded.isEmpty { reasons.append("\(reencoded.count) changed on disk after they were analysed") }
                if !unanalysed.isEmpty { reasons.append("\(unanalysed.count) have not been analysed yet") }
                if !reasons.isEmpty {
                    aiNote = [aiNote, "Of the \(taggedTotal) videos tagged “\(tag)”, "
                             + reasons.joined(separator: " and ")
                             + " — run Classify so they can steer the search."]
                        .compactMap { $0 }.joined(separator: " ")
                }

                // --- and widen the search, rather than asking for it --------
                //
                // Both kinds of invisible video end in the same mechanical
                // place: the engine cannot read this video's vectors, so the
                // search can neither offer it nor let the user reject it. That
                // is the one state a tag never recovers from, because nothing
                // ever asks about such a video again.
                //
                // Telling the user to go and press Classify made that their job
                // — on a folder scope they may not even have open — while the
                // app already knows exactly which videos are affected and has
                // the machinery to fix them: the same enqueue-and-run the tagged
                // videos above use, and the same re-run when that run ends.
                let widening = LookAlikes.widening(
                    unreadable: res.unseenKeys,
                    unscored: unscored,
                    tried: widened,
                    // Deliberately cheap — store lookups only, never a `stat`.
                    // This closure is asked about every candidate, and a stat
                    // against the share costs ~2 ms: at 2,933 candidates that
                    // was 5.6 seconds of blocked main thread, which is the
                    // spinning ball. The disk is asked about the BATCH only,
                    // below, and off the main actor.
                    skip: { key in
                        guard let record = analysis.records[key] else { return true }
                        if gone.contains(key) { return true }        // already found missing
                        return record.userLabel != nil || record.phase == .failed
                    })
                if !widening.batch.isEmpty, app.ai.works(.classify) {
                    let waiting = widening.batch.count == 1 ? "video" : "videos"
                    if app.engine.isBusy {
                        // Mid-run: wait for the engine, then ask the search
                        // again — which takes this same batch, now that nothing
                        // else is using the engine.
                        pendingSearchTag = tag
                        aiNote = [aiNote, "\(widening.offered) more \(waiting) the search cannot read yet — "
                                + "analysing them as soon as the engine is free."]
                            .compactMap { $0 }.joined(separator: " ")
                        guard await engineFree(for: tag) else { return }
                        pendingSearchTag = nil
                        runLookAlikeSearch(afterAnalysis: afterAnalysis)
                    } else {
                        // Only what is about to run is checked against the disk,
                        // and it is checked off the main actor. A key whose file
                        // has moved cannot be analysed — a run against a path
                        // that no longer exists writes a failure and teaches
                        // nothing — and the count travels with the note, because
                        // the user is the one who can go and find it.
                        let wanted = widening.batch.map(Paths.tagPath)
                        let disk = await LookAlikes.existing(wanted)
                        if disk.gone > 0 {
                            // Held so they are not offered again: a key whose
                            // file has moved can never be analysed, and asking
                            // about it every pass would spend a third of every
                            // run on paths that cannot work at all.
                            let live = Set(disk.live)
                            for path in wanted where !live.contains(path) {
                                gone.insert(Paths.tagKey(path))
                            }
                        }
                        guard !disk.live.isEmpty else {
                            aiNote = [aiNote, "None of the \(widening.batch.count) videos the search "
                                    + "cannot read are still where they were cached — the files have "
                                    + "moved, so nothing was re-analysed."]
                                .compactMap { $0 }.joined(separator: " ")
                            return
                        }
                        let runnable = Set(disk.live)
                        for key in widening.batch where runnable.contains(Paths.tagPath(key)) {
                            widened.insert(key)
                        }
                        let count = disk.live.count
                        let noun = count == 1 ? "video" : "videos"
                        let moved = disk.gone > 0
                            ? " \(disk.gone) of them could not be re-analysed — the file has moved."
                            : ""
                        pendingSearchTag = tag
                        // Re-opened, not merely enqueued: these records say Done
                        // while nothing can read their vectors, so `enqueue`
                        // would leave every one of them alone.
                        analysis.requeue(disk.live)
                        // One pass at a time, and the count says which pass this
                        // is: the search re-runs when the run ends and takes the
                        // next instalment then, so a library bigger than one
                        // batch is worked through in steps the footer names.
                        aiNote = [aiNote, (widening.offered > count
                                  ? "Analysing \(count) of \(widening.offered) \(noun) the search cannot "
                                    + "read — more follow, and the candidates update as they finish."
                                  : "Analysing \(count) more \(noun) the search could not read — "
                                    + "the candidates update when that finishes.") + moved]
                            .compactMap { $0 }.joined(separator: " ")
                        await app.classify(paths: disk.live)
                        // Same re-ask as the tagged-videos pass above, for the
                        // same reason: nothing else wakes this view. The batch
                        // just analysed is in `widened`, so the next pass takes
                        // the next instalment and the walk terminates.
                        guard aiSuggest, playback.tagName == tag else { return }
                        pendingSearchTag = nil
                        runLookAlikeSearch(afterAnalysis: afterAnalysis)
                    }
                } else if widening.offered + widening.refused + widening.alreadyTried > 0
                            || res.unseen > 0 {
                    // Nothing this pass can do, so say which kind, in numbers.
                    // "12 more videos not yet classified" read as one problem
                    // when it is three: a model that is not installed, videos
                    // the app has already re-analysed and still cannot read, and
                    // videos it must not re-analyse at all.
                    var why: [String] = []
                    if let blocked = app.ai.reason(.classify) { why.append(blocked) }
                    if widening.alreadyTried > 0 {
                        why.append("\(widening.alreadyTried) were re-analysed this session and are "
                                   + "still unreadable")
                    }
                    if widening.refused > 0 {
                        why.append("\(widening.refused) cannot be re-analysed — the engine has given "
                                   + "up on them, you have settled them, or the file has moved away "
                                   + "from where it was cached")
                    }
                    if why.isEmpty {
                        // Nothing specific to name — the Python engine reports a
                        // count without saying which videos — so the honest
                        // answer is what the user can do about it.
                        why.append("run Classify to widen the search")
                    }
                    let total = widening.offered + widening.refused + widening.alreadyTried
                    aiNote = [aiNote, "\(max(total, res.unseen)) videos the search cannot read — "
                            + why.joined(separator: ", and ") + "."]
                        .compactMap { $0 }.joined(separator: " ")
                }
            } catch {
                aiNote = error.localizedDescription
            }
        }
    }

    /// Accept: the video joins the tag (the user's word), the playlist
    /// rebuilds so it appears among the user's own rows, and the acceptance
    /// is recorded as a positive example.
    private func acceptAI(_ cand: (key: String, score: Double)) {
        let path = Paths.tagPath(cand.key)
        // The other half of the ghost row: a candidate whose file has moved
        // cannot be tagged, and must not leave a tag pointing at a path that
        // does not exist. (The search already withholds those rows; this is the
        // belt for a list that was built before the file went away.)
        guard FileManager.default.fileExists(atPath: path) else {
            aiNote = "That video is no longer at \(path) — nothing was tagged."
            aiCandidates.removeAll { $0.key == cand.key }
            return
        }
        guard let tag = playback.tagName else { return }
        var have = library.tagsFor(path)
        if !have.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            have.append(tag)
        }
        library.setTags(have, for: path)
        library.saveTags()
        suggestions.decide(path, tag: tag, verdict: .accepted)
        // The video has just JOINED this tag, so the playlist itself has to be
        // re-asked — rebuilding rows alone only re-filters a list the video
        // was never in, and the accepted video would vanish from both halves.
        playback.refreshMembership()
        aiCandidates.removeAll { $0.key == cand.key }
    }

    /// Every candidate on screen, as if each row's Accept were clicked — with
    /// one tag write instead of one per video.
    private var acceptAllAIButton: some View {
        Button("Accept All \(aiCandidates.count)") { acceptAllAI() }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.caption2)
            .help("Tag every video in this list with “\(playback.tagName ?? "")” — the same as clicking Accept on each")
    }

    private func acceptAllAI() {
        guard let tag = playback.tagName else { return }
        var missing = 0
        for cand in aiCandidates {
            let path = Paths.tagPath(cand.key)
            // Same guard as `acceptAI`: never tag a path that is gone.
            guard FileManager.default.fileExists(atPath: path) else { missing += 1; continue }
            var have = library.tagsFor(path)
            if !have.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                have.append(tag)
            }
            library.setTags(have, for: path)
            suggestions.decide(path, tag: tag, verdict: .accepted)
        }
        library.saveTags()
        playback.refreshMembership()
        aiCandidates.removeAll()
        if missing > 0 {
            aiNote = "\(missing) video\(missing == 1 ? " is" : "s are") no longer on disk — not tagged."
        }
    }

    /// Dismiss: the video is NOT this tag. A recorded rejection — the
    /// missing training class — and the row leaves the list for good.
    private func dismissAI(_ cand: (key: String, score: Double)) {
        let path = Paths.tagPath(cand.key)
        guard let tag = playback.tagName else { return }
        suggestions.decide(path, tag: tag, verdict: .rejected)
        aiCandidates.removeAll { $0.key == cand.key }
    }

    // MARK: - the rows

    /// Every row the filter leaves. The stacks below are lazy, so only what is
    /// on screen is ever built — a playlist of five thousand draws twenty.
    private var rows: [PlaylistRow] { playback.rows }

    private var videos: [String] {
        rows.compactMap { if case .video(let path) = $0 { return path } else { return nil } }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            ColumnHeader(playback: playback)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .heading(let name):
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                    .id(row.id)
                            case .video(let path):
                                VideoRow(path: path, playback: playback)
                                    .id(row.id)
                            }
                        }
                        if aiSuggest, playback.mode == .tag {
                            aiSection
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: playback.index) { reveal(proxy) }
                // A new tag restarts at index 0 — often the index it already
                // had, so the line above never fires and the list kept the
                // previous tag's scroll.
                .onChange(of: playback.tagName) { reveal(proxy) }
                .onChange(of: app.selection) { if !holdStill { reveal(proxy) } }
                .onAppear { reveal(proxy) }
            }
        }
    }

    private var iconsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                              spacing: 10) {
                        ForEach(videos, id: \.self) { path in
                            IconTile(path: path, playback: playback).id(path)
                        }
                    }
                    .padding(10)
                    // The look-alike candidates belong in this view as much as
                    // in the list: the toggle is offered in both, and a control
                    // that turns nothing on is a broken control.
                    if aiSuggest, playback.mode == .tag {
                        aiGrid
                    }
                }
            }
            .onChange(of: playback.index) { reveal(proxy) }
            .onChange(of: playback.tagName) { reveal(proxy) }
            .onChange(of: app.selection) { if !holdStill { reveal(proxy) } }
        }
    }

    /// True while a batch is being built. Scrolling to the playing video then
    /// would pull the rows out from under whoever is picking them.
    private var holdStill: Bool { app.selection.count > 1 }

    /// Bring what is playing into view.
    ///
    /// Not while a batch is being built: playback moves on by itself, and
    /// scrolling the list to the new video pulls the rows out from under
    /// whoever is picking them. The list stays put until the batch is
    /// dropped back to a single video.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard !holdStill, let path = playback.currentPath else { return }
        withAnimation { proxy.scrollTo(path, anchor: .center) }
    }

    // MARK: - the strip below it

    /// The strip under the list: how many videos there are, and the way out.
    /// Anything that acts on a selection lives at the top, against the list.
    private var footer: some View {
        HStack(spacing: 5) {
            Text(countLabel)
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
            if let job = backgroundJob {
                // One dot, one meaning: what follows it is a job in flight, not
                // a second count. Both halves belong on this line — the count
                // says what the list IS, the job says what is being done to it,
                // and the job is the one thing the user cannot see for
                // themselves. Silence here is how a long run reads as a hang.
                Text("·").foregroundStyle(.tertiary)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
                Text(job)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                    .help(jobDetail.isEmpty ? job : jobDetail)
                // The one control that belongs against a job: it stops the job
                // this line names, and it exists only while that line does. A
                // separate strip above the list said the same thing twice, and
                // charged the list a row of height for the privilege.
                Button("Stop") { app.stopAnalysis() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Stop \(app.engine.phase.title.lowercased())")
            }
            if let run = playback.conversion {
                // The FFmpeg run the user said yes to: same shape as the jobs
                // beside it — what, how far, and the way to stop it.
                Text("·").foregroundStyle(.tertiary)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
                Text(run.total > 1 ? "Converting \(run.done + 1) of \(run.total)" : "Converting")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(((run.path as NSString).lastPathComponent)
                          + (run.fraction.map { " — \(Int($0 * 100))%" } ?? ""))
                Button("Stop") { playback.stopConverting() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Stop converting. Videos already converted stay converted; the one in hand is left as it was.")
            }
            if let batch = app.transcribeBatch {
                // The playlist run, on the same line and in the same shape as
                // the engine's job: what, how far, and the way to stop it.
                Text("·").foregroundStyle(.tertiary)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
                Text("Transcribing \(min(batch.done + 1, batch.total)) of \(batch.total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help([app.transcribingPath.map { ($0 as NSString).lastPathComponent },
                           app.transcribeProgress?.label]
                            .compactMap { $0 }.joined(separator: " — "))
                Button("Stop") {
                    NotificationCenter.default.post(name: AppModel.cancelTranscribeNotification, object: nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Stop transcribing this playlist. Videos already done keep their transcripts.")
            }
            Spacer(minLength: 6)
            // Mirrors the library panel's, on the corner nearest its own
            // edge of the window.
            Button { app.showPlaylist = false } label: {
                Label("Hide", systemImage: "sidebar.trailing")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Hide the playlist (⌘L)")
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var countLabel: String {
        videos.count == playback.playlist.count
            ? "\(playback.playlist.count) videos"
            : "\(videos.count) of \(playback.playlist.count) videos"
    }

    /// What the app is doing in the background right now, in the user's words —
    /// or nil, which is the ordinary state and must read as nothing at all.
    ///
    /// Only the MAIN engine is named. It is the single worker whose states look
    /// alike from the outside (a classify pass over the playlist, the one video
    /// being watched, a model load, a stop that is draining the video in hand),
    /// and it is the only one that can hold the user's attention for minutes.
    /// The suggestion pass answers in well under a second and the duplicate
    /// scans have panels of their own — a footer that flickered for those would
    /// be noise, and noise here costs the line its meaning.
    ///
    /// The count is deliberately done/total and not a percentage: a run over
    /// 3,214 queued videos is a very different thing from one over 7, and the
    /// user is the one who can tell whether that number is the one they asked
    /// for.
    private var backgroundJob: String? {
        guard app.engine.isBusy else { return nil }
        let title = app.engine.phase.title
        return app.engine.totalCount > 0
            ? "\(title) \(app.engine.doneCount) of \(app.engine.totalCount)"
            : title
    }

    /// The job's own detail, for the tooltip: which file is in hand and what
    /// the engine last said about it. A tooltip, never a second line — a footer
    /// that grows when a run starts moves every row above it.
    private var jobDetail: String {
        [app.engine.currentName, app.engine.statusText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }
}

// MARK: - the sortable header

/// Finder's column header: a click sorts by that column, a click on the one
/// already sorting turns it around, and the arrow says which way it points.
struct ColumnHeader: View {
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library

    var body: some View {
        let layout = PlaylistColumns.layout(for: library.playlistWidth)
        HStack(spacing: 0) {
            heading("Name", .name, alignment: .leading)
                .frame(minWidth: PlaylistColumns.nameMin, maxWidth: .infinity,
                       alignment: .leading)
            if layout.showDate {
                heading("Date Added", .date, alignment: .trailing)
                    .frame(width: PlaylistColumns.date)
            }
            if layout.showSize {
                heading("Size", .size, alignment: .trailing)
                    .frame(width: PlaylistColumns.size)
            }
            Text("Verdict")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: PlaylistColumns.classify, alignment: .center)
            if layout.showRemark {
                Text("Remark")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: layout.remark, alignment: .leading)
            }
            Menu {
                // Folder Order has no column of its own — it is the order the
                // scan found things in, which is what the headings describe.
                ForEach(PlaylistSort.allCases) { sort in
                    Button {
                        adopt(sort)
                    } label: {
                        if library.playlistSort == sort {
                            Label(sort.title, systemImage: "checkmark")
                        } else {
                            Text(sort.title)
                        }
                    }
                }
                Divider()
                Toggle("Poster Frames", isOn: $library.showThumbnails)
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: PlaylistColumns.trailing)
        }
        .frame(height: 18)
        .font(.caption)
        .padding(.horizontal, PlaylistColumns.inset)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    @ViewBuilder
    private func heading(_ title: String, _ sort: PlaylistSort,
                         alignment: Alignment) -> some View {
        let active = library.playlistSort == sort
        Button {
            adopt(sort)
        } label: {
            HStack(spacing: 2) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1)
                if active {
                    Image(systemName: library.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.primary : Color.secondary)
        // Padding on the inside edge only, so the heading's text starts (or
        // ends) exactly where the values in its column do.
        .padding(alignment == .leading ? .trailing : .leading, 4)
    }

    /// A column already sorting flips; a new one arrives pointing the way
    /// Finder points it — A to Z by name, newest and largest first.
    private func adopt(_ sort: PlaylistSort) {
        if library.playlistSort == sort {
            guard sort != .folder else { return }
            library.sortDescending.toggle()
        } else {
            library.playlistSort = sort
            library.sortDescending = sort.defaultDescending
        }
        playback.applySort()
    }
}

/// The column widths, in one place so the header and the rows beneath it
/// cannot drift out of line.
enum PlaylistColumns {
    static let date: CGFloat = 78
    static let size: CGFloat = 62
    static let classify: CGFloat = 116
    /// One verdict chip. Both are this wide, always — a chip sized to its
    /// own text moves when the checkmark appears, and the pair drifts.
    static let chip: CGFloat = 55
    static let remark: CGFloat = 130
    /// The strip at the far right: the header's sort menu, and the same
    /// width of empty space on every row beneath it. Header and row must
    /// reserve the SAME trailing width or every column above sits a dozen
    /// points left of the values it names.
    static let trailing: CGFloat = 22
    /// The narrowest the name column may ask for. Without a floor, a row
    /// carrying several long tag chips (each drawn at its own width) demands
    /// more than the list is wide, and SwiftUI takes the difference out of
    /// the fixed columns — which is what made tagged rows drift out of line.
    static let nameMin: CGFloat = 90
    /// The row's own left and right padding.
    static let inset: CGFloat = 10

    /// Which columns fit a panel of this width.
    ///
    /// The fixed columns add up to more than a narrow panel has, and a
    /// column that does not fit was being pushed off the right edge — the
    /// header read "Rem…" with nothing beneath it. So the panel decides
    /// what it can afford, dropping the least important column first:
    /// Remark (a sentence you can also read in the player), then Date, then
    /// Size. Name and Verdict always survive — one says which video, the
    /// other is the whole point of the list.
    ///
    /// Header and rows BOTH read this, so they can never disagree.
    struct Layout {
        var showDate = true
        var showSize = true
        var showRemark = true
        /// Remark takes what is spare, so a wide panel gives it room to say
        /// the whole thing rather than leaving a gap at the edge.
        var remark: CGFloat = PlaylistColumns.remark
    }

    static func layout(for panelWidth: CGFloat) -> Layout {
        var l = Layout()
        // What is left for the optional columns once the two that always
        // show, the padding and the trailing strip are paid for.
        let fixed = inset * 2 + trailing + nameMin + classify
        var spare = panelWidth - fixed
        if spare < remark { l.showRemark = false } else { spare -= remark }
        if spare < date { l.showDate = false } else { spare -= date }
        if spare < size { l.showSize = false } else { spare -= size }
        // Anything still spare widens Remark rather than stretching Name
        // past what a filename needs.
        if l.showRemark { l.remark = remark + max(0, min(spare - 60, 120)) }
        return l
    }
}

// MARK: - the rows themselves

/// Clicking a row or a tile.
///
/// Finder's rules, no mode to switch on first: plain click picks one and
/// plays it, ⌘ adds or removes, ⇧ fills the run. Only a plain click starts
/// playback — building up a selection must not change what you are watching
/// on every press.
@MainActor
func selectAndShow(_ path: String, _ app: AppModel, _ playback: PlaybackController) {
    if app.click(path, from: playback.visibleVideos) { playback.jump(to: path) }
}

struct VideoRow: View {
    let path: String
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    private var isCurrent: Bool { playback.currentPath == path }
    private var tags: [String] { library.tagsFor(path) }

    var body: some View {
        let layout = PlaylistColumns.layout(for: library.playlistWidth)
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if library.showThumbnails {
                    PosterView(path: path, big: false)
                        .frame(width: 64, height: 36)
                        .clipShape(.rect(cornerRadius: 3))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let problem = playback.problems[path] {
                            FileBadge(problem: problem)
                        }
                        // Stars, not the favorite mark: the rating IS the
                        // headline judgement now. A video carries a favorite
                        // still shows it as a chip below, with its other tags.
                        if library.rating(path) > 0 {
                            Text(String(repeating: "★",
                                        count: library.rating(path)))
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .fixedSize()
                                .help("Rated \(library.rating(path)) of 5 stars")
                        }
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fontWeight(isCurrent ? .semibold : .regular)
                        if !library.dupes(for: path).isEmpty {
                            Image(systemName: "square.on.square")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Another copy of this file is in the index")
                        }
                    }
                    // The same chips the tiles carry. They can be here now
                    // because a chip is drawn at its own width and the row
                    // clips what will not fit — before, a long tag in a
                    // narrow column was squeezed until it set one letter per
                    // line. Only tagged rows are taller.
                    if !tags.isEmpty { ChipRow(names: tags) }
                }
                Spacer(minLength: 4)
            }
            // The name column takes what is left and nothing more. Its tag
            // chips are drawn at their own widths, so without a ceiling a
            // heavily-tagged row asked for more room than the list has and
            // SwiftUI squeezed the fixed columns to pay for it — which is
            // why those rows sat out of line with their headings.
            .frame(minWidth: PlaylistColumns.nameMin, maxWidth: .infinity,
                   alignment: .leading)
            .clipped()
            .layoutPriority(-1)
            if layout.showDate {
                Text(columns?.date ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: PlaylistColumns.date, alignment: .trailing)
            }
            if layout.showSize {
                Text(columns?.size ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: PlaylistColumns.size, alignment: .trailing)
            }
            ClassifyChips(path: path)
                .frame(width: PlaylistColumns.classify, alignment: .center)
            if layout.showRemark {
                ClassifyRemark(path: path)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: layout.remark, alignment: .leading)
            }
            Color.clear.frame(width: PlaylistColumns.trailing)
        }
        .padding(.horizontal, PlaylistColumns.inset)
        .padding(.vertical, 5)
        // Every row the same height whether or not it carries tags: a list
        // of rows of two different heights is what read as untidy.
        .frame(minHeight: library.showThumbnails ? 46 : 34)
        .background(rowTint)
        // A 3pt bar says WHICH row is playing even when a selection has
        // tinted half the list the same colour.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isCurrent ? Color.accentColor : .clear)
                .frame(width: 3)
        }
        .contentShape(.rect)
        // The verdict buttons live in this row but are only drawn under the
        // cursor — hover is tracked on the whole row so moving from the
        // filename across to the chips never dismisses them.
        .onHover { hovering = $0 }
        .onTapGesture { selectAndShow(path, app, playback) }
        .contextMenu { RowMenu(path: path, playback: playback) }
        // Stat-ed when the row appears, off the main thread: a share that has
        // gone to sleep answers its first question in seconds.
        .task(id: path) { columns = await library.stats(for: path) }
    }

    @State private var columns: (date: String, size: String)?
    @State private var hovering = false

    private var selected: Bool { app.selection.contains(path) }

    /// Three things want to colour this row, so they are ranked. Selection is
    /// the strongest — while several are picked, seeing which ones matters
    /// more than seeing which is playing, and the playing row keeps its bold
    /// name and accent bar to say so anyway.
    private var rowTint: Color {
        if selected { return Color.accentColor.opacity(0.25) }
        if isCurrent { return Color.accentColor.opacity(0.18) }
        return hovering ? Color.secondary.opacity(0.10) : .clear
    }

}

/// A tile in the icon grid: the poster frame with the name under it.
struct IconTile: View {
    let path: String
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    private var selected: Bool { app.selection.contains(path) }

    var body: some View {
        VStack(spacing: 4) {
            PosterView(path: path, big: true)
                .frame(width: 132, height: 74)
                .clipShape(.rect(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(playback.currentPath == path
                                      ? Color.accentColor : .clear, lineWidth: 2)
                }
                .overlay(alignment: .topLeading) {
                    // A tick on the picture, drawn only on tiles that are
                    // picked. There is no mode to turn on any more, so it
                    // appears the moment a tile is chosen and goes when it
                    // is not — a hollow circle on every tile would be noise
                    // over a grid of pictures.
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                            .padding(4)
                    }
                }
            HStack(spacing: 3) {
                if let problem = playback.problems[path] {
                    FileBadge(problem: problem, small: true)
                }
                if library.rating(path) > 0 {
                    Text(String(repeating: "★", count: library.rating(path)))
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                        .fixedSize()
                }
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 132)
            if !library.tagsFor(path).isEmpty {
                ChipCluster(names: library.tagsFor(path)).frame(width: 132)
            }
        }
        .padding(3)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear,
                    in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture { selectAndShow(path, app, playback) }
        .contextMenu { RowMenu(path: path, playback: playback) }
    }
}

// MARK: - the small pieces

/// What a row offers on a right click.
struct RowMenu: View {
    let path: String
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    /// Needed because tagging and un-favouriting change what BELONGS in the
    /// playlist, not merely how a row is drawn — the list has to be re-asked.
    @ObservedObject var playback: PlaybackController

    /// What the command applies to: the ticked rows when this row is one of
    /// them, otherwise just this row. Right-clicking inside a selection acts
    /// on the selection, the way Finder does.
    private var targets: [String] {
        app.selection.contains(path) ? Array(app.selection) : [path]
    }

    var body: some View {
        // First, because it is the question a right click most often means:
        // what IS this one? Always about THIS row, never the selection — the
        // sheet answers for a single file.
        // Ticks this row first: the window follows `infoTarget`, so asking
        // about a row means making it the row in hand. Finder's rule, and it
        // is what lets the next click in the playlist re-answer the window
        // instead of leaving it showing a video nobody is looking at.
        Button("Get Info") {
            app.selection = [path]
            openWindow(id: "info")
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        Divider()
        Button("Rename…") { app.renameFile(path) }
        Button(targets.count > 1 ? "Move \(targets.count) Videos…" : "Move to Folder…") {
            app.moveFiles(targets)
        }
        Button(targets.count > 1 ? "Delete \(targets.count) Videos…" : "Delete…") {
            app.trashFiles(targets)
        }
        Divider()
        // App-only hiding: the file is untouched, so this sits beside Move and
        // Delete but does nothing like them. Outside the Hidden view it is
        // "Hide"; inside it, the only useful thing is the way back out.
        if library.isHidden(path) {
            Button(targets.count > 1 ? "Unhide \(targets.count) Videos" : "Unhide") {
                app.unhideVideos(targets)
            }
            .help("Put these back in the library. Their tags and marks were never touched.")
        } else {
            Button(targets.count > 1 ? "Hide \(targets.count) Videos" : "Hide") {
                app.hideVideos(targets)
            }
            .help("Keep these out of the app's sight. The files themselves are untouched.")
        }
        Divider()
        // Right where the trouble shows: a row marked missing or unplayable
        // is exactly when this question gets asked, and asking it of one
        // video is far quicker than sweeping the whole playlist.
        Button(targets.count > 1
               ? "Find \(targets.count) Missing Files…"
               : "Find Missing File…") {
            app.findMoved(targets)
        }
        Divider()
        // Classify the ticked rows. The playlist-wide action in the AI menu
        // takes the whole visible list, which is the wrong scope when you have
        // picked out five files; this is the selection, the way Move, Delete
        // and Hide above already work. Filed as a real job, so it appears in
        // the analysis history with retry and cancel — unlike the automatic
        // pass that playing a video starts.
        Button(targets.count > 1 ? "Classify \(targets.count) Videos" : "Classify") {
            guard app.requireAI(.classify) else { return }
            Task { await app.classifyNow(paths: targets) }
        }
        .help("Ask the local engine for a Safe / NSFW verdict on these videos. "
              + "Videos already settled by you or the machine are skipped.")
        Divider()
        // Stars on the targets — the ticked rows when this row is one of
        // them. The tick shows this row's own rating; picking the ticked
        // star clears, the same rule the transport bar's control uses.
        StarRatingMenuItems(current: targets.compactMap { library.rating($0) }.max() ?? 0) { stars in
            library.setRating(stars, for: targets)
        }
        // The full tag vocabulary, not a popular-top-12 — the same set the
        // sidebar and the tag panel offer, minus the star marks (the Stars
        // control above owns those). Applies to the selection when this row
        // is part of one, otherwise just this row.
        // Hand-taggable only: a metadata tag is read off the file, so putting
        // one on by hand would be a false statement about the file itself.
        if !library.handTaggableTags().isEmpty {
            Menu("Tags") {
                ForEach(library.handTaggableTags(), id: \.self) { name in
                    Button {
                        // The same toggle the label shows, but each direction
                        // goes through the function that owns it: taking the
                        // tag off is destructive and records the undo, adding
                        // it is not and does not spend the slot.
                        if targets.allSatisfy({ library.hasTag($0, name) }) {
                            library.removeTag(name, from: targets)
                        } else {
                            library.addTag(name, to: targets)
                        }
                        // Tagging from here can add the video to the very tag
                        // playlist being looked at, or remove it from it.
                        playback.refreshMembership()
                    } label: {
                        if targets.allSatisfy({ library.hasTag($0, name) }) {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        }
    }
}

/// Tags, drawn as chips.
///
/// Every chip is held to one line and given no chance to compress: a long tag
/// in a narrow column was being squeezed until it set one letter per line.
/// What will not fit is truncated, and the tooltip carries the lot.
struct ChipRow: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(names.prefix(3), id: \.self) { name in
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    // Its own width, never squeezed into one: compressing a
                    // chip is what let a long tag wrap to a letter a line.
                    // What does not fit is clipped by the row instead.
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: .capsule)
            }
            if names.count > 3 {
                Text("+\(names.count - 3)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .help(names.joined(separator: ", "))
    }
}

/// Tags under a tile, wrapped rather than squeezed.
///
/// A tile is 132pt wide and its tags were being laid out on one line and
/// clipped, so three tags arrived on top of each other. Here they flow onto
/// as many lines as they need, up to two — past that the rest become "+N",
/// because a tile is a picture with a label, not a tag list.
struct ChipCluster: View {
    let names: [String]
    /// Two lines of tags under a 74pt-tall poster is the most that reads as
    /// a caption rather than a wall.
    var maxLines = 2

    var body: some View {
        ChipFlow(spacing: 3) {
            ForEach(shown, id: \.self) { name in
                Text(name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: .capsule)
            }
            if names.count > shown.count {
                Text("+\(names.count - shown.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 2)
            }
        }
        .help(names.joined(separator: ", "))
    }

    /// How many chips to draw before giving up and counting the rest.
    /// The arithmetic lives in the model layer, where the tests can reach it.
    private var shown: [String] {
        Array(names.prefix(chipsThatFit(names, width: 132, lines: maxLines)))
    }
}

/// A poster frame, fetched when the row appears and drawn once it lands.
struct PosterView: View {
    let path: String
    let big: Bool
    @EnvironmentObject var media: MediaCache
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).clipped()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "film").font(.caption).foregroundStyle(.tertiary)
                    }
            }
        }
        // Fetched here rather than in `body`: asking for it while the view is
        // being drawn would have the fetch change state mid-update.
        .task(id: path) { image = await media.poster(path, big: big) }
    }
}

/// A row-level mark that this file failed to play: ✗ red for missing (the
/// file is not on disk any more), ⚠ orange for corrupted or unsupported
/// (it is there but refuses to play). Hover says which is which.
struct FileBadge: View {
    let problem: PlaybackController.FileProblem
    var small = false

    var body: some View {
        Image(systemName: symbol)
            .font(small ? .system(size: 8) : .caption2)
            .foregroundStyle(tint)
            .help(reason)
    }

    private var symbol: String {
        switch problem {
        case .missing: "xmark.circle.fill"
        case .corrupted: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch problem {
        case .missing: .red
        case .corrupted: .orange
        }
    }

    private var reason: String {
        switch problem {
        case .missing: "Missing — the file is not on disk any more"
        case .corrupted: "Corrupted or unsupported — the file is there but will not play"
        }
    }
}

// MARK: - the classify columns
//
// The review window lives on as code no more: its per-row verbs — the two
// label chips and the caption that says who said what — sit at the end of
// every playlist row instead. The store and engine arrive through the
// environment, exactly as the review window received them.

/// The Safe / NSFW pair for one row. The chip for the verdict in force — the
/// user's mark or the machine's filing — fills with a check; pressing the
/// other chip is a correction. Identical behavior to the old review window's
/// chips, one row earlier in the workflow.
struct ClassifyChips: View {
    let path: String
    /// Kept for the row's hover state; the chips are always drawn. The user
    /// tried the hover-reveal version and preferred the pair standing there
    /// permanently — a verdict is the thing this list is FOR, so it must be
    /// one click away without hunting for it.
    var hovering = false
    @EnvironmentObject var analysis: AnalysisStore

    var body: some View {
        HStack(spacing: 4) {
            chip(.safe)
            chip(.nsfw)
        }
    }

    private func record() -> VideoAnalysis? { analysis.analysis(for: path) }

    private func chip(_ label: NsfwLabel) -> some View {
        let current = record()?.userLabel
        let inForce = current == label
            || (current == nil && record().flatMap({ AnalysisStore.machineVerdict($0) }) == label)
        return Button {
            analysis.mark(label, on: [path])
        } label: {
            HStack(spacing: 2) {
                // The checkmark is drawn in a slot that is always there, so
                // the word beside it never moves when a verdict lands.
                Image(systemName: current == nil ? "checkmark.circle" : "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(inForce ? 1 : 0)
                Text(label.title)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 9, weight: .medium))
        // One line, whatever the column does around it: a wrapped chip reads
        // as two rows of noise.
        .lineLimit(1)
        // Each chip owns an exact slot. Sized to itself, the chip carrying
        // the checkmark grew and pushed its neighbour sideways, so the pair
        // wandered from row to row instead of standing in a column.
        .buttonStyle(LabelChipStyle(applied: inForce, minWidth: nil))
        .frame(width: PlaylistColumns.chip)
        .disabled(current == label)
    }
}

/// The remark column: who decided, and the machine's confidence. Mirrors the
/// old review window's caption; doubles as per-row progress while the engine
/// runs (queued / being analysed).
struct ClassifyRemark: View {
    let path: String
    @EnvironmentObject var analysis: AnalysisStore
    @EnvironmentObject var engine: AnalysisEngine

    var body: some View {
        Text(remark)
    }

    private var remark: String {
        guard let record = analysis.analysis(for: Paths.tagKey(path)) else { return "" }
        if engine.isBusy {
            switch record.phase {
            case .queued: return "queued"
            case .analyzing: return "analysing…"
            default: break
            }
        }
        if let label = record.userLabel {
            var text = "you: \(label.title.lowercased())"
            if let score = record.prediction?.score { text += String(format: " (%.0f%%)", score * 100) }
            return text
        }
        if let score = record.prediction?.score {
            return String(format: "machine: %@ %.0f%%",
                          AnalysisStore.machineVerdict(record)?.title.lowercased() ?? "n/a",
                          score * 100)
        }
        switch record.phase {
        case .failed: return "failed"
        case .done: return "done"
        default: return ""
        }
    }
}
