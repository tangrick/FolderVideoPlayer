import AppKit
import OSLog
import SwiftUI

/// Files dropped on the app icon, or opened with “Open With”, arrive here —
/// SwiftUI has no scene for it on a plain `Window` app, so AppKit's own
/// delegate hands them to the same code a drop on the window uses.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the app model exists. Anything that arrives before then waits
    /// in `pending`: macOS can deliver an open request before the first frame.
    weak var app: AppModel?
    private var pending: [String] = []

    nonisolated func application(_ sender: NSApplication, open urls: [URL]) {
        let paths = urls.map(\.path)
        Task { @MainActor in self.deliver(paths) }
    }

    func attach(_ model: AppModel) {
        app = model
        guard !pending.isEmpty else { return }
        let waiting = pending
        pending = []
        deliver(waiting)
    }

    /// The machine half of the analysis store is written on a clock now (see
    /// `AnalysisStore.machineSaveInterval`), so the last few verdicts of a run
    /// may still be in memory when the app is asked to go away. This is the
    /// one moment that costs something to skip.
    func applicationWillTerminate(_ notification: Notification) {
        let wrote = app?.analysis?.flush()
        // Logged because there is no other way to see it: the store's own gate
        // proves `flush` writes what is pending, but nothing proves AppKit
        // calls this. `log show --predicate 'subsystem == "com.tangrick.
        // foldervideoplayer"'` after a ⌘Q answers that, and says whether the
        // quit actually saved anything or merely found nothing waiting.
        Logger(subsystem: "com.tangrick.foldervideoplayer", category: "lifecycle")
            .notice("willTerminate: analysis flush wrote=\(wrote == true, privacy: .public)")
    }

    private func deliver(_ paths: [String]) {
        guard let playback = app?.playback else {
            pending.append(contentsOf: paths)
            return
        }
        playback.openDropped(paths.sorted())
    }
}

@main
struct FolderVideoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = Library()
    @StateObject private var media = MediaCache()
    @StateObject private var app = AppModel()
    /// The classification store, owned here so the player window and the
    /// review window watch the same records.
    @StateObject private var analysis = AnalysisStore()
    /// The classification engine (the CLIP child process), owned here for the
    /// same reason: one engine for the whole app, warm across review sessions.
    @StateObject private var engine = AnalysisEngine()
    /// Machine tag suggestions and what the user decided about them. Owned at
    /// app level because the tag panel offers them and a later training pass
    /// will read the same decisions.
    @StateObject private var suggestions = SuggestionStore()
    /// Face recognition's People state + face→video index.
    @StateObject private var faceStore = FaceStore()
    /// Timed evidence: when the app saw what it offered, one store per profile.
    /// Owned here so the pass that writes a claim and the panel that shows it are
    /// talking about the same evidence.
    @StateObject private var journal = EvidenceJournal()

    var body: some Scene {
        Window("FolderVideoPlayer", id: "player") {
            PlayerWindow()
                .environmentObject(library)
                .environmentObject(media)
                .environmentObject(app)
                .environmentObject(analysis)
                .environmentObject(engine)
                .environmentObject(suggestions)
                .environmentObject(faceStore)
                .environmentObject(journal)
                .environmentObject(app.rotation)
                .frame(minWidth: 680, minHeight: 420)
                .onAppear {
                    app.attach(library: library, media: media)
                    app.attach(analysis: analysis, engine: engine)
                    app.attach(suggestions: suggestions)
                    app.attach(faceStore: faceStore)
                    // The journal opens the store for the profile already in
                    // force; the observer below moves it on the next switch. It
                    // is not opened at init because the other stores' gate
                    // builds one directly and must not be able to touch a real
                    // profile's evidence.
                    journal.reload(profile: Paths.activeProfile)
                    // Answering a chip answers its timed evidence too, and the
                    // hook sits on the store so every call site does both.
                    suggestions.onVerdict = { path, tag, verdict in
                        journal.decide(verdict, for: path, label: tag)
                    }
                    // Every profile's own AI state moves with the profile, so
                    // the stores are told where to read once all of them exist.
                    app.observeProfileChanges(analysis: analysis, engine: engine,
                                              suggestions: suggestions, faceStore: faceStore,
                                              journal: journal)
                    delegate.attach(app)
                }
        }
        .defaultSize(width: 1040, height: 640)
        .commands { MainMenu(app: app, library: library) }

        Window("Find Duplicates", id: "duplicates") {
            DuplicatesWindow()
                .environmentObject(library)
                .environmentObject(app)
                .frame(minWidth: 780, minHeight: 520)
        }
        .defaultSize(width: 900, height: 660)

        Window("Tag Profiles", id: "profiles") {
            TagProfilesWindow()
                .environmentObject(library)
                .environmentObject(app)
                .environmentObject(suggestions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .defaultSize(width: 760, height: 480)

        Window("People", id: "people") {
            PeopleWindow()
                .environmentObject(library)
                .environmentObject(app)
                .environmentObject(faceStore)
                .frame(minWidth: 460, minHeight: 400)
        }
        .defaultSize(width: 560, height: 600)

        // ⌘I — the video's own facts, as a window rather than a sheet so a
        // second video can be asked about without dismissing the first answer.
        // It follows `infoTarget`, so picking another row re-answers it.
        Window("Video Info", id: "info") {
            InfoWindow()
                .environmentObject(library)
                .environmentObject(media)
                .environmentObject(app)
                .environmentObject(suggestions)
        }
        .defaultSize(width: 520, height: 560)

        // ⌘, — every preference the app has, in the place macOS users look
        // for it first. The stores are injected here by hand: a Settings
        // scene is its own scene and inherits nothing from the player window.
        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(app)
                .environmentObject(engine)
        }

        Window("Help", id: "help") {
            HelpWindow(app: app)
                .environmentObject(library)
                .environmentObject(app)
        }
        .defaultSize(width: 700, height: 520)
    }
}

/// The pieces the whole app shares: the player, the duplicate finder, and the
/// bits of window state that outlive a view.
@MainActor
final class AppModel: ObservableObject {
    private var player: PlaybackController!
    private(set) var duplicates: DuplicateFinder?
    private(set) var library: Library?
    /// The moved-video scan engine — a plain constant created once with the
    /// app model, so the panel and the scan always share one instance and a
    /// scan keeps running no matter which view is on screen.
    let movedScan = MovedScan()
    /// The classification store and engine, surfaced for views that get the
    /// app model but not the environment objects (the playlist sidebar's
    /// classify button and remark column). Force-unwrapped like `player`:
    /// attached on first appear before any of those views are on screen.
    private(set) var analysis: AnalysisStore!
    private(set) var engine: AnalysisEngine!
    /// The suggestions store, attached for the same reason as analysis: the
    /// tag and folder context menus train from the user's rejections, which
    /// live in the suggestions history.
    private(set) var suggestions: SuggestionStore?
    @Published private(set) var jobs: JobLedger?
    private var jobRunner: JobRunner?
    @Published var jobNotice: String?
    @Published var suggestingPath: String?
    /// Videos this launch has already started an automatic suggestion pass for.
    ///
    /// Opening a video runs a pass when it has none, so a video whose pass
    /// produces nothing — the engine is missing, the models are not installed,
    /// the run fails — must not be asked again and again every time the
    /// completion handler looks for work. One automatic attempt per video per
    /// launch; re-running after that is a deliberate act (re-analyse, or a
    /// relaunch), not something browsing can trigger in a loop.
    var autoSuggestAttempted: Set<String> = []
    /// Videos this launch has already started an automatic classification for.
    /// Same rule and same reason as `autoSuggestAttempted`: a video the engine
    /// cannot get through must not be retried every time playback returns to
    /// it. The explicit right-click Classify is unaffected and always runs.
    var autoClassifyAttempted: Set<String> = []
    static let suggestTagsNotification = Notification.Name("FolderVideoPlayer.suggestTagsRequested")

    // MARK: - transcribing (T08 S4)

    /// Asked for from the video's own row in the tag panel. Separate from the
    /// suggestion pass on purpose: transcribing is NEVER automatic — 646 MB of
    /// model and minutes of compute per film must not start because a video was
    /// double-clicked.
    static let transcribeNotification = Notification.Name("FolderVideoPlayer.transcribeRequested")
    /// The panel's Cancel. Sent while a pass is mid-flight, which is why it is
    /// its own notification rather than a second press of the first one.
    static let cancelTranscribeNotification = Notification.Name("FolderVideoPlayer.transcribeCancelled")

    /// The video being transcribed, if any. Nil means no pass is running.
    @Published var transcribingPath: String?
    /// What the panel shows while a pass runs: stage, position, lines so far.
    @Published var transcribeProgress: SpeechProgress?
    /// Lines written per video this launch, so the button can end as
    /// "Transcribed · 412 lines" without re-reading the store.
    @Published var transcriptLines: [String: Int] = [:]
    /// The transcriber in flight, held so Cancel can reach it. Deliberately not
    /// @Published: nothing in the UI draws it, and the panel's state above is
    /// what the user is actually watching.
    var transcribing: WhisperKitTranscriber?

    /// Each video's on-screen turn. Held here so the menus, the bar and the
    /// picture all read the one store.
    let rotation = VideoRotation()

    /// The playlist's AI ▸ Transcribe These. Carries the paths, in list order.
    /// Still never automatic: this is a run the user asked for, like Classify.
    static let transcribeBatchNotification = Notification.Name("FolderVideoPlayer.transcribeBatchRequested")
    /// Where a playlist run has got to. Nil when none is running.
    struct TranscribeBatch: Equatable {
        var done: Int
        var total: Int
    }
    @Published var transcribeBatch: TranscribeBatch?
    /// Set by Cancel so the run stops instead of moving to the next video.
    var transcribeBatchCancelled = false

    /// The only application entry point for an explicitly requested classify job.
    func classify(paths: [String]) async {
        guard library?.profileOpen == true else {
            say("No profile is open",
                "Choose File → Open Profile before classifying videos.")
            return
        }
        guard let jobs, let jobRunner else { return }
        // A model being installed or removed outranks everything here: the run
        // would read files midway through being replaced, so the press is
        // refused with the reason instead of starting a run that cannot finish.
        guard !downloads.isReplacing else {
            jobNotice = AnalysisEngine.replacingReason
            return
        }
        guard !engine.isBusy, jobRunner.runningID == nil, suggestingPath == nil else {
            jobNotice = "An analysis is already running. Stop it before starting another."
            return
        }
        let request = jobs.request(paths: paths)
        guard jobs.job(request.id) != nil else {
            jobNotice = jobs.persistenceError
            return
        }
        jobNotice = nil
        let result = await jobRunner.run(request.id)
        guard self.jobs === jobs else { return }
        if case .failure(let why) = result {
            jobNotice = jobs.persistenceError ?? "Analysis could not start: \(why)."
        }
    }

    /// An explicitly requested classify that takes the engine off whatever it
    /// is doing first.
    ///
    /// `classify(paths:)` refuses while the engine is busy and says so. That
    /// was reasonable when the only runs were ones the user had asked for; now
    /// that playing a video classifies it, the engine is often mid-pass on
    /// something the user did not ask about, and a bare refusal would make the
    /// menu look broken. An explicit request outranks background upkeep: stop
    /// the current run, wait for the in-flight video to drain (the engine is
    /// one worker and refuses a second queue until then), and go.
    ///
    /// `PlaylistSidebar.classifyVisible()` does the same thing inline for the
    /// whole-playlist action; worth sharing if a third caller appears.
    func classifyNow(paths: [String]) async {
        guard !paths.isEmpty else { return }
        let profile = Paths.activeProfile
        if engine.isBusy {
            stopAnalysis()
            while engine.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard !Task.isCancelled, profile == Paths.activeProfile else { return }
        await classify(paths: paths)
    }

    func stopAnalysis() {
        if let id = jobRunner?.runningID { jobRunner?.cancel(id) }
        else { engine?.stop() }
    }

    private func attachJobs(profile: String) {
        guard !profile.isEmpty else {
            jobs = nil
            jobRunner = nil
            jobNotice = nil
            return
        }
        let ledger = JobLedger(profile: profile)
        jobs = ledger
        jobRunner = JobRunner(ledger: ledger, engine: engine, store: analysis)
        jobNotice = ledger.persistenceError
    }

    /// Face recognition's app-side half: the face→video index and the People
    /// state (clusters + named people). Attached like analysis/engine.
    private(set) var faceStore: FaceStore?

    /// A second engine process, declared for the case where tag suggestions
    /// should keep flowing WHILE the main engine is busy analysing a queue.
    /// The main engine is a strict single worker (one CLIP model, one ffmpeg).
    ///
    /// **NOT WIRED — verify before trusting this.** As of 2026-09-19 nothing
    /// constructs or calls this object: `PlayerWindow.autoSuggest` and
    /// `suggestTags` both refuse while `app.engine.isBusy`, so a suggestion
    /// asked for mid-run is simply skipped, and the earlier claim that this
    /// engine serves them is false. It is kept rather than deleted because on
    /// this line a capability that is switched off stays in the code
    /// (`Library.watchDupes` is the same pattern).
    ///
    /// Wiring it is a slice of its own, not a one-line change: it owns a second
    /// copy of the CLIP model (memory), it must be shut down with the app and
    /// re-pointed on a profile switch, and the downloader's
    /// `isReplacingModels`/`isInferring` pair — set on `engine` only, in
    /// `attach` — has to cover it too, or a model swap can land under it.
    lazy var suggestionEngine: AnalysisEngine = AnalysisEngine()

    func attach(analysis: AnalysisStore, engine: AnalysisEngine) {
        self.analysis = analysis
        self.engine = engine
        if jobs == nil { attachJobs(profile: Paths.activeProfile) }
        // Suggestions were injected as an environment object before the app
        // model; reach back through the shared reference the window holds.
        self.suggestions = nil
        // The two sides of "a model may not be swapped under a running pass",
        // wired in the one place that holds both objects: the downloader asks the
        // engine whether the AI is working, and the engine asks the downloader
        // whether a model is being replaced. Both closures are main-actor and
        // both are weak — the two objects would otherwise own each other.
        let downloads = self.downloads
        engine.isReplacingModels = { [weak downloads] in downloads?.isReplacing ?? false }
        downloads.isInferring = { [weak engine] in engine?.isInferring ?? false }
    }

    /// Set after attach: the window's own suggestions store, so scope
    /// training from context menus can read the user's rejections.
    func attach(suggestions: SuggestionStore) {
        self.suggestions = suggestions
    }

    /// Set after attach: the face store, wired to engine + library so naming a
    /// cluster can bind in the engine and tag videos in the library.
    func attach(faceStore: FaceStore) {
        self.faceStore = faceStore
        faceStore.attach(engine: engine, library: library)
    }

    /// Held for the life of the app: the observer that moves the per-profile
    /// AI state when the profile in force changes.
    private var profileObserver: NSObjectProtocol?

    /// Move the per-profile AI state onto the profile now in force.
    ///
    /// Heads, suggestions, verdicts, Safe/NSFW marks and named people all
    /// belong to one profile, so a switch has to take the stores with it —
    /// otherwise the next person is shown the last one's judgement, and trains
    /// on it. The engine is retired too: the Python child reads its profile at
    /// spawn and would otherwise keep filing the old one's heads and people.
    ///
    /// Called once from the window's `onAppear`, which is where every store is
    /// in hand. The stores do not observe this themselves so a test that builds
    /// one directly cannot have its own file swapped out from under it.
    func observeProfileChanges(analysis: AnalysisStore, engine: AnalysisEngine,
                               suggestions: SuggestionStore, faceStore: FaceStore,
                               journal: EvidenceJournal? = nil) {
        guard profileObserver == nil else { return }
        profileObserver = NotificationCenter.default.addObserver(
            forName: .fvpProfileChanged, object: nil, queue: .main) { note in
            guard let slug = note.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.stopAnalysis()
                analysis.reload(profile: slug)
                suggestions.reload(profile: slug)
                faceStore.reload(profile: slug)
                // Evidence is one profile's record of what ITS passes saw: a
                // claim made under another profile is not this one's to show,
                // and the store moves with the profile for the same reason the
                // verdicts do.
                journal?.reload(profile: slug)
                engine.resetForProfile()
                self?.attachJobs(profile: slug)
            }
        }
    }
    /// What ⌘I should be about: the ticked video when exactly one is ticked,
    /// otherwise whatever is playing. A multi-selection has no single answer
    /// so the menu item disables rather than picking one at random.
    var infoTarget: String? {
        if selection.count == 1 { return selection.first }
        return playback?.currentPath
    }

    /// What the AI half of the app can do on this Mac. Probed at launch and
    /// re-probed whenever a model download finishes, so a feature that was
    /// unavailable a minute ago becomes available without a relaunch.
    @Published var ai = AICapability.probe()

    /// Which Settings tab is showing. A view that means "open the AI page" sets
    /// this and then calls `openSettings()` — the `Settings` scene cannot be
    /// handed a tab, and a menu item promising to set AI up that lands on
    /// General has told the user nothing (see `SettingsTab`).
    @Published var settingsTab: SettingsTab = .general

    /// The AI downloader, held for the life of the app rather than rebuilt per
    /// Settings window: an install keeps running when the window closes, and
    /// the catalogue does not have to be fetched again to see its progress.
    let downloads = ModelDownloader()

    init() {
        downloads.onArtifactsChanged = { [weak self] in
            self?.refreshAICapability()
        }
    }

    func refreshAICapability() { ai = AICapability.probe() }

    /// Refuse an AI action out loud, naming the reason and what to do.
    ///
    /// The rule the app already follows for a busy engine (pitfall 0) applied
    /// to a missing one: pressing an AI control on a Mac that cannot run it
    /// must say so, not fail silently or spawn a process that will fail.
    /// Returns true when the caller may proceed.
    @discardableResult
    func requireAI(_ feature: AICapability.Feature) -> Bool {
        guard library?.profileOpen == true else {
            say("No profile is open", "Choose File → Open Profile before using video intelligence.")
            return false
        }
        if ai.works(feature) { return true }
        let why = ai.reason(feature) ?? "This Mac cannot run it."
        let fixable = (ai.blockers[feature] ?? []).contains { $0.fixableInApp }
        say("\(feature.title) is not ready",
            why + (fixable
                   ? "\n\nSettings → AI can download what is missing."
                   : "\n\nEverything else in the app works without it."))
        return false
    }

    @Published var movedExpanded = false
    /// The findings panel is open and waiting, with no scan run yet.
    ///
    /// Files ▾ → Find Moved or Missing Files… sets this instead of starting a
    /// scan. A sweep with nowhere to aim walks every share, which is minutes
    /// on a NAS and cannot be narrowed once it is moving — so the panel comes
    /// up first, the folder gets picked, and Scan is a deliberate press.
    @Published var movedArmed = false
    @Published var showAutoTag = false
    var autoTagRoot: String?

    /// Which Help page the Help window is showing. Whoever opens the window
    /// sets this first, so the first-run screen can ask for the tour.
    @Published var helpPage: HelpPage = .quickStart
    /// True once the user has asked for the tour, so the empty player stops
    /// offering it. Remembered by @AppStorage in the view, not here.
    /// Both panels are up at launch: the library on the left is how a folder is
    /// chosen and the playlist on the right is the list itself, and an app that
    /// opened with either hidden made the user find the control that brings it
    /// back before they could do anything. Hiding is one click away and is not
    /// remembered, so a fresh launch always looks the same.
    @Published var showLibrary = true
    @Published var showPlaylist = true
    /// Whether the window is full screen, and whether the bar is on show
    /// while it is. Both follow the window rather than lead it.
    @Published var fullScreen = false
    @Published var controlsVisible = true
    weak var playerWindow: NSWindow?
    var fullScreenWatchers: [NSObjectProtocol] = []
    var escapeWatcher: Any?
    /// ⌘A → tick every visible row. A key monitor rather than the menu item
    /// alone, because nothing in the window is a responder that answers the
    /// standard selectAll(_:) selector.
    var selectAllWatcher: Any?
    private var foregroundWatchers: [NSObjectProtocol] = []
    @Published var showTagPanel = false
    /// The transcript strip. Shares the bottom slot with the tag panel, so the
    /// two are never open at once — the same space cannot show both.
    @Published var showTranscriptPanel = false
    @Published var selection: Set<String> = []
    /// Where the last plain click landed. A shift click selects everything
    /// between it and the row clicked, the way a Finder list does.
    private var selectionAnchor: String?

    /// Add or remove one, leaving the rest alone.
    func toggle(_ path: String) {
        if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
        selectionAnchor = path
    }

    /// What one click on a row or tile means.
    ///
    /// The same three rules Finder has, so nothing has to be learned and no
    /// mode has to be turned on first: a plain click picks that one video and
    /// drops the rest, ⌘ adds or removes without disturbing the others, and ⇧
    /// fills in the whole run from the last one clicked.
    ///
    /// Returns whether this click should also start the video playing. Only a
    /// plain click does — building a selection with ⌘ or ⇧ must not yank the
    /// picture out from under you on every press.
    func click(_ path: String, from order: [String]) -> Bool {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift),
           let anchor = selectionAnchor ?? order.first,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: path) {
            selection.formUnion(order[min(from, to)...max(from, to)])
            return false
        }
        if flags.contains(.command) {
            toggle(path)
            return false
        }
        selection = [path]
        selectionAnchor = path
        return true
    }

    func selectAll(_ order: [String]) {
        selection = Set(order)
        selectionAnchor = order.first
    }

    func selectNone() {
        selection.removeAll()
        selectionAnchor = nil
    }
    @Published var notice: Notice?
    @Published var ready = false
    /// Set at launch when there is a profile worth choosing, and cleared once
    /// the window has been put up.
    @Published var needsProfileChoice = false

    /// The player, for the few places outside the player window that nudge it.
    var playback: PlaybackController? { ready ? player : nil }

    struct Notice: Identifiable {
        var id = UUID()
        var title: String
        var detail: String
    }

    func attach(library: Library, media: MediaCache) {
        guard !ready else { return }
        self.library = library
        player = PlaybackController(library: library, media: media)
        // A converted copy replaces its original the way Delete sends a file
        // anywhere: the Trash, or the folder asked for on a share with none.
        player.replaceOriginal = { [weak self] original, copy in
            FileOps.replace(original, with: copy, library: library) { volume, why in
                self?.askDiscardFolder(volume, why)
            }
        }
        player.onConversionFinished = { [weak self] line in self?.jobNotice = line }
        duplicates = DuplicateFinder(library: library)
        ready = true
        // What was playing comes back first. The share traffic happens behind
        // it, because a sleeping NAS answers its first request in seconds and
        // nothing about launching should wait on that.
        _ = player.resumeLastSession()
        // A Mac with more than one profile on it, or one that has never been
        // asked, is asked once — at launch, where the answer decides whose
        // tags the session is about.
        needsProfileChoice = library.askProfileAtStartup && library.profiles.count > 1
        Task {
            _ = await library.mergeShared()
            await library.publishTags()
        }
        watchForForeground()
    }

    /// Tags reach the other devices without anyone pressing anything.
    ///
    /// Coming to the front is when a share has most likely just been mounted,
    /// or the Apple TV has just finished tagging something — so that is when
    /// the Mac catches up. Quitting pushes whatever the hold has not reached.
    private func watchForForeground() {
        let center = NotificationCenter.default
        foregroundWatchers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let library = self.library else { return }
                    Task { await library.catchUpWithOtherDevices() }
                }
            })
        // Closing the player window must stop the video: an app left running
        // in the Dock with sound coming out of a window that is not there is
        // the bug this prevents. The session is written first, so reopening
        // picks up exactly where it left off.
        foregroundWatchers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.ready,
                          let window = note.object as? NSWindow,
                          // Only the player window — the duplicates and
                          // profiles windows have nothing to do with playback.
                          window.identifier?.rawValue.contains("player") ?? (window === self.playerWindow)
                    else { return }
                    self.player.notePosition()
                    self.player.saveSession()
                    self.player.pauseForWindowClose()
                }
            })
        foregroundWatchers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.library?.publishOnQuit()
                    self?.library?.flushPrints()
                }
            })
    }

    // MARK: - the moved-video scan

    /// Point the scan at whatever the player is showing.
    func startMovedScanHere() {
        guard let pb = playback else { startMovedScan(); return }
        switch pb.mode {
        case .tag:
            startMovedScan(paths: pb.playlist, label: pb.tagName ?? "tag")
        case .folder:
            startMovedScan(root: pb.root)
        case .favorites:
            // No longer reachable; kept whole so the switch stays exhaustive.
            startMovedScan(paths: pb.playlist, label: "Favorites")
        case .hidden:
            startMovedScan(paths: pb.playlist, label: "Hidden")
        }
    }

    /// Aim at one folder (folder context menus).
    func startMovedScan(root: String?) {
        movedScan.scopePaths = nil
        movedScan.scopeLabel = nil
        movedScan.scopeRoot = root
    }

    /// Aim at an explicit row list (a tag playlist, favorites).
    func startMovedScan(paths: [String]? = nil, label: String? = nil) {
        movedScan.scopeRoot = nil
        movedScan.scopePaths = paths
        movedScan.scopeLabel = label
    }

    /// Aim the moved/missing scan at particular videos, and wait.
    ///
    /// The right-click answer to "this row is red, where did the file go?" —
    /// the whole-playlist scan asks the same question of hundreds of files
    /// when the user is looking at one.
    ///
    /// Aims but does NOT run, the same as Files ▾. Starting here immediately
    /// meant the one control that decides how long the hunt takes — which
    /// folder to search — appeared only after the search was already under
    /// way, walking every share. Both doors now open the panel with the scope
    /// set; Scan is the press that commits.
    func findMoved(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        movedScan.scopeRoot = nil
        movedScan.scopePaths = paths
        movedScan.scopeLabel = paths.count == 1
            ? (paths[0] as NSString).lastPathComponent
            : "\(paths.count) videos"
        movedArmed = true
        movedExpanded = true
    }

    /// Aim at the view on screen, then run — the whole-playlist sweep.
    ///
    /// Nothing calls this at present: the sweep was removed from Files ▾ and
    /// from the panel in favour of right-click → Find Missing File… on the row
    /// that is actually in trouble. Kept whole so a sweep can be offered again
    /// without rebuilding it. Re-aiming every run is the point: a scan always
    /// answers about the view in front of the user, never a leftover scope
    /// from an earlier tag.
    /// Run what the panel is already aimed at.
    ///
    /// The Scan button must NOT re-aim: right-click → Find Missing File… sets
    /// the scope to that one red row, and re-aiming here would silently widen
    /// it back to the whole playlist between the user pointing and pressing.
    /// Only when nothing has aimed it does this fall back to the current view.
    func runMovedScan() {
        guard let library else { return }
        movedArmed = false
        if movedScan.scopePaths == nil && movedScan.scopeRoot == nil {
            startMovedScanHere()
        }
        movedExpanded = true
        movedScan.run(library: library)
    }

    func scanMovedHere() {
        movedArmed = false
        startMovedScanHere()
        guard let library else { return }
        movedScan.run(library: library)
    }

    /// Aim at one folder and run (folder context menus).
    func scanMoved(root: String) {
        startMovedScan(root: root)
        guard let library else { return }
        // The findings panel is only on screen while a scan has something to
        // say, so open it here or the scan would run out of sight.
        movedExpanded = true
        movedScan.run(library: library)
    }

    /// Tag every video in a folder — including subfolders — with one name.
    /// The folder context menu's "Tag All Videos…"; the ask is prefilled with
    /// the folder's own name, so "Holiday" gets tagged "Holiday" in one
    /// return press. The scan is the playlist's own walk (Scanner.scan), so
    /// the rows it tags are exactly what opening the folder plays.
    func tagAllVideos(in root: String) {
        guard let library else { return }
        let suggested = (root as NSString).lastPathComponent
        guard let name = ask("Tag every video in “\(suggested)”",
                             "Add this tag to all \(Scanner.count(root)) videos, "
                               + "subfolders included:",
                             suggested,
                             ok: "Tag All") else { return }
        let paths = Scanner.scan(root)
        guard !paths.isEmpty else {
            say("Nothing to tag",
                "No videos were found under “\(suggested)”.")
            return
        }
        let tagged = library.addTag(name, to: paths)
        playback?.refreshMembership()
        say("Tagged",
            tagged == paths.count
                ? "“\(name)” added to \(tagged) video\(tagged == 1 ? "" : "s") "
                  + "under “\(suggested)”."
                : "“\(name)” added to \(tagged) of \(paths.count) videos — the "
                  + "rest already carried it.")
    }

    // MARK: - tag from metadata

    func startAutoTag(_ root: String) {
        // Tag from Metadata writes the tags it reads into the profile in
        // force. With none open it must not burn a scan producing tags that
        // are refused at the store — and the sheet would sit over a player
        // that cannot accept what it offers.
        //
        // Says so rather than returning quietly: a menu item that does nothing
        // and explains nothing reads as a broken app, which is how this was
        // reported (2026-09-17). Same sentence `requireAI` already uses.
        guard library?.profileOpen == true else {
            say("No profile is open",
                "Choose File → Open Profile before tagging from metadata.")
            return
        }
        autoTagRoot = root
        showAutoTag = true
    }

    func stopAutoTag() {
        showAutoTag = false
        autoTagRoot = nil
    }

    // MARK: - file operations

    /// Rename one video, asked for by name.
    func renameFile(_ path: String) {
        guard let library else { return }
        let current = (path as NSString).lastPathComponent
        guard let wanted = ask("Rename video",
                               "What should this file be called?",
                               current), wanted != current else { return }
        let report = FileOps.rename(path, to: wanted, library: library)
        finish(report, "Renamed")
    }

    /// Move videos into a folder the user picks.
    func moveFiles(_ paths: [String]) {
        guard let library, !paths.isEmpty else { return }
        guard let folder = pickFolder(prompt: "Move Here",
                                      message: paths.count == 1
                                        ? "Where should this video go?"
                                        : "Where should these \(paths.count) videos go?",
                                      start: (paths[0] as NSString).deletingLastPathComponent)
        else { return }
        let report = FileOps.move(paths, into: folder, library: library)
        finish(report, "Moved")
    }

    /// Send videos to the Trash — or, on a share without one, to a folder
    /// the user nominates. Asked about first, always.
    func trashFiles(_ paths: [String]) {
        guard let library, !paths.isEmpty else { return }
        let what = paths.count == 1
            ? "“\((paths[0] as NSString).lastPathComponent)”"
            : "\(paths.count) videos"
        let alert = NSAlert()
        alert.messageText = "Move \(what) to the Trash?"
        alert.informativeText = """
        The tags and resume positions go with them.

        Nothing is deleted outright — on a share with no Trash you will be \
        asked for a folder to move them into instead, and you empty it yourself.
        """
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let report = FileOps.trash(paths, library: library) { volume, why in
            self.askDiscardFolder(volume, why)
        }
        finish(report, "Deleted")
    }

    // MARK: - hidden videos
    //
    // App-only hiding — see HiddenVideos.swift. Nothing on disk is renamed,
    // moved, flagged or encrypted, so these actions only move a path in and
    // out of the library's hidden set and re-ask the playlist. The password
    // guards REVEALING the set, never hiding it: hiding is the private act,
    // and asking for a password to hide something would be the wrong way
    // round.

    /// Which password sheet is up, if any. The player window presents the one
    /// named here; Settings runs its own, because a `Settings` scene is a
    /// different window and two windows both presenting one sheet is worse
    /// than a little duplication.
    @Published var hiddenSheet: HiddenSheetKind?

    enum HiddenSheetKind: String, Identifiable {
        /// Choose a password — before a first hide, or to open a list left by
        /// a build that could hide without one.
        case create
        /// Ask for the password before revealing the Hidden view.
        case unlock
        /// Replace a password that exists.
        case change
        var id: String { rawValue }
    }

    /// What a successful unlock was for. Kept here so the sheet stays a dumb
    /// form that does not know where it was opened from.
    private var afterUnlock: (() -> Void)?

    /// Videos waiting on the create sheet to finish hiding.
    private var pendingHide: [String] = []

    /// Hide these videos, asking for a password first if there is not one yet.
    func hideVideos(_ paths: [String]) {
        guard let library, !paths.isEmpty else { return }
        pendingHide = paths
        if library.lock.hasPassword { completeHide() } else { hiddenSheet = .create }
    }

    /// Hide what the create sheet was opened for. Safe to call with nothing
    /// pending (the sheet was opened to unlock a list, not to hide).
    func completeHide() {
        let paths = pendingHide
        pendingHide = []
        hiddenSheet = nil
        guard let library, !paths.isEmpty else { return }
        let count = library.hide(paths)
        guard count > 0 else { return }
        selectNone()
        playback?.refreshMembership()
        say("Hidden", count == 1
            ? "The video is out of the app's sight. Its tags, marks and progress are kept — and Finder still shows the file."
            : "\(count) videos are out of the app's sight. Their tags, marks and progress are kept — and Finder still shows the files.")
    }

    /// Reveal videos again. Their tags, marks and progress were never touched,
    /// so they come back exactly as they were.
    func unhideVideos(_ paths: [String]) {
        guard let library, !paths.isEmpty else { return }
        let count = library.unhide(paths)
        guard count > 0 else { return }
        selectNone()
        playback?.refreshMembership()
        // Last one out: the Hidden view has nothing left to show.
        if library.hidden.isEmpty { playback?.closePlaylist() }
        say("Unhidden", count == 1
            ? "The video is back in the library, exactly as it was."
            : "\(count) videos are back in the library, exactly as they were.")
    }

    /// Open the Hidden view, asking for the password when it is locked.
    func showHiddenVideos() {
        guard let library else { return }
        guard !library.hidden.isEmpty else {
            say("Nothing is hidden",
                "Hide a video from its right-click menu (or File → Hide Videos) and it will be here. Hiding is app-only — the file itself is untouched.")
            return
        }
        let show: () -> Void = { [weak self] in self?.playback?.playHidden() }
        guard library.lock.hasPassword else {
            // A hidden list with no password: a library carried over from a
            // build that hid without one. Offer to set one rather than leave
            // the videos unreachable.
            afterUnlock = show
            hiddenSheet = .create
            return
        }
        if library.lock.isUnlocked { show(); return }
        afterUnlock = show
        hiddenSheet = .unlock
    }

    /// Lock again and leave the Hidden view. The list is untouched.
    func lockHidden() {
        library?.lock.lock()
        playback?.closePlaylist()
        say("Hidden list locked", "The password will be asked for again next time.")
    }

    /// Run whatever the sheet was opened for. Called by the sheet once the
    /// password step has succeeded.
    func hiddenSheetSucceeded(_ kind: HiddenSheetKind) {
        hiddenSheet = nil
        if kind == .create, !pendingHide.isEmpty {
            completeHide()
            return
        }
        let action = afterUnlock
        afterUnlock = nil
        action?()
    }

    /// Give up on the sheet. The pending work is dropped: a cancelled create
    /// must not leave a hide queued behind it.
    func hiddenSheetCancelled() {
        pendingHide = []
        afterUnlock = nil
        hiddenSheet = nil
    }

    /// Rename a tag from the sidebar, without a trip to Tag Profiles.
    ///
    /// Right-clicking the tag you can see is where the thought occurs; the
    /// window that could do it was two menus away.
    func renameTagEverywhere(_ tag: String) {
        guard let library else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tag
        let alert = NSAlert()
        alert.messageText = "Rename tag"
        alert.informativeText = "What should “\(tag)” be called? "
            + "It changes on all \(library.count(of: tag)) videos carrying it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.caseInsensitiveCompare(tag) != .orderedSame else { return }
        // The star tags are the rating system: renaming one (Favorite above
        // all — the Apple TV favourites with it) would orphan the stars and
        // desync the other devices. Said at the alert, not as a silent no-op.
        guard !isStarTag(tag) else {
            say("“\(tag)” is a star rating", "Its name is what the star rows, the rating controls and the Apple TV's favourites all answer to, so it does not rename.")
            return
        }
        library.renameTag(tag, to: name)
        // A tag playlist is named after its tag, so the open one has to follow
        // the rename or its heading would keep the old word.
        if playback?.mode == .tag, playback?.tagName?.caseInsensitiveCompare(tag) == .orderedSame {
            playback?.playTag(name)
        } else {
            playback?.refreshMembership()
        }
    }

    /// Rename a person from the People window: the face bindings and the tag
    /// both move to the new name, so every video carrying the old name shows
    /// the new one. The ask is the app's standard rename alert; a refusal
    /// (duplicate name, empty) comes back as a notice, not a silent no-op.
    func renamePerson(_ person: FacePerson) {
        guard let faceStore else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = person.name
        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(person.name)\u{201D}"
        alert.informativeText = "What should this person be called? It changes on "
            + "\(library?.count(of: person.name) ?? 0) videos carrying their name."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              name.caseInsensitiveCompare(person.name) != .orderedSame else { return }
        Task {
            switch await faceStore.renamePerson(person.name, to: name) {
            case .renamed:
                break
            case .failed(let why):
                say("Could not rename \u{201C}\(person.name)\u{201D}", why)
            }
        }
    }

    /// Take a tag off every video carrying it, leaving the videos alone.
    ///
    /// Not the same as deleting the tag in Tag Profiles, which is what people
    /// reach for and then hesitate over: this is the "I filed these wrong"
    /// action. The files, their names and their other tags are untouched, and
    /// it goes on the undo record like every other destructive tag edit.
    func removeTagFromVideos(_ tag: String) {
        guard let library else { return }
        let count = library.count(of: tag)
        guard count > 0 else {
            say("Nothing to remove", "No videos carry “\(tag)”.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Take “\(tag)” off \(count) video\(count == 1 ? "" : "s")?"
        alert.informativeText = """
        The tag comes off every video carrying it. The videos themselves, \
        their names and their other tags are untouched, and nothing is moved \
        or deleted on disk.

        This can be undone from Tag Profiles.
        """
        alert.addButton(withTitle: "Take Tag Off")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.deleteTag(tag)
        // The tag playlist that was open is now a playlist of nothing, so it
        // cannot simply be re-filtered — the videos are no longer members.
        if playback?.mode == .tag, playback?.tagName?.caseInsensitiveCompare(tag) == .orderedSame {
            playback?.closePlaylist()
        } else {
            playback?.refreshMembership()
        }
    }

    /// Gather every video carrying a tag into one folder named after it.
    ///
    /// Nothing is typed and nothing is chosen: the tag names the folder, and
    /// the videos decide where it goes — the folder they already live in (the
    /// user's rule). A tag whose videos sit in several folders has no single
    /// answer, so the library root is used, and the confirmation below names
    /// the exact path before a single file moves.
    func gatherTag(_ tag: String) {
        guard let library else { return }
        let paths = library.taggedWith(tag)
        guard !paths.isEmpty else {
            say("Nothing to gather", "No videos carry “\(tag)”.")
            return
        }
        guard let parent = FileOps.gatherParent(for: paths, fallback: playback?.root) else {
            say("Nothing to gather", "“\(tag)”'s videos have no folder on disk to gather into.")
            return
        }
        let target = FileOps.gatherTarget(tag: tag, into: parent)
        let alert = NSAlert()
        alert.messageText = "Gather \(paths.count) video\(paths.count == 1 ? "" : "s") into “\((target as NSString).lastPathComponent)”?"
        alert.informativeText = """
        They will be moved into:
        \(target)

        The tag is kept, so the “\(tag)” playlist keeps working — its videos \
        will simply live together from now on. A name already taken there is \
        never overwritten.
        """
        alert.addButton(withTitle: "Gather")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let report = FileOps.gather(tag: tag, into: parent, library: library)
        finish(report, "Gathered")
    }

    /// Report what a batch did and put the views back in step with the disk.
    private func finish(_ report: FileOps.Report, _ verb: String) {
        guard !report.isEmpty else { return }
        selectNone()
        playback?.refreshAfterFileChanges()
        say("\(verb): \(report.summary)", report.detail)
    }

    private func pickFolder(prompt: String, message: String, start: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    private func askDiscardFolder(_ volume: String, _ why: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "“\((volume as NSString).lastPathComponent)” has no Trash"
        alert.informativeText = """
        \(why)

        The videos can be moved to a folder on that same volume instead, which \
        is instant and changes nothing else. You delete them yourself once you \
        are happy.
        """
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return pickFolder(prompt: "Move Here",
                          message: "Where should deleted videos from this volume go?",
                          start: volume)
    }

    /// A one-line question with a text field — rename and bulk-tag use it.
    private func ask(_ title: String, _ question: String, _ current: String,
                     ok: String = "Rename") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = question
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let answer = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }

    func say(_ title: String, _ detail: String) {
        notice = Notice(title: title, detail: detail)
    }

    // MARK: - training scopes

    /// Train per-tag heads from one scope of the library, and report the
    /// outcome as a notice. The scope is whatever the caller names: a
    /// playlist (toolbar button), a tag (its context menu) or a folder (its
    /// context menu) — one implementation, every entry point.
    ///
    /// Never silent: if the engine is busy or broken the notice says so
    /// instead of the click appearing to do nothing.
    func trainScope(scopePaths: [String]? = nil, scopeTitle: String) {
        guard let library, let analysis, let suggestions else { return }
        let engine = self.engine!
        if engine.isBusy {
            notice = .init(title: "Cannot train right now",
                           detail: busyDetail(engine))
            return
        }
        if case .broken(let why) = engine.phase {
            notice = .init(title: "Cannot train — the engine is not running",
                           detail: why)
            return
        }
        let scopeKeys: Set<String>? = scopePaths.map { Set($0.map { Paths.tagKey($0) }) }
        let set = TrainingSetBuilder.build(scopeKeys: scopeKeys,
                                           library: library,
                                           suggestions: suggestions,
                                           analysis: analysis)
        guard !set.labels.isEmpty else {
            notice = .init(title: "Nothing to train on \(scopeTitle)",
                           detail: "Tag some videos first (⌘T) — typed tags and accepted suggestions are both lessons. A tag needs 4+ accepted and 4+ rejected videos before a head can be fitted, so ⌥clicking a wrong suggestion chip (or ✕ on an AI candidate) matters too.")
            return
        }
        Task {
            do {
                let fits = try await engine.trainHeads(labels: set.labels,
                                                       frameHashes: set.frameHashes)
                var lines = fits.map { fit in
                    fit.fitted
                        ? "✓ \(fit.tag): fitted on \(fit.videos ?? 0) videos, held-out precision \(fit.precision.map { "\($0)" } ?? "–")"
                        : "– \(fit.tag): \(fit.reason ?? "skipped")"
                }
                if !set.unanalysed.isEmpty {
                    lines.append("⏳ \(set.unanalysed.count) tagged video\(set.unanalysed.count == 1 ? "" : "s") not classified yet — run Classify, then Train again")
                }
                notice = .init(
                    title: fits.contains(where: \.fitted) ? "Trained \(scopeTitle)" : "Nothing fitted \(scopeTitle)",
                    detail: lines.isEmpty ? "No tag had enough examples." : lines.joined(separator: "\n"))
            } catch {
                notice = .init(title: "Training failed", detail: error.localizedDescription)
            }
        }
    }

    /// The tagged videos under a folder (share-relative keys), so folder-scope
    /// training only asks about videos that have tags — the rest have nothing
    /// to teach yet.
    func taggedKeys(under folderPath: String) -> [String] {
        guard let library else { return [] }
        let prefix = Paths.tagKey(folderPath)
        return library.tags.keys.filter { key in
            key == prefix || key.hasPrefix(prefix + "/")
        }
    }

    func trainFolder(_ path: String) {
        trainScope(scopePaths: taggedKeys(under: path),
                   scopeTitle: "from this folder")
    }

    func trainTag(_ tag: String) {
        guard let library else { return }
        let keys = library.tags.filter { _, names in
            names.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        }.keys
        trainScope(scopePaths: Array(keys), scopeTitle: "for “\(tag)”")
    }

    /// What the engine is doing this second, in a line the user can act on —
    /// training must never appear to be refused for no reason.
    private func busyDetail(_ engine: AnalysisEngine) -> String {
        let status: String
        switch engine.phase {
        case .starting: status = "Starting the engine…"
        case .preparing: status = engine.statusText.isEmpty ? "Loading the model…" : engine.statusText
        case .working:
            if let name = engine.currentName {
                status = "Classifying “\(name)”"
            } else {
                status = "Classifying…"
            }
        case .stopping: status = "Stopping…"
        default: status = "Working…"
        }
        var detail = "\(status) — Training needs the engine free."
        if engine.totalCount > 0 {
            detail += "\nProgress: \(engine.doneCount) of \(engine.totalCount) done"
            if engine.failedCount > 0 { detail += " · \(engine.failedCount) failed" }
        }
        detail += "\n\nPress Stop in the playlist toolbar to interrupt, then Train again."
        return detail
    }
}
