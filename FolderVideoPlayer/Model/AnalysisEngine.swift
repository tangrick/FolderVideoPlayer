import Foundation
import Combine

// MARK: - the wire protocol
//
// The app and the engine speak one JSON object per line over stdio: requests
// from us ({"id": n, "cmd": ...}), events from it. Every engine event carries
// the request's id, and each request ends in exactly one "done" line, so a
// caller can simply drain events until the matching done arrives. The engine
// keeps no state the app must know about and the app links no model — either
// half can be replaced without rebuilding the other (the spec's one hard rule).

/// What a hello handshake reports back: which model, which device, which
/// tunables — the provenance a stored verdict is judged against.
struct EngineHello: Decodable {
    let engine: String
    let version: String
    let device: String
    let classifier: String
    let sampling: String
    let aggregation: String
    let ffmpeg: String
    let model: EngineModelInfo
    let maxFrames: Int
    let threshold: Double
}

struct EngineModelInfo: Decodable {
    let id: String
    let dim: Int
}

/// The engine's verdict payload for one video (the "result" event).
struct EngineResult: Decodable {
    let videoPath: String
    let nsfwScore: Double
    let classification: String
    let framesAnalyzed: Int
    let framesAboveThreshold: Int
    let dominantLabel: String?
    let frames: [EngineFrame]
    let provenance: EngineProvenance
}

struct EngineFrame: Decodable {
    let at: Double
    let score: Double
    /// Names this frame's cached embedding under `frames/<model>/`. Optional
    /// because records written before the cache existed have no hash, and an
    /// older engine may not send one.
    let hash: String?
}

struct EngineProvenance: Decodable {
    let embeddingModel: String
    let classifierModel: String
    let classifierVersion: String
    let samplingStrategy: String
    let aggregationStrategy: String
    let sampleIntervalS: Double
    let embeddingDim: Int
    let threshold: Double
    // Optional so older stored or streaming payloads still decode.
    let marginBias: Double?
    let temperature: Double?
}

/// A raw event line from the engine, kept as JSON so untyped accessors can
/// pull whatever a particular command needs without a decoder per command.
struct EngineEvent {
    let id: Int
    let kind: Kind
    let raw: [String: Any]

    enum Kind: String {
        case hello, status, result, error, done
    }

    func value(_ key: String) -> Any? { raw[key] }

    func payload<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }
}

enum EngineError: LocalizedError {
    case cancelled
    case engineDied
    case engineRejected(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "stopped"
        case .engineDied: return "the analysis engine stopped unexpectedly"
        case .engineRejected(let message): return message
        }
    }
}

/// Whether the AI is doing anything at all, readable from any thread.
///
/// A model installation or removal runs off the main actor, and it has to know
/// whether inference is under way before it touches the bytes a running pass
/// would load — but the engine is main-actor-isolated, so the answer cannot be
/// a main-actor property. Counted rather than flagged, because one run makes
/// many requests and its status callbacks nest inside them.
final class InferenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func begin() {
        lock.lock(); count += 1; lock.unlock()
    }

    /// Never below zero. A `defer` that runs twice, or a counter reset, must not
    /// leave this claiming work that is not there: a stuck counter would refuse
    /// every install from then on, which is worse than the crash it prevents.
    func end() {
        lock.lock(); count = max(0, count - 1); lock.unlock()
    }

    var isOn: Bool {
        lock.lock(); defer { lock.unlock() }; return count > 0
    }
}

/// The engine's reply routing, deliberately off the main actor: the pipe's
/// dispatch queue delivers events here under a lock, and continuations are
/// resumed outside it. The controller only registers requests and awaits.
private final class EngineMailbox {
    private struct Slot {
        var payload: EngineEvent?
        let onStatus: ((String) -> Void)?
        let continuation: CheckedContinuation<EngineEvent?, Error>
    }
    private var slots: [Int: Slot] = [:]
    private let lock = NSLock()

    /// Park a continuation where the reader will find it. Call before the
    /// request is written so a lightning-fast reply cannot be lost.
    func register(_ id: Int, onStatus: ((String) -> Void)?,
                  continuation: CheckedContinuation<EngineEvent?, Error>) {
        lock.lock()
        slots[id] = Slot(onStatus: onStatus, continuation: continuation)
        lock.unlock()
    }
    /// Undo register() when the write itself failed.
    func drop(_ id: Int) {
        lock.lock()
        slots[id] = nil
        lock.unlock()
    }

    /// Route one parsed event to the request waiting on it. Stray lines (a
    /// fire-and-forget cancel's done) are dropped.
    func deliver(_ event: EngineEvent) {
        lock.lock()
        guard let slot = slots[event.id] else {
            lock.unlock()
            return
        }
        switch event.kind {
        case .status:
            let stage = event.value("stage") as? String ?? ""
            let detail = event.value("detail") as? String ?? ""
            let text = stage.isEmpty ? detail
                       : (detail.isEmpty ? stage : "\(stage): \(detail)")
            lock.unlock()
            if !text.isEmpty, let onStatus = slot.onStatus {
                Task { @MainActor in onStatus(text) }
            }
        case .hello, .result, .error:
            slots[event.id]?.payload = event
            lock.unlock()
        case .done:
            slots[event.id] = nil
            lock.unlock()
            let ok = event.value("ok") as? Bool ?? false
            if ok {
                slot.continuation.resume(returning: slot.payload)
                return
            }
            let reason = event.value("reason") as? String
            if let message = slot.payload?.value("message") as? String {
                slot.continuation.resume(throwing: EngineError.engineRejected(message))
            } else if reason == "cancelled" {
                slot.continuation.resume(throwing: EngineError.cancelled)
            } else {
                slot.continuation.resume(
                    throwing: EngineError.engineRejected(reason ?? "the engine refused the request"))
            }
        }
    }

    /// The child is gone: every request still waiting gets engineDied.
    func flushSlots(_ error: Error) {
        lock.lock()
        let waiting = Array(slots.values)
        slots.removeAll()
        lock.unlock()
        for slot in waiting {
            slot.continuation.resume(throwing: error)
        }
    }
}

// MARK: - the controller

/// The engine's life from the app's point of view: where it is, what it is
/// doing, and who it is doing it to. One instance lives for the app's whole
/// run and is shared by every window that analyses.
///
/// The process is spawned lazily on the first run and then kept alive, so a
/// long queue never pays the model-loading cost more than once. The engine
/// exits on its own when this app dies (stdin closes), so there is no cleanup
/// to forget.
@MainActor
final class AnalysisEngine: ObservableObject {

    /// What the engine is doing right now, for the footer's one-line status.
    enum Phase: Equatable {
        case idle          // installed, warm, waiting for work
        case starting      // first spawn / handshake in progress
        case preparing     // loading (or first-run downloading) the model
        case working       // analysing videos
        case stopping      // a stop was asked for; draining the current video
        case broken(String) // something structural: no python, no torch, crash

        /// What to call this job in the interface. Never a bare "busy" — the
        /// user has to be able to see WHICH job is holding the engine.
        var title: String {
            switch self {
            case .idle: "Idle"
            case .starting: "Starting the engine"
            case .preparing: "Loading the model"
            case .working: "Classifying"
            case .stopping: "Stopping"
            case .broken: "Engine stopped"
            }
        }
    }

    /// Spawn the child (if needed) and load the model, then settle to idle —
    /// all without queueing a single video. The suggestion engine calls this
    /// at launch so its first mid-Analyse suggestion answers instantly
    /// instead of paying a cold model load while the user waits for chips.
    func warm() async {
        guard !isBusy else { return }
        if case .broken = phase { return }
        if CoreMLClassifier.mode == .coreml {
            // Warmth is a convenience, never a requirement — a failed warm
            // leaves the next Classify to report the real reason.
            if (try? await coreML.warm()) != nil { coreMLModelLoaded = true }
            return
        }
        do {
            try prepare()
            if !modelLoaded {
                phase = .preparing
                _ = try await request(["cmd": "ensure_model"])
                modelLoaded = true
                phase = .idle
            }
        } catch {
            // Warmth is a convenience, never a requirement: a failed warm
            // leaves the engine idle and a later real request retries it.
            if case .broken = phase { phase = .idle }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = ""       // stage/detail from events
    @Published private(set) var modelText = ""        // which model is loaded
    @Published private(set) var currentName: String?  // basename being analysed
    @Published private(set) var doneCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var totalCount = 0

    var isBusy: Bool {
        switch phase {
        case .starting, .preparing, .working, .stopping: return true
        case .idle, .broken: return false
        }
    }

    /// The AI's own answer to "are you working right now", readable from off the
    /// main actor, and the question a model installation asks before it replaces
    /// anything. Broader than `isBusy` on purpose: a suggestion pass never touches
    /// `phase` (it must not light up the Analysis window), and the in-process
    /// Core ML run answers without a child process at all — both load the very
    /// models an install is about to swap.
    nonisolated let inference = InferenceCounter()
    nonisolated var isInferring: Bool { inference.isOn }

    /// Asked before any engine command is sent, and before a run starts: the app
    /// injects "a model is being installed or removed right now".
    ///
    /// The other half of the rule. `ModelDownloader.isInferring` refuses to
    /// START a replacement under running work; this refuses to start work under
    /// a replacement, which is the half the installer cannot see — a pass that
    /// begins while a 165 MB bundle is midway through activation would load one
    /// file from each version.
    var isReplacingModels: () -> Bool = { false }

    /// One sentence for both refusals, so the two places that say it agree. Says
    /// what to do, because "try again later" is not a reason.
    static let replacingReason =
        "a model is being installed or removed — wait for that to finish, then try again"

    /// Test-only peek at the child's liveness, so integration harnesses can
    /// tell "engine wedged" from "engine gone".
    var debugIsRunning: Bool { process?.isRunning ?? false }
    /// Test-only peek at the child's stderr ring.
    var debugStderr: [String] { stderrTail }

    private var process: Process?
    private var outputPipe: Pipe?     // the child's stdout (we read events)
    private var inputPipe: Pipe?      // the child's stdin (we write requests)
    private let mailbox = EngineMailbox()
    private var nextRequestID = 1
    private var modelLoaded = false
    private var stopRequested = false
    private var stderrTail: [String] = []   // last lines, for broken-state text

    /// The in-process engine: the default one, and the only one a shipped build
    /// runs unless `~/.fvp-engine` asks for Python. Created lazily because it
    /// captures `Paths.support` at init, and a test or a redirected support dir
    /// must be able to move before anything loads.
    private lazy var coreML = CoreMLClassifier(root: Paths.support)
    private var coreMLModelLoaded = false

    /// Which engine this run uses. Read from the environment, once per call —
    /// a switch for the whole process, not something the UI toggles.
    nonisolated static var engineMode: CoreMLClassifier.Mode { CoreMLClassifier.mode }


    // MARK: - spawn & handshake

    /// The engine script, installed next to the app's other state files.
    nonisolated static var installedScript: String {
        (Paths.support as NSString).appendingPathComponent("engine/engine.py")
    }

    /// Where the child's stderr goes, so a silent "could not classify" is
    /// never silent twice: every spawn records its python + script + model
    /// home here, and the child's own output appends after it.
    nonisolated static var logPath: String {
        (Paths.support as NSString).appendingPathComponent("engine/engine.log")
    }

    /// The serial queue every log write goes through.
    ///
    /// Two threads log: the spawn header from the main actor, and the child's
    /// stderr from a detached utility task. Without a queue their
    /// check-rollover-open-append sequences interleave, and two writers that
    /// both miss the open take the create path and truncate each other. It
    /// also keeps file I/O off the stderr reader, which must never block: a
    /// reader that falls behind fills the 64 KB pipe buffer and the child
    /// stalls on its own stderr write — hanging the very model load this log
    /// exists to explain.
    nonisolated private static let logQueue = DispatchQueue(label: "fvp.engine.log", qos: .utility)

    /// The timestamp format for a log line. `ISO8601DateFormatter` is not
    /// Sendable, so it is marked unsafe rather than nonisolated: only
    /// `writeLog` touches it, and `writeLog` only ever runs on `logQueue`.
    nonisolated(unsafe) private static let logStamp = ISO8601DateFormatter()

    /// The last spawn header, re-emitted after a rollover so the log always
    /// says which python, script and model home produced the lines under it.
    nonisolated(unsafe) private static var lastSpawnHeader: String?

    /// Best-effort append to the engine log. Never throws and never blocks the
    /// caller: diagnostics must not be able to break — or slow — the engine
    /// path itself.
    nonisolated static func logEngine(_ line: String, isHeader: Bool = false) {
        logQueue.async {
            if isHeader { lastSpawnHeader = line }
            writeLog(line)
        }
    }

    /// The actual write. Only ever runs on `logQueue`.
    nonisolated private static func writeLog(_ line: String) {
        let entry = "[\(logStamp.string(from: Date()))] \(line)\n"
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Rollover keeps the tail, not nothing: a long model download can push
        // hundreds of KB of progress through here, and deleting the file would
        // throw away the spawn header — the one line worth reading. The header
        // is re-stated after the trim so it survives every rollover.
        if let size = try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int,
           size > 200_000,
           let data = try? Data(contentsOf: url) {
            var kept = Data("[log trimmed — earlier lines dropped]\n".utf8)
            if let header = lastSpawnHeader {
                kept.append(Data("[last spawn] \(header)\n".utf8))
            }
            kept.append(data.suffix(100_000))
            try? kept.write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // First write: create the file.
            try? entry.data(using: .utf8)?.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(entry.utf8))
    }

    nonisolated static var modelsDir: String {
        (Paths.support as NSString).appendingPathComponent("models")
    }

    /// Make sure the script is on disk (from the app bundle) and a python
    /// that can run it exists. Throws an explanation when the machine cannot
    /// run the engine, so the window can say why instead of guessing.
    private func prepare() throws {
        // In Core ML mode there is no child to prepare and no script to deploy.
        // Every remaining caller of this is a Python-only command — the face
        // family, which has no Swift port — and the capability probe already
        // reports those features unavailable, so refusing is the honest answer.
        // Without this guard `FaceStore`'s launch-time people query deployed
        // engine.py into a Core ML library and started python for nothing: the
        // rig's engine.log held one spawn line and not a single command
        // (2026-09-11). The throw is safe there — that call site is `try?` and
        // falls back to the people file on disk — and nothing on this path sets
        // the engine to `.broken`, so suggestions never suffer for it.
        guard CoreMLClassifier.mode == .python else {
            throw EngineError.engineRejected(
                "that still needs the Python engine — it has no Core ML version yet")
        }
        let scriptURL = URL(fileURLWithPath: Self.installedScript)
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            guard let bundled = Bundle.main.url(forResource: "engine",
                                                withExtension: "py") else {
                throw EngineError.engineRejected(
                    "the app bundle has no engine.py — rebuild with the Copy analysis engine phase")
            }
            try FileManager.default.copyItem(at: bundled, to: scriptURL)
        } else if let bundled = Bundle.main.url(forResource: "engine", withExtension: "py"),
                  let bundledDate = try? bundled.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  let diskDate = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  bundledDate > diskDate {
            // The bundle is the source of truth after every build: refresh the
            // installed copy so a newer engine never lingers unrun.
            try? FileManager.default.removeItem(at: scriptURL)
            try FileManager.default.copyItem(at: bundled, to: scriptURL)
        }

        // The engine needs a python that has torch + transformers. The base
        // anaconda install is the known-good one on this machine; anything
        // else is opt-in through the environment.
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["FVP_ENGINE_PYTHON"] {
            candidates.append(override)
        }
        // The same list AICapability probes. Two lists would mean the app can
        // report a feature ready and then fail to start the engine for it.
        candidates += AICapability.pythonCandidates
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw EngineError.engineRejected("no python3 found on this Mac")
        }

        if let proc = process, proc.isRunning { return }   // already warm

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = (Self.modelsDir as NSString).appendingPathComponent("hf")
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        // The child files a profile's own decisions — the heads it fits and the
        // people it has named — under this name. A different profile is a
        // different child (see `resetForProfile`).
        env["FVP_PROFILE"] = Paths.activeProfile
        proc.environment = env

        let input = Pipe()    // requests: app -> engine stdin
        let out = Pipe()      // events: engine stdout -> app
        let err = Pipe()
        proc.standardInput = input
        proc.standardOutput = out
        proc.standardError = err
        inputPipe = input
        outputPipe = out
        do {
            try proc.run()
        } catch {
            throw EngineError.engineRejected("could not start the engine: \(error.localizedDescription)")
        }
        process = proc
        // A fresh process has no model loaded yet; whoever spawned it must
        // re-ask for the model before its first analysis.
        modelLoaded = false
        // The profile is in the header on purpose: when heads or named people
        // look wrong, "which profile did this child read?" is the first question.
        Self.logEngine("spawn python=\(python) script=\(scriptURL.path) "
                       + "profile=\(Paths.activeProfile) hf=\(env["HF_HOME"] ?? "?")",
                       isHeader: true)
        readLoop(out: out, err: err, mailbox: mailbox)
    }

    private func readLoop(out: Pipe, err: Pipe, mailbox: EngineMailbox) {
        // readabilityHandler is the pipe API that does not wedge: AsyncBytes
        // .lines and pool-task reads both stalled on this pipe mid-stream.
        let handle = out.fileHandleForReading
        let buffer = LineBuffer()
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                mailbox.flushSlots(EngineError.engineDied)   // stdout closed: the child is gone
                return
            }
            buffer.data.append(chunk)
            while let nl = buffer.data.firstIndex(of: 0x0A) {
                let lineData = buffer.data.subdata(in: buffer.data.startIndex..<nl)
                buffer.data.removeSubrange(buffer.data.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8),
                      !line.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let kindRaw = json["type"] as? String,
                      let kind = EngineEvent.Kind(rawValue: kindRaw),
                      let id = json["id"] as? Int else { continue }
                if ProcessInfo.processInfo.environment["FVP_EVENT_DEBUG"] != nil {
                    FileHandle.standardError.write("[R] \(line)\n".data(using: .utf8)!)
                }
                mailbox.deliver(EngineEvent(id: id, kind: kind, raw: json))
            }
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                for try await line in err.fileHandleForReading.bytes.lines {
                    guard !line.isEmpty else { continue }
                    AnalysisEngine.logEngine(String(line.prefix(400)))
                    Task { @MainActor in
                        guard let self else { return }
                        // Keep a ring of the last lines: a long download's
                        // earlier progress must not crowd out the failure.
                        if self.stderrTail.count == 12 { self.stderrTail.removeFirst() }
                        self.stderrTail.append(String(line.prefix(240)))
                    }
                }
            } catch {
                // Pipe closed with the process; nothing to keep.
            }
        }
    }

    /// Set when the profile changed while the engine was mid-run: the child
    /// cannot be retired under an analysis already talking to it, so the reset
    /// waits for the run to finish.
    private var profileResetPending = false

    /// A different tag profile is in force.
    ///
    /// The Python child reads its profile from the environment at spawn, so it
    /// cannot be told about a switch: it is retired here and started again on
    /// the next command, under the new name. Without this, a profile's named
    /// people and fitted heads would keep being read from the first profile.
    /// The Core ML path holds no profile state of its own — every pass reads
    /// the heads from the profile in force as it runs — so it has nothing to do.
    func resetForProfile() {
        guard CoreMLClassifier.mode == .python else { return }
        guard !isBusy else { profileResetPending = true; return }
        retireChild()
    }

    private func retireChild() {
        profileResetPending = false
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        modelLoaded = false
    }

    /// Mutable byte accumulation across readability callbacks, captured by a
    /// @Sendable handler without tripping exclusivity diagnostics.
    private final class LineBuffer {
        var data = Data()
    }

    // MARK: - requests

    private func send(_ object: [String: Any]) throws {
        guard let proc = process, proc.isRunning,
              let pipe = inputPipe,
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw EngineError.engineDied
        }
        pipe.fileHandleForWriting.write(data + Data([0x0A]))
    }

    /// Send one request and suspend until its terminal done line. The slot is
    /// registered before the write so a lightning-fast reply cannot be lost.
    private func request(_ body: [String: Any],
                         onStatus: ((String) -> Void)? = nil) async throws -> EngineEvent? {
        // Nothing new starts while a model is being installed or removed. Every
        // command here loads or reads the installed models, and the window
        // between "the file exists" and "the file is the new one" is exactly
        // where a load gets half of each version.
        if isReplacingModels() { throw EngineError.engineRejected(Self.replacingReason) }
        let id = nextRequestID
        nextRequestID += 1
        // Counted for the whole wait, not just the write: an install asks
        // `isInferring` while this reply is outstanding, and the file it would
        // replace is the one this call is reading.
        inference.begin()
        defer { inference.end() }
        return try await withCheckedThrowingContinuation { continuation in
            mailbox.register(id, onStatus: onStatus, continuation: continuation)
            do {
                try send(["id": id].merging(body) { $1 })
            } catch {
                mailbox.drop(id)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - public flow

    /// Analyse every queued video in `paths`, reporting into the store.
    /// Videos that were settled (marked, finished, failed) while the run was
    /// in progress are skipped as they come up — a human's word stands in
    /// over the engine's schedule.
    func run(store: AnalysisStore, paths: [String]) async {
        guard !isBusy else { return }
        // A run is a long read of the installed models, in either mode, so it may
        // not begin while they are being replaced. The reason goes in
        // `statusText`, NOT in `phase`: `.broken` is sticky — `suggestTags`
        // refuses every pass while it stands — so a transient install would
        // quietly turn tag suggestions off until the user found Retry. The
        // refusals the user actually meets are the ones that can say so:
        // `AppModel.classify` reports this in the Analysis window, and the
        // automatic passes stand down without spending their one attempt.
        guard !isReplacingModels() else {
            statusText = Self.replacingReason
            return
        }
        if CoreMLClassifier.mode == .coreml {
            await runCoreML(store: store, paths: paths)
            return
        }
        let context = store.contextID
        let profile = Paths.activeProfile
        func canWrite() -> Bool {
            !stopRequested && !Task.isCancelled && context == store.contextID && profile == Paths.activeProfile
        }
        stopRequested = false
        failedCount = 0
        doneCount = 0
        totalCount = 0
        phase = .starting
        statusText = "starting engine"
        defer {
            if case .broken = phase {
                // keep the diagnostic; only the text resets
                statusText = ""
            } else {
                phase = .idle
                statusText = ""
            }
            currentName = nil
            // A profile switch that arrived mid-run could not swap the child
            // out from under an analysis that was already talking to it.
            if profileResetPending { retireChild() }
        }

        do {
            try prepare()
        } catch {
            phase = .broken(brokenText(error))
            return
        }

        // Rescuing stale analysing rows is a run's first duty: any row left
        // in flight by a quit or a stop belongs back in the queue.
        store.rescueStaleAnalyses()
        let todo = paths.filter { store.analysis(for: $0)?.phase == .queued }

        do {
            if !modelLoaded {
                phase = .preparing
                statusText = "first run — loading the CLIP model (downloads ~1.7 GB once)"
                _ = try await request(["cmd": "ensure_model"]) { [weak self] text in
                    self?.statusText = text
                }
                modelLoaded = true
            }

            guard !todo.isEmpty, !stopRequested else { return }
            phase = .working
            totalCount = todo.count
            for path in todo {
                if !canWrite() { break }
                guard store.analysis(for: path)?.phase == .queued else { continue }
                currentName = (path as NSString).lastPathComponent
                guard let source = SourceRevision.of(path) else {
                    store.fail(path)
                    failedCount += 1
                    continue
                }
                store.begin(path)
                do {
                    let event = try await request(["cmd": "analyse", "path": path]) { [weak self] text in
                        self?.statusText = text
                    }
                    guard canWrite() else { break }
                    if let event, event.kind == .result,
                       let result = event.payload(EngineResult.self) {
                        if store.finish(path, prediction: Self.prediction(from: result),
                                        frames: Self.frames(from: result), expectedRevision: source) {
                            doneCount += 1
                        } else {
                            store.fail(path)
                            failedCount += 1
                        }
                    } else {
                        store.fail(path)   // done without a verdict: a refusal
                        failedCount += 1
                    }
                } catch EngineError.cancelled {
                    break   // user stopped; the in-flight row is rescued next run
                } catch {
                    if !canWrite() { break }
                    store.fail(path)
                    failedCount += 1
                }
            }
        } catch {
            // A stop can surface here as engineDied (the child was killed
            // mid-load); that is not a broken engine, just an interrupted
            // one, so the diagnostic stays quiet.
            if !stopRequested {
                phase = .broken(brokenText(error))
            }
        }
    }

    /// Classify without Python, ffmpeg or a child process.
    ///
    /// Deliberately the same shape as the Python loop above: same counters,
    /// same phases, same three store calls, same stop contract — the queue and
    /// the Analysis window cannot tell which engine answered them.
    ///
    /// `prepare()` and the `ensure_model` request are absent because they exist
    /// to install and spawn a Python child, which is the thing this path
    /// removes. `rescueStaleAnalyses()` is emphatically NOT absent: a row left
    /// in flight by a quit belongs back in the queue, whichever engine runs.
    ///
    /// A video that fails here fails alone: `store.fail` marks it and the loop
    /// carries on, exactly as the engine's refusals do.
    private func runCoreML(store: AnalysisStore, paths: [String]) async {
        let context = store.contextID
        let profile = Paths.activeProfile
        func canWrite() -> Bool {
            !stopRequested && !Task.isCancelled && context == store.contextID && profile == Paths.activeProfile
        }
        stopRequested = false
        failedCount = 0
        doneCount = 0
        totalCount = 0
        phase = .starting
        statusText = "starting the Core ML engine"
        // Counted for the whole run, not just its requests: this path loads the
        // towers in-process and decodes frames between them, and an install
        // asking `isInferring` must see that as work in progress.
        inference.begin()
        defer {
            inference.end()
            // A broken state is a diagnostic the window shows: leave it in
            // place, exactly as the Python path does, or the reason the run
            // could not start is erased the moment it is reported.
            if case .broken = phase {
                statusText = ""
            } else {
                phase = .idle
                statusText = ""
            }
            currentName = nil
        }

        store.rescueStaleAnalyses()
        let todo = paths.filter { store.analysis(for: $0)?.phase == .queued }

        do {
            if !coreMLModelLoaded {
                phase = .preparing
                statusText = "loading the vision model"
                try await coreML.warm()
                coreMLModelLoaded = true
            }
            guard !todo.isEmpty, !stopRequested else { return }

            phase = .working
            totalCount = todo.count
            for path in todo {
                if !canWrite() { break }
                guard store.analysis(for: path)?.phase == .queued else { continue }
                currentName = (path as NSString).lastPathComponent
                statusText = "scoring with Core ML (Falconsai)"
                guard let source = SourceRevision.of(path) else {
                    store.fail(path)
                    failedCount += 1
                    continue
                }
                store.begin(path)
                do {
                    let verdict = try await coreML.analyse(path: path)
                    guard canWrite() else { break }
                    if store.finish(path, prediction: verdict.prediction,
                                    frames: verdict.frames, expectedRevision: source) {
                        doneCount += 1
                    } else {
                        store.fail(path)
                        failedCount += 1
                    }
                } catch is CancellationError {
                    break   // the in-flight row is rescued on the next run
                } catch {
                    if !canWrite() { break }
                    store.fail(path)
                    failedCount += 1
                }
            }
        } catch {
            if !stopRequested {
                phase = .broken(brokenText(error))
            }
        }
    }

    /// Ask the engine to stop: after the current video when one is running
    /// (the engine checks between units and kills ffmpeg), or right now when
    /// it is still loading the model — a first-run download cannot be
    /// interrupted from inside the child (its main thread is blocked in the
    /// synchronous load), so the child is terminated and respawns next run,
    /// resuming the partially-downloaded model.
    func stop() {
        if CoreMLClassifier.mode == .coreml {
            // No child to signal: the loop checks between videos, so the
            // in-flight verdict lands (it is sub-second) and the queue stops.
            guard isBusy else { return }
            stopRequested = true
            phase = .stopping
            statusText = "stopping…"
            return
        }
        guard isBusy, let proc = process, proc.isRunning else { return }
        stopRequested = true
        if case .preparing = phase {
            proc.terminate()
            modelLoaded = false
            phase = .idle
            statusText = "stopped during model load — the next Analyse resumes it"
            return
        }
        phase = .stopping
        statusText = "stopping…"
        // Fire and forget: the in-flight drain sees the cancelled done.
        try? send(["id": nextRequestID, "cmd": "cancel"])
        nextRequestID += 1
    }

    /// After a broken state, clear the diagnostic so the next Analyse press
    /// tries again from scratch — the fix (python install, model download,
    /// a permissions change) usually happens outside the app.
    func retry() {
        guard case .broken = phase else { return }
        stderrTail = []
        stopRequested = false
        phase = .idle
    }

    // MARK: - tag suggestions

    /// Serialises suggestion requests.
    ///
    /// `isBusy` is derived from `phase`, and suggestions deliberately never
    /// touch `phase` (that drives the Analysis window's progress UI, and a
    /// background suggestion is not a run the user started). So `isBusy` alone
    /// cannot keep two suggestions apart: skipping quickly between videos fires
    /// two requests, the engine's own single-worker flag refuses the second
    /// with "engine busy", and that video silently never gets suggestions —
    /// measured against the real engine, not theorised.
    ///
    /// A plain FIFO gate rather than chained Tasks: chaining a Task onto its
    /// predecessor only tracks when the PREDECESSOR finished, not when this
    /// request's own work does, so it serialises nothing. This holds the
    /// engine's one-job-at-a-time contract and loses no request.
    private var suggestionBusy = false
    private var suggestionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Take the suggestion slot, waiting in line if it is taken.
    private func acquireSuggestionSlot() async {
        if !suggestionBusy {
            suggestionBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            suggestionWaiters.append(continuation)
        }
    }

    /// Hand the slot to whoever is next, or leave it free.
    private func releaseSuggestionSlot() {
        if suggestionWaiters.isEmpty {
            suggestionBusy = false
        } else {
            suggestionWaiters.removeFirst().resume()
        }
    }

    /// Ask the engine which tags might suit one video.
    ///
    /// Quiet by design — this runs while the user is watching something, so it
    /// must never touch `phase` or `statusText`. It also yields to a real
    /// analysis run: `isBusy` means the engine has a queue to work through, and
    /// a suggestion can wait for the next play.
    ///
    /// `paired` tells the engine the video has been filed NSFW, which adds
    /// the paired tags (PAIRED_VOCAB) to the prompt pool —
    /// safe videos are never asked which way they lean.
    ///
    /// `libraryTags` gives the engine your own tag vocabulary as frame-hash
    /// prototypes ({tag: {videoKey: [hashes]}}), so tags CLIP's phrases have
    /// never heard of (Kite, Bench, Confetti…) can still be suggested — and, just as
    /// importantly, rejected — on look-alike videos. Built by the caller from
    /// the tag library + analysis store; tags the video already carries are
    /// excluded so the engine never offers what is already applied.
    ///
    /// Returns nil when the engine is unavailable or produced nothing usable;
    /// callers treat that as "no advice", never as an error worth showing.
    /// The model id a suggestion recorded right now would carry, for deciding
    /// whether a stored suggestion is still current.
    ///
    /// Nil on the Python path, where the id arrives in the engine's own reply
    /// and cannot be known before the run. `SuggestionStore.hasSuggestions`
    /// reads nil as "do not compare models", so a video suggested there is
    /// still treated as visited — it just is not re-asked when the model
    /// changes underneath it.
    var suggestionModelID: String? {
        CoreMLClassifier.mode == .coreml ? CoreMLClassifier.modelID : nil
    }

    func suggestTags(for path: String, paired: Bool = false,
                     faces: Bool = true,
                     libraryTags: [String: [String: [String]]] = [:],
                     neighbours: NeighbourPrior = NeighbourPrior()) async
        -> (tags: [TagSuggestion], model: String?, framesSeen: Int?, facesDetected: Int?, faceHashes: [String])? {
        // Neither path below is safe while the models are being replaced — the
        // Core ML one loads them in this process, the Python one asks a child to
        // — so the pass is simply not run. Callers that spend a "once per video"
        // attempt check this before they spend it, so the video is asked again
        // rather than going without for the rest of the launch.
        if isReplacingModels() { return nil }
        await acquireSuggestionSlot()
        defer { releaseSuggestionSlot() }

        // Checked AFTER the wait: a full analysis may have started while this
        // request sat in the queue, and that outranks a background suggestion.
        guard !isBusy else { return nil }
        if case .broken = phase { return nil }
        // And again after the wait, for the same reason: a model operation can
        // begin while this request sits in the queue.
        if isReplacingModels() { return nil }
        // Counted around the work so an install sees the quiet pass as work in
        // progress too — it never touches `phase`, so it is invisible to
        // `isBusy` and that is exactly how a swap ends up under a live pass.
        inference.begin()
        defer { inference.end() }

        // In Core ML mode — the default — the answer comes from the model in
        // this process. The code below deploys engine.py and spawns Python,
        // which is precisely what that mode exists to stop doing.
        if CoreMLClassifier.mode == .coreml {
            return await suggestTagsCoreML(for: path, paired: paired,
                                           faces: faces, libraryTags: libraryTags,
                                           neighbours: neighbours)
        }

        do {
            try prepare()
            var body: [String: Any] = ["cmd": "suggest_tags", "path": path,
                                       "paired": paired,
                                       "faces": faces]
            if !libraryTags.isEmpty { body["libraryTags"] = libraryTags }
            let event = try await request(body)
            guard let event else { return nil }

            guard let raw = event.value("suggestions") as? [[String: Any]] else { return nil }
            let tags: [TagSuggestion] = raw.compactMap { item in
                guard let tag = item["tag"] as? String,
                      let confidence = item["confidence"] as? Double,
                      let frames = item["frames"] as? Int else { return nil }
                return TagSuggestion(tag: tag, confidence: confidence,
                                     frames: frames, source: item["source"] as? String)
            }
            return (tags,
                    event.value("model") as? String,
                    event.value("frames_seen") as? Int,
                    event.value("faces_detected") as? Int,
                    event.value("faces") as? [String] ?? [])
        } catch {
            // Suggestions are a convenience. A failure here is logged by the
            // engine itself and must not surface as an alert mid-playback.
            return nil
        }
    }

    /// The evidence behind a suggestion — "why did you suggest this?".
    ///
    /// Core ML answers it from the cached vectors, in-process. The Python engine
    /// has no equivalent command yet, so this returns nil there and the panel
    /// says which engine can explain it rather than showing an empty box. (A
    /// feature that silently does nothing is the thing this app keeps having to
    /// fix; see the `guard ... else { return }` pitfall.)
    func explainSuggestion(tag: String, source: String, path: String,
                           learnedFrom: [String] = [],
                           person: String? = nil) async -> SuggestionExplanation? {
        guard CoreMLClassifier.mode == .coreml else { return nil }
        return try? await coreML.explain(tag: tag, source: source, path: path,
                                         learnedFrom: learnedFrom, person: person)
    }

    /// The material for timed evidence: the frames each offered tag agreed with,
    /// from the same pass and the same rule that offered it.
    ///
    /// Nil (not empty) when the in-process path is not in force — the same
    /// condition as `explainSuggestion`, because there is no honest answer when
    /// the app did not see the video this way.
    func tagSightings(for path: String, tags: [TagSuggestion]) async -> EvidenceProposal.TagSightings? {
        guard CoreMLClassifier.mode == .coreml else { return nil }
        return try? await coreML.sightings(path: path, tags: tags)
    }

    /// The identity of the space the tag pass scores in, as an evidence row
    /// records it. Read fresh rather than cached: a pack switch has to move this
    /// with it, and a cached identity is exactly how stale evidence would go on
    /// claiming to be about vectors that no longer exist.
    var tagsSpace: ModelSpace? { ModelSpace.read(root: Paths.support) }

    /// The same suggestion request, answered in-process.
    ///
    /// ALL FOUR sources now, faces included. Until Phase 6.2–6.4 this returned
    /// nil for `facesDetected` and empty for `faceHashes`, because identity had
    /// no Core ML path — which meant a Core ML build could never offer a person's
    /// name, the one thing face recognition exists for. The face pass now runs
    /// over the same frames CLIP was given, against the registry, and returns
    /// `source: "face"` candidates like the Python path does.
    ///
    /// `faces: false` (the Tags > Face Recognition switch) is passed THROUGH to
    /// the classifier rather than applied here, so a switched-off pass stores
    /// nothing at all.
    ///
    /// `libraryTags` arrives in the engine's own shape
    /// ({tag: {videoKey: [frameHash]}}), which is the shape the prototypes want;
    /// only the vectors behind those hashes differ, and they are read out of the
    /// Core ML cache.
    private func suggestTagsCoreML(for path: String, paired: Bool, faces: Bool,
                                   libraryTags: [String: [String: [String]]],
                                   neighbours: NeighbourPrior) async
        -> (tags: [TagSuggestion], model: String?, framesSeen: Int?,
            facesDetected: Int?, faceHashes: [String])? {
        do {
            let answer = try await coreML.suggest(
                path: path, paired: paired,
                tagged: TagPrototypes.taggedVideos(libraryTags), faces: faces,
                neighbours: neighbours)
            let tags = answer.candidates.map {
                TagSuggestion(tag: $0.tag, confidence: $0.confidence,
                              frames: $0.frames, source: $0.source)
            }
            return (tags, CoreMLClassifier.modelID, answer.framesSeen,
                    answer.facesDetected, answer.faceHashes)
        } catch {
            // Suggestions are a convenience. A failure here is not an alert
            // mid-playback, exactly as on the Python path.
            return nil
        }
    }

    /// Bind a video's detected faces to a person name (the "name this person
    /// once" step). From then on, any video whose faces match those vectors
    /// suggests the name. Returns the number of new face crops bound, or
    /// throws when the engine cannot run (busy / dead / no faces / no model).
    func nameFace(_ name: String, on path: String) async throws -> Int {
        guard !isBusy else { throw EngineError.engineRejected("the engine is busy") }
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "name_face", "name": name, "path": path,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        return event.value("bound") as? Int ?? 0
    }

    /// Detect + persist faces across a batch of existing videos. Returns
    /// {absolutePath: [faceHash]} so the app can build its face→video index.
    func faceIndex(paths: [String], onStatus: ((String) -> Void)? = nil) async throws -> [String: [String]] {
        guard !isBusy else { throw EngineError.engineRejected("the engine is busy") }
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "face_index", "paths": paths,
        ], onStatus: onStatus) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        guard let raw = event.value("videos") as? [String: [String]] else { return [:] }
        return raw
    }

    /// Cancel an in-flight face index. Face indexing deliberately does not
    /// touch `phase` (that drives the Analyse progress UI), so the ordinary
    /// `stop()` — which guards on `isBusy`/`phase` — would not fire. This
    /// sends the engine's `cancel` directly; the index thread checks it
    /// between videos and releases the busy slot.
    func cancelFaceIndex() {
        try? send(["id": nextRequestID, "cmd": "cancel"])
        nextRequestID += 1
    }

    /// Every unnamed identity cluster the face engine found, biggest first.
    func faceClusters() async throws -> [FaceCluster] {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request(["cmd": "face_clusters"]) else {
            throw EngineError.engineDied
        }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        guard let raw = event.value("clusters") as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let rep = item["representative"] as? String,
                  let faces = item["faces"] as? Int,
                  let hashes = item["hashes"] as? [String] else { return nil }
            return FaceCluster(representative: rep, faces: faces, hashes: hashes)
        }
    }

    /// Named people and their face counts.
    func facePeople() async throws -> [FacePerson] {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request(["cmd": "face_people"]) else {
            throw EngineError.engineDied
        }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        guard let raw = event.value("people") as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let name = item["name"] as? String,
                  let faces = item["faces"] as? Int else { return nil }
            return FacePerson(name: name, faces: faces,
                              representative: item["representative"] as? String)
        }
    }

    /// Bind a whole identity cluster to a name (merge, never replace).
    func nameCluster(_ name: String, hashes: [String]) async throws {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "name_cluster", "name": name, "hashes": hashes,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
    }

    /// Faces the system has seen that look most like a person, best match
    /// first — straight from the cached vectors, no video re-decoding.
    func similarFaces(_ name: String) async throws -> [String] {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "similar_faces", "name": name,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        return (event.value("faces") as? [String]) ?? []
    }

    /// Make an existing cached face a person's representative thumbnail.
    func setRepresentative(_ name: String, hash: String) async throws {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "set_representative", "name": name, "hash": hash,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
    }

    /// Give a person a portrait photo as their representative thumbnail.
    /// The engine detects the biggest face in the image and makes it the
    /// person's thumbnail; returns the face hash when a face was found.
    func setPhoto(_ name: String, path: String) async throws -> String? {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "set_photo", "name": name, "path": path,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        return event.value("photo") as? String
    }

    /// Forget a person: drop their name→face binding from the registry. The
    /// face vectors and thumbnails stay, so the same face can later be bound
    /// to the right person.
    func forgetPerson(_ name: String) async throws {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "forget_person", "name": name,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
    }

    /// 'Add a person' step 1: the biggest faces (by pixel area) in one video
    /// or image, so the user can pick which face to add. Capped at 5 by the
    /// engine (FACE_MAX_CHOICES) so a crowd scene can't overwhelm the chooser.
    func detectFaces(path: String) async throws -> [String] {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "detect_faces", "path": path,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        return event.value("faces") as? [String] ?? []
    }

    /// 'Add a person' step 2: scan the analysed library for one named person.
    /// Returns the absolute paths of every video where that face appears.
    func scanPerson(name: String, paths: [String],
                    onStatus: ((String) -> Void)? = nil) async throws -> [String] {
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "scan_person", "name": name, "paths": paths,
        ], onStatus: onStatus) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        return event.value("matched") as? [String] ?? []
    }

    /// Cancel an in-flight face scan (scan_person). Same rationale as
    /// `cancelFaceIndex` — the scan does not touch `phase`.
    func cancelScan() {
        try? send(["id": nextRequestID, "cmd": "cancel"])
        nextRequestID += 1
    }

    // MARK: - training (Phase D: learn from your tags)

    /// Ask the engine to rank the analysed library against one user tag.
    ///
    /// The tag-review playlist calls this when its AI toggle is on: which
    /// videos, anywhere in the library, look like the ones already carrying
    /// this tag? Pure cache reads on the engine side (no ffmpeg, no model),
    /// so it returns in ~2 s even over the whole library and does not care
    /// whether an Analyse run is in flight.
    func tagCandidates(tag: String,
                       tagged: [String: [String]],
                       pool: [String: [String]],
                       limit: Int = 25) async throws
        -> (candidates: [(key: String, score: Double)], unseen: Int,
            unseenKeys: [String], reason: String?) {
        // Core ML answers this one itself, out of `LookAlikes.rank` — the port
        // that was written and gated in Phase 3 but never wired to the button,
        // so the search went on refusing with "still needs the Python engine"
        // long after the maths existed in-process. No child process, no model
        // load. The Python path below stays for `mode=python`, which is what a
        // library still in the old embedding space has to use.
        if CoreMLClassifier.mode == .coreml {
            // OFF the main actor, deliberately. `LookAlikes.rank` reads every
            // cached frame of every tagged and pooled video — 593 tagged + 434
            // pooled here, ~6,000 small file reads — and measured on the live
            // store that is **576 ms** of blocked main thread, which is a frozen
            // window every time the AI toggle is pressed. `tagCandidates` is
            // `nonisolated` precisely so a cache read need not queue behind an
            // analyse, so it can be moved; the actor reference is captured first
            // (on the main actor) because the engine's own property is not.
            let classifier = coreML
            let result = await Task.detached(priority: .userInitiated) {
                classifier.tagCandidates(tag: tag, tagged: tagged, pool: pool, limit: limit)
            }.value
            return (result.candidates.map { (key: $0.key, score: $0.score) },
                    result.unseenPool, result.unseen, result.reason)
        }
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request(["cmd": "tag_candidates",
                                             "tag": tag, "tagged": tagged,
                                             "pool": pool, "limit": limit]) else {
            throw EngineError.engineDied
        }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        let raw = (event.value("candidates") as? [[String: Any]]) ?? []
        let candidates = raw.compactMap { item -> (key: String, score: Double)? in
            guard let key = item["key"] as? String,
                  let score = item["score"] as? Double else { return nil }
            return (key, score)
        }
        return (candidates,
                (event.value("unseen_pool") as? Int) ?? 0,
                // engine.py reports the count and nothing else, so under the
                // Python engine the widening set can only be the records this
                // side can see for itself. Named, not silently equal to the
                // count: an empty list here means "this engine cannot say
                // which ones", never "there are none".
                [],
                event.value("reason") as? String)
    }

    /// Fit one head per tag from the labels the user has already given.
    ///
    /// Sends {tag: {videoKey: true|false}} plus each video's stored frame
    /// hashes; the engine reads the cached embeddings and never re-embeds, so
    /// a fit is seconds even over a big library. Returns the per-tag fits for
    /// display, or throws when the engine cannot run one.
    struct TrainedHeadFit {
        let tag: String
        let fitted: Bool
        let reason: String?
        let videos: Int?
        let heldOut: Int?
        let precision: Double?
        let recall: Double?
    }

    func trainHeads(labels: [String: [String: Bool]],
                    frameHashes: [String: [String]]) async throws -> [TrainedHeadFit] {
        guard !isBusy else { throw EngineError.engineRejected("the engine is busy") }
        // Core ML fits these itself, out of the embedding cache. The port has
        // been in the repo and gated since Phase 4 (run_logistic_head.sh); only
        // the button was never wired to it, so Train went on refusing with
        // "still needs the Python engine" long after the maths ran in-process.
        // No child process, no model load — and the heads merge into the same
        // file the classifier reads back.
        if CoreMLClassifier.mode == .coreml {
            return try coreML.trainHeads(labels: labels, frameHashes: frameHashes)
                .map(Self.trainedHeadFit)
        }
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "train",
            "labels": labels,
            "frameHashes": frameHashes,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        guard let raw = event.value("fits") as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let tag = item["tag"] as? String else { return nil }
            return TrainedHeadFit(
                tag: tag,
                fitted: (item["fitted"] as? Bool) ?? false,
                reason: item["reason"] as? String,
                videos: item["videos"] as? Int,
                heldOut: item["held_out"] as? Int,
                precision: item["precision"] as? Double,
                recall: item["recall"] as? Double
            )
        }
    }

    /// A ported `HeadFit` wears the shape the two callers above already speak,
    /// so the Core ML path changes nothing anywhere above this point.
    private static func trainedHeadFit(_ fit: HeadFit) -> TrainedHeadFit {
        TrainedHeadFit(tag: fit.tag, fitted: fit.fitted, reason: fit.reason,
                       videos: fit.videos, heldOut: fit.heldOut,
                       precision: fit.precision, recall: fit.recall)
    }

    private static func nsfwFit(_ fit: HeadFit) -> NsfwCorrectionFit {
        NsfwCorrectionFit(fitted: fit.fitted, reason: fit.reason,
                          videos: fit.videos, heldOut: fit.heldOut,
                          precision: fit.precision, recall: fit.recall)
    }

    /// One Safe/NSFW correction-head fit result. Reuses the same fields as
    /// `TrainedHeadFit` but is a single head (no per-tag dimension), so it
    /// carries no `tag`.
    struct NsfwCorrectionFit {
        let fitted: Bool
        let reason: String?
        let videos: Int?
        let heldOut: Int?
        let precision: Double?
        let recall: Double?
    }

    /// Fit the Safe/NSFW correction head from the user's mark history. Labels
    /// are `{key: Bool}` (true = marked NSFW), frame hashes `{key: [hash]}` —
    /// the same cache-keyed shape `trainHeads` uses. Returns one fit, or throws
    /// when the engine cannot run one (busy / dead / rejected).
    func trainNsfw(labels: [String: Bool],
                   frameHashes: [String: [String]]) async throws -> NsfwCorrectionFit {
        guard !isBusy else { throw EngineError.engineRejected("the engine is busy") }
        // Same in-process fit as `trainHeads`, over the Safe/NSFW marks alone.
        if CoreMLClassifier.mode == .coreml {
            return Self.nsfwFit(try coreML.trainNsfw(labels: labels,
                                                    frameHashes: frameHashes))
        }
        if case .broken = phase { throw EngineError.engineDied }
        try prepare()
        guard let event = try await request([
            "cmd": "train_nsfw",
            "labels": labels,
            "frameHashes": frameHashes,
        ]) else { throw EngineError.engineDied }
        if let message = event.value("message") as? String {
            throw EngineError.engineRejected(message)
        }
        guard let raw = event.value("fit") as? [String: Any] else {
            return NsfwCorrectionFit(fitted: false, reason: "engine returned no fit",
                                     videos: nil, heldOut: nil, precision: nil, recall: nil)
        }
        return NsfwCorrectionFit(
            fitted: (raw["fitted"] as? Bool) ?? false,
            reason: raw["reason"] as? String,
            videos: raw["videos"] as? Int,
            heldOut: raw["held_out"] as? Int,
            precision: raw["precision"] as? Double,
            recall: raw["recall"] as? Double
        )
    }

    // MARK: - mapping engine results into the store

    static func prediction(from result: EngineResult) -> NsfwPrediction {
        let frameScores = result.frames.map(\.score)
        let mean = frameScores.isEmpty ? 0 : frameScores.reduce(0, +) / Double(frameScores.count)
        return NsfwPrediction(score: result.nsfwScore,
                              maxFrame: frameScores.max() ?? result.nsfwScore,
                              meanFrame: mean,
                              frames: result.framesAnalyzed,
                              framesAbove: result.framesAboveThreshold,
                              threshold: result.provenance.threshold,
                              aggregation: result.provenance.aggregationStrategy,
                              modelID: result.provenance.embeddingModel,
                              classifier: result.provenance.classifierModel,
                              classifiedAt: Date().timeIntervalSince1970)
    }

    /// The per-frame record to store.
    ///
    /// `hash` is the engine's content hash of the sampled frame, which names
    /// the cached embedding on disk — that is what lets a later pass (a new
    /// category, a retrained head, a retuned prompt set) reuse the vector
    /// instead of paying for the GPU again. Engines too old to send one fall
    /// back to the frame's position, which at least stays unique per video.
    static func frames(from result: EngineResult) -> [FrameScore] {
        result.frames.enumerated().map { index, frame in
            FrameScore(at: frame.at, score: frame.score,
                       hash: frame.hash ?? "f\(index)")
        }
    }

    private func brokenText(_ error: Error) -> String {
        var text = (error as? EngineError)?.errorDescription
            ?? error.localizedDescription
        if case .engineRejected(let message) = error as? EngineError {
            text = message
        }
        if !stderrTail.isEmpty {
            text += " — engine said: " + stderrTail.joined(separator: " ")
        }
        return String(text.prefix(500))
    }
}
