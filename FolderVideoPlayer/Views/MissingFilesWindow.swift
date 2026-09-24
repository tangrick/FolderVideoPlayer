import AppKit
import SwiftUI

/// Find Missing Files — its own window, like Find Duplicates.
///
/// It used to be a strip at the top of the playlist panel: about 320 points
/// wide with a 220-point scroll box, so names and folders were cut off, and a
/// collapsed findings list could not be opened again without a new scan.
///
/// Every way in (Files ▾, a red row's right-click, a folder's right-click)
/// only aims the scan and opens this window; the scope is shown before
/// anything runs, and Search is the press that commits. The search runs in
/// the background — close the window and it carries on, open it again to see
/// where it got to. Nothing here is modal.
///
/// The findings come in three groups: what was repaired (listed, with an
/// Undo that really undoes), what needs a pick (one choice per video, with
/// size and date to choose by), and what was found nowhere (search another
/// folder for just those, or remove their references).
struct MissingFilesWindow: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    var body: some View {
        MissingFilesContent(scan: app.movedScan)
    }
}

private struct MissingFilesContent: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @ObservedObject var scan: MovedScan
    @State private var confirmRemoveAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            if scan.phase == .idle && !scan.hasFindings {
                idleExplainer
            } else {
                findings
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        // Repairs and removals move tags between paths; the open playlist may
        // still be drawing the old ones. Re-query it so the tags show now,
        // not after the user hops away and back.
        .onChange(of: scan.repaired) { _, _ in app.playback?.refreshAfterTagRepair() }
        .onChange(of: scan.removed) { _, _ in app.playback?.refreshAfterTagRepair() }
        .confirmationDialog("Remove \(scan.unmatched.count) missing video references?",
                            isPresented: $confirmRemoveAll) {
            Button("Remove \(scan.unmatched.count) References", role: .destructive) {
                scan.remove(scan.unmatched, library: library)
            }
        } message: {
            Text("Their tags are dropped from the library. The files themselves are already gone. Undo in Tag Profiles puts the tags back.")
        }
    }

    // MARK: - Header: what is checked, where it looks, Search

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scopeTitle)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("Search in:")
                    .foregroundStyle(.secondary)
                searchMenu
                    .disabled(scan.isRunning)
                Spacer()
                if scan.isRunning {
                    Button("Stop") { scan.cancel() }
                } else {
                    Button(scan.phase == .done ? "Search Again" : "Search") {
                        app.runMovedScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            progressLine
        }
    }

    /// What will be checked, in words — read from the scope the entry point set.
    private var scopeTitle: String {
        if let label = scan.scopeLabel {
            let count = scan.scopePaths?.count ?? 0
            return count == 1 ? "Checking “\(label)”"
                              : "Checking \(count) videos in “\(label)”"
        }
        if let root = scan.scopeRoot {
            return "Checking tagged videos in “\((root as NSString).lastPathComponent)”"
        }
        return "Checking every tagged video in the library"
    }

    /// Where to hunt: everywhere, one of the user's own folders, or any
    /// folder. Naming a folder is the difference between a walk of every share
    /// and a glance, so the folders already in the library are one click away.
    private var searchMenu: some View {
        Menu {
            Button("Everywhere") { scan.searchRoot = nil }
            let folders = quickFolders
            if !folders.isEmpty {
                Divider()
                ForEach(folders, id: \.self) { root in
                    Button((root as NSString).lastPathComponent) { scan.searchRoot = root }
                        .help(root)
                }
            }
            Divider()
            Button("Choose Folder…") { chooseSearchFolder() }
        } label: {
            if let root = scan.searchRoot {
                Label((root as NSString).lastPathComponent, systemImage: "folder")
            } else {
                Label("Everywhere", systemImage: "globe")
            }
        }
        .fixedSize()
        .help(scan.searchRoot ?? "Every mounted share — slow on a large NAS")
    }

    /// Pinned folders first, then recent ones, without repeats.
    private var quickFolders: [String] {
        var seen = Set<String>()
        return (library.pinned + library.recent).filter { seen.insert($0).inserted }
    }

    private func chooseSearchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search Here"
        panel.directoryURL = scan.searchRoot.map { URL(fileURLWithPath: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            scan.searchRoot = url.path
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        switch scan.phase {
        case .idle:
            EmptyView()
        case .checking(let done, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Checking \(done) of \(total)…")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .indexing(let files):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching… \(files.formatted()) files looked at")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .done:
            Label(doneSummary, systemImage: allClear ? "checkmark.circle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(allClear ? .green : .secondary)
        }
    }

    private var allClear: Bool {
        scan.candidates.isEmpty && scan.unmatched.isEmpty
    }

    private var doneSummary: String {
        var bits: [String] = []
        if let fixed = scan.repaired { bits.append("\(fixed) repaired") }
        if !scan.candidates.isEmpty { bits.append("\(scan.movedVideoCount) need a choice") }
        if !scan.unmatched.isEmpty { bits.append("\(scan.unmatched.count) not found") }
        if let gone = scan.removed { bits.append("\(gone) removed") }
        return bits.isEmpty ? "All \(scan.totalTagged) videos are where they should be."
                            : bits.joined(separator: " · ")
    }

    // MARK: - Before the first search

    private var idleExplainer: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Find tagged videos whose files have moved")
                .font(.title3.weight(.medium))
            Text("Each video's file is checked. One that has gone is looked for by name: a single match of the same size is repaired for you, several matches are offered for you to pick, and anything found nowhere is listed so you can remove its tags. Choosing a folder to search makes this much faster.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Findings

    private var findings: some View {
        List {
            if !scan.repairs.isEmpty {
                Section {
                    ForEach(scan.repairs) { repairRow($0) }
                } header: {
                    Text("Repaired (\(scan.repairs.count))")
                }
            }
            if !scan.candidates.isEmpty {
                Section {
                    ForEach(pendingKeys, id: \.self) { key in
                        choiceGroup(key)
                    }
                } header: {
                    Text("Needs Your Choice (\(scan.movedVideoCount))")
                } footer: {
                    Text("The same name was found in more than one place, or in one place with a different size. Pick where each video is now, then Apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !scan.unmatched.isEmpty {
                Section {
                    ForEach(scan.unmatched) { missingRow($0) }
                } header: {
                    Text("Not Found (\(scan.unmatched.count))")
                } footer: {
                    HStack {
                        Button("Search Another Folder for These…") { searchAgainForMissing() }
                        Spacer()
                        Button("Remove All…") { confirmRemoveAll = true }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    private func repairRow(_ fix: MovedRepair) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(fix.oldName)
                Text("\(fix.oldFolder)  →  \((fix.newPath as NSString).deletingLastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if fix.sizeMatches == nil {
                Text("Matched by name only")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("No size was recorded for this file, so only its name could be checked. Turn on Settings ▸ Library ▸ Fingerprint while playing to record sizes.")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fix.newPath)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    /// Missing videos awaiting a pick, in finding order, one entry each.
    private var pendingKeys: [String] {
        var seen = Set<String>()
        return scan.candidates.map(\.oldKey).filter { seen.insert($0).inserted }
    }

    private func choiceGroup(_ key: String) -> some View {
        let options = scan.candidates.filter { $0.oldKey == key }
        let first = options[0]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(first.oldName).fontWeight(.medium)
                if !first.tagNames.isEmpty {
                    Text(first.tagNames.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Text("Was in \(first.oldFolder)")
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Picker("", selection: Binding(
                get: { scan.choice(for: key) ?? "" },
                set: { scan.choose($0.isEmpty ? nil : $0, for: key) }
            )) {
                ForEach(options) { option in
                    optionLabel(option).tag(option.id)
                }
                Text("Leave for now").foregroundStyle(.secondary).tag("")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private func optionLabel(_ option: MovedCandidate) -> some View {
        HStack(spacing: 6) {
            Text(option.newFolder)
                .lineLimit(1).truncationMode(.middle)
                .help(option.newPath)
            if let size = option.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            if let date = option.modified {
                Text(date, format: .dateTime.day().month().year())
                    .foregroundStyle(.secondary)
            }
            switch option.sizeMatches {
            case true?:
                badge("Same size", .green)
            case false?:
                badge("Different size", .orange)
            case nil:
                EmptyView()
            }
        }
        .font(.caption)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule)
    }

    private func missingRow(_ ref: MissingRef) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name)
                Text(ref.folder)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Remove") { scan.remove([ref], library: library) }
                .controlSize(.small)
                .help("Drop this video's tags from the library — Undo in Tag Profiles puts them back")
        }
        .padding(.vertical, 2)
    }

    /// Hunt again for just the videos found nowhere, inside a folder the user
    /// picks — the usual next step when "everywhere" meant the wrong shares.
    private func searchAgainForMissing() {
        let paths = scan.unmatched.map { Paths.tagPath($0.key) }
        chooseSearchFolder()
        guard scan.searchRoot != nil else { return }
        app.findMoved(paths)
        app.runMovedScan()
    }

    // MARK: - Footer: Undo, pick, apply, done

    private var footer: some View {
        HStack(spacing: 10) {
            if !scan.repairs.isEmpty {
                Button("Undo Repairs") { scan.undoRepairs(library: library) }
                    .disabled(!scan.canUndo(library))
                    .help(scan.canUndo(library)
                          ? "Put these videos' tags back where they were, and offer them for review"
                          : "Another change has been made since, so these repairs can no longer be undone on their own")
            }
            Spacer()
            if !scan.candidates.isEmpty {
                Button("Pick for All") { scan.selectAll() }
                    .help("Choose the same-size match for each video, or else the first place it was found")
                Button("Apply \(pickedCount) Choice\(pickedCount == 1 ? "" : "s")") {
                    scan.apply(scan.candidates.filter { scan.chosen.contains($0.id) },
                               library: library)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickedCount == 0)
            }
            Button("Done") {
                scan.reset()
                dismissWindow(id: "moved")
            }
            .disabled(scan.isRunning)
        }
    }

    private var pickedCount: Int { scan.chosen.count }

    @Environment(\.dismissWindow) private var dismissWindow
}
