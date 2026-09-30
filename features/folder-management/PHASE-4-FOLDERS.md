# Phase 4: folder operations (engine, no new UI)

**Read `README.md` in this folder first.** Its rules apply here, especially rule 3: never delete a folder recursively.
**Covers:** R1, R2 (folders), folder moves, and R5.
**Depends on:** phases 1 and 2 (done), and phase 3 (the `skipping:` walks and generalised `apply`).
**No Apple TV change.**

This phase builds the operations and their tests. The window that uses them is phase 5. You may add *minimal* menu hooks to try them, but that isn't required.

---

## 1. Operations to add

Put them in a new **`Model/FolderOps.swift`**, and add it to `Tests/model_sources.sh`. It's `@MainActor`, with file work in `Task.detached`, the same pattern as `FileOps`. Each returns a `FileOps.Report`.

```swift
static func makeFolder(in parent: String, named: String? = nil) async -> FileOps.Report
static func renameFolder(_ path: String, to name: String, library: Library) async -> FileOps.Report
static func moveFolder(_ path: String, into parent: String, library: Library) async -> FileOps.Report
static func deleteFolder(_ path: String, library: Library) async -> FileOps.Report
static func contents(of folder: String, skipping: [String] = []) -> FolderContents   // nonisolated, blocking
static func validateName(_ name: String, isFolder: Bool, currentExtension: String? = nil) -> String?  // nil = OK, else why not
```

Also use `validateName` in the existing `FileOps.rename`, which today checks only empty and `/`.

### 1.1 Name rules, via `validateName`

| Rule | Why |
|---|---|
| Trim leading and trailing whitespace first | Finder does |
| Not empty, not `.` or `..`, no `/`, no `:` | POSIX, and Finder shows `:` as `/` |
| **Must not start with `.`** | The scanner skips dot-names, so the item would vanish from the library |
| Not `.FolderVideoPlayer` | Reserved: the app's NAS data lives there |
| At most 255 bytes in UTF-8 | Filesystem limit |
| A video whose new extension isn't in the global `videoExtensions` (`Model/Paths.swift`) | Refused; it would drop out of the library. Keep the existing rule that a name with no extension keeps the old one |

### 1.2 Create a folder
- `createDirectory(atPath:withIntermediateDirectories: false)`.
- With `named == nil`, use "untitled folder", then "untitled folder 2" and so on.
- Fail if the name exists. There's nothing to relocate.

### 1.3 Rename or move a folder

Both go through one private function, `relocateFolder(from:to:library:)`.

**Guards**, checked before anything moves; refuse with a clear reason:
- **The same volume only.** Compare the `URLResourceValues.volumeIdentifier` of the source and the destination parent. Otherwise: *"Folders move within one drive only. Move the videos inside instead."* Make the check a `static var sameVolume: (String, String) -> Bool` so the tests can replace it.
- Not into itself or a descendant: `PathMap(from: path, to: path, isFolder: true).map(dest) != nil`.
- Not a volume root (`/Volumes/X`), not `/`, not the home folder.
- Not `.FolderVideoPlayer`, and not a folder that **contains** one (that's a share root).
- The target name must be free, **unless** it's the same folder under another capitalisation (`FileOps.sameFile`). That's a case-only rename, and `FileOps.moveFile` already handles it through a scratch name.

**Steps:**
1. `RelocationJournal.begin(PathMap(from: old, to: new, isFolder: true))`.
2. `FileOps.moveFile(old, to: new)`, detached. A same-volume folder move is one atomic `rename`, instant even over SMB for thousands of files.
3. `landed = FileOps.onDisk(new)`.
4. **Expand to per-file moves.** Take the union of:
   - `Scanner.scan(landed)`, each path mapped back to its old path by swapping the prefix. Run it detached, because it's a walk;
   - every key the library holds **under the old prefix** that the walk didn't find: tags, facts, watch, progress, hidden, prints. These are orphans; they move with the folder too. Add `Library.keys(under folder: String) -> Set<String>`.
5. **Ring 1, in a batch** (§2). Every per-file move through the `moveTags` logic, **plus** the folder-level lists (§3).
6. `library.saveTags()` and `library.save()`, once.
7. `await ProfileRelocation.spread(perFileMoves, library:)`, which covers rings 2 and 3 for the videos.
8. **Ring 3 pins** (§3.3).
9. `RelocationJournal.end`.

**Crash recovery.** `Library.recoverRelocations` today calls `moveTags(from:to:)` even for a folder entry, which is harmless but does nothing useful. Make it route `isFolder` entries to a `FolderOps.finishRelocation(_ map:, library:)`, which does steps 4–8. Use the same function in step 4 onwards of a normal move, so there's one code path.

---

## 2. Batching (required: this is where a folder rename gets slow)

A folder can hold thousands of videos. Today each `moveTags` call writes `tags.json`, `readings.json` and `watch.json`. Through the hook, `AnalysisStore.move` writes `marks.json`, and the journal runs one SQLite statement. At 5,000 videos that's tens of thousands of file writes on the main actor.

**Build a batch path:**
- **`Library.moveTags(_ moves: [PathMap])`.** Apply every per-key move in memory, then save each store **once**. The simplest way: a private `batching` flag that makes `saveTags`, `saveFacts`, `saveWatch` and `saveProvenance` defer to one flush at the end. **`recordSharedEdit` must still record every edit**, so every move still reaches the share.
- **A batch hook next to `pathMoved`:** `var pathsMoved: (([(String, String)]) -> Void)?`. Wire it in `FolderVideoPlayerApp.swift` to batch methods that save once: `AnalysisStore.move(_ pairs:)`, `SuggestionStore.move(_:)`, `MomentStore.move(_:)`, `EvidenceJournal.moveTranscripts(_:)` in **one SQLite transaction**, `MediaCache.move(_:)`, `VideoRotation.move(_:)`, `PlaybackController.moveTrackChoices(_:)`.
- **Keep the single-file `moveTags(from:to:)`** as a batch of one, so phase 1's behaviour and tests are unchanged.

**Target, tested in §6 check 9:** carrying 2,000 tagged keys under one folder takes **under 2 seconds** on the main actor, and `tags.json` is written **once**.

---

## 3. Folder-level lists

These are keyed by **folder**, not by video, so the per-file carry doesn't reach them.

### 3.1 This Mac, every profile

Add `Library.relocateFolderLists(_ map: PathMap)` and `Library.forgetFolderEverywhere(_ folder: String)`. Both apply the change with `map.map(_:)` (prefix at the `/` boundary) to:
- `pinned` and every profile's entry in `pinnedByProfile` (private to `Library`, so do it inside `Library`); set `pinsDirty` so the pins publish;
- `recent` and every entry in `recentByProfile`;
- `scans[].folders` (`DupeScan`);
- `discardFolders` values;
- `session?.root`;
- **every bundle's `maintenance.json`:** `settings.folders`, the keys of `known`, queue item paths, and `failed` keys. Use `ProfileBundle.file(in: slug, "maintenance.json")`. The **active** profile's copy is held in memory by `MaintenanceWorker` (app target). Add `MaintenanceWorker.followRelocation(_ map:)` and `forgetFolder(_:)` and call them from the app side.

### 3.2 Playback
- If `PlaybackController.root`, or the playing item, is under the old folder, remap it. Add `PlaybackController.followRelocation(_ map: PathMap)`, which remaps `root`, the playlist entries and the current path, and then `refreshAfterFileChanges()`.
- A local file keeps playing after a rename. If the item fails, reload it at its resume point.

### 3.3 Ring 3: pins
- `pins.json` holds share-relative **folders**.
- Extend `ProfileRelocation.apply` so a **folder** relocation also re-keys every person's `pins.json` by prefix, under their lock. Skip the profile in force, whose own pin sync sends the change.
- For every other bundle's `shared-extras.json`, re-key `pinBase[share]` the same way, so that profile's next pin merge doesn't see a false change.

---

## 4. Delete a folder: zero files only (R5)

Put this in a new file, **`Model/FolderDelete.swift`**, kept small so the code guard in §6 check 11 is easy to write.

### 4.1 `contents(of:)`: what's inside, including hidden files

Walk with `FileManager.enumerator` **without** `.skipsHiddenFiles`, and return:

```swift
struct FolderContents {
    var videos: [String]        // relative paths
    var otherFiles: [String]    // relative paths — anything not clutter, hidden files included
    var clutter: [String]       // files the Mac or NAS made
    var folders: [String]       // every subfolder, deepest first
    var isEmpty: Bool { videos.isEmpty && otherFiles.isEmpty }
}
```

**Clutter**, which doesn't count:
- the file names `.DS_Store`, `.localized`, `Icon\r`, `Thumbs.db` (any case) and `desktop.ini`;
- any `._*` file (AppleDouble);
- **everything under** a folder named `@eaDir` (Synology) or `.@__thumb` (QNAP). The NAS's indexer writes these wholesale.

**Everything else counts**, including `.srt`, `.nfo`, `.jpg` and a dotfile a person put there. The app never shows those files, so deleting them silently is exactly the loss R5 exists to prevent.

### 4.2 `deleteFolder`: three layers, each sufficient on its own

1. **UI (phase 5).** *Delete Folder* is disabled unless `contents(of:).isEmpty`, and the status line says why: *"Holidays holds 12 videos and 3 other files."*
2. **Preflight at click time.** Call `contents(of:)` **fresh**, never from a cache, and refuse if it isn't empty.
3. **The filesystem.**
   - **Unlink** each clutter **file** (`unlink(2)`, or `removeItem` only after checking it isn't a directory).
   - Then **`rmdir(2)`** each folder, deepest first, ending with the folder itself. `rmdir` refuses a folder that isn't empty, so a file another device adds in between blocks the delete harmlessly.
   - On `ENOTEMPTY`: walk again. If the only newcomers are clutter (Finder recreating `.DS_Store`), remove them and retry **once**. Otherwise stop and report exactly what appeared.
   - Some folders may already have been removed. That's fine; they were empty.

**Guards:**
- Never the organizer's root. The UI passes it; also accept an optional `root:` argument and refuse it.
- Never a volume root, `/`, the home folder, `.FolderVideoPlayer`, or a folder containing one.
- **Never `FileManager.removeItem` on a directory.** Never send a folder to the Trash either: the Trash accepts folders that aren't empty.

**Afterwards:** `library.forgetFolderEverywhere(folder)` (§3.1), and ring 3 drops the folder and anything under it from every person's `pins.json`.

---

## 5. Out of scope
- Cross-volume folder moves: refused (a user decision).
- Undo for folder operations.
- Inline rename UI (phase 5).
- Merging two folders when the target name exists: refuse instead.

---

## 6. Tests

Create `Tests/test_folder_ops.swift` and its runner, and add a line in `Tests/run.sh`. For rings 2 and 3, reuse the two-Mac and NAS setup from `Tests/test_profile_relocation.swift`.

| # | Check |
|---|---|
| 1 | `validateName`, one line per rule in §1.1 |
| 2 | `makeFolder` gives "untitled folder", then "untitled folder 2"; an existing name is refused |
| 3 | `renameFolder(Clips → Trips)`: tags, progress, hidden and watch for videos **including those in subfolders** follow. **`Clips 2019/` is untouched** |
| 4 | An orphaned key under the old folder (tagged, but its file is already gone) moves too |
| 5 | Pinned and recent for the active **and** another profile, scans, discard folders, the session root, and both profiles' `maintenance.json` folders all follow |
| 6 | Rings 2 and 3: another bundle's tags, and another person's `tags.json` **and `pins.json`**, follow. That person's `devices` are untouched |
| 7 | `moveFolder` into a sibling works. Into itself or a descendant: refused. Cross-volume, with the stubbed `sameVolume`: refused, and nothing moves |
| 8 | Case-only folder rename (`clips` → `Clips`) |
| 9 | **Batching:** 2,000 tagged keys under a folder carry in under 2 s, and `tags.json` is written once (count writes via its mtime or a test hook) |
| 10 | Journal recovery: move a folder by hand with a journal entry → `recoverRelocations` routes it to `finishRelocation`, and everything follows |
| 11 | **Code guard:** `FolderDelete.swift` source has no `removeItem(` applied to a folder (e.g. exactly one `removeItem` or `unlink`, guarded by an is-not-a-directory check) and uses `rmdir(` |
| 12 | Delete refused for: a video; an `.srt`; a hidden dotfile a user put there. The folder and every file are still there afterwards |
| 13 | Delete allowed when there's only clutter (`.DS_Store`, `._x`, `Icon\r`, `@eaDir/SYNO_x.jpg`) and empty subfolders. Everything is gone afterwards |
| 14 | **The race:** a file created after preflight and before removal (inject a hook between the two) → `rmdir` fails, **nothing** that isn't clutter is deleted, and the report names the newcomer |
| 15 | After a delete, the folder is gone from pinned and recent (every profile), scans, maintenance, discard folders, and another person's `pins.json` |

**Mutation-check:**
- Replace `rmdir` with a recursive remove and check 14 must fail.
- Drop the orphan union and check 4 must fail.
- Drop `relocateFolderLists` and check 5 must fail.

---

## 7. Done when
- Every check passes, and the full suite and the app build pass with no new warnings.
- `features/PROGRESS.md` is updated.
- **Hand-test list for the user**, if phase 5 isn't there yet: offer a temporary Debug-only menu item, or leave the hand test for after phase 5.
