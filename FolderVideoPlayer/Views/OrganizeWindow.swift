import SwiftUI

/// Folders, and the videos in them: make, rename, move and delete folders,
/// and move videos between them by dragging.
///
/// The playlist lists videos, and a folder heading exists only above one — so
/// an empty folder never appears there, and could be neither filled nor
/// deleted. This window shows the folders themselves. Every operation goes
/// through `FolderOps` / `FileOps`, so tags, stars, watch state and the rest
/// follow — for every profile and every person, not only the one in force.
///
/// Built for a big library on a share. The disk is only ever read off the
/// main thread; after an operation only the folders it touched are read again
/// (`FolderTree.refreshed`); the tree is indexed once per change rather than
/// walked on every redraw; and a drop is sorted into videos and folders from
/// what the window already knows, without asking the disk about each item.
struct OrganizeWindow: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    @State private var root: String?
    @State private var tree: FolderNode?
    /// The tree by path, and the folders Move To offers — both worked out once
    /// per tree, not on every redraw.
    @State private var nodes: [String: FolderNode] = [:]
    @State private var moveTargets: [FolderNode] = []
    @State private var expanded: Set<String> = []
    @State private var generation = 0
    @State private var selectedFolder: String?
    @State private var selectedVideos = Set<String>()
    @State private var rows: [VideoRow] = []
    @State private var otherFiles: [String] = []
    @State private var shownFolder: String?
    @State private var loading = false
    @State private var loadingVideos = false
    /// The folder a drag is over, drawn highlighted so it is plain where the
    /// drop will land.
    @State private var dropTarget: String?
    /// A video asked for by Show in Organizer, and its folder — held until
    /// the tree and then the folder's list have what they need to show it.
    @State private var pendingFolder: String?
    @State private var pendingVideo: String?
    @State private var handledRequest: UUID?
    @State private var scrollTarget: String?

    /// Move To lists at most this many folders, the shallow ones first; the
    /// rest are one "Other…" away. A menu of every folder on a big share is
    /// both slow to build and no use to read.
    private static let moveToLimit = 150

    struct VideoRow: Identifiable, Hashable {
        var id: String { path }
        var path: String
        var name: String
        var size: Int64
        var added: Date?
        var hasSubtitles: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            HSplitView {
                folderList
                    .frame(minWidth: 220, idealWidth: 280)
                videoTable
                    .frame(minWidth: 420)
            }
            Divider()
            bottomBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { FileOpProgressBanner().padding(.bottom, 44) }
        .background(WindowReader { app.organizeWindow = $0 })
        .onAppear {
            if let request = app.organizeRequest { handle(request) }
            if root == nil { root = app.playback?.root ?? library.pinned.first ?? library.recent.first }
        }
        .onChange(of: app.organizeRequest) { _, request in if let request { handle(request) } }
        .task(id: "\(root ?? "")|\(app.organizeRevision)") { await reloadTree() }
        .task(id: "\(selectedFolder ?? "")|\(app.organizeRevision)") { await reloadVideos() }
    }

    // MARK: - top: the root, and the folder verbs

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                let choices = rootChoices
                ForEach(choices, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { root = path }.help(path)
                }
                if !choices.isEmpty { Divider() }
                Button("Choose…") { chooseRoot() }
            } label: {
                Label(root.map { ($0 as NSString).lastPathComponent } ?? "Choose a Folder", systemImage: "folder")
            }
            .fixedSize()
            if loading {
                ProgressView().controlSize(.small)
                Text("Reading folders…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Folder") { if let target = selectedFolder ?? root { app.newFolder(in: target) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(root == nil)
            Button("Rename…") { renameSelection() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedVideos.count != 1 && (selectedFolder == nil || selectedFolder == root))
            Button("Delete Folder") { if let folder = selectedFolder { app.deleteFolder(folder, root: root) } }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!(selectedNode?.isEmpty ?? false) || selectedFolder == root)
                .help(deleteHelp)
        }
    }

    private var rootChoices: [String] {
        var seen = Set<String>()
        return ([app.playback?.root].compactMap { $0 } + library.pinned + library.recent)
            .filter { seen.insert($0).inserted }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Organize"
        if panel.runModal() == .OK, let path = panel.url?.path { root = path }
    }

    // MARK: - left: the folders

    private var folderList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedFolder) {
                if let tree { branch(tree) }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
    }

    // MARK: - going where asked

    /// Organise a folder, or find a video. A video's folder is shown inside
    /// the folder being organised when it is in there; otherwise inside the
    /// playing folder, a pinned or a recent one that holds it; failing all of
    /// those, the video's own folder becomes the root.
    private func handle(_ request: AppModel.OrganizeRequest) {
        guard request.id != handledRequest else { return }
        handledRequest = request.id
        if let video = request.video {
            let folder = (video as NSString).deletingLastPathComponent
            pendingFolder = folder
            pendingVideo = video
            let holders = [root, app.playback?.root].compactMap { $0 } + library.pinned + library.recent
            let target = holders.first { contains($0, folder) } ?? folder
            if target != root { root = target } else { showPending() }
        } else if let asked = request.root {
            pendingFolder = nil
            pendingVideo = nil
            root = asked
        }
    }

    private func contains(_ folder: String, _ path: String) -> Bool {
        PathMap(from: folder, to: folder, isFolder: true).map(path) != nil
    }

    /// Select the asked-for folder, open every folder above it, scroll to it
    /// — once the tree has it — and the video, once its list is on screen.
    private func showPending() {
        if let folder = pendingFolder, nodes[folder] != nil {
            var above = folder
            while above != root, let parent = Optional((above as NSString).deletingLastPathComponent),
                  parent != above, nodes[parent] != nil {
                expanded.insert(parent)
                above = parent
            }
            selectedFolder = folder
            scrollTarget = folder
            pendingFolder = nil
        }
        if let video = pendingVideo, shownFolder == (video as NSString).deletingLastPathComponent,
           rows.contains(where: { $0.path == video }) {
            selectedVideos = [video]
            pendingVideo = nil
        }
    }

    /// One folder and, when it is open, the folders in it. Written out rather
    /// than left to `OutlineGroup` so which folders are open is the window's
    /// to change — a folder held under a drag opens by itself.
    private func branch(_ node: FolderNode) -> AnyView {
        if let children = node.children {
            return AnyView(DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.path) },
                set: { open in if open { expanded.insert(node.path) } else { expanded.remove(node.path) } })) {
                    ForEach(children) { branch($0) }
                } label: {
                    folderRow(node)
                })
        }
        return AnyView(folderRow(node))
    }

    private func folderRow(_ node: FolderNode) -> some View {
        let count = max(0, node.videoCount - library.hiddenCount(under: node.path))
        let targeted = dropTarget == node.path
        return HStack {
            Label(node.name, systemImage: targeted ? "folder.fill" : "folder")
            Spacer()
            Text(node.isEmpty ? "empty" : "\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(targeted ? 0.28 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(Color.accentColor, lineWidth: targeted ? 1.5 : 0))
        .opacity(node.isEmpty && !targeted ? 0.6 : 1)
        .help(node.path)
        .id(node.path)
        .tag(node.path)
        .draggable(node.path)
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            return drop(items, onto: node.path)
        } isTargeted: { over in
            hover(over, on: node)
        }
        .contextMenu {
            Button("New Folder Inside") { app.newFolder(in: node.path) }
            if node.path != root {
                Button("Rename Folder…") { app.renameFolder(node.path) }
                Button("Delete Folder…") { app.deleteFolder(node.path, root: root) }
            }
        }
    }

    /// A drag coming over or leaving a folder. Held over a closed folder for a
    /// moment, it opens — so a drop can reach a folder deep in the tree.
    private func hover(_ over: Bool, on node: FolderNode) {
        if over {
            dropTarget = node.path
            guard node.children != nil, !expanded.contains(node.path) else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                if dropTarget == node.path { expanded.insert(node.path) }
            }
        } else if dropTarget == node.path {
            dropTarget = nil
        }
    }

    /// Videos dropped on a folder move into it; a folder dropped on a folder
    /// moves inside it. Which is which comes from the tree the window already
    /// holds — asking the disk about every dragged file was a round trip each
    /// on the main thread. `FolderOps` refuses the moves that cannot be — into
    /// itself, across drives — and says why.
    private func drop(_ items: [String], onto folder: String) -> Bool {
        let folders = items.filter { nodes[$0] != nil && $0 != folder }
        let videos = items.filter { nodes[$0] == nil && ($0 as NSString).deletingLastPathComponent != folder }
        guard !videos.isEmpty || !folders.isEmpty else { return false }
        if !videos.isEmpty { app.moveFiles(videos, into: folder) }
        for moving in folders { app.moveFolder(moving, into: folder) }
        return true
    }

    // MARK: - right: the videos in the selected folder

    private var videoTable: some View {
        VStack(spacing: 0) {
            Table(of: VideoRow.self, selection: $selectedVideos) {
                TableColumn("Name") { row in
                    HStack(spacing: 4) {
                        if row.path == app.playback?.currentPath {
                            Image(systemName: "play.fill").foregroundStyle(.secondary)
                        }
                        Text(row.name).lineLimit(1)
                        if row.hasSubtitles {
                            Text("CC").font(.caption2).foregroundStyle(.secondary)
                                .help("Subtitle files travel with this video")
                        }
                    }
                }
                TableColumn("Size") { row in
                    Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Added") { row in
                    Text(row.added.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 100)
                TableColumn("Tags") { row in
                    Text(library.tagsFor(row.path).joined(separator: ", "))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            } rows: {
                ForEach(rows) { row in
                    TableRow(row).draggable(row.path)
                }
            }
            .contextMenu(forSelectionType: String.self) { chosen in
                videoMenu(Array(chosen))
            }
            .overlay {
                if loadingVideos && rows.isEmpty {
                    ProgressView("Reading “\((selectedFolder.map { ($0 as NSString).lastPathComponent }) ?? "")”…")
                        .controlSize(.small)
                }
            }
            if !otherFiles.isEmpty {
                Divider()
                Text("+ \(otherFiles.count) other file\(otherFiles.count == 1 ? "" : "s") (\(otherFiles.prefix(3).joined(separator: ", "))\(otherFiles.count > 3 ? ", …" : ""))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func videoMenu(_ paths: [String]) -> some View {
        if paths.count == 1, let path = paths.first {
            Button("Rename…") { app.renameFile(path) }
        }
        if !paths.isEmpty {
            moveToMenu(paths)
            Button(paths.count == 1 ? "Move to Trash…" : "Move \(paths.count) to Trash…") { app.trashFiles(paths) }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            }
        }
    }

    private func moveToMenu(_ paths: [String]) -> some View {
        Menu("Move To") {
            ForEach(moveTargets, id: \.path) { node in
                Button(indented(node)) { app.moveFiles(paths, into: node.path) }
            }
            Divider()
            Button("Other…") { app.moveFiles(paths) }
        }
    }

    /// A folder's name, indented by how deep it sits under the root.
    private func indented(_ node: FolderNode) -> String {
        String(repeating: "   ", count: depth(node.path)) + node.name
    }

    private func depth(_ path: String) -> Int {
        guard let root else { return 0 }
        return path.dropFirst(root.count).split(separator: "/").count
    }

    private func renameSelection() {
        if selectedVideos.count == 1, let path = selectedVideos.first {
            app.renameFile(path)
        } else if let folder = selectedFolder, folder != root {
            app.renameFolder(folder)
        }
    }

    // MARK: - bottom: move and trash, and why a folder stays

    private var bottomBar: some View {
        HStack(spacing: 8) {
            moveToMenu(Array(selectedVideos))
                .fixedSize()
                .disabled(selectedVideos.isEmpty)
            Button("Move to Trash") { app.trashFiles(Array(selectedVideos)) }
                .disabled(selectedVideos.isEmpty)
            Spacer()
            let line = [app.lastFileOp ?? "", statusLine].filter { !$0.isEmpty }.joined(separator: " · ")
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(line)
        }
    }

    private var selectedNode: FolderNode? { selectedFolder.flatMap { nodes[$0] } }

    private var deleteHelp: String {
        guard let node = selectedNode else { return "Select an empty folder" }
        if node.path == root { return "This is the folder being organised" }
        return node.isEmpty ? "Delete “\(node.name)” — it holds no files" : holds(node)
    }

    private func holds(_ node: FolderNode) -> String {
        let parts = [node.videoCount > 0 ? "\(node.videoCount) video\(node.videoCount == 1 ? "" : "s")" : nil,
                     node.otherCount > 0 ? "\(node.otherCount) other file\(node.otherCount == 1 ? "" : "s")" : nil]
            .compactMap { $0 }
        return "“\(node.name)” holds \(parts.joined(separator: " and ")) — move or delete them first."
    }

    private var statusLine: String {
        guard let node = selectedNode else { return "" }
        if node.isEmpty && node.path != root { return "“\(node.name)” is empty and can be deleted." }
        return node.path == root ? "" : holds(node)
    }

    // MARK: - reading the disk, off the main thread

    /// The tree: after an operation, only the folders it touched are read
    /// again; for a new root, the last tree built for it is shown at once and
    /// read again behind it.
    private func reloadTree() async {
        guard let root else { adopt(nil); return }
        let change = app.takeOrganizeChange()
        if let current = tree, current.path == root, let change {
            let started = generation
            let updated = await Task.detached(priority: .userInitiated) {
                FolderTree.refreshed(current, touched: change.folders, moved: change.moved)
            }.value
            // Another refresh landed meanwhile: this one was worked out from
            // an older tree, so read the whole thing instead of guessing.
            if generation == started { return adopt(updated) }
        }
        if tree?.path != root, let known = app.organizeTrees[root] { adopt(known) }
        loading = true
        let built = await Task.detached(priority: .userInitiated) { FolderTree.build(root: root) }.value
        loading = false
        if self.root == root { adopt(built) }
    }

    private func adopt(_ built: FolderNode?) {
        generation += 1
        tree = built
        guard let built else { nodes = [:]; moveTargets = []; return }
        nodes = FolderTree.index(built)
        moveTargets = Array(nodes.values
            .sorted { depth($0.path) != depth($1.path) ? depth($0.path) < depth($1.path) : naturalLess($0.path, $1.path) }
            .prefix(Self.moveToLimit))
            .sorted { naturalLess($0.path, $1.path) }
        app.organizeTrees[built.path] = built
        expanded.insert(built.path)
        showPending()
        if selectedFolder == nil || nodes[selectedFolder ?? ""] == nil {
            selectedFolder = built.path
        }
    }

    /// One folder's videos. The list empties the moment another folder is
    /// picked — showing the last folder's videos while this one is read was
    /// what looked like a click that had not taken — and a reading that comes
    /// back after the pick has moved on is dropped.
    private func reloadVideos() async {
        guard let folder = selectedFolder else { rows = []; otherFiles = []; return }
        if folder != shownFolder {
            rows = []
            otherFiles = []
            selectedVideos = []
        }
        loadingVideos = true
        let listing = await Task.detached(priority: .userInitiated) { FolderTree.listing(of: folder) }.value
        guard selectedFolder == folder, !Task.isCancelled else { return }
        loadingVideos = false
        shownFolder = folder
        rows = listing.videos.map {
            VideoRow(path: $0.path, name: ($0.path as NSString).lastPathComponent,
                     size: $0.size, added: $0.added, hasSubtitles: $0.hasSubtitles)
        }
        otherFiles = listing.otherFiles
        let present = Set(rows.map(\.path))
        selectedVideos = selectedVideos.filter { present.contains($0) }
        showPending()
        // A video Finder put back from the Trash gets its tags back.
        await ParkedTags.restore(present: rows.map(\.path), library: library)
    }
}

/// A batch of moves on its way: how far it has got, and Stop — which takes
/// effect between files, so each is either moved with everything it carries,
/// or untouched. Shown only for more than one file.
struct FileOpProgressBanner: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let progress = app.fileOpProgress, progress.total > 1 {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .frame(width: 180)
                Text("\(progress.done + 1) of \(progress.total) · \(progress.current)")
                    .font(.caption)
                    .lineLimit(1)
                Button("Stop") { app.stopFileOp() }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Hands back the window a view is in — how `AppModel` knows which window is
/// the Organize window, to say things there rather than on the player window.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { found(view.window) }
    }
}
