# Folder management: handoff

**Read this first, then the spec for your phase.** This is everything a new agent needs to continue without the original conversation.

| Phase | What | Status |
|---|---|---|
| 1 | Relocation engine: a renamed or moved video keeps everything the app knows about it | **Done**: commit `a561833` |
| 2 | Every tag profile follows a move, on this Mac and on the NAS | **Done**: commit `d01f2a4` |
| 3 | The Trash keeps tags, hidden; Put Back restores them | **Done**: commit `7943926` |
| 4 | Folder operations: create, rename, move, delete-when-empty | **Built**, uncommitted — [PHASE-4-FOLDERS.md](PHASE-4-FOLDERS.md) |
| 5 | The Organize window and sidebar folder actions | [PHASE-5-ORGANIZE-UI.md](PHASE-5-ORGANIZE-UI.md) |
| 6 | *(optional)* Apple TV: follow `gone` before sending a `.set` for a path that no longer exists | Not specified; ask the user first |

- **Do the phases in order.** Phase 5 needs the engine APIs from phases 3 and 4.
- **Branch:** `feature/folder-management`.
- **Commit** only when the user asks.
- **Never push.**

---

## 1. What the user asked for (decided; do not re-open)

| # | Requirement |
|---|---|
| R1 | Create folders |
| R2 | Rename folders and video files |
| R3 | Move videos between folders easily (drag and drop, *Move To…*). Subtitle files (`clip.srt`, `clip.en.srt`) travel with their video |
| R4 | Delete video files (to the Trash, or to the nominated folder on a NAS with no Trash). This is still allowed |
| R5 | Delete a folder **only when it holds zero files**. Files the Mac or NAS create by themselves don't count (`.DS_Store`, `._*`, `Icon\r`, `.localized`, `Thumbs.db`, `desktop.ini`, `@eaDir`, `.@__thumb`). Empty subfolders don't count either |
| R6 | Nothing the library knows about a video is lost: tags, stars, readings, resume point, watch state, moments, transcripts, Safe/NSFW marks, hidden status |
| R7 | **Every tag profile follows.** When one person moves a video another person also tagged, the other person's profile is updated too, on every Mac and on the Apple TV |
| R8 | Tags on a video in the Trash are kept but **hidden everywhere**, and Put Back restores them |

**Also decided by the user:**
- Moving tagged videos off their NAS: warn, naming the people whose tags can't follow, then let the move continue. Built in phase 2.
- Folder moves are within one volume only (no cross-volume folder moves).
- The Organize window works on one root folder at a time.

---

## 2. How the move machinery works (phases 1 and 2)

Everything the app knows is keyed by **path**:
- `Paths.tagKey(path)` gives a share-relative key (`"NAS/clips/a.mp4"`) for a file under `Paths.volumes`, and an absolute path otherwise.
- Some stores use absolute paths instead, for example `progress` and the transcripts in SQLite.

So every change to a path must go through the machinery below.

| Piece | Where | What it does |
|---|---|---|
| `PathMap` | `Model/PathMap.swift` | One relocation: `from`, `to`, `isFolder`. `map(_:)` maps absolute paths and `mapKey(_:)` maps tag keys. A folder maps by prefix, **at a `/` boundary** |
| `RelocationJournal` | `Model/PathMap.swift` | `support/relocations-pending.json`. `begin` is written before the file moves; `end` after every ring has run |
| **Ring 1** — `Library.moveTags(from:to:)` | `Model/Library.swift` | **The one per-file carry for the profile in force.** It moves tags (plus `recordSharedEdit`), facts, watch, progress, session, **hidden**, fingerprint, spared duplicate and provenance. It calls the `pathMoved` hook, which the app wires in `FolderVideoPlayerApp.swift` to transcripts, moments, `AnalysisStore`, `SuggestionStore`, `MediaCache`, `VideoRotation` and track choices. **It does not write `state.json`; callers must `library.save()` once per batch** |
| `Library.recoverRelocations()` | `Model/Library.swift` | Finishes journal entries after a crash. Returns the finished `[PathMap]`. `AppModel.recoverRelocationsOnce` then calls `ProfileRelocation.spread` |
| **Rings 2 and 3** — `ProfileRelocation.spread(_:library:)` | `Model/ProfileRelocation.swift` | Off the main thread: retries anything owed (`support/relocations-owed.json`), then runs rings 2 and 3 |
| Ring 2 — `carryIntoBundles` | same file | Every other `profiles/<slug>.fvpprofile` on this Mac: tags, readings, watch, moments, suggestions, marks, `evidence.sqlite`. It queues `SharedTagEdit.forMove(...)` in that bundle's `shared-sync.json` `pending` |
| Ring 3 — `carryOnShares` / `apply(_:inPersonFolder:device:)` | same file | Every person folder with a shared `tags.json` on that share, except the profile in force. It takes their `tags.lock`, applies `.move` and re-keys `facts.json` and `transcripts.json` |
| `SharedTagEdit.forMove(from:to:)` | same file | The single rule for turning a move into a share edit: a `.move` within one share, a `.remove` when the video leaves it |
| `SharedTagFile.unseenMoves(seen:)` | same file | Another Mac replays `gone` records it hasn't seen, in `syncShare` and `applySync` (`Model/TagSharing.swift`). What's been seen is kept in `SharedSyncState.goneSeen` |
| `FileOps.move`, `rename`, `gather` (all `async`), `shift`, `moveFile`, `sameFile`, `onDisk`, `freeName(companions:)` | `Model/FileOps.swift` | File work runs off the main thread; bookkeeping comes back one file at a time. They never overwrite, handle case-only renames, carry sidecar subtitles, and read names back as the disk spells them |
| `AppModel.runFileOp` | `FolderVideoPlayerApp.swift` | Runs one file operation at a time, then calls `finish(report, verb)`, which refreshes the playlist and shows the report |
| `ProfileRelocation.peopleTagging` + `AppModel.confirmLeavingShare` | — | The warning shown when tagged videos leave their share |

**NAS file formats** live in `<share>/.FolderVideoPlayer/<person-slug>/`:
- `tags.json`: a `SharedTagFile`. Its `videos` field is rest-path → tags. Its `gone` field is rest-path → `{to?, at}`.
- `facts.json`, `transcripts.json`, `pins.json`, `faces.json`: see `SharedExtras`.
- Every writer holds `tags.lock` (`SharedTagDisk.lock`/`unlock`) and writes via a scratch file plus rename (`SharedTagDisk.write`, `SharedExtras.write`).

The **Apple TV** (repo `~/FolderVideoPlayerTV`) reads these files fresh each time and needs no change for phases 3–5.

---

## 3. Rules that are not optional

1. **Every path change** goes through ring 1, then `ProfileRelocation.spread`, inside a `RelocationJournal` begin/end.
2. **Never overwrite.** `FileManager.moveItem` refuses an existing target; keep it that way. For case-only renames, use `FileOps.moveFile`.
3. **Never delete a folder recursively.** No `FileManager.removeItem` on a directory in any folder-management code. Remove empty folders with `rmdir(2)` only (phase 4).
4. **Store mutation happens on the main actor; file and NAS I/O happens off it.** `Library`, the stores and `FileOps` are `@MainActor`.
5. **NAS trickle rule** (from `features/PROGRESS.md`): background work must never flood a share. Walk and stat a few at a time, and never scan or sort the whole library on the main thread.
6. **The upper part of `Model/SharedTagFile.swift`**, above `// MARK: - what this device has to say`, is copied verbatim into the TV repo. Don't change it. Anything Mac-only goes below that mark or in another file (for example `ProfileRelocation.swift`).
7. **Every new file in `FolderVideoPlayer/Model/`** must also be added to `Tests/model_sources.sh`, or the whole suite stops compiling.
8. **Don't edit source files while `Tests/run.sh` or `xcodebuild` is running.** The build fails with "input file was modified during the build".
9. **Mutation-check every new test.** Disable the feature, see the checks fail, then restore it. Phases 1 and 2 did this.
10. **The repo is public.** No real personal names in code, tests or docs (use Alex and Sam). Commit as `tangrick <40586271+tangrick@users.noreply.github.com>`, which is already set in this checkout's git config. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.
11. **The user runs the app themselves.** Build and test headlessly; do **not** launch the GUI. Give the user a short hand-test list instead.
12. **Match the house style:** long-form "why" comments, like the surrounding code.

---

## 4. Build and test

```bash
sh Tests/run.sh
```

This runs the full suite, about 4–5 minutes. The baseline after phase 2 is **2,919 checks, exit 0**.

```bash
sh Tests/run_relocation.sh
```

```bash
sh Tests/run_profile_relocation.sh
```

These two are the phase 1 and phase 2 tests.

```bash
xcodebuild -project FolderVideoPlayer.xcodeproj -scheme FolderVideoPlayer -configuration Debug -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

This is the app build, and it must succeed with no new warnings in lines you touched.

**Writing a test:**
- A test is a plain script, `Tests/test_<name>.swift`, using `@testable import FVPModel` and a local `check(name, cond, detail)`.
- Each test needs a runner, `Tests/run_<name>.sh`, copied from `run_relocation.sh`, plus one line in `Tests/run.sh`.
- For a two-Mac or NAS scenario, copy the setup in `Tests/test_profile_relocation.swift`: two scratch support roots, one scratch `Paths.volumes`, a short `ProfileRelocation.lockBudget`, and `closeProfile()` before switching `Paths.support`, because it is global.

**When you finish a phase:** add an entry to the session log in `features/PROGRESS.md` and update its row in the status table.

---

## 5. Background (optional)

`features/FOLDER_MANAGEMENT.md` is the original full design, including the rationale behind the rings, and a "Phase N as built" section for phases 1 and 2. It is **untracked on purpose**: it uses a real person's name. Read it if it's present in your checkout, but don't commit it as is.

---

## 6. A prompt to start the next agent

> Continue folder management in this repo (`~/FolderVideoPlayer-public`, branch `feature/folder-management`). Read `features/folder-management/README.md`, then `features/folder-management/PHASE-3-TRASH.md`, and implement phase 3 exactly as specified. Follow the README's rules (especially: no GUI launch, mutation-check tests, no personal names, don't commit unless I ask). Run the full suite and the app build before reporting. Report what you built, what you verified, and a short hand-test list for me.

Replace the phase number and spec file for phases 4 and 5.
