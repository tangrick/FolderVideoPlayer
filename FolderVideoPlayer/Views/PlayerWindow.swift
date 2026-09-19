import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlayerWindow: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var library: Library
    @EnvironmentObject var media: MediaCache
    @EnvironmentObject var app: AppModel
    /// Held here only to hand on to the Info sheet, which presents from this
    /// view and therefore inherits nothing.
    @EnvironmentObject var suggestions: SuggestionStore

    var body: some View {
        Group {
            if let playback = app.playback {
                PlayerScreen(playback: playback)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .alert(item: $app.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.detail))
        }
        .sheet(isPresented: $app.showAutoTag) {
            if let root = app.autoTagRoot {
                AutoTagSheet(root: root) { app.stopAutoTag() }
            }
        }
        // The hidden-videos password: before a first hide, before revealing
        // the Hidden view. Settings runs its own copy of this sheet.
        .sheet(item: $app.hiddenSheet) { kind in
            HiddenPasswordSheet(kind: kind) { app.hiddenSheetSucceeded(kind) }
                .environmentObject(library)
                .environmentObject(app)
        }
        // Whose tags is this session about? Asked once, at launch, and only
        // when this Mac holds more than one profile to choose between.
        .onChange(of: app.needsProfileChoice) {
            guard app.needsProfileChoice else { return }
            app.needsProfileChoice = false
            openWindow(id: "profiles")
        }
    }
}

struct PlayerScreen: View {
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var engine: AnalysisEngine
    @EnvironmentObject var suggestions: SuggestionStore
    @EnvironmentObject var journal: EvidenceJournal

    /// The library sidebar is there whenever it is asked for — and always
    /// when there is nothing playing, because then it is the only thing to do.
    /// Full screen is for watching, so neither panel is there.
    private var showingLibrary: Bool {
        !app.fullScreen && (app.showLibrary || playback.playlist.isEmpty)
    }

    private var showingPlaylist: Bool {
        !app.fullScreen && app.showPlaylist && !playback.playlist.isEmpty
    }

    /// True while something draggable is over the window, so the overlay can
    /// say what dropping would do. A drop target that gives no sign it is one
    /// is indistinguishable from a window that ignores drops.
    @State private var dropping = false

    /// When the title last recomputed its "Published … ago" words — bumped by
    /// the minute timer so the age stays true while the window sits open.
    @State private var titleNow: Double = Date().timeIntervalSince1970

    /// The whole title: where you are in the playlist, and — the point of the
    /// document model — whether what you are looking at is what the TV sees.
    private var playerTitle: String {
        let document = PlayerWindowTitle.profilePart(
            name: library.person,
            open: library.profileOpen,
            publishing: library.isPublishing,
            publishedClean: library.publishedClean,
            lastPublishedAt: library.lastPublishedAt,
            now: titleNow)
        let playlist = PlayerWindowTitle.windowTitle(
            playlistEmpty: playback.playlist.isEmpty,
            sessionLabel: playback.sessionLabel,
            mode: CoreMLClassifier.mode,
            support: Paths.support)
        switch (document, playlist == "FolderVideoPlayer") {
        case (nil, true): return "FolderVideoPlayer"
        case (nil, false): return playlist
        case (let doc?, true): return doc
        case (let doc?, false): return doc + " — " + playlist
        }
    }

    /// Take the dropped file URLs and hand them to the player.
    ///
    /// `loadItem` answers on a background queue, so the paths are gathered
    /// there and the playing happens back on the main actor.
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var paths: [String] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier) else { continue }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    paths.append(url.path)
                } else if let url = item as? URL {
                    paths.append(url.path)
                }
            }
            guard !paths.isEmpty else { return }
            playback.openDropped(paths.sorted())
        }
        return true
    }

    /// The bar is always there in a window. Full screen it fades with the
    /// pointer, and stays put whenever nothing is playing.
    private var showingBar: Bool {
        !app.fullScreen || app.controlsVisible || !playback.playing
    }

    var body: some View {
        HStack(spacing: 0) {
            if showingLibrary {
                LibrarySidebar(playback: playback)
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                if app.fullScreen {
                    // Over the picture rather than under it, so the video keeps
                    // the whole screen and the bar is something that appears.
                    stage.overlay(alignment: .bottom) {
                        if showingBar {
                            TransportBar(playback: playback, head: playback.head)
                                .background(.ultraThinMaterial)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                } else {
                    stage
                    TransportBar(playback: playback, head: playback.head)
                }
            }
            if showingPlaylist {
                Divider()
                PlaylistSidebar(playback: playback)
                    .transition(.move(edge: .trailing))
            }
        }
        // A folder dropped on the window opens it, the way every Mac player
        // works. The whole window takes the drop, not just the picture: with
        // nothing playing the picture is the smallest target on screen.
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            receive(providers)
        }
        .overlay {
            if dropping {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 34))
                        Text("Drop a folder to play it")
                            .font(.headline)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropping)
        .animation(.easeInOut(duration: 0.22), value: showingLibrary)
        .animation(.easeInOut(duration: 0.22), value: showingPlaylist)
        .animation(.easeInOut(duration: 0.2), value: showingBar)
        .background(WindowWatcher(app: app))
        .fullScreenControls(app, paused: !playback.playing)
        .navigationTitle(playerTitle)
        // "Published 2 min ago" has to age. The title only recomputes when a
        // value it reads changes, so a minute timer refreshes the words while
        // a profile is open; idle without a profile needs no ticking.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            titleNow = Date().timeIntervalSince1970
        }
        .onChange(of: library.lastPublishedAt) { titleNow = Date().timeIntervalSince1970 }
        .onChange(of: app.showTagPanel) { _, open in playback.tagPanelOpen = open }
        // A new scope is a new list. The rows a selection pointed at are not on
        // screen any more, so the batch controls must not go on acting on them —
        // and the tag panel reads that same selection, so it would keep
        // describing videos the user has just navigated away from. Clearing it
        // hands the panel back to the video that IS playing.
        .onChange(of: playback.mode) { _, _ in app.selectNone() }
        .onChange(of: playback.tagName) { _, _ in app.selectNone() }
        .onChange(of: playback.root) { _, _ in app.selectNone() }
        // Same rule for the tag FILTER. Ticking a tag in the left panel narrows
        // the playlist without changing `tagName` or `mode`, so the three
        // handlers above never fire — and a batch picked before the tick stayed
        // live against rows that had just been filtered out of sight. That is
        // the case where chips land on videos the user cannot see.
        .onChange(of: playback.tagFilter) { _, _ in app.selectNone() }
        .onChange(of: playback.tagExcluded) { _, _ in app.selectNone() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.suggestTagsNotification)) { note in
            guard let path = note.object as? String else { return }
            Task { await suggestTags(for: path) }
        }
        // Transcribing: asked for from the video's row in the tag panel, never
        // on its own. Cancel reaches the model through the flag on the
        // transcriber, so it stops at the next window instead of at the end.
        .onReceive(NotificationCenter.default.publisher(for: AppModel.transcribeNotification)) { note in
            guard let path = note.object as? String else { return }
            Task { await transcribe(path) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.cancelTranscribeNotification)) { _ in
            app.transcribing?.cancel()
        }
        // Opening a video asks for tag ideas about it, once. The maintainer
        // asked for this on 2026-09-17, replacing the explicit Suggest Tags
        // button that `f94ec78` had put in its place: chips should be there
        // when the panel opens, not one press away on every video.
        //
        // The cost is real and is the reason this was explicit before — a pass
        // decodes and embeds around 75 frames, a few seconds of CPU per video.
        // It is paid once per video: a video with current suggestions is
        // skipped, and a video whose pass produced nothing is not asked again
        // this launch (see `AppModel.autoSuggestAttempted`).
        .onChange(of: playback.currentPath) { _, path in
            guard let path else { return }
            Task { await autoWork(path) }
        }
        // One pass runs at a time, so a video opened while another was running
        // was skipped. When a pass ends, look at what is on screen NOW — or
        // browsing faster than the engine would leave videos permanently blank.
        .onChange(of: app.suggestingPath) { _, running in
            guard running == nil, let path = playback.currentPath else { return }
            Task { await autoWork(path) }
        }
    }

    /// Everything playing a video is allowed to start, in the order that makes
    /// it cheapest.
    ///
    /// Classify FIRST, then suggest. Not arbitrary: the classify pass leaves
    /// its decoded frames in the classifier's memo, and the suggestion pass
    /// over the same video then reuses them — measured at 75 + 0 decoded
    /// frames with 75 memo hits, half the decoding of two independent passes.
    /// Suggesting first would throw that away, and running them concurrently
    /// would make one of them bounce off the other's busy guard.
    private func autoWork(_ path: String) async {
        await autoClassify(path)
        await autoSuggest(path)
    }

    /// The automatic classification: what playing a video is allowed to start.
    ///
    /// Deliberately NOT the job ledger. The ledger is the record of explicit
    /// jobs — the playlist's right-click Classify, with history, retry and
    /// cancellation — and filing one job per video watched would bury the
    /// jobs the user actually asked for and pop an "analysis already running"
    /// notice while browsing. This takes the play-time route the store was
    /// built for: `needsClassification` decides, `enqueue` queues, `run`
    /// rescues any stale row and works the queue.
    private func autoClassify(_ path: String) async {
        // A closed profile has no tag vocabulary to classify INTO: the store
        // would file verdicts nobody reads, and the suggestion pass behind it
        // would offer chips for a tag set that is deliberately not in force.
        guard library.profileOpen else { return }
        // The one switch, checked BEFORE the attempt is recorded: turning the
        // pass back on must not find this video already marked as tried.
        guard library.autoWorkWhilePlaying else { return }
        guard app.ai.works(.classify) else { return }
        // Models mid-replacement: the pass cannot load them, and this check sits
        // before the attempt is recorded, so the video is asked again later
        // rather than going without classification for the whole launch.
        guard !app.downloads.isReplacing else { return }
        guard app.suggestingPath == nil, !app.engine.isBusy else { return }
        guard app.analysis.wantsAutoClassification(path,
                                                   attempted: app.autoClassifyAttempted)
        else { return }
        app.autoClassifyAttempted.insert(Paths.tagKey(path))
        app.analysis.enqueue([path])
        await app.engine.run(store: app.analysis, paths: [path])
    }

    /// The automatic pass: what opening a video is allowed to start.
    ///
    /// Separate from `suggestTags` because the rules are not the same. An
    /// explicit request re-runs whatever it is pointed at; this one must be
    /// unable to spend the machine's time twice on the same video, so it
    /// refuses a video that already has current suggestions and a video it has
    /// already tried this launch.
    private func autoSuggest(_ path: String) async {
        // Same closed-profile rule as `autoClassify` — suggestions are tag
        // ideas, and with no profile open there is no tag set to suggest from.
        guard library.profileOpen else { return }
        // The same one switch as classification, with the same placement rule:
        // before the attempt is recorded, so a video played while the pass is
        // off is not charged for the attempt it never got.
        guard library.autoWorkWhilePlaying else { return }
        // Same rule as `autoClassify`, and for the same reason it sits before the
        // attempt is recorded: a swap in progress must not cost this video its
        // one automatic suggestion pass.
        guard !app.downloads.isReplacing else { return }
        guard app.ai.works(.tags), app.suggestingPath == nil, !app.engine.isBusy else { return }
        let nsfw = Self.filedNSFW(path, analysis: app.analysis)
        guard suggestions.wantsAutoSuggestion(path, model: engine.suggestionModelID,
                                              paired: nsfw,
                                              attempted: app.autoSuggestAttempted)
        else { return }
        app.autoSuggestAttempted.insert(Paths.tagKey(path))
        await suggestTags(for: path)
    }

    /// Transcribe one video, at the user's asking, and own the app's state
    /// around it: which video is running, what the panel shows, and what to say
    /// when it refuses.
    ///
    /// The writing is not done here. The pass owns that, and it writes nothing
    /// at all for a run that was cancelled or whose file changed underneath it.
    private func transcribe(_ path: String) async {
        guard app.transcribingPath == nil else { return }
        let root = URL(fileURLWithPath: Paths.support).appendingPathComponent("models/speech")
        guard FileManager.default.fileExists(atPath: root.path) else {
            app.jobNotice = "The speech model is not installed. Install it in Settings → AI."
            return
        }
        let transcriber = WhisperKitTranscriber(modelsRoot: root)
        app.transcribing = transcriber
        app.transcribingPath = path
        app.transcribeProgress = SpeechProgress(stage: "Reading the audio",
                                                done: 0, total: 0, lines: 0)
        defer {
            app.transcribing = nil
            app.transcribingPath = nil
            app.transcribeProgress = nil
        }
        do {
            let outcome = try await journal.transcribe(path: path, using: transcriber) { progress in
                Task { @MainActor in app.transcribeProgress = progress }
            }
            app.transcriptLines[path] = outcome.lines
            app.jobNotice = "Transcribed \(outcome.lines) lines."
        } catch is CancellationError {
            app.jobNotice = SpeechPassRefusal.cancelled.sentence
        } catch let refusal as SpeechPassRefusal {
            app.jobNotice = refusal.sentence
        } catch {
            app.jobNotice = "Transcribing stopped: \(error.localizedDescription). "
                + "If the speech model is missing, install it in Settings → AI."
        }
        await transcriber.unload()
    }

    /// Ask the engine for tag ideas about one video, once.
    ///
    /// Silent by design. It skips videos already suggested for, never reports
    /// failure to the user (the engine logs its own troubles), and holds no
    /// UI state — if it works, chips appear in the tag panel; if not, nothing
    /// happens and playback is untouched.
    ///
    /// `paired` follows the video's verdict: only a video filed NSFW
    /// (by the engine or by the user) gets the paired-tag candidates — safe
    /// content is never asked which way it leans.
    private func suggestTags(for path: String) async {
        // Reached from `autoSuggest` when a video opens, and from the
        // re-analyse request. The "once per video" rules live in the caller.
        guard app.ai.works(.tags), app.suggestingPath == nil, !app.engine.isBusy else { return }
        let profile = Paths.activeProfile
        let context = app.analysis.contextID
        app.suggestingPath = path
        defer { app.suggestingPath = nil }
        let nsfw = Self.filedNSFW(path, analysis: app.analysis)
        let engine = self.engine
        let payload = libraryTagPrototypes(excluding: path)
        // What the videos shot around this one say about each tag — built from
        // dates the library ALREADY holds, so a cold cache yields no opinion
        // rather than a stat storm on a sleeping share. `datedPool()` drops
        // hidden videos; this must never be assembled from raw `addedDates`.
        // Off unless the dev override says otherwise: the parity gates compare
        // against engine.py, which has no neighbour prior, and an empty one is
        // a no-op that leaves ranking exactly as it ships today.
        let neighbours = NeighbourPrior.enabled
            ? NeighbourPrior.measure(for: library.addedOn(path),
                                     dated: library.datedPool(),
                                     tagsFor: { library.tagsFor($0) },
                                     excluding: path)
            : NeighbourPrior()
        guard let result = await engine.suggestTags(for: path, paired: nsfw,
                                                    faces: library.facesEnabled,
                                                    libraryTags: payload,
                                                    neighbours: neighbours) else { return }
        guard profile == Paths.activeProfile, context == app.analysis.contextID, !Task.isCancelled else { return }
        suggestions.record(path, suggestions: result.tags, model: result.model,
                           framesSeen: result.framesSeen, paired: nsfw,
                           facesDetected: result.facesDetected)
        // The chips are stored; now the WHEN. Written here, from the same pass
        // and the same rule that offered them, so a reviewer can see which
        // frames agreed rather than being asked to take the chip on trust.
        //
        // Skipped entirely when the app cannot name the space it scored in:
        // evidence that cannot say which vectors it came from is evidence no
        // later pass could check, and the columns it would leave blank are the
        // ones the store scopes on.
        if let sighting = await engine.tagSightings(for: path, tags: result.tags),
           let space = engine.tagsSpace {
            journal.record(path: path, model: space.sourceLabel,
                           space: space.identityLabel, sighting)
        }
        // No face work means no face hashes to file. Guarded rather than
        // trusted: an empty list from a switched-off engine must not be read
        // as "this video has no faces", which is a different claim.
        if library.facesEnabled {
            app.faceStore?.recordFaces(result.faceHashes, for: path)
        }
    }

    /// The user's own tag vocabulary, as frame-hash prototypes for the engine.
    ///
    /// For every library tag the current video does NOT already carry, gather
    /// up to a few analysed tagged videos and their cached frame hashes. The
    /// engine averages those vectors into a prototype and offers the tag when
    /// a video looks like them — which is how tags CLIP never heard of (Kite,
    /// Bench, Confetti…) can be suggested AND rejected. Payload is capped: a tag's
    /// prototype needs only a handful of videos, and a video's first few
    /// frames carry the picture.
    private func libraryTagPrototypes(excluding path: String,
                                      maxVideosPerTag: Int = 8,
                                      maxFramesPerVideo: Int = 10) -> [String: [String: [String]]] {
        // The building lives in the model layer so a gate can reach it — see
        // LibraryTagPayload for the `as? [String]` bug that hid in here and kept
        // the library source silent for the whole life of the feature.
        // Hidden videos are invisible to the app, so they are no part of a
        // prototype either — a tag's look must not be learned from videos the
        // user has taken out of sight.
        let visibleTags = library.tags.filter { !library.hidden.contains($0.key) }
        return LibraryTagPayload.build(
            current: Paths.tagKey(path),
            tags: visibleTags,
            frameHashes: { key in
                app.analysis.analysis(for: key)?.frameScores.map(\.hash) ?? []
            },
            maxVideosPerTag: maxVideosPerTag,
            maxFramesPerVideo: maxFramesPerVideo)
    }

    /// Is this video NSFW in force: the user's mark wins, otherwise the
    /// engine's own filing at its 0.5 cut.
    private static func filedNSFW(_ path: String,
                                  analysis: AnalysisStore?) -> Bool {
        guard let record = analysis?.analysis(for: path) else { return false }
        if let label = record.userLabel { return label == .nsfw }
        return AnalysisStore.machineVerdict(record) == .nsfw
    }

    /// The picture, with whatever has to be said over it.
    private var stage: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if playback.scanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for videos…").foregroundStyle(.secondary)
                }
            } else if playback.playlist.isEmpty {
                EmptyStage(playback: playback)
            } else {
                VideoSurface(player: playback.engine.player)
                    .accessibilityLabel("Video")
                    .accessibilityValue(playback.currentPath.map {
                        ($0 as NSString).lastPathComponent
                    } ?? "Nothing playing")
                    .accessibilityHint("Click to play or pause, double-click for full screen")
                    // A double click is what a player means by full screen;
                    // a single one plays and pauses, as before.
                    .onTapGesture(count: 2) { app.toggleFullScreen() }
                    .onTapGesture { playback.togglePlayPause() }
            }
            if let trouble = playback.trouble {
                Text(trouble)
                    .font(.callout)
                    .padding(10)
                    .background(.thinMaterial, in: .rect(cornerRadius: 8))
                    .padding(.bottom, (app.showTagPanel || app.showTranscriptPanel) ? 150 : 14)
                    .transition(.opacity)
            }
            if app.showTagPanel {
                // With no profile open the panel shows the reason instead of
                // an editor for a tag set nobody owns — and ⌘T is disabled in
                // the Tags menu, so this only shows if it was open at close.
                if library.profileOpen {
                    TagPanel(playback: playback)
                        .transition(.move(edge: .bottom))
                } else {
                    closedProfileNotice
                        .transition(.move(edge: .bottom))
                }
            }
            if app.showTranscriptPanel {
                // Transcripts live in the profile's store, so with no profile
                // open there is nothing to read and the panel says so rather
                // than showing an empty list as if the film were silent.
                if library.profileOpen {
                    TranscriptPanel(playback: playback)
                        .transition(.move(edge: .bottom))
                } else {
                    closedProfileNotice
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.showTagPanel)
        .animation(.easeInOut(duration: 0.2), value: app.showTranscriptPanel)
    }

    /// What the tag panel's place says when no profile is open. The player
    /// itself keeps working — this is the one surface that needs a reason
    /// rather than a grey control, because it can be on screen at the moment
    /// the profile closes and a vanished panel reads like a crash.
    private var closedProfileNotice: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No profile is open")
                .font(.headline)
            Text("File ▸ Open Profile brings your tags back. Videos play as usual.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.bar)
    }
}

/// The player with nothing in it — the first thing anybody sees.
///
/// Three real actions rather than a line of grey print. It used to say
/// "Choose a folder, a tag or your favorites" with nothing to choose: a tag
/// needs a library, favorites need videos, and both need a folder opened
/// first. So: open a folder (the only way in), the folders you had open
/// before (if any), and the tour.
private struct EmptyStage: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var playback: PlaybackController
    /// The tour is offered until it has been taken once. After that the
    /// empty screen keeps its two real actions and loses the third: help is
    /// in the Help menu for anybody who wants it again.
    @AppStorage("tourTaken") private var tourTaken = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Nothing playing")
                .font(.title3.weight(.semibold))
            Text("Point the app at a folder of videos. Tags, stars and "
                 + "duplicates all follow from there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            HStack(spacing: 8) {
                Button {
                    chooseFolder(playback: playback)
                } label: {
                    Label("Open a Folder…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    ForEach(library.recent, id: \.self) { root in
                        Button((root as NSString).lastPathComponent) {
                            playback.openFolder(root)
                        }
                    }
                } label: {
                    Label("Open Recent", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(library.recent.isEmpty)

                if !tourTaken {
                    Button {
                        tourTaken = true
                        app.helpPage = .quickStart
                        openWindow(id: "help")
                    } label: {
                        Label("Take the Tour", systemImage: "questionmark.circle")
                    }
                }
            }
            .padding(.top, 6)

            Text("No account, nothing uploaded — everything happens on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            // One line, offered only while nothing is installed. Never a modal
            // and never on a first launch that has to be dismissed: the app is
            // useful without any of it, and this is the whole of the invitation.
            if nothingInstalled {
                Button("AI features are available — Set Up…") {
                    app.settingsTab = .ai          // land ON the page, not merely
                    openSettings()                 // inside the window
                }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Tag suggestions and Safe/NSFW sorting are a download away."
                          + " Everything else already works without them.")
                    .padding(.top, 2)
            }
        }
        .padding(30)
    }

    /// Has the user installed none of the download catalogue?
    ///
    /// Asked of the downloader rather than the capability probe, because this
    /// is about what is on disk, not about what this Mac could run: a machine
    /// with the models already present gets no invitation at all. An unfetched
    /// catalogue counts as nothing installed, which is the right answer for a
    /// stranger's first launch.
    private var nothingInstalled: Bool {
        (app.downloads.manifest?.bundles ?? []).allSatisfy { !app.downloads.isInstalled($0) }
    }
}

/// Everything there is to play, down the left: a folder to open, where you
/// left off, the folders you have had open lately, your favorites, and every
/// tag with something behind it.
///
/// It sits beside the picture rather than in front of it, so choosing what to
/// watch next never interrupts what is playing now.
struct LibrarySidebar: View {
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var faceStore: FaceStore
    @Environment(\.openWindow) private var openWindow

    @State private var counts: [String: Int] = [:]
    /// Real folder icons for the pinned and recent rows, fetched off the
    /// main thread beside the counts — an icon lookup is a stat on the
    /// volume, and a sleeping share should not freeze the sidebar.
    @State private var folderIcons: [String: NSImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // The order NEVER changes, and the three navigation sections
                // are always drawn — Pinned and Recent used to vanish when
                // empty and come back when not, so the sidebar rearranged
                // itself between sessions and the row you reached for had
                // moved. An empty section says it is empty instead; that is
                // one quiet line, against a list that jumps.
                //
                // The data-driven sections below them still come and go,
                // because a heading the user has never made is not a section
                // that has gone missing.
                VStack(alignment: .leading, spacing: 16) {
                    open
                    pinned
                    recent
                    stars
                    // Headings first: a filed tag is easier to find under its
                    // heading than in a long alphabetical run, and the run is
                    // what is left over.
                    headingLists
                    if !tags.isEmpty { tagList }
                    // What the app READ off the files, below the tags: your own
                    // words come first, the file's facts after them.
                    fileFactLists
                    // People is the face section. With face recognition off it
                    // goes away entirely rather than sitting there empty and
                    // inviting a click that would do nothing.
                    if library.facesEnabled { peopleList }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: library.recent + library.pinned) { await loadCounts() }
            .task {
                // Load named people so a library that has them shows them
                // without waiting for the People window. Skipped when face
                // recognition is off — the section is hidden anyway, and
                // waking the engine for it would be work the user declined.
                if faceStore.people.isEmpty && library.facesEnabled {
                    await faceStore.reload()
                }
            }
            Divider()
            HStack {
                Button {
                    app.showLibrary = false
                } label: {
                    Label("Hide", systemImage: "sidebar.leading")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Hide the library (⌘N)")
                .accessibilityLabel("Hide the library")
                .disabled(playback.playlist.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: library.librarySidebarWidth ?? 250)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { libraryResizeHandle }
    }

    /// The edge you drag to resize the library panel. A fixed-width hit zone
    /// straddling the panel's right edge — wide enough to find, and the
    /// cursor flips to the resize arrows whenever it is over the zone, not
    /// just while dragging.
    private var libraryResizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 14)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { drag in
                        let start = widthAtDragStart ?? 250
                        widthAtDragStart = start
                        // The panel is on the left, so dragging right widens it.
                        library.librarySidebarWidth = min(max(start + drag.translation.width, 200), 600)
                    }
                    .onEnded { _ in
                        widthAtDragStart = nil
                        library.save()
                    }
            )
    }

    @State private var widthAtDragStart: Double?
    /// The three navigation sections' folds. Open by default — they are how
    /// you get anywhere — but each remembers being shut.
    @AppStorage("sidebarPinnedOpen") private var pinnedOpen = true
    @AppStorage("sidebarRecentOpen") private var recentOpen = true
    @AppStorage("sidebarStarsOpen") private var starsOpen = true

    /// Which headings are open. One string rather than one setting per
    /// heading, because headings are the user's own and there is no list of
    /// them to write settings for in advance.
    @AppStorage("sidebarOpenHeadings") private var openHeadingsRaw = ""

    /// The people the face engine knows, lowercased. Worked out once per
    /// redraw rather than rebuilt inside each of the tag lists below.
    private var personNames: Set<String> {
        Set(faceStore.people.map { $0.name.lowercased() })
    }

    /// Tags for the sidebar's Tags section: everything except the star tags
    /// (they own the Stars section), person names (they own the People
    /// section) and any tag filed under a heading in Tag Profiles — those get
    /// a group of their own below.
    ///
    /// Years are no longer subtracted here. A year is a READING off the file
    /// and lives in the facts store, so it never reaches `assignableTags()` in
    /// the first place; it is drawn by `fileFactLists` below. A year the user
    /// typed by hand before the split — which the migration leaves alone,
    /// because it was never the scan's — stays an ordinary tag, and belongs in
    /// Tags with the rest of their own words.
    private var tags: [String] {
        let people = personNames
        return library.assignableTags().filter {
            !people.contains($0.lowercased())
            && library.group(of: $0) == nil
        }
    }

    /// The headings the user has filed tags under, each with its tags.
    ///
    /// Driven by Tag Profiles rather than worked out here, so a heading the
    /// user invents shows up without anybody writing code for it, and a tag
    /// moved to a different heading moves in the sidebar too.
    private var headingGroups: [(name: String, tags: [String])] {
        let people = personNames
        var byHeading: [String: [String]] = [:]
        for tag in library.assignableTags() {
            guard !people.contains(tag.lowercased()),
                  let heading = library.group(of: tag)
            else { continue }
            byHeading[heading, default: []].append(tag)
        }
        return byHeading.keys.sorted().map { heading in
            (heading, byHeading[heading]!.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            })
        }
    }

    /// A heading's own open/closed switch, stored inside the one string above.
    private func openBinding(_ heading: String) -> Binding<Bool> {
        Binding(
            get: { openHeadingsRaw.split(separator: "\n").contains(Substring(heading)) },
            set: { isOpen in
                var open = Set(openHeadingsRaw.split(separator: "\n").map(String.init))
                if isOpen { open.insert(heading) } else { open.remove(heading) }
                openHeadingsRaw = open.sorted().joined(separator: "\n")
            }
        )
    }

    /// A picture for a heading, when the heading is one the app can guess at.
    /// Anything the user invents gets the plain tag icon rather than a symbol
    /// chosen at random, which would mean nothing.
    private func icon(forHeading heading: String) -> String {
        switch heading {
        case TagKinds.place:  return "globe"
        case TagKinds.person: return "person"
        case TagKinds.event:  return "sparkles"
        case TagKinds.camera: return "camera"
        case TagKinds.when:   return "calendar"
        default:              return "tag"
        }
    }

    /// The year a tag refers to, or nil when it refers to none. Catches a bare
    /// year ("2024") and a tag that names one ("December 2022").
    ///
    /// Kept for the tag side only — the facts store has its own, in
    /// `AutoTagCore.year(in:)`, which the library uses to order the Date group.
    static func yearIn(_ tag: String) -> Int? {
        guard let match = tag.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression)
        else { return nil }
        return Int(tag[match])
    }

    /// The readings taken off the files, grouped the way the library orders
    /// them: Date newest first, then Camera & Quality, then Place.
    ///
    /// The library decides both the grouping and the order — `factsByKind()` —
    /// so the sidebar invents no vocabulary of its own and a kind with nothing
    /// in it simply does not appear. Person names are not filtered out here the
    /// way they are for tags: a person is something the FACE ENGINE decided,
    /// never something read off a file, so a name cannot reach this store.
    private var fileFacts: [(kind: String, names: [String])] {
        library.factsByKind()
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                chooseFolder(playback: playback)
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .controlSize(.regular)

            if let resuming {
                row("Resume \((resuming as NSString).lastPathComponent)",
                    icon: "play.circle", help: resuming) {
                    playback.resumeLastSession()
                }
            }
        }
    }

    private var pinned: some View {
        section("Pinned", count: library.pinned.count, open: $pinnedOpen,
                empty: "Right-click a recent folder to pin it here.") {
            ForEach(Array(library.pinned.enumerated()), id: \.element) { index, root in
                let name = (root as NSString).lastPathComponent
                row(folderCount(root).map { "\(name) (\($0))" } ?? name,
                    icon: "folder",
                    image: folderIcons[root].map { Image(nsImage: $0) },
                    help: root,
                    current: playback.mode == .folder && playback.root == root) {
                    playback.openFolder(root)
                }
                .contextMenu {
                    Button("Train Tags in This Folder…") { app.trainFolder(root) }
                    Button("Tag from Metadata…") { app.startAutoTag(root) }
                    Button("Tag All Videos…") { app.tagAllVideos(in: root) }
                    Button("Find Missing Files in This Folder…") { app.scanMoved(root: root) }
                    Button("Unpin") { library.unpin(folder: root) }
                }
                .onDrag {
                    NSItemProvider(object: String(index) as NSString)
                }
                .onDrop(of: [.text], delegate: ReorderDrop(index: index) { from, to in
                    library.movePinned(from: from, to: to)
                })
            }
        }
    }

    /// Per-row drop target for dragging Pinned folders into a new order. The
    /// drag payload is the row's pre-drag index as text; the drop reports the
    /// row it landed on, and the library does the move.
    private struct ReorderDrop: DropDelegate {
        let index: Int
        let move: (Int, Int) -> Void

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            let providers = info.itemProviders(for: [.text])
            guard !providers.isEmpty else { return false }
            let provider: NSItemProvider = providers[0]
            let index = self.index
            provider.loadDataRepresentation(forTypeIdentifier: UTType.text.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8),
                      let from = Int(text) else { return }
                DispatchQueue.main.async { self.move(from, index) }
            }
            return true
        }
    }

    private var recent: some View {
        section("Recent", count: library.recent.count, open: $recentOpen,
                empty: "Folders you open show up here.") {
            ForEach(library.recent, id: \.self) { root in
                let name = (root as NSString).lastPathComponent
                row(folderCount(root).map { "\(name) (\($0))" } ?? name,
                    icon: "clock.arrow.circlepath",
                    image: folderIcons[root].map { Image(nsImage: $0) },
                    help: root,
                    current: playback.mode == .folder && playback.root == root) {
                    playback.openFolder(root)
                }
                .contextMenu {
                    Button("Train Tags in This Folder…") { app.trainFolder(root) }
                    Button("Tag from Metadata…") { app.startAutoTag(root) }
                    Button("Tag All Videos…") { app.tagAllVideos(in: root) }
                    Button("Find Missing Files in This Folder…") { app.scanMoved(root: root) }
                    if !library.isPinned(root) {
                        Button("Pin") { library.pin(folder: root) }
                    }
                }
            }
        }
    }

    /// A folder's count as the app should show it: the walk's number minus the
    /// hidden videos under it, so the figure beside a folder matches what
    /// opening it puts in the playlist. The raw count is cached; the
    /// subtraction is live, because hiding a video must not wait on a rescan.
    private func folderCount(_ root: String) -> Int? {
        counts[root].map { max(0, $0 - library.hiddenCount(under: root)) }
    }

    /// Video counts and folder icons for the sidebar rows, both walked in the
    /// background so the sidebar never waits on a slow disk. Folders already
    /// known keep their value; only the new ones are asked.
    private func loadCounts() async {
        let roots = library.recent + library.pinned.filter { !library.recent.contains($0) }
        let pendingCounts = roots.filter { counts[$0] == nil }
        let pendingIcons = roots.filter { folderIcons[$0] == nil }
        guard !pendingCounts.isEmpty || !pendingIcons.isEmpty else { return }
        let loaded = await Task.detached(priority: .utility) {
            () -> (counts: [String: Int], icons: [String: NSImage]) in
            var counted: [String: Int] = [:]
            for root in pendingCounts { counted[root] = Scanner.count(root) }
            var icons: [String: NSImage] = [:]
            for root in pendingIcons {
                icons[root] = NSWorkspace.shared.icon(forFile: root)
            }
            return (counted, icons)
        }.value
        for (path, count) in loaded.counts { counts[path] = count }
        for (path, icon) in loaded.icons { folderIcons[path] = icon }
    }

    /// Stars, best first. A star rating IS a tag now — "Favorite" is 5
    /// stars (the Apple TV's own mark), "4 Stars" … "1 Star" carry the rest —
    /// and this section is the grouping of those five tags. Rows show only
    /// the ratings that exist, because a row of ★4 with nothing behind it is
    /// a door to an empty list.
    ///
    /// No icon in the row's slot: the stars ARE the label, and an SF star
    /// beside five star glyphs said the same thing twice. Each row reads
    /// like every other row — what it is, then how many — "★★★★★ (12)".
    private var stars: some View {
        section("Stars", count: (1...5).reduce(0) { $0 + library.countRated($1) },
                open: $starsOpen,
                empty: "Rate a video 1–5 stars and it shows up here.") {
            ForEach((1...5).reversed(), id: \.self) { stars in
                let count = library.countRated(stars)
                if count > 0 {
                    row("\(String(repeating: "★", count: stars)) (\(count))",
                        help: "Play every video rated \(stars) stars",
                        current: playback.mode == .tag
                            && playback.tagName?.caseInsensitiveCompare(starTag(stars)) == .orderedSame) {
                        playback.playTag(starTag(stars))
                    }
                    .contextMenu {
                        // Stars are tags, so a star row offers what any tag
                        // row does — play, train, gather, file under — minus
                        // rename (the names are the rating system; Favorite
                        // especially is what the Apple TV favourites with).
                        tagMenu(starTag(stars))
                    }
                }
            }
        }
    }

    /// The commands every tag row offers, wherever it appears. One definition
    /// so a tag in Countries can do exactly what a tag in Tags can do.
    @ViewBuilder
    private func tagMenu(_ tag: String) -> some View {
        Button("Play “\(tag)”") { playback.playTag(tag) }
        Divider()
        Button("Train Tags from “\(tag)”") { app.trainTag(tag) }
        // Turn a tag into a real folder: its videos are gathered
        // together on disk and keep the tag.
        Button("Gather into Folder…") { app.gatherTag(tag) }
        Divider()
        Button("Rename “\(tag)”…") { app.renameTagEverywhere(tag) }
        // Filing from the row the thought occurs on, rather than a trip to
        // Tag Profiles to do the same thing.
        // `New Heading…` is what makes this menu usable on its own. Without
        // it the submenu listed only headings already in use, so on a library
        // where nothing had been filed yet it opened EMPTY and filing a first
        // tag was impossible from here — reported 2026-09-17 as "File under
        // does nothing", and it was doing nothing, because there was nothing
        // in it to do. Tag Profiles always had this; the sidebar copy did not.
        Menu("File under") {
            ForEach(library.knownGroups(), id: \.self) { heading in
                Button(heading) { library.setGroup(heading, for: [tag]) }
                    .disabled(library.group(of: tag) == heading)
            }
            if !library.knownGroups().isEmpty { Divider() }
            Button("New Heading…") {
                guard let name = ask("New heading",
                                     "What kind of thing is “\(tag)”? (Place, Person, Event…)",
                                     "") else { return }
                let clean = name.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { return }
                library.setGroup(clean, for: [tag])
            }
            if library.group(of: tag) != nil {
                Button("Nothing") { library.setGroup(nil, for: [tag]) }
            }
        }
        // Takes the label off the videos; the videos stay put.
        Button("Remove Tag from Videos…") { app.removeTagFromVideos(tag) }
    }

    /// A named, collapsible run of rows — a heading's tags, or a kind of
    /// reading. Collapsed state is the caller's, so each group remembers its
    /// own.
    ///
    /// `menu` is passed in rather than assumed, because a reading and a tag do
    /// NOT offer the same commands: you cannot train a model on "1080p".
    /// `count(anyName:)` counts either kind, so one row draws both.
    @ViewBuilder
    private func tagGroup<Menu: View>(_ title: String, tags: [String], icon: String,
                                      expanded: Binding<Bool>,
                                      @ViewBuilder menu: @escaping (String) -> Menu) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("\(title) (\(tags.count))")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .help(expanded.wrappedValue ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")

            if expanded.wrappedValue {
                ForEach(tags, id: \.self) { tag in
                    row("\(tag) (\(library.count(anyName: tag)))",
                        icon: icon,
                        current: playback.mode == .tag && playback.tagName == tag) {
                        playback.playTag(tag)
                    }
                    .contextMenu { menu(tag) }
                }
            }
        }
    }

    /// The same group with the ordinary tag commands — what every caller but
    /// the readings wants.
    @ViewBuilder
    private func tagGroup(_ title: String, tags: [String], icon: String,
                          expanded: Binding<Bool>) -> some View {
        tagGroup(title, tags: tags, icon: icon, expanded: expanded) { tagMenu($0) }
    }

    private var tagList: some View {
        section("Tags") {
            ForEach(tags, id: \.self) { tag in
                row("\(tag) (\(library.count(of: tag)))",
                    icon: "tag",
                    current: playback.mode == .tag && playback.tagName == tag) {
                    playback.playTag(tag)
                }
                .contextMenu { tagMenu(tag) }
            }
        }
    }

    /// Readings the app took off the files, in a section of their own —
    /// Date, Camera & Quality, Place. One collapsible group per kind.
    ///
    /// These are not tags and their menu says so: you can play them and gather
    /// them, because finding your 2016 clips is exactly what they are for, but
    /// there is no Train (a model cannot learn "1080p" from pixels), no File
    /// under (their kind is read, not chosen), and no Remove from Videos — a
    /// reading is a statement about the file, and taking it off would not make
    /// the file any less 1080p. Correcting one means correcting the file.
    @ViewBuilder
    private var fileFactLists: some View {
        ForEach(fileFacts, id: \.kind) { group in
            tagGroup(group.kind, tags: group.names,
                     icon: icon(forHeading: group.kind),
                     expanded: openBinding("fact:" + group.kind)) { name in
                factMenu(name)
            }
        }
    }

    /// What a reading's row offers. Deliberately shorter than `tagMenu`.
    @ViewBuilder
    private func factMenu(_ name: String) -> some View {
        Button("Play “\(name)”") { playback.playTag(name) }
        Divider()
        Button("Gather into Folder…") { app.gatherTag(name) }
        Divider()
        Text("Read from the file — not a tag")
    }

    /// One collapsible group per heading the user has filed tags under.
    ///
    /// Nothing appears until Tag Profiles → Sort All… has been run and
    /// approved, so the sidebar cannot fill up with headings nobody asked for.
    @ViewBuilder
    private var headingLists: some View {
        ForEach(headingGroups, id: \.name) { group in
            tagGroup(group.name, tags: group.tags,
                     icon: icon(forHeading: group.name),
                     expanded: openBinding(group.name))
        }
    }

    // MARK: - People (face recognition)

    /// Who the face engine knows. A named person IS a tag — the app tags every
    /// video a face appears in — so the rows play exactly like the tag rows
    /// above. Adding a person happens in the separate People window; this list
    /// offers a way there.
    private var peopleList: some View {
        section("People") {
            ForEach(faceStore.people.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }, id: \.name) { person in
                row("\(person.name) (\(library.count(of: person.name)))",
                    icon: "person.crop.circle",
                    image: person.representative.flatMap(FaceStore.thumbnail),
                    help: "Play every video with \(person.name) in it",
                    current: playback.mode == .tag && playback.tagName == person.name) {
                    playback.playTag(person.name)
                }
                // A person IS a tag, so the same commands apply. Removing
                // takes the name off the videos; the person and their learned
                // face stay in the People window, so it can be applied again.
                .contextMenu {
                    Button("Play “\(person.name)”") { playback.playTag(person.name) }
                    Divider()
                    Button("Train Tags from “\(person.name)”") { app.trainTag(person.name) }
                    Button("Gather into Folder…") { app.gatherTag(person.name) }
                    Divider()
                    Button("Remove Name from Videos…") {
                        app.removeTagFromVideos(person.name)
                    }
                }
            }
            row("Add Person…", icon: "person.badge.plus",
                help: "Add a person from a video or photo — the app finds them everywhere") {
                openWindow(id: "people")
            }
        }
    }

    /// What the last session left off on, when that is not already what is
    /// playing. Deliberately not checked against the disk: this is read on
    /// every redraw, and the share it names may be asleep.
    ///
    /// A hidden video is never named here: this row is in the LEFT PANEL, on
    /// screen while the app is locked, and it prints a file name. Which
    /// sessions are safe to offer is the library's question, not this view's —
    /// it knows the hidden set and the mode, and a gate covers it.
    private var resuming: String? {
        guard let path = library.resumable(library.session),
              path != playback.currentPath else { return nil }
        return path
    }

    @ViewBuilder
    private func row(_ title: String, icon: String? = nil, image: Image? = nil,
                     help: String? = nil,
                     current: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // The icon slot exists only when there is something to put in
                // it: a row whose title is already a picture of itself (the
                // Stars rows) starts flush, with no empty 14 pt gutter.
                if let image {
                    // A real folder icon is full-colour and must not be
                    // tinted; it is fitted into the same slot an SF
                    // Symbol would occupy.
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14)
                } else if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(current ? Color.accentColor : .secondary)
                        .frame(width: 14)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(current ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(current ? Color.accentColor.opacity(0.15) : .clear,
                        in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }

    /// A plain section: a heading and its rows. Used by People, which is
    /// hidden outright when face recognition is off.
    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            content()
        }
    }

    /// A section that is always on screen whether or not it has anything in
    /// it: heading with a count, a fold that is remembered, and one quiet line
    /// saying how to fill it when it is empty.
    ///
    /// This is what stops the sidebar rearranging itself. A section that
    /// disappears when its last item goes takes every row below it up a line,
    /// so the thing the user was reaching for is somewhere else the next time
    /// they look — and there is nothing on screen to explain why.
    @ViewBuilder
    private func section<Content: View>(_ title: String, count: Int,
                                        open: Binding<Bool>, empty: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 8)
                        .opacity(count == 0 ? 0.3 : 1)
                    Text(count == 0 ? title : "\(title) (\(count))")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .help(open.wrappedValue ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")

            if count == 0 {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            } else if open.wrappedValue {
                content()
            }
        }
    }
}

/// The folder chooser, in one place because several things reach it.
@MainActor
func chooseFolder(playback: PlaybackController) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Play"
    panel.message = "Choose a folder of videos"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    playback.openFolder(url.path)
}
