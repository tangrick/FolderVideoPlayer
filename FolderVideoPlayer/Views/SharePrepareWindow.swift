import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Prepare for Sharing: a new copy of one or more videos — smaller, or in a
/// container everything opens — optionally trimmed, optionally with the
/// transcript as subtitles beside it, optionally all in one ZIP.
///
/// The originals are only ever read. Each copy goes to a place the user picks,
/// is written under a hidden partial name and appears only when complete; a
/// cancelled or failed job leaves nothing that looks finished.
struct SharePrepareWindow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var journal: EvidenceJournal

    /// What the copy is made at. `asIs` puts the original bytes in a package
    /// untouched — only meaningful with a package, since a copy of a file that
    /// changes nothing is not worth making.
    enum Quality: Hashable {
        case asIs
        case preset(SharePreset)
    }

    enum Sidecar: String, CaseIterable, Identifiable {
        case none, srt, vtt
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "No subtitles"
            case .srt: return "SubRip (.srt) beside the video"
            case .vtt: return "WebVTT (.vtt) beside the video"
            }
        }
        var format: TranscriptExport.Format? {
            switch self {
            case .none: return nil
            case .srt: return .srt
            case .vtt: return .vtt
            }
        }
    }

    struct Result: Identifiable {
        let id = UUID()
        let name: String
        let output: String?
        let problem: String?
    }

    @State private var targets: [String] = []
    @State private var sources: [String: ShareSource] = [:]
    @State private var quality: Quality = .preset(.hd720)
    @State private var package = false
    @State private var sidecar: Sidecar = .none
    @State private var trimOn = false
    @State private var trimStart = "0:00.000"
    @State private var trimEnd = ""
    @State private var job: Task<Void, Never>?
    @State private var status = ""
    @State private var fraction: Double?
    @State private var results: [Result] = []
    @State private var hasFFmpeg = PlayableCopy.findTools() != nil

    private var running: Bool { job != nil }
    private var single: String? { targets.count == 1 ? targets[0] : nil }
    /// A hidden video's name stays out of sight while the hidden list is locked.
    private var hiddenAndLocked: Bool {
        !library.lock.isUnlocked && targets.contains { library.isHidden($0) }
    }
    private var transcribed: [String] { targets.filter { journal.transcribedPaths.contains($0) } }
    private var trim: ClosedRange<Double>? {
        guard trimOn, single != nil,
              let s = TranscriptDraft.parseTime(trimStart), let e = TranscriptDraft.parseTime(trimEnd),
              e > s else { return nil }
        return s...e
    }
    private var trimInvalid: Bool { trimOn && trim == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if targets.isEmpty || hiddenAndLocked {
                placeholder
            } else {
                Form {
                    Section { videoList }
                    Section("Quality") { qualityPicker }
                    if single != nil, quality != .asIs { Section("Range") { trimControls } }
                    Section("Extras") { extras }
                }
                .formStyle(.grouped)
                Divider()
                footer
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { adopt(app.shareTargets) }
        .onChange(of: app.shareTargets) { _, new in adopt(new) }
        .onChange(of: app.shareTrim) { _, _ in takeTrim() }
        .onDisappear { job?.cancel() }
    }

    // MARK: - pieces

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(hiddenAndLocked ? "These videos are hidden." : "Nothing to prepare.").font(.headline)
            Text(hiddenAndLocked ? "Unlock hidden videos to share them."
                 : "Right-click a video in the playlist and choose Prepare for Sharing…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(targets.count == 1 ? "1 video" : "\(targets.count) videos").font(.headline)
            ForEach(targets.prefix(6), id: \.self) { path in
                HStack {
                    Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let source = sources[path] {
                        Text(describe(source)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            if targets.count > 6 {
                Text("and \(targets.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
            Text("The originals are never changed. Each copy is a new file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Make", selection: $quality) {
                ForEach(SharePreset.allCases) { Text($0.title).tag(Quality.preset($0)) }
                if package { Text("Files as they are (no copy)").tag(Quality.asIs) }
            }
            .pickerStyle(.radioGroup)
            .disabled(running)
            Text(qualityDetail).font(.caption).foregroundStyle(.secondary)
            if let unavailable = unavailableReason {
                Label(unavailable, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Only part of the video", isOn: $trimOn).disabled(running)
            if trimOn {
                HStack {
                    TextField("From", text: $trimStart).frame(width: 100)
                    Text("to")
                    TextField("To", text: $trimEnd).frame(width: 100)
                    if let head = app.playback?.head, app.playback?.currentPath == single {
                        Button("From Playhead") { trimStart = TranscriptDraft.formatTime(head.position) }
                            .controlSize(.small)
                        Button("To Playhead") { trimEnd = TranscriptDraft.formatTime(head.position) }
                            .controlSize(.small)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(running)
                if trimInvalid {
                    Text("Type two times, the second after the first — like 0:10 and 1:25.5.")
                        .font(.caption).foregroundStyle(.red)
                } else if engineFor(single ?? "")?.isRemux == true {
                    Text("A copy without re-encoding starts at the nearest keyframe, which can be a moment early.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var extras: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Transcript", selection: $sidecar) {
                ForEach(Sidecar.allCases) { Text($0.title).tag($0) }
            }
            .disabled(running || transcribed.isEmpty)
            .help(transcribed.isEmpty ? "None of these videos has a transcript."
                  : "Writes the saved (corrected) transcript as a subtitle file named like the video.")
            if !transcribed.isEmpty, transcribed.count < targets.count, sidecar != .none {
                Text("\(transcribed.count) of \(targets.count) videos have a transcript; the others go without.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Put everything in one ZIP package", isOn: $package)
                .disabled(running)
                .onChange(of: package) { _, on in if !on, quality == .asIs { quality = .preset(.original) } }
            Text("A package is one file to send. It does not make videos smaller — they are already compressed — so choose a smaller quality for that.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if running || !status.isEmpty {
                HStack {
                    if running {
                        if let fraction { ProgressView(value: fraction).frame(maxWidth: 220) }
                        else { ProgressView().controlSize(.small) }
                    }
                    Text(status).font(.callout).lineLimit(2)
                }
            }
            if !results.isEmpty {
                ForEach(results) { result in
                    HStack(spacing: 6) {
                        Image(systemName: result.problem == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.problem == nil ? Color.green : Color.red)
                        Text(result.name).lineLimit(1).truncationMode(.middle)
                        if let problem = result.problem {
                            Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            HStack {
                if let estimate = totalEstimate {
                    Text("About \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) (estimate)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                let made = results.compactMap(\.output)
                if !made.isEmpty, !running {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(made.map { URL(fileURLWithPath: $0) })
                    }
                    Button("Share…") { SharePresenter.shared.share(made) }
                }
                if running {
                    Button("Cancel") { job?.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(package ? "Create Package…" : "Prepare…") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
            }
        }
        .padding(12)
    }

    // MARK: - reading

    /// A moment's Export Clip hands over a range: take it, once.
    private func takeTrim() {
        guard !running, let range = app.shareTrim, targets.count == 1 else { return }
        trimOn = true
        trimStart = TranscriptDraft.formatTime(range.lowerBound)
        trimEnd = TranscriptDraft.formatTime(range.upperBound)
        if quality == .asIs { quality = .preset(.original) }
        app.shareTrim = nil
    }

    private func adopt(_ new: [String]) {
        defer { takeTrim() }
        guard !running, new != targets else { return }
        targets = new
        sources = [:]
        results = []
        status = ""
        trimOn = false
        trimStart = "0:00.000"
        trimEnd = ""
        if quality == .asIs, !package { quality = .preset(.original) }
        hasFFmpeg = PlayableCopy.findTools() != nil
        let paths = new
        // Off the main thread: each is a file open, and on a share a round trip.
        Task {
            for path in paths {
                let source = await ShareExport.inspect(path)
                guard targets == paths else { return }
                sources[path] = source
                if path == paths.first, paths.count == 1, trimEnd.isEmpty, source.duration > 0 {
                    trimEnd = TranscriptDraft.formatTime(source.duration)
                }
            }
        }
    }

    private func describe(_ source: ShareSource) -> String {
        var parts: [String] = []
        if source.height > 0 { parts.append("\(source.height)p") }
        if let codec = source.codec { parts.append(codec.uppercased()) }
        if source.duration > 0 { parts.append(TranscriptPanel.clock(source.duration)) }
        parts.append(ByteCountFormatter.string(fromByteCount: source.bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func engineFor(_ path: String) -> ShareEngine? {
        guard case .preset(let preset) = quality, let source = sources[path] else { return nil }
        return SharePrep.engine(for: preset, source: source, hasFFmpeg: hasFFmpeg)
    }

    private var qualityDetail: String {
        switch quality {
        case .asIs:
            return "The original files go into the package unchanged."
        case .preset(let preset):
            guard let path = single, let engine = engineFor(path) else { return preset.detail }
            return preset.detail + " " + engine.summary
        }
    }

    private var unavailableReason: String? {
        let blocked = targets.filter { if case .unavailable = engineFor($0) { return true } else { return false } }
        guard !blocked.isEmpty else { return nil }
        if case .unavailable(let why)? = engineFor(blocked[0]) {
            return blocked.count == 1 ? why : "\(blocked.count) videos can't be converted here. " + why
        }
        return nil
    }

    private var totalEstimate: Int64? {
        let all: [Int64] = targets.compactMap { path in
            guard let source = sources[path] else { return nil }
            switch quality {
            case .asIs: return source.bytes
            case .preset(let preset):
                let engine = SharePrep.engine(for: preset, source: source, hasFFmpeg: hasFFmpeg)
                return SharePrep.estimatedBytes(engine: engine, preset: preset, source: source,
                                                trim: single == nil ? nil : trim)
            }
        }
        return all.isEmpty ? nil : all.reduce(0, +)
    }

    private var canStart: Bool {
        !targets.isEmpty && sources.count == targets.count && !trimInvalid
            && (quality == .asIs || unavailableReason == nil || targets.count > 1)
    }

    // MARK: - doing

    private func start() {
        // Where it goes: one file names itself in a save panel (which asks
        // before replacing); several go into a folder under names that never
        // collide with what is already there.
        var destinationFile: String?
        var destinationFolder: String?
        var replacing = false
        if package || single != nil {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            if package {
                panel.title = "Save Package"
                panel.nameFieldStringValue = single.map {
                    (($0 as NSString).lastPathComponent as NSString).deletingPathExtension + ".zip"
                } ?? "Shared Videos.zip"
                panel.allowedContentTypes = [.zip]
            } else if let single, case .preset(let preset) = quality {
                panel.title = "Save Copy"
                panel.nameFieldStringValue = SharePrep.suggestedName(for: single, preset: preset, trimmed: trim != nil)
                panel.allowedContentTypes = [.mpeg4Movie]
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinationFile = url.path
            replacing = FileManager.default.fileExists(atPath: url.path)
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose a Folder for the Copies"
            panel.prompt = "Choose"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinationFolder = url.path
        }

        results = []
        let targets = targets, sources = sources, quality = quality, sidecar = sidecar
        let package = package, trim = single == nil ? nil : trim, hasFFmpeg = hasFFmpeg
        job = Task {
            defer { job = nil; fraction = nil }
            let fm = FileManager.default
            // A package's contents are made in a scratch folder and removed once
            // zipped: the user asked for one file, not one file and its parts.
            let staging = package ? NSTemporaryDirectory() + "fvp-share-\(UUID().uuidString)" : nil
            if let staging { try? fm.createDirectory(atPath: staging, withIntermediateDirectories: true) }
            defer { if let staging { try? fm.removeItem(atPath: staging) } }
            let folder = staging ?? destinationFolder
                ?? ((destinationFile ?? "") as NSString).deletingLastPathComponent
            var packaged: [String] = []

            for (i, path) in targets.enumerated() {
                if Task.isCancelled { break }
                let name = (path as NSString).lastPathComponent
                status = targets.count > 1 ? "\(i + 1) of \(targets.count): \(name)" : "Preparing \(name)"
                fraction = nil
                var output: String
                switch quality {
                case .asIs:
                    packaged.append(path)
                    output = path
                case .preset(let preset):
                    guard let source = sources[path] else { continue }
                    let engine = SharePrep.engine(for: preset, source: source, hasFFmpeg: hasFFmpeg)
                    if !package, targets.count == 1, let destinationFile {
                        output = destinationFile
                    } else {
                        let wanted = SharePrep.suggestedName(for: path, preset: preset, trimmed: trim != nil)
                        output = (folder as NSString).appendingPathComponent(
                            SharePrep.uniqueName(wanted) { fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) })
                    }
                    do {
                        try await ShareExport.make(
                            source: path, output: output, preset: preset, engine: engine, trim: trim,
                            estimate: SharePrep.estimatedBytes(engine: engine, preset: preset, source: source, trim: trim),
                            replacing: replacing && output == destinationFile) { value in
                                Task { @MainActor in fraction = value }
                            }
                    } catch is CancellationError {
                        status = "Cancelled. Nothing unfinished was kept."
                        return
                    } catch {
                        results.append(Result(name: name, output: nil, problem: error.localizedDescription))
                        continue
                    }
                    if package { packaged.append(output) }
                    if !package { results.append(Result(name: (output as NSString).lastPathComponent, output: output, problem: nil)) }
                }
                // The corrected transcript, named like the copy, beside it.
                if let format = sidecar.format {
                    let lines = journal.transcript(for: path)
                    if !lines.isEmpty {
                        let base = ((output as NSString).lastPathComponent as NSString).deletingPathExtension
                        let subtitle = (folder as NSString).appendingPathComponent(
                            SharePrep.uniqueName(base + "." + format.fileExtension) {
                                fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) })
                        let body = TranscriptExport.render(trim.map { shifted(lines, into: $0) } ?? lines,
                                                           as: format, videoName: name)
                        if (try? body.write(toFile: subtitle, atomically: true, encoding: .utf8)) != nil {
                            if package {
                                packaged.append(subtitle)
                            } else {
                                results.append(Result(name: (subtitle as NSString).lastPathComponent,
                                                      output: subtitle, problem: nil))
                            }
                        }
                    }
                }
            }

            if Task.isCancelled {
                status = "Cancelled. Nothing unfinished was kept."
                return
            }
            if package, let destinationFile, !packaged.isEmpty {
                status = "Packaging \(packaged.count) files…"
                fraction = nil
                do {
                    try await ShareExport.zip(packaged, to: destinationFile, replacing: replacing)
                    results.append(Result(name: (destinationFile as NSString).lastPathComponent,
                                          output: destinationFile, problem: nil))
                } catch is CancellationError {
                    status = "Cancelled. Nothing unfinished was kept."
                    return
                } catch {
                    results.append(Result(name: "Package", output: nil, problem: error.localizedDescription))
                }
            }
            let done = results.filter { $0.problem == nil }.count
            let failed = results.count - done
            status = failed == 0 ? "Done." : "\(done) made, \(failed) could not be."
        }
    }

    /// A trimmed copy starts at zero, so its subtitles must too: lines inside
    /// the range, moved earlier by its start, clipped to its end.
    private func shifted(_ lines: [TranscriptLine], into range: ClosedRange<Double>) -> [TranscriptLine] {
        lines.compactMap { line in
            guard line.end > range.lowerBound, line.start < range.upperBound else { return nil }
            var moved = line
            moved.start = max(line.start, range.lowerBound) - range.lowerBound
            moved.end = min(line.end, range.upperBound) - range.lowerBound
            return moved
        }
    }
}
