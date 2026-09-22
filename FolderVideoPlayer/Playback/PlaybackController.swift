import AVFoundation
import AppKit
import Foundation

/// A row in the playlist: a folder heading, or a video.
enum PlaylistRow: Identifiable, Hashable {
    case heading(String)
    case video(String)

    var id: String {
        switch self {
        case .heading(let name): return "#" + name
        case .video(let path): return path
        }
    }
}

/// Where the playhead is, on its own object.
///
/// This changes four times a second. Published from the controller, it made
/// every view that observes the controller — the whole playlist among them —
/// re-evaluate at that rate, and with a thousand rows that is a thousand rows
/// of work per tick. Only the transport bar needs to see it, so only the
/// transport bar observes this.
@MainActor
final class Playhead: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
}

/// The playlist and the player: what is playing, what plays next, and where
/// each video got to.
@MainActor
final class PlaybackController: ObservableObject {
    let engine: AVPlayerEngine
    private let library: Library
    let media: MediaCache

    @Published private(set) var playlist: [String] = []
    @Published private(set) var index = 0
    @Published private(set) var mode: PlayMode = .folder
    @Published private(set) var root: String?
    @Published private(set) var tagName: String?
    let head = Playhead()
    /// The rows as they are drawn, held rather than derived on demand: the
    /// list asks for them several times per redraw, and filtering a thousand
    /// paths on each of those showed.
    @Published private(set) var rows: [PlaylistRow] = []
    /// Typing in the filter rebuilds the rows, but not per keystroke: a
    /// hundred-and-twenty-millisecond hold means a full playlist re-filter
    /// lands when the typing pauses, not once per letter. Filename substring
    /// only — tags stay out so typing a tag never hides untagged files.
    @Published var nameFilter = "" { didSet { scheduleFilter() } }
    /// Tags ticked in the filter strip, and how they combine — see
    /// `TagFilterMode`.
    /// How several ticked tags combine.
    ///
    /// AND was the only option and could not express "Iceland or Singapore",
    /// nor "2015 but not Birthday" — the two questions a big library asks most.
    enum TagFilterMode: String, CaseIterable, Identifiable {
        case all, any
        var id: String { rawValue }
        var title: String { self == .all ? "All" : "Any" }
        var help: String {
            self == .all
                ? "Show videos carrying every ticked tag"
                : "Show videos carrying at least one ticked tag"
        }
    }

    @Published private(set) var tagFilter: Set<String> = []
    /// Tags that rule a video OUT, whatever else it carries.
    @Published private(set) var tagExcluded: Set<String> = []
    @Published var tagFilterMode: TagFilterMode = .all { didSet { rebuildRows() } }
    private var filterWork: Task<Void, Never>?
    /// What went wrong with the current video, when something did.
    @Published private(set) var trouble: String?
    /// Files this session has tried and failed to play, and why — the
    /// playlist's badge source. A file is missing (gone from disk) or
    /// corrupted (there but unplayable); existence is the only honest test
    /// and it is asked off the main thread.
    enum FileProblem { case missing, corrupted }
    @Published private(set) var problems: [String: FileProblem] = [:]

    /// A video AVFoundation could not open, waiting on the user's yes or no
    /// to converting it (and the rest of the playlist like it) to MP4.
    struct ConversionOffer: Equatable {
        let path: String
        let why: String
    }
    @Published private(set) var conversionOffer: ConversionOffer?
    /// The conversion run in progress: which video, how far, of how many.
    struct Conversion: Equatable {
        let path: String
        var remux: Bool
        /// 0…1, nil until FFmpeg knows the length.
        var fraction: Double?
        var done: Int
        var total: Int
    }
    @Published private(set) var conversion: Conversion?
    private var conversionTask: Task<Void, Never>?
    /// Said no to, or already failed, this launch: not offered again.
    private var conversionDeclined: Set<String> = []
    /// Puts a finished copy in the original's place: details moved, original
    /// to the Trash. Supplied by the app, which owns the "which folder, on a
    /// share with no Trash" question.
    var replaceOriginal: ((_ original: String, _ copy: String) -> FileOps.Report)?
    /// The run's closing line, for the app to show.
    var onConversionFinished: ((String) -> Void)?
    /// Set while a folder is being walked, so the window can say so.
    @Published private(set) var scanning = false
    /// Held open while the tag panel is up: you are looking at this video
    /// because you are labelling it, so it does not move on underneath you.
    @Published var tagPanelOpen = false { didSet { if !tagPanelOpen { releaseHold() } } }

    /// The shuffled order, as paths rather than positions: the list can be
    /// re-sorted underneath it, and a position would then mean something else.
    private var bag: [String] = []
    private var heldAdvance = false
    private var failures = 0
    private var ticks = 0
    private var progressTimer: Timer?

    var position: Double { head.position }
    var duration: Double { head.duration }
    var playing: Bool { head.playing }

    var currentPath: String? {
        // A preview plays a file OUTSIDE the playlist (an AI-suggested
        // candidate the user is judging): it must never re-point the list.
        if let previewPath { return previewPath }
        return playlist.indices.contains(index) ? playlist[index] : nil
    }

    /// A video playing without being IN the playlist: an AI look-alike
    /// candidate clicked for a quick look. The playlist, mode and rows stay
    /// exactly as they were — previewing must not feel like navigation.
    @Published private(set) var previewPath: String?

    init(library: Library, media: MediaCache) {
        self.library = library
        self.media = media
        self.engine = AVPlayerEngine()
        engine.volume = library.volume
        engine.rate = library.speed
        engine.onEnded = { [weak self] in self?.itemFinished() }
        engine.onTime = { [weak self] seconds in
            guard let self else { return }
            self.head.position = seconds
            self.head.duration = self.engine.duration
            self.head.playing = self.engine.isPlaying
            // The length comes free once the video is open, so it is written
            // down here rather than by opening every file in the list to ask.
            if let path = self.currentPath, self.head.duration > 0,
               self.media.length(path) == nil {
                self.media.remember(length: self.head.duration, for: path)
            }
        }
        engine.onFailed = { [weak self] why in self?.reportTrouble(why) }
        progressTimer = Timer.scheduledTimer(withTimeInterval: Tuning.progressTick,
                                             repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordProgress() }
        }
    }

    // MARK: - opening things

    /// Walk a folder and play what is in it.
    ///
    /// The walk happens off the main thread. A folder tree of several thousand
    /// files takes long enough that doing it here would stop the window
    /// answering, which macOS draws as a spinning wheel.
    func openFolder(_ root: String, resume: String? = nil) {
        library.remember(folder: root)
        scanning = true
        trouble = nil
        Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) {
                Scanner.scan(root)
            }.value
            guard let self else { return }
            self.scanning = false
            guard !items.isEmpty else {
                self.trouble = "No videos in “\((root as NSString).lastPathComponent)”."
                self.playlist = []
                self.rebuildRows()
                return
            }
            self.start(items, mode: .folder, root: root, resume: resume)
        }
    }

    /// Play every video carrying a name — a tag, a person, or a reading the
    /// scan took off the file.
    ///
    /// `pathsCarrying` rather than `taggedWith`, so a Date or Camera & Quality
    /// row in the sidebar plays the same way a tag row does. For a name that is
    /// only ever a tag the two answer identically, so nothing about the old
    /// behaviour changes.
    func playTag(_ tag: String, resume: String? = nil) {
        tagName = tag
        start(library.pathsCarrying(tag), mode: .tag, root: nil, resume: resume)
    }

    /// Play the hidden videos. Callers must have asked for the password first;
    /// this function does not check the lock, because the point of the lock is
    /// to stop the list being REACHED, and every caller goes through the
    /// unlock sheet. An empty hidden set is reported rather than shown blank.
    func playHidden(resume: String? = nil) {
        let items = library.hiddenPaths()
        guard !items.isEmpty else {
            trouble = "No videos are hidden."
            return
        }
        start(items, mode: .hidden, root: nil, resume: resume)
    }

    /// Pick up where the last session left off, if what it names still exists.
    @discardableResult
    func resumeLastSession() -> Bool {
        guard let session = library.session, !session.path.isEmpty else { return false }
        switch PlayMode(rawValue: session.mode) ?? .folder {
        case .folder:
            // Deliberately not checked for existence here: that is a stat on a
            // share that may be asleep, and the walk that follows reports a
            // folder that has gone anyway.
            guard let root = session.root else { return false }
            openFolder(root, resume: session.path)
        case .tag:
            guard let tag = session.tag, !library.taggedWith(tag).isEmpty else { return false }
            playTag(tag, resume: session.path)
            // A v1.1.1 star playlist (mode "rated") resumes as its tag now;
            // anything else pre-stars resumes into nothing, as before.
        case .favorites:
            return false
        case .hidden:
            // A relaunch is locked, so there is nothing to resume into. The
            // session is left alone rather than cleared.
            return false
        }
        return true
    }

    private func start(_ items: [String], mode: PlayMode, root: String?, resume: String?) {
        // The one place the hidden filter is applied on the way into a
        // playlist, so every caller — folder, tag, favorites, a drop, a
        // resume — is covered by construction rather than by remembering.
        let filter: HiddenFilter = mode == .hidden ? .only(library.hidden) : .omit(library.hidden)
        playlist = library.sorted(filter.apply(to: items))
        self.mode = mode
        self.root = root
        if mode != .tag { tagName = nil }
        failures = 0
        nameFilter = ""
        tagFilter = []
        tagExcluded = []
        rebuildRows()
        reshuffle(after: nil)
        // The list shows in folder order while the stats are warmed, and
        // settles when they land.
        applySort()
        var startAt = 0
        if let resume, let found = playlist.firstIndex(of: resume) {
            // A folder can change between sessions; falling back to the top is
            // the only sane answer when the video we left off on is gone.
            startAt = found
        } else if library.order == .shuffle, let first = bag.first,
                  let found = playlist.firstIndex(of: first) {
            startAt = found
        }
        play(at: startAt)
        saveSession()
    }

    /// Stop and empty the playlist: no video, no rows, no session to resume.
    ///
    /// For switching tag profile. A profile is a different person's library,
    /// and their tags decide what a tag playlist even contains — so carrying
    /// the last one across would leave rows on screen that the new profile
    /// has no claim to, and a video playing that it never chose.
    func closePlaylist() {
        stopConverting()
        conversionOffer = nil
        stop()
        // stop() only rewinds and pauses — the video is still loaded and still
        // on screen. Switching profile means the window goes blank, so the
        // item is unloaded outright.
        engine.stop()
        previewPath = nil
        playlist = []
        index = 0
        mode = .folder
        root = nil
        tagName = nil
        nameFilter = ""
        tagFilter = []
        tagExcluded = []
        trouble = nil
        head.position = 0
        head.duration = 0
        head.playing = false
        rebuildRows()
        // The remembered session belongs to the profile being left. Cleared,
        // or the next launch would reopen one profile's videos under another
        // profile's name.
        library.session = nil
        library.save()
    }

    /// Re-sort in place, keeping whatever is playing playing.
    ///
    /// Date Added and File Size sort on a stat apiece, and the accessors only
    /// report what has already been asked — so sorting before the stats are in
    /// had every file tie on zero and fall through to the name, which sorted
    /// by name while claiming to sort by date. They are warmed first.
    func applySort() {
        guard !playlist.isEmpty else { return }
        guard library.playlistSort == .date || library.playlistSort == .size else {
            return reorder()
        }
        let items = playlist
        Task { [weak self] in
            await self?.library.warmStats(items)
            self?.reorder()
        }
    }

    /// What Next plays follows the order on screen, so this moves the playlist
    /// itself rather than only the list drawn from it.
    private func reorder() {
        let current = currentPath
        playlist = library.sorted(playlist)
        if let current, let found = playlist.firstIndex(of: current) { index = found }
        rebuildRows()
    }

    /// The videos as the list is showing them, in that order — what a shift
    /// click selects a run of.
    var visibleVideos: [String] {
        rows.compactMap { if case .video(let path) = $0 { return path } else { return nil } }
    }

    // MARK: - playing

    func play(at i: Int) {
        guard !playlist.isEmpty else { return }
        previewPath = nil                    // navigation leaves preview mode
        notePosition()
        index = ((i % playlist.count) + playlist.count) % playlist.count
        let path = playlist[index]
        trouble = nil
        problems.removeValue(forKey: path)
        head.position = 0
        head.duration = media.length(path) ?? 0
        engine.rate = library.speed
        engine.volume = library.volume
        conversionOffer = nil
        engine.load(URL(fileURLWithPath: path), startAt: library.resumePoint(path))
        engine.play()
        head.playing = true
        // Auto duplicate scanning is switched off: the index no longer
        // grows while you watch. `noticeWhilePlaying` remains in Library for
        // when the feature is wanted again — re-add the call here.
        // library.noticeWhilePlaying(path)
        saveSession()
    }

    /// Open whatever was dropped on the window.
    ///
    /// A folder is the ordinary case and behaves exactly like Open Folder. A
    /// handful of video files becomes a playlist of its own, rooted at the
    /// folder they came from, so the title and the Recent list still name
    /// something real. Anything that is neither is reported rather than
    /// silently ignored — a drop that appears to do nothing reads as a bug.
    func openDropped(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var isDir: ObjCBool = false
        // One folder: the plain case, and the only one that can walk a tree.
        if paths.count == 1,
           FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDir),
           isDir.boolValue {
            openFolder(paths[0])
            return
        }
        let videos = paths.filter {
            videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }
        guard !videos.isEmpty else {
            trouble = paths.count == 1
                ? "“\((paths[0] as NSString).lastPathComponent)” is not a video this app plays."
                : "Nothing dropped there was a video this app plays."
            return
        }
        // Several files: their own list. The root is the folder they share,
        // when they share one, so Recent and the window title mean something.
        let parents = Set(videos.map { ($0 as NSString).deletingLastPathComponent })
        let root = parents.count == 1 ? parents.first : nil
        if let root { library.remember(folder: root) }
        start(videos, mode: .folder, root: root, resume: nil)
        if videos.count < paths.count {
            trouble = "Playing \(videos.count) of \(paths.count) — the rest were not videos."
        }
    }

    /// Play one video WITHOUT leaving the playlist that is on screen.
    ///
    /// The AI-suggested rows in a tag playlist live outside `playlist` — they
    /// are candidates, not members. Clicking one to look at it must not
    /// navigate (open its folder / switch the playlist): it loads in the same
    /// player, the list stays put, and when it ends playback simply stops
    /// here rather than advancing into the tag list — the user is judging,
    /// not queueing. `next`/`previous`/clicking a real row all leave preview.
    func preview(_ path: String) {
        previewPath = path
        trouble = nil
        problems.removeValue(forKey: path)
        head.position = 0
        head.duration = media.length(path) ?? 0
        engine.rate = library.speed
        engine.volume = library.volume
        conversionOffer = nil
        engine.load(URL(fileURLWithPath: path), startAt: library.resumePoint(path))
        engine.play()
        head.playing = true
        // Deliberately no saveSession(): the session must keep describing
        // the tag playlist, not a candidate that is not in it.
    }

    /// Stop the picture and the sound because the window has gone. Not
    /// `stop()`: that forgets the resume position, and closing a window is
    /// "I am done looking at this for now", not "start me from the top".
    func pauseForWindowClose() {
        engine.pause()
        head.playing = false
    }

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
        } else {
            if heldAdvance { return releaseHold() }
            engine.play()
        }
        head.playing = engine.isPlaying
    }

    /// Stop, as against pause. The resume position goes with it: pause means
    /// "I am coming back to this spot", stop means "I am done with it", and
    /// being dropped two thirds of the way in next time would contradict that.
    func stop() {
        if let path = currentPath {
            library.progress.removeValue(forKey: path)
            library.progressSeen.removeValue(forKey: path)
            library.save()
        }
        engine.seek(to: 0)
        engine.pause()
        head.position = 0
        head.playing = false
    }

    func next() { play(at: step(1)) }
    func previous() { play(at: step(-1)) }

    func skip(_ seconds: Double) {
        let target = max(0, position + seconds)
        engine.seek(to: duration > 0 ? min(target, duration) : target)
        head.position = target
    }

    func seek(to seconds: Double) {
        engine.seek(to: seconds)
        head.position = seconds
    }

    func setSpeed(_ speed: Double) {
        library.speed = speed
        engine.rate = speed
    }

    /// Deliberately not saved here: a slider being dragged would otherwise
    /// rewrite state.json on every tick. It goes out with the next progress
    /// flush, which is at most half a minute away.
    func setVolume(_ volume: Int) {
        library.volume = volume
        engine.volume = volume
    }

    /// What plays when the current video ends, or nil to stop.
    private func followOn() -> Int? {
        switch library.order {
        case .one: return index
        case .once: return index + 1 < playlist.count ? index + 1 : nil
        default: return step(1)
        }
    }

    private func itemFinished() {
        if tagPanelOpen {
            // Hold here rather than moving on under an open tag panel.
            heldAdvance = true
            engine.pause()
            head.playing = false
            return
        }
        // A preview ending is a judgement moment, not a queue: the AI
        // candidate is done, stop here and let the user accept or dismiss
        // it — do not silently advance into the tag playlist.
        if previewPath != nil {
            previewPath = nil
            engine.pause()
            head.playing = false
            return
        }
        guard let nxt = followOn() else {
            engine.pause()
            head.playing = false
            return
        }
        play(at: nxt)
    }

    private func releaseHold() {
        guard heldAdvance else { return }
        heldAdvance = false
        if let nxt = followOn() { play(at: nxt) }
    }

    /// The index `delta` videos away, in the order the list is showing.
    ///
    /// The list is what "next" means. Sort by Date and the next video is the
    /// next one down the list, not whatever happened to follow in the order
    /// the folder was scanned in — and a filtered list plays only what it
    /// shows. Shuffle walks its own order, which is what asking for shuffle
    /// means.
    private func step(_ delta: Int) -> Int {
        guard !playlist.isEmpty else { return 0 }
        let shown = library.order == .shuffle ? bag : visibleVideos
        // A video that the filter has hidden is not in the list to step
        // through, so its own position in the playlist is the honest answer.
        guard !shown.isEmpty, let path = currentPath,
              let here = shown.firstIndex(of: path) else {
            return ((index + delta) % playlist.count + playlist.count) % playlist.count
        }
        let next = ((here + delta) % shown.count + shown.count) % shown.count
        if library.order == .shuffle, delta > 0, next == 0 { reshuffle(after: index) }
        return playlist.firstIndex(of: shown[next]) ?? index
    }

    /// A fresh shuffled order over what the list is showing, with the video in
    /// hand at the front so it is not immediately played again.
    func reshuffle(after: Int? = nil) {
        bag = visibleVideos.shuffled()
        guard let after, playlist.indices.contains(after) else { return }
        let path = playlist[after]
        bag.removeAll { $0 == path }
        bag.insert(path, at: 0)
    }

    // MARK: - trouble

    /// A video that will not play is said so, out loud, and skipped — rather
    /// than a black rectangle nobody can explain. A whole playlist of them
    /// stops rather than spinning through every file in it.
    // MARK: - the FFmpeg fallback

    /// Formats AVFoundation reads as a rule. Anything else in the playlist is
    /// a candidate for the run — and still asked `isPlayable` first, because a
    /// camera's Motion-JPEG `.avi` plays and must not be converted.
    private static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// The offer's Convert: this video first, then every other one in the
    /// playlist that AVFoundation cannot play, one at a time. Each finished
    /// copy replaces its original (`replaceOriginal`).
    func acceptConversion() {
        guard let offer = conversionOffer, conversionTask == nil,
              let tools = PlayableCopy.findTools() else { return }
        conversionOffer = nil
        trouble = nil
        let others = playlist.filter {
            $0 != offer.path && !Self.nativeExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        let queue = [offer.path] + others
        conversion = Conversion(path: offer.path, remux: true, fraction: nil, done: 0, total: queue.count)
        conversionTask = Task { [weak self] in
            var converted = 0, skipped = 0
            var failed: [String] = []
            var stayed: [String] = []
            for (i, source) in queue.enumerated() {
                guard !Task.isCancelled, let self else { break }
                self.conversion = Conversion(path: source, remux: true, fraction: nil, done: i, total: queue.count)
                // The first one has just failed to play; the rest are asked.
                if i > 0, await Self.plays(source) { skipped += 1; continue }
                let name = (source as NSString).lastPathComponent
                let target = FileOps.freeName(in: (source as NSString).deletingLastPathComponent,
                                              for: (name as NSString).deletingPathExtension + ".mp4")
                do {
                    try await PlayableCopy.make(from: source, to: target, tools: tools) { progress in
                        Task { @MainActor [weak self] in self?.noteProgress(progress, for: source) }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failed.append("\(name): \(error.localizedDescription)")
                    self.conversionDeclined.insert(source)
                    continue
                }
                converted += 1
                if let report = self.replaceOriginal?(source, target), !report.failed.isEmpty {
                    stayed.append(name)
                }
                self.adopt(source, as: target)
            }
            guard let self else { return }
            let stopped = Task.isCancelled
            self.conversion = nil
            self.conversionTask = nil
            var line = (stopped ? "Stopped. " : "") + "Converted \(converted) video\(converted == 1 ? "" : "s") to MP4."
            if skipped > 0 { line += " \(skipped) already played and were left alone." }
            if !stayed.isEmpty { line += " \(stayed.count) original\(stayed.count == 1 ? "" : "s") could not be moved to the Trash and are still there." }
            if !failed.isEmpty { line += " \(failed.count) could not be converted:\n" + failed.prefix(5).joined(separator: "\n") }
            self.onConversionFinished?(line)
        }
    }

    /// The offer's Not Now: this video is reported the ordinary way, and not
    /// offered again this launch.
    func declineConversion() {
        guard let offer = conversionOffer else { return }
        conversionOffer = nil
        conversionDeclined.insert(offer.path)
        guard offer.path == currentPath else { return }
        showTrouble(offer.path, offer.why)
    }

    /// Stop the run. The video in hand is abandoned with nothing half-written;
    /// the ones already done stay done.
    func stopConverting() {
        conversionTask?.cancel()
    }

    private func noteProgress(_ progress: PlayableCopy.Progress, for path: String) {
        guard var current = conversion, current.path == path else { return }
        // Whole percents only: this object is watched by the whole playlist,
        // and FFmpeg reports twice a second.
        let rounded = progress.fraction.map { ($0 * 100).rounded() / 100 }
        guard rounded != current.fraction || progress.remux != current.remux else { return }
        current.remux = progress.remux
        current.fraction = rounded
        conversion = current
    }

    /// Whether AVFoundation opens a file as it is. An inspection that errors is
    /// treated as "plays": nothing is converted on a guess.
    private nonisolated static func plays(_ path: String) async -> Bool {
        (try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.isPlayable)) ?? true
    }

    /// The converted copy is the video now: the list points at it, and if it
    /// is the one on screen, it plays from where the original was.
    private func adopt(_ old: String, as new: String) {
        let wasOnScreen = currentPath == old
        playlist = playlist.map { $0 == old ? new : $0 }
        bag = bag.map { $0 == old ? new : $0 }
        if previewPath == old { previewPath = new }
        problems.removeValue(forKey: old)
        rebuildRows()
        guard wasOnScreen else { return }
        trouble = nil
        engine.load(URL(fileURLWithPath: new), startAt: library.resumePoint(new))
        engine.play()
        head.playing = true
        saveSession()
    }

    private func reportTrouble(_ why: String) {
        guard let path = currentPath else { return }
        // AVFoundation said no. With FFmpeg here, ask before converting — the
        // answer replaces files — unless a run is already going or this video
        // has been declined or failed once this launch.
        //
        // Only for a definite "this format": a share that did not answer or a
        // file that has gone is not something converting would fix, and must
        // never put a Convert button in front of a video that plays.
        if conversionTask == nil, !conversionDeclined.contains(path), PlayableCopy.findTools() != nil {
            trouble = nil
            Task { [weak self] in
                let definite = await Self.definitelyUnplayable(path)
                guard let self, self.currentPath == path, self.conversionTask == nil else { return }
                if definite {
                    self.conversionOffer = ConversionOffer(path: path, why: why)
                } else {
                    self.showTrouble(path, why)
                }
            }
            return
        }
        showTrouble(path, why)
    }

    /// There, and AVFoundation answered "not playable" — not an error.
    private nonisolated static func definitelyUnplayable(_ path: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return (try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.isPlayable)) == false
    }

    private func showTrouble(_ path: String, _ why: String) {
        // The run is converting this very one: it plays when done (`adopt`),
        // so there is nothing to report and nowhere to skip to.
        if conversion?.path == path { trouble = nil; return }
        var line = "“\((path as NSString).lastPathComponent)” could not be played — \(why)"
        if conversionTask != nil {
            line += ". A conversion run is going; this one is converted if it is in the list."
        } else if PlayableCopy.findTools() == nil {
            line += ". Installing FFmpeg (brew install ffmpeg) lets the app convert formats like this one."
        }
        trouble = line
        // Gone or broken? Only the disk knows, and a sleeping NAS answers in
        // its own time — so the question is asked off the main thread and the
        // badge lands on the row when the answer comes back.
        Task { @MainActor [weak self] in
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            self?.problems[path] = exists ? .corrupted : .missing
        }
        failures += 1
        // During a preview a failed candidate stops here — no auto-advance
        // into the playlist (the user is judging, not queueing), and the
        // failure count must not accumulate against the tag list either.
        guard previewPath == nil else { return }
        guard failures < min(playlist.count, 10) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.trouble != nil else { return }
            if let nxt = self.followOn() { self.play(at: nxt) }
        }
    }

    // MARK: - remembering where each video got to

    private func recordProgress() {
        notePosition()
        ticks += 1
        // Sampling is cheap, writing is not; a crash costs half a minute at most.
        if ticks % Tuning.progressFlush == 0 { library.save() }
    }

    func notePosition() {
        guard let path = currentPath, position > 0 else { return }
        library.note(position: position, total: duration, for: path)
    }

    func saveSession() {
        guard let path = currentPath else { return }
        library.session = Session(mode: mode.rawValue, root: root, path: path,
                                  tag: tagName)
        library.save()
    }

    // MARK: - the list on screen

    /// Rebuild the drawn rows. Called when the playlist, the filter or the
    /// sort changes — and by the tag panel, since a filter can name a tag.
    func rebuildRows() {
        pruneTagFilter()
        rows = buildRows()
        // The shuffled order is drawn from the list, so it moves with it.
        if library.order == .shuffle { reshuffle(after: index) }
    }

    /// After the moved-video scan repairs or removes references, the session
    /// can be stale: a tag playlist holds the old paths, so the repaired
    /// videos show tagless until the tag is opened again. Re-query what the
    /// session is about and keep the playing video in place.
    func refreshAfterTagRepair() {
        let currentPath = index < playlist.count ? playlist[index] : nil
        switch mode {
        case .tag:
            guard let tag = tagName else { return }
            playlist = library.pathsCarrying(tag)
        case .favorites:
            // Retired mode; kept exhaustive, never live.
            break
        case .hidden:
            playlist = library.sorted(library.hiddenPaths())
        case .folder:
            // Same files on disk — only their drawn tags were stale.
            rebuildRows()
            return
        }
        if let currentPath, let newIndex = playlist.firstIndex(of: currentPath) {
            index = newIndex
        } else {
            index = min(index, max(playlist.count - 1, 0))
        }
        rebuildRows()
    }

    /// Re-ask what this playlist is made of, keeping the playing video put.
    ///
    /// `rebuildRows` only re-filters the list already in hand, so a video that
    /// has just BECOME a member — accepting an AI look-alike, tagging one from
    /// the tag panel — was still absent from `playlist` and could not appear
    /// however many times the rows were rebuilt. This re-queries the source.
    func refreshMembership() {
        let playing = index < playlist.count ? playlist[index] : nil
        switch mode {
        case .tag:
            guard let tag = tagName else { return rebuildRows() }
            playlist = library.sorted(library.pathsCarrying(tag))
        case .favorites:
            break
        case .hidden:
            playlist = library.sorted(library.hiddenPaths())
        case .folder:
            // A folder's membership is the disk's business, not a tag's —
            // but hiding is the app's, so what was just hidden leaves the
            // list in hand rather than waiting for the folder to be reopened.
            playlist = library.hiddenFilter.apply(to: playlist)
            index = min(index, max(playlist.count - 1, 0))
            return rebuildRows()
        }
        if let playing, let found = playlist.firstIndex(of: playing) {
            index = found
        } else {
            index = min(index, max(playlist.count - 1, 0))
        }
        rebuildRows()
    }

    // MARK: - filtering by tag

    /// Every tag carried by the videos in this playlist, most-used first
    /// then alphabetical — the chips the filter offers. Only tags that are
    /// actually on these files: a chip that can only ever empty the list is
    /// not worth offering.
    var tagsInPlaylist: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for path in playlist {
            for name in library.tagsFor(path) {
                let key = name.lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = name }
            }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .compactMap { key, count in display[key].map { ($0, count) } }
    }

    func isTagFiltered(_ name: String) -> Bool {
        tagFilter.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func isTagExcluded(_ name: String) -> Bool {
        tagExcluded.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A tag chip cycles: off -> wanted -> not wanted -> off.
    ///
    /// One control for both halves of the question, because "show me Iceland"
    /// and "hide anything tagged Birthday" are the same gesture on the same
    /// chip — a separate exclude list somewhere else would be a second place
    /// to look when the list comes back empty.
    func toggleTagFilter(_ name: String) {
        if let existing = tagFilter.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            tagFilter.remove(existing)
            tagExcluded.insert(existing)
        } else if let existing = tagExcluded.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            tagExcluded.remove(existing)
        } else {
            tagFilter.insert(name)
        }
        rebuildRows()
    }

    func clearTagFilter() {
        guard !tagFilter.isEmpty || !tagExcluded.isEmpty else { return }
        tagFilter.removeAll()
        tagExcluded.removeAll()
        rebuildRows()
    }

    /// Drop any ticked tag that nothing in the list carries any more — after
    /// a re-tag or a move, a chip for a tag that has left would filter the
    /// list down to nothing with no way to see why.
    private func pruneTagFilter() {
        guard !tagFilter.isEmpty || !tagExcluded.isEmpty else { return }
        let present = Set(tagsInPlaylist.map { $0.name.lowercased() })
        tagFilter = tagFilter.filter { present.contains($0.lowercased()) }
        tagExcluded = tagExcluded.filter { present.contains($0.lowercased()) }
    }

    /// After videos are moved, renamed or trashed, the list in hand names
    /// paths that may no longer exist. A folder session is walked again; a
    /// tag or favorites session is re-queried. Whatever is still playable
    /// keeps playing.
    func refreshAfterFileChanges() {
        let playingNow = currentPath
        switch mode {
        case .folder:
            guard let root else { return }
            Task { [weak self] in
                let items = await Task.detached(priority: .userInitiated) {
                    Scanner.scan(root)
                }.value
                guard let self else { return }
                self.playlist = self.library.sorted(items)
                self.settle(on: playingNow)
            }
        case .tag:
            guard let tag = tagName else { return }
            playlist = library.pathsCarrying(tag)
            settle(on: playingNow)
        case .favorites:
            break
        case .hidden:
            playlist = library.sorted(library.hiddenPaths())
            settle(on: playingNow)
        }
    }

    /// Keep the playhead where it was if that video is still in the list;
    /// otherwise stay at the same spot in the list rather than jumping home.
    private func settle(on playingNow: String?) {
        if let playingNow, let found = playlist.firstIndex(of: playingNow) {
            index = found
        } else {
            index = min(index, max(playlist.count - 1, 0))
        }
        rebuildRows()
    }

    private func scheduleFilter() {
        filterWork?.cancel()
        filterWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.rebuildRows()
        }
    }

    /// The playlist as rows, with folder headings when the list is in folder
    /// order under a root — the headings describe that order and would be a
    /// lie under any other.
    private func buildRows() -> [PlaylistRow] {
        // A file-name substring filter, nothing else — the tags stay out of
        // the playlist filter so typing a tag never hides untagged files.
        let needle = nameFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let ticked = tagFilter
        let banned = tagExcluded
        let combine = tagFilterMode
        // The hidden filter applies here as well as at `start`, so hiding a
        // video takes effect on the list already on screen — a folder playlist
        // holds the disk's contents, and hiding one must not need a re-open.
        let filter: HiddenFilter = mode == .hidden ? .only(library.hidden) : .omit(library.hidden)
        let visible = filter.apply(to: playlist).filter { path in
            if !needle.isEmpty,
               !(path as NSString).lastPathComponent.lowercased().contains(needle) {
                return false
            }
            guard !ticked.isEmpty || !banned.isEmpty else { return true }
            let carried = library.tagsFor(path)
            func carries(_ want: String) -> Bool {
                carried.contains { $0.caseInsensitiveCompare(want) == .orderedSame }
            }
            // A NOT beats everything: an excluded tag rules the video out
            // however well it satisfies the rest.
            if banned.contains(where: carries) { return false }
            guard !ticked.isEmpty else { return true }
            return combine == .all ? ticked.allSatisfy(carries) : ticked.contains(where: carries)
        }
        guard library.playlistSort == .folder, let root, mode == .folder else {
            return visible.map { .video($0) }
        }
        var rows: [PlaylistRow] = []
        var heading: String?
        for path in visible {
            let folder = (path as NSString).deletingLastPathComponent
            let label = groupLabel(folder, under: root)
            if label != heading {
                heading = label
                rows.append(.heading(label))
            }
            rows.append(.video(path))
        }
        return rows
    }

    private func groupLabel(_ folder: String, under root: String) -> String {
        if folder == root { return (root as NSString).lastPathComponent }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard folder.hasPrefix(prefix) else { return (folder as NSString).lastPathComponent }
        return String(folder.dropFirst(prefix.count))
    }

    /// What the window is called: the folder, the tag, or Favorites.
    var sessionLabel: String {
        let name: String
        switch mode {
        case .folder: name = root.map { ($0 as NSString).lastPathComponent } ?? "FolderVideoPlayer"
        case .tag: name = tagName ?? "Tag"
        case .favorites: name = "Favorites"
        case .hidden: name = "Hidden"
        }
        return playlist.isEmpty ? name : "\(name) (\(playlist.count))"
    }

    func jump(to path: String) {
        guard let found = playlist.firstIndex(of: path) else { return }
        play(at: found)
    }
}
