import Foundation
import IOKit.ps

/// Keeps the opted-in folders up to date in the background: looks for new,
/// removed and moved videos every so often, and works through each new video's
/// allowed jobs one at a time — pausing while something plays, on battery, or
/// outside the chosen hours, as the settings say.
///
/// The decisions live in `MaintenancePlanner`; this is the loop around them.
/// The AI passes go through the same entry points a person uses — classify
/// through the job ledger, tag ideas and transcripts through their panels'
/// requests — so there is one way each is done and one place it is shown.
///
/// Nothing starts until a folder is opted in. A folder that does not answer (a
/// NAS asleep, a share unplugged) is reported and tried again later; nothing
/// waits on it on the main thread.
@MainActor
final class MaintenanceWorker: ObservableObject {

    enum Status: Equatable {
        case off
        case idle(String)
        case scanning(String)
        case working(name: String, left: Int)
        case paused(String)

        var line: String {
            switch self {
            case .off: return "Off — no folder is kept up to date."
            case .idle(let why): return why
            case .scanning(let folder): return "Looking for changes in \(folder)…"
            case .working(let name, let left): return "Working on \(name) — \(left) left"
            case .paused(let why): return why
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var file = MaintenanceFile()

    private var profile = ""
    private weak var app: AppModel?
    private weak var library: Library?
    private weak var media: MediaCache?
    private var loop: Task<Void, Never>?
    private var forceScan = false

    var settings: MaintenanceSettings { file.settings }

    func attach(app: AppModel, library: Library, media: MediaCache) {
        self.app = app
        self.library = library
        self.media = media
        reload(profile: Paths.activeProfile)
    }

    /// A profile's own folders and queue. The loop of the profile being left
    /// stops first, so nothing it was doing lands in the new one.
    func reload(profile: String) {
        loop?.cancel()
        loop = nil
        self.profile = profile
        file = profile.isEmpty ? MaintenanceFile() : MaintenanceFile.load(at: path)
        restart()
    }

    private var path: String { ProfileBundle.file(in: profile, "maintenance.json") }

    // MARK: - settings

    func update(_ change: (inout MaintenanceSettings) -> Void) {
        change(&file.settings)
        file.settings.concurrency = min(max(file.settings.concurrency, 1), 4)
        file.settings.rescanMinutes = min(max(file.settings.rescanMinutes, 5), 24 * 60)
        persist()
        restart()
    }

    func isMaintained(_ folder: String) -> Bool { file.settings.folders.contains(folder) }

    /// Opt a folder in or out. Out forgets its snapshot and its queued work:
    /// the folder is none of this feature's business any more.
    func setMaintained(_ folder: String, _ on: Bool) {
        if on {
            guard !isMaintained(folder) else { return }
            file.settings.folders.append(folder)
        } else {
            file.settings.folders.removeAll { $0 == folder }
            file.known.removeValue(forKey: folder)
            file.lastScan.removeValue(forKey: folder)
            file.queue.removeAll { Scanner.under($0.path, [folder]) }
        }
        persist()
        restart()
    }

    func checkNow() {
        forceScan = true
        restart()
    }

    func clearQueue() {
        file.queue = []
        persist()
    }

    func retryFailed() {
        let paths = Array(file.failed.keys)
        file.failed = [:]
        file.queue = MaintenancePlanner.enqueue(paths, work: file.settings.work, into: file.queue,
                                                hidden: library?.hidden ?? [], now: Date().timeIntervalSince1970)
        persist()
        restart()
    }

    private func persist() {
        guard !profile.isEmpty else { return }
        _ = file.save(to: path)
    }

    private func restart() {
        loop?.cancel()
        guard !profile.isEmpty, !file.settings.folders.isEmpty else {
            loop = nil
            status = .off
            return
        }
        loop = Task { [weak self] in await self?.run() }
    }

    // MARK: - the loop

    private func run() async {
        while !Task.isCancelled {
            if let why = pauseReason() {
                status = .paused(why)
                try? await Task.sleep(for: .seconds(20))
                continue
            }
            let now = Date().timeIntervalSince1970
            // Only pinned folders are kept up to date, and pins now follow the
            // profile between Macs: a folder another Mac unpinned has left
            // Settings' list, so it is left alone here too until pinned again.
            let due = file.settings.folders.filter {
                library?.isPinned($0) == true
                && (forceScan || MaintenancePlanner.isDue(lastScan: file.lastScan[$0],
                                                          minutes: file.settings.rescanMinutes, now: now))
            }
            forceScan = false
            for folder in due {
                guard !Task.isCancelled, pauseReason() == nil else { break }
                await scan(folder)
            }
            if Task.isCancelled { return }
            if !file.queue.isEmpty {
                await workBatch()
                continue
            }
            let failed = file.failed.count
            status = .idle(failed == 0 ? "Up to date."
                           : "Up to date. \(failed) video\(failed == 1 ? "" : "s") could not be done.")
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func pauseReason() -> String? {
        let hour = Calendar.current.component(.hour, from: Date())
        if let reason = MaintenancePlanner.pauseReason(file.settings, playing: app?.playback?.head.playing ?? false,
                                                       onBattery: Self.onBattery, hour: hour) {
            return reason
        }
        guard library?.profileOpen == true else { return "Paused: no profile is open." }
        return nil
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    // MARK: - scanning

    /// Walk one folder off the main thread and fold the changes in. A folder
    /// that does not answer within a minute is left for next time.
    private func scan(_ folder: String) async {
        guard let library else { return }
        let name = (folder as NSString).lastPathComponent
        status = .scanning(name)
        let walked: [(path: String, size: Int64)]? = await withTaskGroup(of: [(path: String, size: Int64)]?.self) { group in
            group.addTask { await Task.detached(priority: .utility) { Self.walk(folder) }.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let now = Date().timeIntervalSince1970
        guard let walked else {
            // Not answering, or not there: try again at the next interval.
            file.lastScan[folder] = now
            persist()
            status = .paused("“\(name)” is not reachable right now; it will be tried again.")
            return
        }
        let hidden = library.hidden
        let fresh = MaintenancePlanner.snapshot(walked, under: folder, hidden: hidden)
        let old = file.known[folder] ?? [:]
        let changes = MaintenancePlanner.diff(old: old, new: fresh)
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        func full(_ relative: String) -> String { prefix + relative }

        // A move the scan is sure of carries the video's tags, readings,
        // transcript, moments and watch history — the moved-file repair's own
        // single-match rule, applied as it is noticed.
        for move in changes.moved { library.moveTags(from: full(move.from), to: full(move.to)) }
        if !changes.moved.isEmpty { library.save() }    // resume points, hidden flags
        var queue = MaintenancePlanner.move(changes.moved.map { (full($0.from), full($0.to)) }, in: file.queue)
        queue = MaintenancePlanner.drop(Set(changes.removed.map(full)), from: queue)
        for gone in changes.removed { file.failed.removeValue(forKey: full(gone)) }
        queue = MaintenancePlanner.enqueue(changes.added.map(full).filter { file.failed[$0] == nil },
                                           work: file.settings.work, into: queue, hidden: hidden, now: now)
        file.queue = queue
        file.known[folder] = fresh
        file.lastScan[folder] = now
        persist()
    }

    /// Every video under a folder with its size. Nil when the folder is not
    /// there — which is different from a folder with nothing in it.
    nonisolated private static func walk(_ folder: String) -> [(path: String, size: Int64)]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue,
              let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles]) else { return nil }
        var found: [(String, Int64)] = []
        let discarded = Scanner.discarded
        for case let url as URL in walk {
            if Scanner.isInside(url.path, discarded) { walk.skipDescendants(); continue }
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            found.append((url.path, Int64(values?.fileSize ?? 0)))
        }
        return found
    }

    // MARK: - working

    enum StepResult: Equatable {
        case done
        /// Not possible here (the feature is not installed, or not needed).
        case skip
        /// Possible, but not now (the engine is busy with something asked for).
        case later
        case failed(String)
    }

    /// The light work of up to `concurrency` videos at once, then the AI work of
    /// the first one — so a share is never asked for more at a time than the
    /// setting allows, and the engine never runs two passes.
    private func workBatch() async {
        let batch = Array(file.queue.prefix(file.settings.concurrency))
        await withTaskGroup(of: Void.self) { group in
            for item in batch {
                group.addTask { @MainActor [weak self] in await self?.work(item.path, lightOnly: true) }
            }
        }
        guard !Task.isCancelled, pauseReason() == nil, let first = file.queue.first else { return }
        await work(first.path, lightOnly: false)
    }

    private func work(_ path: String, lightOnly: Bool) async {
        guard let library, var item = file.queue.first(where: { $0.path == path }) else { return }
        if library.isHidden(path) {
            file.queue.removeAll { $0.path == path }
            persist()
            return
        }
        let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
        guard exists else {
            // Gone since the scan: dropped, not retried; the next scan says so.
            file.queue.removeAll { $0.path == path }
            persist()
            return
        }
        status = .working(name: (path as NSString).lastPathComponent, left: file.queue.count)
        for kind in item.remaining where !lightOnly || kind.isLight {
            if Task.isCancelled || pauseReason() != nil { return }
            let result = await step(kind, path)
            switch result {
            case .done, .skip:
                item.remaining.removeAll { $0 == kind }
            case .later:
                // Keep it, but let the next video go first.
                file.queue.removeAll { $0.path == path }
                file.queue.append(item)
                persist()
                try? await Task.sleep(for: .seconds(15))
                return
            case .failed(let why):
                file.queue.removeAll { $0.path == path }
                if let again = MaintenancePlanner.afterFailure(item, error: why) {
                    file.queue.append(again)
                } else {
                    file.failed[path] = why
                }
                persist()
                return
            }
            if let i = file.queue.firstIndex(where: { $0.path == path }) { file.queue[i] = item }
            persist()
        }
        if item.remaining.isEmpty {
            file.queue.removeAll { $0.path == path }
            persist()
        }
    }

    private func step(_ kind: MaintenanceWork, _ path: String) async -> StepResult {
        guard let app, let library, let media else { return .later }
        switch kind {
        case .posters:
            if media.cachedPoster(path, big: false) != nil { return .skip }
            return await media.poster(path, big: false) != nil ? .done : .failed("no poster frame could be made")

        case .metadata:
            if library.factsFor(path).contains(where: { AutoTagCore.yearIn($0) != nil }) { return .skip }
            let date = await Task.detached(priority: .utility) { MetadataTagger.fileDate(path) }.value
            guard let date, let year = AutoTagCore.yearTag(date) else { return .skip }
            library.addFacts([year], for: path)
            library.saveFacts()
            return .done

        case .classify:
            guard app.ai.works(.classify), let analysis = app.analysis else { return .skip }
            guard analysis.needsClassification(path) else { return .skip }
            guard !app.engine.isBusy, app.suggestingPath == nil else { return .later }
            await app.classify(paths: [path])
            switch analysis.analysis(for: path)?.phase {
            case .done: return .done
            case .failed: return .failed("the verdict pass could not read it")
            default: return .later
            }

        case .suggest:
            guard app.ai.works(.tags), let suggestions = app.suggestions else { return .skip }
            guard suggestions.entry(path) == nil else { return .skip }
            guard !app.engine.isBusy, app.suggestingPath == nil else { return .later }
            NotificationCenter.default.post(name: AppModel.suggestTagsNotification, object: path)
            return await waitFor(start: { app.suggestingPath == path }, end: { app.suggestingPath == nil },
                                 limit: 600) ? (suggestions.entry(path) == nil ? .failed("no suggestions were made") : .done)
                                            : .later

        case .transcribe:
            guard app.ai.works(.speech) else { return .skip }
            guard app.transcribingPath == nil, app.transcribeBatch == nil else { return .later }
            NotificationCenter.default.post(name: AppModel.transcribeNotification, object: path)
            return await waitFor(start: { app.transcribingPath == path }, end: { app.transcribingPath == nil },
                                 limit: 3 * 3600) ? .done : .later
        }
    }

    /// Wait for a pass asked for by notification to start and then finish.
    /// False when it never started (the window refused it) or ran too long.
    private func waitFor(start: () -> Bool, end: () -> Bool, limit: Double) async -> Bool {
        var waited = 0.0
        while !start() {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25
            if waited > 10 || Task.isCancelled { return false }
        }
        waited = 0
        while !end() {
            try? await Task.sleep(for: .seconds(1))
            waited += 1
            if waited > limit || Task.isCancelled { return false }
        }
        return true
    }
}
