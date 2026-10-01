import SwiftUI

/// The library at a glance: what to continue, what is new, what is done, and
/// what is waiting on you. Each section opens as an ordinary playlist in the
/// player; missing files and duplicates open the windows that already handle
/// them, rather than a second way of doing the same thing.
struct LibraryOverviewWindow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var analysis: AnalysisStore
    @EnvironmentObject private var suggestions: SuggestionStore
    @EnvironmentObject private var journal: EvidenceJournal
    @Environment(\.openWindow) private var openWindow

    @State private var overview = LibraryOverview()
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !library.profileOpen {
                    Text("No profile is open.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(LibraryOverview.Kind.allCases) { kind in
                            card(kind)
                        }
                    }
                    Divider()
                    Text("Housekeeping").font(.headline)
                    HStack(spacing: 12) {
                        Button {
                            app.findMovedEverywhere()
                            openWindow(id: "moved")
                        } label: {
                            Label("Find Missing Files…", systemImage: "questionmark.folder")
                        }
                        .help("Check tagged videos for files that have moved or gone")
                        Button {
                            openWindow(id: "duplicates")
                        } label: {
                            Label(duplicateLabel, systemImage: "doc.on.doc")
                        }
                        .help("Find identical copies; nothing is deleted without asking")
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 420)
        // A removal or an undo changes what the profile knows without touching
        // the watch log, so the revision is part of what it rebuilds on.
        .task(id: "\(library.watchRevision)|\(library.folderRevision)") { await rebuild() }
        .onChange(of: library.profileOpen) { _, _ in Task { await rebuild() } }
    }

    private var duplicateLabel: String {
        guard let finder = app.duplicates, !finder.groups.isEmpty else { return "Find Duplicates…" }
        let bytes = ByteCountFormatter.string(fromByteCount: finder.reclaimable, countStyle: .file)
        return "Duplicates: \(bytes) recoverable…"
    }

    private func card(_ kind: LibraryOverview.Kind) -> some View {
        let paths = overview.paths(kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(kind.title, systemImage: kind.icon).font(.headline)
                Spacer()
                Text(loading ? "…" : "\(paths.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if paths.isEmpty {
                Text(loading ? "Looking…" : kind.emptyNote)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(paths.prefix(3), id: \.self) { path in
                    Text((path as NSString).lastPathComponent)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
                Button("Play \(paths.count == 1 ? "It" : "All \(paths.count)")") {
                    app.playback?.playList(kind.title, paths)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// Everything from memory at once; then the dates Recently Added needs are
    /// fetched as a gentle trickle (a flood of stats on a share starves the
    /// video that is playing) and the overview is built again when they land.
    private func rebuild() async {
        guard library.profileOpen else { overview = LibraryOverview(); loading = false; return }
        let extra = Set(analysis.records.keys).union(journal.transcribedPaths.map { Paths.tagKey($0) })
        let known = library.knownVideoKeys(adding: extra)
        build(known)
        await library.warmStats(known.map { Paths.tagPath($0) },
                                parallel: SmartCollectionStore.trickle, priority: .background)
        guard !Task.isCancelled else { return }
        build(known)
    }

    private func build(_ known: [String]) {
        var added: [String: Double] = [:]
        for key in known {
            let path = Paths.tagPath(key)
            let when = library.addedOn(path)
            if when > 0 { added[path] = when }
        }
        let input = LibraryOverview.Input(
            known: known, hidden: library.hidden,
            watch: { library.watchState(Paths.tagPath($0)) },
            lastPlayed: { library.lastPlayed(Paths.tagPath($0)) },
            progressSeen: library.progressSeen,
            addedOn: added,
            hasPendingSuggestions: { !suggestions.pending(Paths.tagPath($0)).isEmpty },
            analysis: { AnalysisStore.bucket(record: analysis.records[$0]) })
        overview = LibraryOverview.build(input)
        loading = false
    }
}
