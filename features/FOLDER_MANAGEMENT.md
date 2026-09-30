# Folder management: design and plan

**Status:** design only, nothing implemented.
**Target:** FolderVideoPlayer (this repo) after 1.1.24, plus one optional Apple TV change.
**Written:** 2026-09-30.
**Supersedes** the earlier plan written against the retired PyObjC build (`~/FolderVideoPlayer/FOLDER-MANAGEMENT-PLAN.md`). Its decisions carry over; its NAS "moves ledger" is dropped, because the shared `tags.json` already records moves (§4).

File and line references are to `main` at `3d72820`.

---

## 1. What is being asked

| # | Requirement |
|---|---|
| R1 | Create folders |
| R2 | Rename folders and video files |
| R3 | Move videos between folders easily (drag and drop, *Move To…*). Subtitle files move with them |
| R4 | Delete video files (still allowed) |
| R5 | Delete a folder **only when it holds zero files**. Files the Mac or NAS create by themselves don't count |
| R6 | Nothing the library knows about a video is lost: tags, stars, readings, resume position, watch state, moments, transcripts, Safe/NSFW marks, hidden status |
| R7 | **Every tag profile follows.** When Richard moves a video that Jean also tagged, Jean's profile is updated to the new location too, even though it isn't Richard's. When Jean opens her profile, on any Mac or on the Apple TV, nothing is missing |
| R8 | Tags on a video in the Trash are kept, but **don't show anywhere while it's in the Trash**. Put Back brings them back |

---

## 2. What 1.1.24 already has, and what's missing

**Already built.** A move is handled in one place, `Library.moveTags` (`Model/Library.swift:1044`), and the plan builds on it.

| Piece | Where |
|---|---|
| Rename a video, move videos to a folder, move to Trash (or to a nominated folder on a NAS with no Trash), gather a tag into a folder | `Model/FileOps.swift` |
| A move carries: tags and stars, readings (facts), watch state, transcripts and moments (via the `pathMoved` hook), resume position | `FileOps.carryBookkeeping` → `Library.moveTags` → `FolderVideoPlayerApp.swift:112` |
| A move is recorded for the NAS as a `.move` edit on the shared `tags.json` | `Library.recordSharedEdit` (`TagSharing.swift:270`) |
| Each person's `tags.json` on the NAS, with a record of moved and removed paths (`gone`, kept 60 days) and a lock every device honours | `Model/SharedTagFile.swift` |
| Row menu: *Rename…*, *Move to Folder…*, *Move to Trash…* | `Views/PlaylistSidebar.swift:2361` |
| *Find Missing Files* repairs moves made outside the app, by name | `Model/MovedScan.swift`, `Views/MissingFilesWindow.swift` |

**Missing, or wrong:**

| # | Gap | Effect today |
|---|---|---|
| G1 | No create, rename, move or delete for **folders** | R1, R2 and R5 are not possible |
| G2 | A move reaches **only the profile in force**. `moveTags`, `recordSharedEdit` and the `pathMoved` hook all act on the active profile. Other bundles in `profiles/` and other people's folders on the NAS are never touched | **Exactly the Richard and Jean problem.** Jean's tags on moved videos go missing |
| G3 | The **hidden** flag isn't carried (`hidden` is keyed by path; nothing in `FileOps` or `moveTags` touches it) | A hidden video that's renamed or moved **reappears in ordinary browsing**. A privacy bug |
| G4 | Not carried even for the active profile: Safe/NSFW marks and machine verdicts (`AnalysisStore`), suggestion accept/reject verdicts (`SuggestionStore`), tag provenance (`TagProvenance.move` exists but is never called), the duplicate index and spared copies, rotation and subtitle/audio choices (UserDefaults), the maintenance queue | Those judgements are orphaned by any move |
| G5 | **Trash forgets the tags.** `dropBookkeeping` → `forgetPath` sends `.remove` to the NAS | Contradicts R8: Put Back returns an untagged video |
| G6 | **Case-only rename refused.** `FileOps.rename` checks `fileExists(target)` (`FileOps.swift:110`), which is true on a case-insensitive volume | `clip.mp4` → `Clip.mp4` fails with "already in that folder" |
| G7 | Keys use the **typed** name, not the name as stored on disk | Narrower than first thought. Swift's `String` compares by Unicode meaning, so the tags themselves are safe. But SQLite (transcripts, keyed by absolute path) and `NSString` compare bytes, so a typed NFC name against an NFD one on a NAS still misses there |
| G8 | `FileOps` is `@MainActor` and does its file I/O there | Moving gigabytes to or from the NAS freezes the window |
| G9 | Subtitle sidecars are left behind by a rename or move | VLC and the TV stop finding `clip.srt` |

---

## 3. The core: one relocation, applied everywhere

### 3.1 `PathMap`

A small, pure, testable value:
- It holds `old → new`, and whether the path is a folder.
- It answers "what is this key now?" for both key forms the app uses: `Paths.tagKey` (share-relative or absolute) and absolute paths.
- **A folder maps by prefix, with the `/` boundary.** Renaming `Clips` must not touch `Clips 2019/…`. This is the classic prefix bug, and it gets its own test.
- Every store gets a `move(using: PathMap)`. Several already have a single-key move that can be reused: `WatchLog.move`, `MomentBook.move`, `MetadataFacts.move`, `TagProvenance.move`, `EvidenceStore.moveTranscript`, `MaintenancePlanner.move`.

### 3.2 Three rings, one relocation

A relocation is applied outward in three rings. Today only part of ring 1 exists.

| Ring | What | Stores |
|---|---|---|
| **1. This Mac, shared by every profile** | Things the Mac knows regardless of who's looking | `state.json`: `progress`, `progressSeen`, `session`, **`hidden`** (G3), `discardFolders`, dupe `scans`, `sparedDupes`; `fingerprints.json`; `durations.json`; `analysis.json` (machine verdicts); UserDefaults rotation and subtitle/audio choices; posters in `thumbs/` and on the NAS |
| **1. The profile in force** | Today's carry, plus G4 | `tags.json`, `readings.json`, `watch.json`, `moments.json`, `evidence.sqlite`, `suggestions.json`, `marks.json`, `maintenance.json`, tag provenance, pinned and recent folders |
| **2. Every other profile on this Mac** | **New.** Profiles nobody has open right now | The same per-profile files, in each `profiles/<slug>.fvpprofile/` (`ProfileBundle.slugs()`); `pinnedByProfile` and `recentByProfile` in `state.json`; each bundle's `shared-sync.json` (its `base` and `pending` are remapped too, so that profile's next sync is quiet rather than re-sending everything) |
| **3. Every person on the NAS** | **New.** Every folder under `<share>/.FolderVideoPlayer/`, including people who have never used this Mac | `tags.json` (a `.move` edit under that person's `tags.lock`); `facts.json`, `pins.json` and `transcripts.json` (keys and folder entries remapped under the same lock) |

There's precedent for ring 2: the one-time readings migration already rewrites every profile's file, "visited or not" (`unsavedProfileTagFiles`, `Library.swift:881`).

### 3.3 The sequence

```
1. Preflight    names, guards and conflicts (§5); nothing touched yet
                a move that takes tagged videos off their NAS: warn, naming the people (§4.4)
2. Journal      append the relocation to support/relocations-pending.json
3. Filesystem   move it, with its subtitle files, off the main thread (G8)
4. Read back    the real new name, from the destination listing (G7)
5. Ring 1       on the main actor, then save
6. Ring 2       each other bundle: read, remap, write
7. Ring 3       each person folder on that NAS: lock, read, apply, write, unlock (background)
8. Clear        remove the journal entry, once rings 5–7 have all landed
```

- **The journal makes a crash harmless.** At launch, an entry whose `new` exists and `old` doesn't gets steps 5–7 replayed. Each step is idempotent: `SharedTagFile.move` ignores an `old` that has no entry any more ("already moved by someone else").
- **A NAS lock that stays busy** (another device mid-save) keeps the ring 3 part in the journal, and it's retried on the next sync. So a person folder can be late, but it isn't skipped.
- **Undo** of a move or rename is the reverse relocation through the same path, rather than the tags-and-facts snapshot `rememberForUndo` keeps today. That covers every ring.

---

## 4. Every tag profile follows (R7)

### 4.1 Why the existing NAS format already does most of the work

Each person has **one** `tags.json` per share, and every device treats it as the master copy:
- **The Apple TV** reads it fresh whenever it opens, or opens a tag or the tag panel. It stats the file and re-reads it if it changed (`TagStore.refreshIfChanged`, in the TV repo). It doesn't keep a private copy.
- **A Mac** replaces its own tags for that share with the file's contents on every sync (`applySync`, `TagSharing.swift:188`).
- **The lock** (`tags.lock`) is honoured by both apps, so Richard's Mac can edit Jean's file safely while her TV is saving.
- **The `.move` edit** already exists, and records `gone[old] = {to: new}` so a late edit follows the move instead of bringing the old path back.

So the only thing missing for R7 is **someone applying the move to every person's file**, not only to the active profile's. That's ring 3. No new file format, no ledger, and no Apple TV change for tags.

### 4.2 What Richard's Mac writes into each person's NAS folder

For every folder `<share>/.FolderVideoPlayer/<person>/`, Jean's included:

| File | Change | Why |
|---|---|---|
| `tags.json` | One `.move(old, new)` per tagged video affected. A folder rename becomes one edit per tagged video under it | Jean's tags follow on every device |
| `pins.json` | Folder entries remapped, by prefix | Otherwise Jean's pinned folder on the TV's Home screen stops working, and so does her Mac's sidebar pin |
| `facts.json` | Keys remapped | Her dates, cameras and places stay attached |
| `transcripts.json` | Keys remapped | Her transcripts follow |
| `tags-<device>.json` (old per-device files, only while an old writer is still active) | Left alone | The existing switch-over logic already follows `gone` when it reads them (`editsFromLegacy`) |

**Only locations change.** No tag, star, reading, pin or transcript is added, removed or reworded, in anyone's file.

### 4.3 How Jean's devices catch up

| Jean's device | What happens | Needs a new version? |
|---|---|---|
| **Apple TV** | The next time she opens the app or a tag, it re-reads her `tags.json` and `pins.json` with the new paths | **No** (§4.4 has one small edge case) |
| **Her own Mac, tags** | Its next sync adopts her `tags.json`, including the moves | **No.** 1.1.24 already does this |
| **Her own Mac, Mac-only data** (watch state, moments, resume position, Safe/NSFW marks, suggestion verdicts, hidden status) | These live only on her Mac, so they can't be rewritten from Richard's Mac. **New:** when her Mac syncs and sees a `gone` entry with a `to` for a key it holds data for, and `old` is missing while `new` exists, it runs the same relocation locally (rings 1 and 2) | Yes. Until she updates, *Find Missing Files* can repair them |
| **A new device, or Jean on Richard's Mac** | Reads the rewritten files | No |

### 4.4 Limits

| Case | Result |
|---|---|
| Moving a tagged video **off its NAS** (to a local disk or another share) | Other people's tags can't follow: they can't see the new location. **The app warns first, naming them, and lets Richard continue** (decided). On the NAS it's recorded as a `.remove`, as today, and each person's tags for it are parked on Richard's Mac (§5.4), so moving it back restores them |
| Jean's Mac offline for more than 60 days (`SharedTagFile.keepFor`) | Her tags still follow, because her Mac adopts the file. Her Mac-only data can't replay from `gone` any more; *Find Missing Files* repairs by name |
| **TV edge case:** Jean tags a video on the TV in the seconds between Richard's move and her TV's next refresh | Her `.set(old, …)` brings the old path back, as a missing video carrying that tag. **Optional TV fix** (phase 6): before sending a `.set`, follow `gone` if the path no longer exists |
| A person folder Richard's NAS account can't write to | Reported in the result. That person's own devices still catch up through `gone` once someone with access writes the move |
| Moves made in Finder, outside the app | As today: *Find Missing Files* |

### 4.5 Walkthrough

1. Richard drags `Holidays/` onto `Trips/` in the Organize window.
2. His Mac moves the folder on the NAS: one atomic rename, instant even for thousands of files.
3. **Ring 1:** Richard's tags, stars, readings, watch state, moments, transcripts, marks, resume positions and hidden flags now point at `Trips/Holidays/…`. So do his pins and recent folders.
4. **Ring 2:** the same happens in every other profile bundle on his Mac, Jean's included if she has one there.
5. **Ring 3:** for every person folder on the NAS (Richard, Jean, …): lock → `.move` each of their tagged videos under `Holidays/` → remap `pins.json`, `facts.json` and `transcripts.json` → write → unlock.
6. Jean turns on the Apple TV: her tags and her pinned folder are at `Trips/Holidays/`. **Nothing is missing.**
7. Jean opens the app on her own Mac: its sync adopts her `tags.json`. With the new version, it also relocates her watch state and moments from the `gone` entries.

---

## 5. Filesystem rules

### 5.1 Create a folder (R1)
- `createDirectory(withIntermediateDirectories: false)`. Fail if the name exists.
- Finder-style: "untitled folder" (then " 2", " 3"…), with its name open for editing.

### 5.2 Rename or move a folder (R2)
- **Same volume:** one atomic rename, then one prefix `PathMap` through all three rings.
- **Guards:**
  - never into itself or a descendant
  - never a volume root
  - never `.FolderVideoPlayer`, or a folder that contains one (that's a share root)
  - never outside the organizer's root
- **Across volumes:** not in v1 (assumed; see §9). The message says *"Move the videos inside instead."*

### 5.3 Rename or move videos (R2, R3)

The existing `FileOps.move` and `FileOps.rename` stay the entry points, with these changes:
- **Never overwrite.** Keep `freeName` (" (2)") for moves, and `moveItem`, which refuses an existing target.
- **Case-only rename (G6):** detect it when the source and target are the same file (same inode), and rename through a hidden temporary name.
- **Unicode (G7):** after the move, list the destination, match the entry with NFC normalisation, and remap to **that** string.
- **Subtitle sidecars (G9, decided):** reuse `SubtitleFile.sidecars(for:in:)` (`MediaTracks.swift:97`), which already finds `clip.srt` and `clip.en.srt`.
  - Sidecars are renamed with their video (`clip.en.srt` → `beach.en.srt`).
  - A clashing sidecar makes the whole video a clash, so a video never arrives without its subtitles.
- **Off the main thread (G8):** the file work runs in a background task with a progress sheet and *Stop*. Each finished file hops back to the main actor to run rings 1 and 2, so *Stop* leaves the stores matching the disk.
- **Across volumes:** Foundation's `moveItem` copies and then deletes. Keep it, but verify byte count and fingerprint (`Fingerprints.swift`) before the source goes.
- **The playing video** can be moved: note its position, move it, relocate, and reload it at the same position.

### 5.4 Delete videos (R4, R8)

The Trash, or the nominated folder on a NAS with no Trash, as today. The difference is what happens to the tags:
- **Park, don't forget (G5).** Before the file moves, record every profile's and every person's tags for it in `support/trashed-tags.json`: `{key: {when, where, tags: {slug: [names]}}}`. That covers ring 2 bundles and ring 3 person folders.
- **Then hide it everywhere.**
  - Local stores drop the tags, so nothing shows: tag lists, counts, Favorites, stars, smart collections, the filter.
  - The NAS gets `.remove` for each person, as today, so the Apple TV drops it too.
  - Readings, watch state, moments and resume position stay where they are, keyed to the same path. They're invisible without the file and return with it.
- **Put Back brings everything back.** When the file is at its original path again:
  - Each parked profile gets its tags back.
  - Each person on the NAS gets `.set(path, theirTags)`. The existing format treats *"tags on a path in `gone`"* as bringing it back.
  - The check runs when a folder is scanned, when the Organize window walks its tree, and once in the background at launch.
- **Trash emptied:** the parked entry stays, invisible. *Find Missing Files* offers to forget it.
- **Discard folders are not library.** A "trashed" video in a nominated folder inside the library would be listed straight back. `Scanner` and the Organize tree skip every folder in `discardFolders`.

### 5.5 Delete a folder: the zero-files rule (R5)

**A folder can be deleted only if no file exists anywhere beneath it.**

| Content | Blocks the delete? |
|---|---|
| A video | **Yes** |
| Any other file (`.srt`, `.nfo`, `.jpg`, a dotfile somebody put there) | **Yes.** The app never shows these, so deleting them silently would be exactly the loss this rule prevents |
| Empty subfolders | No. Removed together, deepest first (assumed; see §9) |
| Files the Mac or NAS create by themselves: `.DS_Store`, `._*`, `Icon\r`, `.localized`, `Thumbs.db`, `desktop.ini`, `@eaDir` (Synology), `.@__thumb` (QNAP) | **No** (decided). Removed with the folder |

**Enforced in three layers.** Each is enough on its own:
1. **UI:** *Delete Folder* is disabled, with the reason: *"Holidays holds 12 videos and 3 other files."*
2. **Preflight:** a fresh walk at the moment of the click, never a cached count.
3. **The filesystem:** folders are removed only with `rmdir(2)`, deepest first. The OS refuses a folder that isn't empty, so a file another device adds in between blocks the delete harmlessly.

**Never `FileManager.removeItem` on a folder in this feature.** It deletes recursively, which is exactly what R5 forbids. A test enforces this (§7). Folders are never sent to the Trash, because the Trash accepts folders that aren't empty.

**Afterwards:** the folder leaves pinned and recent (every profile), dupe scans, maintenance folders and discard folders. Ring 3 then remaps `pins.json` for every person.

### 5.6 Names

| Rule | Why |
|---|---|
| Not empty, no `/`, no `:` | POSIX; Finder shows `:` as `/` |
| **Must not start with `.`** | The scanner skips dot-names, so the item would vanish from the library |
| `.FolderVideoPlayer` is reserved | The app keeps its NAS data there |
| Under 255 bytes in UTF-8 | Filesystem limit |
| A video's extension changed to one the app doesn't list | Warn. It would drop out of the library |

---

## 6. User interface

**Organize window:** *File ▸ Organize Folders…*, `Window("Organize", id: "organize")`.
- **Root picker:** the playing folder, Pinned, Recent, *Choose…*.
- **Left pane:** a folder tree (`OutlineGroup`) with recursive video counts, *empty* shown dimmed, and discard folders left out.
  - Counts come from one background walk, trickled the way `PROGRESS.md` asks for NAS work.
- **Right pane:** the selected folder's videos.
  - Name, size, date and tags, with **CC** when subtitle files travel with a video.
  - Other files are summarised in one line, which explains why a folder can't be deleted.
- **Drag and drop:** videos onto a folder, and a folder onto a folder. Refused drops show as refused.
- **Finder's keys:** ↩ rename, ⇧⌘N new folder, ⌘⌫ Trash, ⌥⌘⌫ delete an empty folder.
- **Status line** after each operation, e.g. *"Moved 4 · updated 3 tag profiles."*

**Sidebar:** Pinned and Recent folder rows get *New Folder…*, *Rename Folder…*, *Delete Folder* (enabled only when empty) and *Organize…* in their context menus.

**Playlist:** *Rename…*, *Move to Folder…* and *Move to Trash…* are already in the row menu (`PlaylistSidebar.swift:2361`). They move onto the new engine.

**Confirmations:**

| Action | Asks first? |
|---|---|
| Rename, new folder, move within a volume | No |
| Move across volumes | Yes, with size, and the promise that originals are removed only after each copy is verified |
| Tagged videos leaving their NAS | Yes, naming the people whose tags can't follow |
| Move to Trash | Yes, as today |
| Delete an empty folder | Yes |

---

## 7. Tests

The house pattern is in `PROGRESS.md` §How to build and test:
- `Tests/test_folder_ops.swift`, `Tests/run_folder_ops.sh`, and a line in `Tests/run.sh`
- **every new `Model/` file also goes into `Tests/model_sources.sh`**
- a temporary support directory (`FVP_SUPPORT`), and `Paths.volumes` pointed at a temporary fake NAS

| # | Check |
|---|---|
| 1 | `PathMap`: exact and prefix, with the `/` boundary (`Clips` vs `Clips 2019`), both key forms |
| 2 | **Ring 1:** a rename carries every store in the §3.2 table, including hidden, marks, suggestions, provenance, prints and spared copies (G3, G4) |
| 3 | **Ring 2:** a second profile bundle on the same Mac, never opened in the test, has its tags, readings, watch, moments, pins, recents and `shared-sync.json` remapped |
| 4 | **Ring 3:** a fake NAS with `richard/` and `jean/`. After a folder rename, both `tags.json` files hold the new keys and a `gone` record, and **tag names are byte-identical**. `pins.json`, `facts.json` and `transcripts.json` are remapped |
| 5 | **Richard and Jean, start to finish:** Jean's side (a second support directory reading the same fake NAS) syncs → zero missing files, tags intact, and watch state relocated from `gone` |
| 6 | **The TV reader:** decoding Jean's rewritten files with the TV's `SharedTagFile` rules (same format, copied code) finds her tags and pins at the new paths |
| 7 | A lock held by "another device" keeps ring 3 in the journal; the next sync completes it |
| 8 | Journal recovery: a crash after step 3 is completed on relaunch; replaying twice changes nothing |
| 9 | Subtitle sidecars move and rename with their video; a clashing sidecar stops the whole video |
| 10 | Case-only rename works (G6); an NFD-named folder keys to the on-disk string (G7) |
| 11 | **Trash:** tags leave every surface and every person's `tags.json`; Put Back restores them for every profile and person |
| 12 | A discard folder inside the library isn't scanned |
| 13 | **Folder delete:** a video, an `.srt` or a dotfile → refused; only clutter or empty subfolders → deleted; a file added after preflight → `rmdir` fails and nothing is deleted |
| 14 | **The code guard:** the source finds no `removeItem` applied to a folder path in the new folder operations |
| 15 | Leaving a NAS: the warning names exactly the people who tag those videos |

The gate for every phase is `sh Tests/run.sh` green, plus the Debug `xcodebuild` from `PROGRESS.md` building with no new warnings.

---

## 8. Phases

| Phase | Work | Done when |
|---|---|---|
| **0: Baseline** | `sh Tests/run.sh` green on `main`; Debug build OK; branch `feature/folder-management` | Recorded in `PROGRESS.md` |
| **1: Relocation engine, ring 1** | `PathMap`; journal; carry every store (fixes G3, G4); case and Unicode (G6, G7); sidecars (G9); file work off the main actor (G8) | Tests 1, 2, 8, 9, 10. **Built 2026-09-30, uncommitted, on branch `feature/folder-management`** — see "Phase 1 as built" below |
| **2: Every tag profile (R7)** | Ring 2 (every bundle), ring 3 (every person folder, under the lock), replay from `gone` on sync, the leaving-a-NAS warning | Tests 3–7, 15. **Ships together with phase 1**, so no move ever reaches only one profile again. **Built 2026-09-30** — see "Phase 2 as built" below |
| **3: Trash park and Put Back** | `trashed-tags.json`, the per-person `.remove` and `.set`, discard folders out of the scanner | Tests 11, 12 |
| **4: Folder operations** | Create, rename, move (same volume), delete-if-empty with three layers | Tests 13, 14 |
| **5: UI** | Organize window, sidebar folder menus, progress sheet, drag and drop; Help and README | Manual pass by you (per `PROGRESS.md`, the UI isn't driven here) |
| **6: Apple TV** *(optional)* | Follow `gone` before sending a `.set` for a path that no longer exists (§4.4) | TV repo tests; TestFlight build |
| **Release** | `docs/releasing.md` → `scripts/release.sh` | Version only goes up |

### Phase 1 as built (2026-09-30)

- **`Model/PathMap.swift`:** `PathMap` (file or folder, prefix at a `/` boundary, both key forms) and `RelocationJournal` (`support/relocations-pending.json`, written before each file moves, struck off after the batch saves).
- **`Library.moveTags` is the one carry.** It now also moves: resume point, `session.path`, **hidden** (G3), spared duplicates, the fingerprint entry (plus `dupesChanged()`) and tag provenance. It doesn't write `state.json`; callers save once per batch. `MovedScan` and `MaintenanceWorker` now call `library.save()` after their repairs.
- **The `pathMoved` hook** (`FolderVideoPlayerApp.swift`) now also carries: `AnalysisStore.move` (machine record + Safe/NSFW mark), `SuggestionStore.move` (verdicts), `MediaCache.move` (running time, local frames, and the share's poster when the move stays within that share), `VideoRotation.move`, and `PlaybackController.moveTrackChoices`.
- **`Library.recoverRelocations()`** runs once per launch (`AppModel.recoverRelocationsOnce`), after the hook is attached. It finishes an interrupted move, drops one that never happened, and keeps one whose share isn't mounted.
- **`FileOps.move`, `FileOps.rename` and `FileOps.gather` are `async`.**
  - The file work runs in `Task.detached` (`FileOps.shift`); the bookkeeping runs back on the main actor, one file at a time.
  - `AppModel.runFileOp` runs one operation at a time, and Trash waits for it too.
- **Subtitle sidecars** (`SubtitleFile.sidecars`) are renamed and moved with their video. `freeName(companions:)` picks a " (2)" that's free for the video *and* its sidecars, and a rename whose sidecar name is taken is refused whole.
- **Case-only rename:** `FileOps.moveFile` goes through a hidden scratch name when the target is the same inode. **On-disk spelling:** `FileOps.onDisk`, skipped for pure-ASCII names.
- **Undo** is taken when the first file actually lands, so a refused rename leaves no Undo behind.
- **Not carried, on purpose:** the maintenance queue (its own scan already sees the move and re-points itself), and a subtitle *choice* that names a sidecar file (it falls back to Automatic).
- **Tests:** `Tests/test_relocation.swift` (38 checks). 9 of them fail with the new carry disabled, which proves they test it. `Tests/main.swift` now awaits `FileOps`.

### Phase 2 as built (2026-09-30)

- **`Model/ProfileRelocation.swift`.** `spread(moves, library:)` runs after every `FileOps` batch, before the journal is struck off, and after crash recovery at launch. It does three things off the main thread: retries anything owed, then ring 2, then ring 3.
- **Ring 2, `carryIntoBundles`.** It covers every `profiles/<slug>.fvpprofile` except the one in force, and rewrites the per-video files: `tags.json` (by `moveTags`' merge rule), `readings.json`, `watch.json`, `moments.json`, `suggestions.json`, `marks.json`, and `evidence.sqlite` (`moveTranscript`).
  - **The move is queued in that bundle's `shared-sync.json` `pending`**, exactly as `recordSharedEdit` queues one for the profile in force. Its own next sync therefore sends it. That also makes it correct if ring 3 missed that person's file, which is why it's done this way rather than by re-keying `base`.
- **Ring 3, `carryOnShares`.** It covers every person folder on the share that holds a shared `tags.json`, except the profile in force (whose own sync sends its `.move`).
  - Under that person's `tags.lock`: `SharedTagFile.apply(.move)`, then `prune`, then write. Only when something moved. `devices` is never touched.
  - Then `facts.json` and `transcripts.json` are re-keyed. `SharedExtras.readJSON` and `write` are now internal so they can be reused.
  - Moves across shares or to a local disk aren't carried (they're a `.remove` in `SharedTagEdit.forMove`).
  - Folders holding only old per-device files are left alone.
  - A lock that can't be had within `lockBudget` (10 s) goes to `support/relocations-owed.json`, and `retryOwed` delivers it later.
- **`SharedTagEdit.forMove`** is the one rule for turning a move into a share edit. `recordSharedEdit` now uses it too.
- **Replay on another Mac.** `SharedTagFile.unseenMoves(seen:)` finds `gone` records this Mac hasn't looked at and follows chains. `syncShare` checks each one on disk, off the main thread: old path gone, new path there. `applySync` then runs `moveTags` for each, *after* adopting the file, so the tags are already in place and nothing is sent back. What's been seen is kept per share in `SharedSyncState.goneSeen`, an optional field, so older state files still load.
- **The leaving-a-share warning.** `AppModel.moveFiles` → `ProfileRelocation.peopleTagging` → *"“jean” tagged some of these videos… Move Anyway / Cancel"*.
- **`FileOps.replace`** (a converted copy taking the original's place) now spreads too.
- **`MediaCache.move`'s disk work** now runs on one serial queue, so a big batch or a replay trickles to the share instead of hitting it all at once.
- **Tests.** `Tests/test_profile_relocation.swift` has 37 checks: Richard's Mac and Jean's Mac as two support roots sharing one scratch NAS, plus a held lock, leaving the share, a crash, and `unseenMoves`.
  - **Mutation-checked.** With ring 3 disabled, Jean's own Mac opens with her tags still at the old path, the reported bug reproduced. Disabling ring 2 or the replay fails its own checks.
- **Not changed:** *Find Missing Files* and maintenance repairs still reach only the profile in force. They repair a move made outside the app by name, which is a guess, and a guess shouldn't be written into other people's files.

---

## 9. Decisions

**Decided by you:**
- Files the Mac or NAS create by themselves don't count as files for deleting a folder.
- File renames are included. They already exist and get fixed (G6, G7, G9).
- Subtitle files move and rename with their video.
- Trashed videos keep their tags, hidden everywhere until Put Back. This changes today's behaviour (G5).
- A tag profile is one person (Richard, Jean). Moves update every person's profile, even ones that aren't the mover's.
- Moving tagged videos off their NAS: warn, naming the people, and let the move continue.

**Found in the Apple TV code:** the TV needs no change for tags, pins or facts to follow a move. There's one optional fix (phase 6).

**Also confirmed by you (30 Sep):**
- A folder holding only empty subfolders counts as empty.
- Folders move within one volume only in v1.
- The Organize window works on one root folder at a time.
- The hidden-flag bug (G3) and the gaps in G4 are fixed as part of phase 1.

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| A store missed in a ring loses data quietly | The §3.2 inventory; tests 2–4 check every store; the journal replays |
| Editing another person's NAS files while their device saves | Their own `tags.lock`, the read-again-under-lock rule `syncShare` already follows, and a retry through the journal (test 7) |
| A NAS drops out mid-batch | Verify-then-remove across volumes; per-file hop to the main actor; the journal |
| A folder is deleted while it still holds files | Three independent layers; `rmdir(2)` only; tests 13 and 14 |
| NAS I/O flooding (the 1.1.21 launch-stall lesson) | Walks and counts trickle in the background; nothing sorts or scans the library on the main thread |
| A move by an older Mac (1.1.24) only reaches its own profile | Other people's tags still exist at the old path; *Find Missing Files* repairs them. Everyone should update before reorganising shared folders |
