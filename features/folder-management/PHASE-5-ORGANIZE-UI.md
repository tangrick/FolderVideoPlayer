# Phase 5: the Organize window and sidebar folder actions

**Read `README.md` in this folder first.** Its rules apply. Rule 11 matters most here: **don't launch the GUI.** Build it, test the model parts headlessly, and give the user a hand-test list.
**Depends on:** phases 3 (`FileOps.trash` async, `ParkedTags.restore`, `skipping:` walks) and 4 (`FolderOps`, `FolderContents`).
**No Apple TV change.**

---

## 1. Why a window, not just the playlist

The playlist lists **videos**, and its folder headings exist only above videos. **An empty folder never appears there**, so you couldn't fill it or delete it. The Organize window shows the **folders**.

---

## 2. What to build

### 2.1 The scene and the menu
- **Scene.** Add `Window("Organize Folders", id: "organize") { OrganizeWindow() … }` in `FolderVideoPlayerApp.swift`, beside the other `Window` scenes (lines ~149–240). Inject the same environment objects they do (`library`, `app`), and use `.defaultSize(width: 980, height: 640)`.
- **Menu.** Add *File ▸ Organize Folders…* in `Views/Menus.swift`, in the `CommandGroup(replacing: .newItem)` at ~291, calling `openWindow(id: "organize")`.
- **Shortcut: ⌥⌘O.** ⇧⌘O is already *Open Folder…*, so don't use it.
- **Opening at a folder.** Follow the `findMoved(inFolder:)` pattern (`FolderVideoPlayerApp.swift:840`): add `@Published var organizeRoot: String?` and `func organize(_ root: String)` on `AppModel`. The caller sets it, then calls `openWindow(id: "organize")`.

### 2.2 The model: `Model/FolderTree.swift`

This is a new, pure file, so add it to `Tests/model_sources.sh`.

```swift
struct FolderNode: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var videoCount: Int          // recursive, hidden videos excluded (library.hiddenCount(under:))
    var children: [FolderNode]?  // nil for a leaf, for OutlineGroup
    var isEmpty: Bool            // FolderContents.isEmpty (phase 4) — zero videos AND zero other files
}
enum FolderTree {
    /// One background walk: dot-directories and discard folders skipped, natural order.
    static func build(root: String, skipping: [String]) -> FolderNode
    /// One folder, not recursive: its videos, and the other files that are not clutter.
    static func listing(of folder: String) -> (videos: [String], otherFiles: [String])
}
```

- Build the tree **off the main thread**. That's a whole-folder walk, the same cost as opening the folder to play.
- After an operation, update only the affected nodes, or rebuild in the background. **Never walk on the main actor.**
- After each walk, pass the videos it saw to `ParkedTags.restore(present:)` (phase 3), so a video put back shows up with its tags.

### 2.3 The view: `Views/OrganizeWindow.swift`

```
┌ Organize Folders ─────────────────────────────────────────────────────────┐
│ [ Movies (NAS) ▾ ]                    [New Folder] [Rename…] [Delete Folder]│
├────────────────────────────┬──────────────────────────────────────────────┤
│ ▾ Movies              412  │   Name                  Size     Added  Tags │
│   ▾ Holidays           38  │ ▶ beach-2019.mp4  CC    1.2 GB   3 Jun  Beach│
│       2019             12  │   hike.mp4              800 MB   4 Jun   ★   │
│       2020         empty   │                                              │
│   ▸ Concerts          121  │   + 1 other file (cover.jpg)                 │
├────────────────────────────┴──────────────────────────────────────────────┤
│ [Move To… ▾] [Move to Trash]     “2020” is empty and can be deleted.      │
└───────────────────────────────────────────────────────────────────────────┘
```

**Root picker:**
- Offers the playing folder (`playback.root`), `library.pinned`, `library.recent`, and *Choose…* (an `NSOpenPanel` for folders).
- Starts at `app.organizeRoot` if set, otherwise the playing folder.

**Left pane:** `List(selection:)` with `OutlineGroup(root, children: \.children)`.
- Each row shows a folder icon, the name, and the recursive count.
- An empty folder shows *empty*, dimmed.

**Right pane:** a `Table` of the selected folder's videos, with multiple selection.
- Columns: name, size, date added, tags. Reuse the playlist's tag-chip look (`LabelChipStyle`).
- ▶ marks the video that's playing.
- **CC** marks a video with subtitle files (`SubtitleFile.sidecars`); they travel with it.
- Below the table, one line summarises the other files: *"+ 2 other files (cover.jpg, notes.txt)"*. They explain why a folder can't be deleted.

**Buttons, context menus and keys:**

| Action | Where | Key | Calls |
|---|---|---|---|
| New Folder | toolbar; folder context menu | ⇧⌘N (free) | `FolderOps.makeFolder(in: selectedFolder)`, then open *Rename…* on the new folder at once |
| Rename… | toolbar; both context menus | ↩ in the focused pane | `FolderOps.renameFolder` or `FileOps.rename`. Prompt with the existing `AppModel.ask` alert; don't edit inline in the outline |
| Delete Folder | toolbar; folder context menu | ⌥⌘⌫ (free) | Enabled only when `node.isEmpty`; `.help` gives the reason otherwise. Confirm: *"Delete “2020”? It holds no files."* → `FolderOps.deleteFolder` |
| Move To ▸ | toolbar menu; video context menu | — | The tree's folders, then *Other…*. Calls a refactored `AppModel.moveFiles(_:into:)` (§2.5) |
| Move to Trash | toolbar; video context menu | **none**: ⌘⌫ is already the Edit menu's *Move to Trash*, which acts on `app.selection` | `app.trashFiles(paths)` |
| Reveal in Finder, Play | video context menu | — | Existing actions |

**Drag and drop:**
- Video rows can be dragged (`.draggable` with the path, or `.onDrag` with an `NSItemProvider`, as the sidebar already does).
- Folder rows can be dragged too.
- Folder rows accept drops (`.dropDestination(for: String.self)`):
  - videos → `moveFiles(_:into:)`;
  - a folder → `FolderOps.moveFolder`.
- **Refuse** a folder dropped onto itself or a descendant, a folder dropped across volumes, and videos dropped onto the folder they're already in. Show the refusal as a disabled drop.

**Status line:**
- After an operation: *"Moved 4 · updated 2 other tag profiles."* Count the profiles and people ring 2 and ring 3 actually touched. Have `ProfileRelocation.spread` return that count, which is a small change.
- When *Delete Folder* is disabled, why.

### 2.4 Progress and Stop for batches
- Add `@Published var fileOpProgress: (done: Int, total: Int, current: String)?` and `func stopFileOp()` on `AppModel`.
- Give `FileOps.move` (and `trash`) two optional parameters, `progress: ((Int, Int, String) -> Void)?` and `shouldStop: (() -> Bool)?`, checked **between** files, never in the middle of one.
- Show a progress bar with **Stop** as an overlay in the Organize window, and in the player window when the operation started there. Only show it for more than one file, or for a move across volumes.
- **A stop leaves the stores matching the disk.** The per-file bookkeeping design from phase 1 already guarantees that.

### 2.5 `AppModel` changes
- **Split `moveFiles(_:)`** into the panel part and `moveFiles(_ paths:, into folder:)`. The leaving-the-share warning from phase 2 moves into the second, so drag and drop and *Move To ▸* get it too.
- Add `renameFolder(_:)`, `newFolder(in:)`, `deleteFolder(_:)` and `moveFolder(_:into:)` wrappers. They go through `runFileOp`, which keeps them one at a time and reports them.
- `finish` already refreshes the playlist. Also have it trigger an Organize tree refresh (for example, publish a revision counter the window observes).

### 2.6 The sidebar and the playlist
- **Sidebar folder rows.** In `Views/PlayerWindow.swift`, the Pinned rows' `.contextMenu` (~1092) and the Recent rows' (~1155) get *New Folder Inside…*, *Rename Folder…*, *Delete Folder…* and *Organize…*.
  - SwiftUI builds a context menu eagerly, so **don't** walk the folder to decide whether *Delete Folder…* is enabled.
  - Keep it always enabled, and run `FolderOps.contents` when it's chosen. If the folder isn't empty, say what's in it instead of deleting.
- **Playlist row menu.** In `Views/PlaylistSidebar.swift:2361`, add *Show in Organizer*, which opens the window at the video's folder with the video selected.

---

## 3. Confirmations

| Action | Asks first? |
|---|---|
| New folder, rename, move within a volume | No. Instant and reversible |
| Move across volumes | Yes, with the total size: *"Copy 4 videos (6.2 GB) to “NAS”? The originals are removed once each copy has moved."* |
| Tagged videos leaving their share | Yes. The phase 2 warning, via `moveFiles(_:into:)` |
| Move to Trash | Yes, as today |
| Delete an empty folder | Yes |

---

## 4. Out of scope
- Inline editing of names in the outline.
- Multiple roots at once.
- Undo.
- Managing non-video files: they're summarised, never listed for action.

---

## 5. Tests

Create `Tests/test_folder_tree.swift` and its runner, and add a line in `Tests/run.sh`.

| # | Check |
|---|---|
| 1 | `FolderTree.build`: nested folders; recursive counts; dot-directories skipped; a discard folder skipped; natural order (`clip2` before `clip10`) |
| 2 | `isEmpty` is true for a folder with only clutter and empty subfolders; false for one with an `.srt` |
| 3 | `listing(of:)` lists videos and non-clutter other files, and is not recursive |
| 4 | `FileOps.move` with `progress` reports each file, in order; `shouldStop` returning true after the first file stops cleanly, with the rest untouched and the report saying so |
| 5 | `moveFiles(_:into:)` warning logic: the paths that leave a share are found. Test the pure helper, for example move `AppModel.share(of:)` into the model layer if needed |

**Views aren't unit-tested here.** The app build (`xcodebuild … build`) must succeed with no new warnings.

---

## 6. Done when
- Every check passes, and the full suite and the app build pass.
- `features/PROGRESS.md` is updated.
- The README bullet for the feature and the Help window mention the Organize window.
- **Hand-test list for the user:**
  1. *File ▸ Organize Folders…* (⌥⌘O) opens at the playing folder.
  2. New Folder, then Rename it, then drag two videos into it; check their tags stayed.
  3. Rename a folder that another profile tagged videos in; open that profile and check nothing is missing.
  4. *Delete Folder* is disabled for a folder with a `.srt`, and works once the folder is empty.
  5. Move 20 videos between the Mac and the NAS and watch the progress, then press Stop half-way; what moved and what didn't should both be intact.
  6. Sidebar: right-click a pinned folder, then choose *Organize…*.
