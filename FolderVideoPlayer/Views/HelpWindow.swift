import AppKit
import SwiftUI

/// Help — Quick start, Keyboard shortcuts, and where the data lives.
///
/// One window with a three-item list, rather than three menu items opening
/// three windows: a person looking for help does not yet know which of the
/// three they need, and this way all of them are one click away.
///
/// Nothing here reads the engine or the library beyond counts that are
/// already in memory, and nothing here starts any work.
struct HelpWindow: View {
    /// Which page is showing. Set before the window opens by whoever asked
    /// for it (the first-run screen goes straight to the tour, for example).
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                Group {
                    switch app.helpPage {
                    case .quickStart: QuickStartPage()
                    case .shortcuts: ShortcutsPage()
                    case .hidden: HiddenPage()
                    case .data: DataPage()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 440)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpPage.allCases) { page in
                Button {
                    app.helpPage = page
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: page.symbol)
                            .foregroundStyle(app.helpPage == page ? Color.accentColor : .secondary)
                            .frame(width: 16)
                        Text(page.title)
                            .fontWeight(app.helpPage == page ? .semibold : .regular)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(app.helpPage == page ? Color.accentColor.opacity(0.15) : .clear,
                                in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 184)
        .background(.regularMaterial)
    }
}

/// The three pages, and their names. `allCases` drives the list, so adding a
/// page is one case and one view.
enum HelpPage: String, CaseIterable, Identifiable {
    case quickStart, shortcuts, hidden, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStart: return "Quick start"
        case .shortcuts: return "Keyboard shortcuts"
        case .hidden: return "Hidden videos"
        case .data: return "Where my data lives"
        }
    }

    var symbol: String {
        switch self {
        case .quickStart: return "flag"
        case .shortcuts: return "keyboard"
        case .hidden: return "eye.slash"
        case .data: return "folder"
        }
    }
}

// MARK: - Hidden videos

/// The honest page. A password that looks like it protects a file, when it
/// only hides it from this app, is worse than no password at all — so this
/// says plainly what it does and does not do, and how to undo it by hand.
private struct HiddenPage: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hidden videos")
                .font(.title2.weight(.semibold))
            Text("Hide individual videos so they disappear from the playlist, tag lists, "
                 + "counts, duplicates and the AI — and reveal them again behind a password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("What hiding does", systemImage: "eye.slash")
                        .font(.headline)
                    Text("• The video is left out of everything this app shows or does.\n"
                         + "• There is no tag, no tag playlist and no row in the library panel for them — View → Show Hidden Videos… in the menu bar is the only way in.\n"
                         + "• Its tags, favourite mark and resume position are kept, so unhiding restores it exactly as it was.\n"
                         + "• Nothing the app shows while it is locked names a hidden video — the library panel's Resume row skips it.\n"
                         + "• Hiding never deletes anything.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("What hiding does NOT do", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("The file itself is untouched — not renamed, not moved, not encrypted. "
                         + "Finder, and any other app on this Mac, can still open it. The password "
                         + "keeps this app's list out of sight; it does not protect the file.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Text("\(library.hidden.count) video\(library.hidden.count == 1 ? " is" : "s are") hidden right now.")
                .font(.callout)

            HStack(spacing: 10) {
                Button("Show Hidden Videos…") { app.showHiddenVideos() }
                    .disabled(library.hidden.isEmpty || library.lock.isUnlocked)
                Button("Lock Now") { app.lockHidden() }
                    .disabled(!library.lock.isUnlocked)
            }

            Text("Forgot the password? The hidden list is a plain JSON file (`state.json`, the "
                 + "`hidden` list) and the password record is `hidden.json` — both under the app's "
                 + "support folder, shown on the next page. Removing `hidden.json` clears the "
                 + "password and leaves the hidden videos hidden; the list can then be edited by "
                 + "hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Quick start

private struct QuickStartPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick start")
                .font(.title2.weight(.semibold))
            Text("Four steps. Everything after them is optional.")
                .font(.callout)
                .foregroundStyle(.secondary)

            step(1, "Play something",
                 "Open a folder of videos — or drag one onto the window or the "
                 + "app icon — and the app plays the lot, in order. Stars "
                 + "and tags join in from the left-hand library.")
            Text("Steps 2 to 4 need the AI features turned on first: Settings → AI "
                 + "downloads them from inside the app. Playing, tags, stars "
                 + "and the duplicate finder work without them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            step(2, "Say what you see",
                 "Press Tags (⌘T) while a video plays. The panel offers what the "
                 + "engine thinks fits; click a suggestion to accept it, or its ✕ "
                 + "to say it is not that.")
            step(3, "Four of each",
                 "Training needs four examples of what a tag IS and four of what "
                 + "it is not. Accepts and ✕s both count. The rejections are the "
                 + "half people forget — a tag with no rejections cannot learn.")
            step(4, "Train",
                 "AI ▾ → Train Tags from These. From then on that tag is offered "
                 + "by your own trained head rather than a guess.")

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Label("Nothing is uploaded", systemImage: "lock")
                Label("No account, no password — only your Mac", systemImage: "person.crop.circle")
                Label("Nothing is deleted outright; removals go to the Trash", systemImage: "trash")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text("Where your tags are kept, and how they carry to other devices: "
                 + "see Where my data lives.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Keyboard shortcuts

private struct ShortcutsPage: View {
    private struct Row: Identifiable {
        let keys: [String]
        let what: String
        let where_: String
        var id: String { keys.joined() + what }
    }

    private let playing: [Row] = [
        Row(keys: ["Space"], what: "Play or pause", where_: "Anywhere"),
        Row(keys: ["←", "→"], what: "Skip back or forward (Settings sets how far)", where_: "Playback menu"),
        Row(keys: ["↓", "↑"], what: "Next or previous video", where_: "Playback menu"),
        Row(keys: ["⌘←", "⌘→"], what: "Next or previous video", where_: "Playback menu"),
        Row(keys: ["⌘."], what: "Stop", where_: "Playback menu"),
        Row(keys: ["double-click"], what: "Full screen, on and off", where_: "On the picture"),
        Row(keys: ["⌘F", "⌃⌘F", "Esc"], what: "Full screen, green button, and the way out", where_: "View menu"),
    ]

    private let windows: [Row] = [
        Row(keys: ["⌘O"], what: "Open a folder", where_: "File menu"),
        Row(keys: ["⌘N"], what: "Show or hide the library", where_: "File menu"),
        Row(keys: ["⌘L"], what: "Show or hide the playlist", where_: "View menu"),
        Row(keys: ["⌘1"], what: "Poster frames", where_: "View menu"),
        Row(keys: ["⌘2"], what: "The list", where_: "View menu"),
    ]

    private let tagging: [Row] = [
        Row(keys: ["⌘T"], what: "Tag what is playing", where_: "Tags menu"),
        Row(keys: ["⌘⇧D"], what: "Rate the playing video 5 stars", where_: "Tags menu"),
        Row(keys: ["⌘⇧P"], what: "Tag Profiles", where_: "Tags menu"),
        Row(keys: ["Esc"], what: "Close the tag panel", where_: "Tag panel"),
        Row(keys: ["⌘-click", "⇧-click"], what: "Add one video to the selection, or take a run", where_: "Playlist"),
        Row(keys: ["⌘A", "⌘⇧A"], what: "Select all the videos showing, or none of them", where_: "Edit menu"),
        Row(keys: ["⌘I"], what: "Everything known about one video", where_: "Edit menu"),
        Row(keys: ["⌘R"], what: "Reveal what is picked in Finder", where_: "Edit menu"),
        Row(keys: ["⌘⌫"], what: "Move what is picked to the Trash", where_: "Edit menu"),
        Row(keys: ["Space"], what: "Preview a duplicate copy, Quick Look style", where_: "Find Duplicates"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Right-click any tag in the library for its own menu — play it, "
                     + "train from it, gather it into a folder, rename it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group("Playing", playing)
            group("Windows and views", windows)
            group("Tagging and files", tagging)
            Text("⌘, opens Settings, where the skip step, the default speed and "
                 + "Face Recognition live.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func group(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        HStack(spacing: 4) {
                            ForEach(row.keys, id: \.self) { key in
                                KeyCap(key)
                            }
                        }
                        .frame(width: 132, alignment: .leading)
                        Text(row.what)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(row.where_)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }
}

/// One key, drawn the way every Mac shortcut list draws them.
private struct KeyCap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if text == "double-click" || text == "⌘-click" || text == "⇧-click" {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 34)
        } else {
            Text(text)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        }
    }
}

// MARK: - Where my data lives

private struct DataPage: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var app: AppModel

    private struct Item: Identifiable {
        let name: String
        let what: String
        var id: String { name }
    }

    private let items: [Item] = [
        Item(name: "tags.json", what: "Your tags — the one file worth backing up"),
        Item(name: "state.json", what: "Resume positions, recent folders, preferences, duplicate scans"),
        Item(name: "thumbs/", what: "Poster frames this Mac has drawn"),
        Item(name: "tags/", what: "The AI models you chose to download, and the prompt table beside them — nothing here ships with the app"),
        Item(name: "models/", what: "Scratch space for a download in progress, plus the older engine's own models if this Mac ever used it"),
        Item(name: "engine/", what: "The classifying engine and its log"),
        Item(name: "hidden.json", what: "The salt and hash for the hidden-videos password — not the password itself. Remove it to forget the password; the hidden list in state.json is left alone"),
        Item(name: "analysis.json", what: "What the engine has worked out about each video — shared by every profile, because it is a reading of the video"),
        Item(name: "frames/", what: "The frame vectors every pass reads, also shared"),
        Item(name: "profiles/", what: "What each profile decided for itself: machine guesses and your yes/no on them, your Safe/NSFW marks, the people you have named, and the tag models trained from all of it"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where my data lives")
                .font(.title2.weight(.semibold))
            Text("Everything is on this Mac, under one folder. Nothing is in the cloud.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(Paths.support)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.support))
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Paths.support, forType: .string)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))

            VStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.name)
                            .font(.callout.monospaced())
                            .frame(width: 150, alignment: .leading)
                        Text(item.what)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }

            Text("A library on a network share also keeps a copy of the tags in a "
                 + "hidden .FolderVideoPlayer folder, so your other devices — and the "
                 + "older build — can read them. Your tags travel; the duplicate "
                 + "index does not, because the two builds fingerprint differently.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
