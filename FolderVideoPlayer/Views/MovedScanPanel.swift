import SwiftUI

/// The "Find Moved Videos" interface, living inside the playlist panel. The
/// scan runs in the background — browsing, playing and tagging keep working
/// while it walks thousands of files. What it can fix on its own it fixes
/// (one undoable edit); what needs a human (a name matching in several
/// places) is offered as rows to tick; what it cannot find anywhere is
/// reported with an explicit remove-reference button. Nothing is modal.
struct MovedScanPanel: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    @ObservedObject var scan: MovedScan
    /// Findings list visible — lives in AppModel so it survives the panel
    /// being rebuilt when the playlist changes.
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: statusIcon)
                    .foregroundStyle(tint)
                statusText
                    .font(.caption)
                    .foregroundStyle(scan.phase == .idle ? .secondary : .primary)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                if case .checking(let done, let total) = scan.phase, total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                } else if case .indexing = scan.phase {
                    ProgressView()
                        .controlSize(.small)
                }
                controls
                Spacer(minLength: 0)
            }
            if expanded { detail }
        }
        .padding(10)
        // Repairs and removals move tags between paths; the open playlist may
        // still be drawing the old ones. Re-query it so the tags show now,
        // not after the user hops away and back.
        .onChange(of: scan.repaired) { _, _ in app.playback?.refreshAfterTagRepair() }
        .onChange(of: scan.removed) { _, _ in app.playback?.refreshAfterTagRepair() }
    }

    /// Stop while it runs; afterwards, where to hunt and a Scan to run again.
    ///
    /// The folder picker sits next to Scan because it is the one thing that
    /// decides how long the scan takes — aiming it is part of starting it, not
    /// a setting kept somewhere else.
    @ViewBuilder
    private var controls: some View {
        if scan.isRunning {
            Button("Stop") { scan.cancel() }
                .controlSize(.small)
        } else {
            locationPicker
            Button("Scan") { app.runMovedScan() }
                .controlSize(.small)
                .help("Check every video in the playlist and hunt for the ones that have moved")
            // Disarms as well as resets: the panel is on screen either because
            // a scan has findings or because Files ▾ armed it, and Done must
            // put it away in both cases.
            Button("Done") {
                app.movedArmed = false
                scan.reset()
            }
            .controlSize(.small)
        }
    }

    /// Where to hunt for the missing files — the whole share, or one folder
    /// the user names. The choice sticks until cleared, so repeated scans
    /// stay fast.
    ///
    /// Shown whenever the panel is open: the sweep is reachable again from
    /// Files ▾, and a sweep with nowhere to aim walks every share — minutes on
    /// a NAS. Naming one folder is the difference between a walk and a glance.
    private var locationPicker: some View {
        HStack(spacing: 6) {
            Text("in:")
                .font(.caption).foregroundStyle(.secondary)
            if let root = scan.searchRoot {
                Text((root as NSString).lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Button {
                    scan.searchRoot = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Search everywhere again")
            } else {
                Text("everywhere")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = scan.searchRoot.map { URL(fileURLWithPath: $0) }
                if panel.runModal() == .OK, let url = panel.url {
                    scan.searchRoot = url.path
                }
            }
            .controlSize(.small)
            .help("Look for the missing files only inside a folder you pick")
        }
    }

    private var statusIcon: String {
        switch scan.phase {
        case .idle: "arrow.triangle.branch"
        case .checking: "square.stack.3d.up"
        case .indexing: "magnifyingglass"
        case .done:
            scan.candidates.isEmpty && scan.unmatched.isEmpty
                ? "checkmark.circle" : "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        if scan.isRunning { return .accentColor }
        return scan.candidates.isEmpty && scan.unmatched.isEmpty ? .green : .orange
    }

    /// The end-of-scan line: what was fixed, what needs a human, what's
    /// gone — and which scope produced it, since the user may have moved on
    /// to another playlist while it ran.
    private var doneSummary: String {
        var bits: [String] = []
        if let fixed = scan.repaired { bits.append("Repaired \(fixed)") }
        if !scan.candidates.isEmpty { bits.append("\(scan.movedVideoCount) to review") }
        if !scan.unmatched.isEmpty { bits.append("\(scan.unmatched.count) missing") }
        let summary = bits.isEmpty ? "All \(scan.totalTagged) in place" : bits.joined(separator: " · ")
        let scope: String
        if let label = scan.scopeLabel {
            scope = "“\(label)”"
        } else if let root = scan.scopeRoot {
            scope = "“\((root as NSString).lastPathComponent)”"
        } else {
            scope = "the library"
        }
        return summary + " — scanned " + scope
    }

    @ViewBuilder
    private var statusText: some View {
        switch scan.phase {
        case .idle:
            if let label = scan.scopeLabel {
                Text("Will check the \(scan.scopePaths?.count ?? 0) videos in “\(label)”, then repair what it can")
            } else if let root = scan.scopeRoot {
                Text("Will check tagged videos in “\((root as NSString).lastPathComponent)”, then repair what it can")
            } else {
                Text("Will check every tagged video, then repair what it can")
            }
        case .checking(let done, let total):
            Text("Checking… \(done) of \(total)")
        case .indexing(let files):
            Text("Searching shares… \(files) files")
        case .done:
            Text(doneSummary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch scan.phase {
        case .idle, .done:
            Button("Scan") { scan.run(library: library) }
                .controlSize(.small)
        case .checking, .indexing:
            Button("Stop") { scan.cancel() }
                .controlSize(.small)
        }
    }

    // MARK: - Findings (expanded)

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !scan.candidates.isEmpty {
                        Text("This name lives in several places — tick the right one")
                            .font(.caption.weight(.semibold))
                        ForEach(scan.candidates) { item in
                            candidateRow(item)
                        }
                    }
                    if !scan.unmatched.isEmpty {
                        Text("File not found on any share — its reference can be removed")
                            .font(.caption.weight(.semibold))
                        ForEach(scan.unmatched) { ref in
                            missingRow(ref)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            footer
        }
    }

    private func candidateRow(_ item: MovedCandidate) -> some View {
        Button {
            scan.toggle(item.id)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: scan.chosen.contains(item.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(scan.chosen.contains(item.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.oldName).font(.caption)
                    Text("→  \(item.newFolder)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func missingRow(_ ref: MissingRef) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.name).font(.caption)
                Text(ref.folder)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button("Remove Reference") {
                scan.remove([ref], library: library)
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            if scan.repaired != nil, scan.candidates.isEmpty {
                Button("Undo Repairs") {
                    library.undoTagChange()
                    scan.run(library: library)
                }
                .controlSize(.small)
            }
            if !scan.unmatched.isEmpty {
                Button("Remove All \(scan.unmatched.count)…") {
                    scan.remove(scan.unmatched, library: library)
                }
                .controlSize(.small)
                .help("Drop every reported reference in one undoable edit")
            }
            Spacer()
            if !scan.candidates.isEmpty {
                Text("\(scan.chosen.count) ticked")
                    .font(.caption).foregroundStyle(.secondary)
                Button("All") { scan.selectAll() }
                    .controlSize(.small)
                    .help("Tick one row per moved video")
                Button("Re-tag \(scan.chosen.count)") {
                    scan.apply(scan.candidates.filter { scan.chosen.contains($0.id) },
                               library: library)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(scan.chosen.isEmpty)
            } else {
                Button("Done") {
                    scan.reset()
                    expanded = false
                }
                .controlSize(.small)
            }
        }
    }
}
