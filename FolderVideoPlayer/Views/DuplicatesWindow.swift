import AVKit
import AppKit
import SwiftUI

/// The duplicate finder.
///
/// A scan is a named set of folders, so the same sweep can be re-run without
/// picking them again. The results are sets of identical files, biggest
/// reclaim first, each with one copy chosen to survive — by rule, or by hand.
/// Nothing is ever deleted: copies go to the Trash, or, on a volume that has
/// none, to a folder you nominate.
struct DuplicatesWindow: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    var body: some View {
        if app.ready, let finder = app.duplicates {
            DuplicatesScreen(finder: finder)
        } else {
            Text("Starting…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DuplicatesScreen: View {
    @ObservedObject var finder: DuplicateFinder
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    @State private var selected: String?
    @State private var confirming = false
    @State private var preview: String?

    var body: some View {
        VStack(spacing: 0) {
            scanStrip
            Divider()
            controls
            Divider()
            results
            Divider()
            totals
        }
        .onAppear { finder.refresh() }
        .background {
            // Space bar previews the selected copy, Quick Look style.
            Button("") { if let key = selected { preview = Paths.tagPath(key) } }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
        .sheet(item: Binding(
            get: { preview.map { PreviewTarget(path: $0) } },
            set: { preview = $0?.path }
        )) { target in
            PreviewSheet(path: target.path) { preview = nil }
        }
        .confirmationDialog("Discard \(finder.doomedCount) copies?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            The copy marked Keep in each set stays where it is. The rest go to \
            the Trash, or to the folder you nominate on a volume that has none. \
            Their tags are carried over to the copy being kept first.

            Nothing is deleted.
            """)
        }
    }

    // MARK: - the scan

    /// Choosing a scan and saying which folders it covers.
    ///
    /// Without this the window was a dead end: Start Scan is disabled until a
    /// scan has folders, and there was no longer any way to give it any.
    private var scanStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Scan result:", selection: Binding(
                    get: { library.scanId ?? Library.autoScanId },
                    set: { library.scanId = $0; library.save(); finder.derive() }
                )) {
                    ForEach(library.scans) { scan in Text(scan.name).tag(scan.id) }
                }
                .frame(width: 260)

                Button("New…") { newScan() }
                Button("Rename…") { renameScan() }
                    .disabled(library.currentScan == nil || library.scanId == Library.autoScanId)
                Button("Delete") {
                    if let id = library.scanId { library.deleteScan(id); finder.derive() }
                }
                .disabled(library.currentScan == nil || library.scanId == Library.autoScanId)
                Spacer()
            }

            if let scan = library.currentScan {
                if scan.id == Library.autoScanId {
                    // The auto scan is fed by playback, not by folders, so it
                    // has nothing to add a folder to.
                    autoScanNote(scan)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(scan.folders, id: \.self) { folder in
                                HStack {
                                    Text(folder).font(.caption).lineLimit(1).truncationMode(.head)
                                    Button {
                                        remove(folder: folder, from: scan)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            if scan.folders.isEmpty {
                                Text("No folders yet — add one to scan.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("Add Folder…") { addFolder(to: scan) }
                            Text(summary(scan)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    /// The auto scan, and what it is.
    ///
    /// There is deliberately no switch here. Fingerprinting as videos play
    /// matched a moved-and-refound video against where it used to be and
    /// reported it as a copy of itself, so the feature is off and stays off.
    /// `Library.watchDupes` and `noticeWhilePlaying` are left intact for
    /// whenever that is fixed properly — this only takes the control away.
    private func autoScanNote(_ scan: DupeScan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Copies noticed during playback, from earlier runs.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(summary(scan)).font(.caption).foregroundStyle(.secondary)
            }
            Text("Nothing is added here any more. To look for copies, choose a "
                 + "folder scan above — and run Find Moved or Missing Files "
                 + "first, so a video that simply moved is not taken for a copy.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ scan: DupeScan) -> String {
        guard scan.ran > 0 else { return "Never run" }
        return "Ran \(whenWords(scan.ran)) — \(scan.seen.formatted()) videos, \(scan.groups) sets"
    }

    // MARK: - the controls

    private var controls: some View {
        HStack(spacing: 8) {
            if finder.scanning {
                Button("Stop") { finder.stopScan() }
                ProgressView().controlSize(.small)
            } else {
                Button("Start Scan") { finder.startScan() }
                    .disabled(library.scanFolders().isEmpty)
            }
            Toggle("Verify in full", isOn: $library.verifyDupes)
                .help("Read matching files end to end before offering to remove them")

            Divider().frame(height: 16)

            Menu("Keep…") {
                Button("Tagged Copy") { applied(.tags, "Tagged") }
                Button("Oldest Copy") { applied(.oldest, "Oldest") }
                Button("Shortest Path") { applied(.shortest, "Shortest Path") }
            }
            .frame(width: 90)
            .disabled(finder.groups.isEmpty)

            Spacer()

            TextField("Filter", text: $finder.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func applied(_ rule: DuplicateFinder.KeepRule, _ name: String) {
        let touched = finder.applyKeepRule(rule)
        if !finder.filter.isEmpty {
            app.say("\(name) applied",
                    "Applied to \(touched) of \(finder.groups.count) sets — those the filter shows.")
        }
    }

    // MARK: - the results

    private var results: some View {
        List(selection: $selected) {
            ForEach(Array(finder.filteredGroups.enumerated()), id: \.element.id) { number, group in
                Section {
                    ForEach(group.keys, id: \.self) { key in
                        row(group, key)
                            .tag(key)
                            .onTapGesture(count: 2) { preview = Paths.tagPath(key) }
                    }
                } header: {
                    HStack {
                        Text("Set \(number + 1) — \(humanBytes(group.size)) each, "
                             + "\(humanBytes(group.reclaim)) to reclaim")
                        if group.verified {
                            Image(systemName: "checkmark.seal")
                                .foregroundStyle(.green)
                                .help("Read end to end; these are byte for byte the same")
                        }
                        Spacer()
                    }
                    .font(.caption)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if finder.groups.isEmpty {
                ContentUnavailableView(
                    finder.scanning ? "Scanning…" : "No duplicates in the index",
                    systemImage: "square.on.square",
                    description: Text(finder.scanning
                                      ? finder.status
                                      : "Run a scan, or let the player fingerprint what you watch.")
                )
            }
        }
    }

    private func row(_ group: DupeGroup, _ key: String) -> some View {
        let path = Paths.tagPath(key)
        let isKeeper = group.keeper == key
        return HStack(spacing: 8) {
            Button {
                finder.setKeeper(group, key)
            } label: {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isKeeper ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Keep this copy and discard the rest of the set")

            Button {
                preview = path
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Preview this video")

            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if !library.tagsFor(path).isEmpty {
                Image(systemName: "tag.fill").font(.caption2).foregroundStyle(.secondary)
                    .help(library.tagsFor(path).joined(separator: ", "))
            }
            if isKeeper {
                Text(group.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .contextMenu {
            Button("Preview…") { preview = path }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Divider()
            Button("Take This Copy Out of the List") { finder.removeFromList([key]) }
        }
    }

    // MARK: - the totals

    private var totals: some View {
        HStack {
            Text(finder.status.isEmpty ? statusLine : finder.status)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Discard \(finder.doomedCount) Copies…") { confirming = true }
                .disabled(finder.doomedCount == 0 || finder.scanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        let sets = finder.filteredGroups.count
        guard sets > 0 else { return "Nothing to reclaim." }
        return "\(sets) sets — \(humanBytes(finder.reclaimable)) to reclaim"
    }

    private func discard() {
        let report = finder.discardDoomed(finder.filteredGroups)
        var detail = "\(report.moved) copies discarded, \(humanBytes(report.reclaimed)) reclaimed."
        if !report.failed.isEmpty {
            detail += "\n\n\(report.failed.count) could not be moved:\n"
                + report.failed.prefix(5).map { "\(($0.0 as NSString).lastPathComponent): \($0.1)" }
                    .joined(separator: "\n")
        }
        app.say("Done", detail)
    }

    // MARK: - editing scans

    private func newScan() {
        let folders = pickFolders(prompt: "Scan")
        guard !folders.isEmpty else { return }
        _ = library.addScan(folders: folders)
        finder.derive()
    }

    private func renameScan() {
        guard var scan = library.currentScan else { return }
        guard let name = ask("Rename scan", "What should this scan be called?", scan.name)
        else { return }
        scan.name = name
        library.updateScan(scan)
    }

    private func addFolder(to scan: DupeScan) {
        let folders = pickFolders(prompt: "Add")
        guard !folders.isEmpty else { return }
        var updated = scan
        for folder in folders where !updated.folders.contains(folder) {
            updated.folders.append(folder)
        }
        library.updateScan(updated)
        finder.derive()
    }

    private func remove(folder: String, from scan: DupeScan) {
        var updated = scan
        updated.folders.removeAll { $0 == folder }
        library.updateScan(updated)
        finder.derive()
    }

    private func pickFolders(prompt: String) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.path }
    }
}

/// A copy being looked at before its fate is decided — its own window and its
/// own player, because inspecting a file is not the same as watching it, and
/// loading it into the main player would lose your place in the playlist.
struct PreviewTarget: Identifiable {
    var path: String
    var id: String { path }
}

struct PreviewSheet: View {
    let path: String
    var done: () -> Void
    @State private var player = AVPlayer()
    @State private var info = ""

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(width: 640, height: 380)
            HStack {
                Text((path as NSString).lastPathComponent).lineLimit(1)
                Spacer()
                Button("Done") { player.pause(); done() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.top, .horizontal, .bottom], 10)
            HStack(spacing: 12) {
                Text(info).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding([.horizontal, .bottom], 10)
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
            player.play()
            loadInfo()
        }
        .onDisappear { player.pause() }
    }

    /// Resolution, duration, codec and size — loaded off the main thread.
    private func loadInfo() {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        Task {
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                var line = "\(Int(duration.seconds.rounded()))s · \(humanBytes(Int64(size)))"
                if let track = tracks.first {
                    let size2 = try await track.load(.naturalSize)
                    let desc = try? await track.load(.formatDescriptions)
                    let codec = desc?.first.flatMap { CMFormatDescriptionGetMediaSubType($0).fourCC() }
                    line = "\(Int(size2.width))×\(Int(size2.height)) · \(codec ?? "video") · "
                        + line
                }
                await MainActor.run { info = line }
            } catch {
                await MainActor.run { info = humanBytes(Int64(size)) }
            }
        }
    }
}

extension FourCharCode {
    /// e.g. 'avc1' → "H.264", 'hvc1'/'hev1' → "HEVC", 'vp09' → "VP9"
    func fourCC() -> String {
        switch self {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kCMVideoCodecType_MPEG2Video: return "MPEG-2"
        case kCMVideoCodecType_JPEG: return "Motion JPEG"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        default:
            let bytes = [
                UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
                UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF),
            ]
            return String(bytes: bytes, encoding: .ascii) ?? "video"
        }
    }
}

/// A one-line prompt, the way the AppKit build asked for a name.
@MainActor
func ask(_ title: String, _ detail: String, _ initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
    return typed.isEmpty ? nil : typed
}
