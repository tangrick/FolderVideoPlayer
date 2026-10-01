import SwiftUI

/// Every folder the open profile's library draws videos from — chosen ones
/// (pinned, recent, kept up to date) and the ones that are only here because
/// of the videos the profile holds tags and history for — each with a way to
/// organize it or take it out of the library.
struct LibraryFoldersSheet: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel
    /// Make this folder the one Organize Folders works on.
    var organize: (String) -> Void
    var close: () -> Void

    @State private var rows: [LibraryFolder] = []
    @State private var loading = true
    @State private var filter = ""

    private var shown: [LibraryFolder] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in words.allSatisfy { row.path.lowercased().contains($0) } }
    }

    /// Rebuild the list when anything it is made of changes. The revision is
    /// the one that matters for removals and undos; the counts catch the
    /// changes made elsewhere while the list is open.
    private var token: String {
        "\(library.person)|\(library.folderRevision)|\(library.pinned.count)|\(library.recent.count)"
            + "|\(library.tags.count)|\(app.maintenance.file.settings.folders.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library Folders").font(.title3.weight(.semibold))
                Text(library.profileOpen ? "in \(library.person)’s library" : "no profile open")
                    .foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Text("Every folder this profile gets videos from, or holds tags, ratings or watch history "
                 + "for. Taking one out forgets what the profile holds for its videos; the files are "
                 + "never touched.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Filter folders", text: $filter)
                .textFieldStyle(.roundedBorder)

            List(shown) { folder in
                row(folder)
            }
            .listStyle(.inset)
            .overlay {
                if !loading && shown.isEmpty {
                    Text(rows.isEmpty ? "This profile holds no folders yet." : "No folder matches.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if let removal = library.lastFolderRemoval {
                    Button("Undo Remove “\((removal.folder as NSString).lastPathComponent)”") {
                        app.undoFolderRemoval()
                    }
                    .keyboardShortcut("z")
                    .help("Put back what the last removal took (⌘Z)")
                }
                Spacer()
                Text("\(rows.count) folder\(rows.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 480)
        .task(id: token) { await reload() }
    }

    private func row(_ folder: LibraryFolder) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text((folder.path as NSString).lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(folder.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if folder.pinned { badge("Pinned") }
                    if folder.recent { badge("Recent") }
                    if folder.maintained { badge("Kept up to date") }
                    // The one that explains how a folder nobody chose got in.
                    if folder.viaVideosOnly { badge("Only because of its videos", emphasised: true) }
                }
            }
            Spacer(minLength: 8)
            Text(folder.videos == 0 ? "no videos held" : "\(folder.videos) video\(folder.videos == 1 ? "" : "s")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Organize") { organize(folder.path) }
                .controlSize(.small)
                .help("Work on this folder in Organize Folders")
            Button("Remove from Library…") {
                // Gone from the list as soon as it is confirmed, not when the
                // list next rebuilds; the rebuild then confirms it.
                if app.removeFromLibrary(folder.path) {
                    rows.removeAll { LibraryFolders.contains(folder.path, $0.path) }
                }
            }
                .controlSize(.small)
                .help("Forget what this profile holds for the videos under this folder")
        }
        .padding(.vertical, 3)
        // `.contain`, not `.combine`: combined, the two buttons stop being
        // reachable one by one, and the row can only be pressed as a whole.
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, emphasised: Bool = false) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(emphasised ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15),
                        in: .rect(cornerRadius: 4))
    }

    private func reload() async {
        guard library.profileOpen else { rows = []; loading = false; return }
        let paths = library.knownProfileVideoKeys().map { Paths.tagPath($0) }
        let pinned = library.pinned, recent = library.recent
        let kept = app.maintenance.file.settings.folders
        let built = await Task.detached(priority: .userInitiated) {
            LibraryFolders.build(pinned: pinned, recent: recent, maintained: kept, videoPaths: paths)
        }.value
        guard !Task.isCancelled else { return }
        rows = built
        loading = false
    }
}
