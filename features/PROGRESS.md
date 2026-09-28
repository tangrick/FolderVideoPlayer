# Feature Backlog — Implementation Progress

Working log for implementing `features/FEATURE_BACKLOG.md`. **Any agent picking
this up: read this file first, then continue from the first unchecked item.**
Update the checkboxes and the "Session log" as you go, so the next agent can
resume from here too.

## How to build and test

```bash
# model-layer tests (no Xcode project needed; builds build/tests/libFVPModel.a once)
sh Tests/run.sh                       # full suite (slow; some stages skip without models)
sh Tests/run_transcript_edit.sh       # just the transcript editor/export tests (added P1)

# app build (verifies the SwiftUI views compile)
xcodebuild -project FolderVideoPlayer.xcodeproj -scheme FolderVideoPlayer \
  -configuration Debug -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build

# release (see docs/releasing.md): tests, Developer ID archive, DMG, notarize, staple
scripts/release.sh                    # → dist/FolderVideoPlayer-v<version>.dmg

# a test copy beside the installed app (separate bundle id; same library)
xcodebuild -project FolderVideoPlayer.xcodeproj -scheme FolderVideoPlayer -configuration Release \
  -derivedDataPath build/dd-test CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  PRODUCT_BUNDLE_IDENTIFIER=com.tangrick.foldervideoplayer.dev build
```

Where the user's library actually is: `~/.fvp-engine` has a `support=` line, so
every bundled copy of the app (installed or test) reads and writes the library
at that path, not `~/Library/Application Support/FolderVideoPlayer`. Test
binaries ignore that file.

Conventions discovered (follow them):

- The app target uses one synchronized source group: a new `.swift` file under
  `FolderVideoPlayer/` is picked up by Xcode automatically — no pbxproj edit.
- A new file in `FolderVideoPlayer/Model/` **must also be added to
  `Tests/model_sources.sh`** or the whole test suite stops compiling.
- Tests are plain scripts: `Tests/test_<name>.swift` using `@testable import
  FVPModel` and a local `check(name, ok, detail)`; a `Tests/run_<name>.sh` runner
  sourcing `harness.sh`; and a line in `Tests/run.sh`.
- Comment style is long-form "why" prose; match it.
- Per-profile transcript storage is SQLite: `EvidenceStore` (schema-versioned,
  backup-before-migrate), wrapped for the app by `EvidenceJournal`.
- Transcript rows are keyed by the video's **absolute path** (not the tag key).
- Commits use `tangrick <40586271+tangrick@users.noreply.github.com>` (set in
  this checkout's and the website checkout's git config). Never a personal
  address — both repos are public, and their histories were rewritten once to
  remove one.
- Background work must never flood a network share: stat/scan in the
  background as a trickle (2 at a time, `.background` priority), and never sort
  or scan the whole library on the main thread (see the 1.1.21 launch-stall fix).

## Releases

| Version | Date | What | Commit |
|---|---|---|---|
| 1.1.21 | 2026-09-27 | Priorities 1–8, the label refinement, test feedback fixes, launch-stall fixes | `7234402` |
| 1.1.22 | 2026-09-27 | File facts sync between Macs (`facts.json` on the share) | `51d7e8d` |
| 1.1.23 | 2026-09-28 | Pinned folders published for the Apple TV (`pins.json`, one-way) | `9bfd5e5` |
| 1.1.24 | 2026-09-28 | Pinned folders follow the profile between Macs; upkeep only on pinned folders | `97539f3` |

Each is a notarized DMG on the GitHub release (`v<version>`), which is also what
the app's Check for Updates reads, and the website's download buttons
(`~/foldervideoplayer-site`, `./deploy.sh`) point at it.

### Apple TV (TestFlight)

The TV app lives in `~/FolderVideoPlayerTV` (private repo `tangrick/FolderVideoPlayerTV`,
commits as that repo's configured identity). Builds go to App Store Connect from
the command line: `xcodebuild -scheme FolderVideoPlayerTV -configuration Release
-destination 'generic/platform=tvOS' -allowProvisioningUpdates archive`, then
`xcodebuild -exportArchive` with an options plist of `method app-store-connect`,
`destination upload`, `teamID 4DMMS5733P`, `signingStyle automatic`. Bump
`CURRENT_PROJECT_VERSION` (both configurations) first. Xcode rewrites
`project.pbxproj` during builds (it once dropped the comment explaining the
SMBClient fork) — commit only the version lines, never its rewrite.

| Version (build) | Date | What | Commit |
|---|---|---|---|
| 1.1 (7) | 2026-09-28 | Home as shelves (Continue, Pinned, Ratings, Tags + All Tags, From the file); file facts; desktop transcripts as captions; the Mac's pins on Home | `d4e16b0` |
| 1.1 (8) | 2026-09-28 | People shelf from the Mac's `faces.json`; people kept out of Tags / All Tags | `6a1e845` |
| 1.1 (9) | 2026-09-28 | Subtitles menu in the transport bar (Off / Transcript / subtitle files beside the video); nothing laid over the picture; off by default, kind of choice remembered | `861f17f` |
| 1.1 (10) | 2026-09-28 | Captions 38 pt with Small / Medium / Large; Settings as four rows (Tagging as, Share, Away from home, Acknowledgements); one press picks a name; Connection screen switches share without hanging up (`Library.switchTo`); Connect to page and the 4-step add-a-connection flow redesigned as cards | `46e4bf3` |

None has been tried on a real Apple TV by this log's author: the simulator
cannot log in to the test share (see Known gaps). 1.0.1 (6) was the build
before these.

## Status overview

| # | Feature | Status |
|---|---------|--------|
| 1 | Transcript editor and export | released 1.1.21; editing moved into the transcript panel after user testing |
| 2 | Multi-tag selection from library sidebar | released 1.1.21; not yet exercised by hand |
| 3 | Share and prepare video | released 1.1.21 (real-export tests); UI not yet exercised by hand |
| — | My Tags / File Facts labels (optional refinement) | released 1.1.21 |
| 4 | Smart Collections | released 1.1.21; user-tested (always-visible section, File fact rule, launch-stall fix) |
| 5 | Watch state and dashboard | released 1.1.21; not yet exercised by hand |
| 6 | Moments, bookmarks, clip export | released 1.1.21; not yet exercised by hand |
| 7 | Subtitle and audio track controls | released 1.1.21 (engine probe on a real multi-track file); UI not yet exercised by hand |
| 8 | Opt-in background maintenance | released 1.1.21; worker not yet exercised end-to-end |
| — | File facts sync between Macs (user request) | released 1.1.22; not yet run between two real Macs |
| — | Pinned folders published for the Apple TV (`pins.json`, user request) | released 1.1.23 (one-way); TV 1.1 (7) on TestFlight reads them |
| — | Pins follow the profile between Macs; People shelf on the TV (user request) | done, uncommitted, unreleased; `run_profile_travels.sh` covers a second Mac opening the profile |
| 9 | Additional-format playback (VLCKit/libmpv) | KIV — on hold by the user's decision (2026-09-27); do not start without asking |

## Priority 1 — Transcript editor and export

Design:

- The `transcript` table stays the **current** (possibly corrected) revision,
  so search, subtitle overlay and share sync read the corrections with no change.
- New table `transcript_original` (schema v2 migration, backed up first) holds
  the machine lines, copied there on the first saved edit. Its presence for a
  path means "this transcript has user edits". Restore = copy back + drop it.
- Pure model `TranscriptDraft` (new `Model/TranscriptEdit.swift`): edit ops,
  undo/redo snapshots, validation (invalid → error, overlap/gap → warning, never
  auto-rewritten).
- Pure `TranscriptExport` (new `Model/TranscriptExport.swift`): txt/srt/vtt/csv/json.
- Moved-file repair: `EvidenceStore.moveTranscript(from:to:)`, invoked through
  a `Library` hook from `moveTags`.

Tasks:

- [x] Model: `TranscriptDraft` edit operations + undo/redo + validation (`Model/TranscriptEdit.swift`)
- [x] Model: `TranscriptExport` (txt, srt, vtt, csv, json) (`Model/TranscriptExport.swift`)
- [x] Store: additive `transcript_original` table (NOT a schema bump, so older builds still open the file); `saveEditedTranscript`, `restoreOriginalTranscript`, `hasUserEdits`, `editedTranscriptPaths`, `originalTranscript`, `moveTranscript`. `deleteTranscript` (re-transcription) also drops the kept original.
- [x] Journal: `hasUserEdits`, `saveEdited`, `restoreOriginal`, `moveTranscript`, `@Published transcriptEdits` counter (panel + subtitle overlay reload on it)
- [x] Moved-file repair carries transcripts: `Library.pathMoved` hook called from `moveTags`, wired to the journal in `FolderVideoPlayerApp`
- [x] Retranscribe asks "Keep My Edits / Replace" (`PlayerWindow.transcribe`); batch already skips videos that have transcripts
- [x] Tests: `Tests/test_transcript_edit.swift` + `run_transcript_edit.sh` + line in `run.sh` (all pass)
- [x] UI: `Views/TranscriptEditor.swift` — editing happens IN the transcript panel (user feedback, 2026-09-27; the separate window was removed). `TranscriptPanel` has an `editing` path; Edit / View ▸ Edit Transcript (`AppModel.transcriptEditTarget` request) switches it; Done asks Save / Discard / Keep Editing when dirty; `AppModel.transcriptEditing` widens the panel cap to 60%; `AppModel.mayLeaveTranscriptEdit()` guards the transport-bar panel buttons
- [x] UI: Export menu (panel + editor) via `TranscriptExporter` (NSSavePanel confirms overwrite)
- [x] Menus: View ▸ Edit Transcript (opens the panel in edit mode); panel has Edit and Export
- [x] README bullet
- [ ] Manual UI pass (couldn't automate: the user's own FolderVideoPlayer instances share the bundle id). Scratch fixture recipe: `ffmpeg -f lavfi -i testsrc=duration=30 ... demo.mp4`, seed lines with an `EvidenceStore` script under `FVP_SUPPORT`, then `open -n --env FVP_SUPPORT=<dir> build/dd/.../FolderVideoPlayer.app demo.mp4`
- [ ] (optional) Help window mention

Known limitations of P1:
- Closing the editor window with unsaved edits does not prompt (SwiftUI `Window` has no close veto here); edits survive while the app runs only if SwiftUI keeps the view state.
- Undo of a moved-file repair does not move the transcript back.

## Priority 2 — Multi-tag selection from the sidebar

Design: no new `PlayMode`. A combined playlist is a `.tag` playlist with
`tagName == nil` and `PlaybackController.tagQuery` set, so every single-tag
feature (look-alikes, training, bulk accept) stands aside automatically. A query
is never saved as the session (like `.said`); Clear returns to the session.

- [x] Model `Model/TagQuery.swift` (names, Any/All, toggle, case-insensitive, prune, label, pure `combine`)
- [x] `Library.paths(matching:)` — each name via `pathsCarrying` (tags, stars, people, file facts; hidden excluded)
- [x] Controller: `tagQuery`, `toggleQueryName`, `setQueryMatch`, `clearTagQuery`, `tagMembers()` (prunes vanished names) used by `refreshAfterTagRepair` / `refreshMembership` / `refreshAfterFileChanges`; `start()`, `playTag`, `closePlaylist` (profile switch) clear it; `saveSession` skips it; `sessionLabel` uses `query.label`
- [x] Sidebar (`LibrarySidebar` in `Views/PlayerWindow.swift`): `pick()` reads ⌘ at click; `row(... queried:)` tick + outline + `.isSelected` trait; "Add to/Remove from Combined Playlist" in every row's context menu (keyboard/VoiceOver path); `queryBand` with chips, Any/All picker, count, Clear
- [x] Tests `Tests/test_tag_query.swift` + runner + `run.sh` line (all pass)
- [x] README bullet
- [ ] Manual UI pass
- [ ] Later (backlog): Exclude action; save query as Smart Collection (see P4)

## Priority 3 — Share and prepare video

Design: FFmpeg is NOT bundled (clean-start Macs lack it), so copies are made
with `AVAssetExportSession` for AVFoundation-readable sources (passthrough =
remux, or 1080/720/540 presets); FFmpeg (`PlayableCopy.findTools`) only for
MKV/AVI/WebM/FLV, else the plan says why. ZIP is `/usr/bin/zip -0` (stored)
over a staging dir of symlinks.

- [x] Model `Model/SharePrep.swift` (pure): `SharePreset`, `ShareSource`, `ShareEngine`, `SharePrep.engine(...)` (remux preferred when it satisfies the preset), FFmpeg args (trim via `-ss`/`-t`), `suggestedName`, `uniqueName`, `packageEntries`, `estimatedBytes`, `hasRoom`
- [x] Model `Model/ShareExport.swift`: `inspect`, `make` (partial file → atomic publish, cleanup on cancel/failure, free-space check, refuse existing unless `replacing`), `zip`
- [x] Tests `Tests/test_share_prep.swift` (+ runner, `run.sh`): plan checks always; real remux/trim/720p/MKV→MP4/cancel/collision/ZIP + original SHA-256 unchanged when FFmpeg is installed (38 checks pass)
- [x] UI `Views/ShareSupport.swift`: `SharePresenter` (NSSharingServicePicker at pointer; reports service refusals via `app.say`)
- [x] UI `Views/SharePrepareWindow.swift` (Window id `share-prepare`, targets `AppModel.shareTargets`): quality presets with per-file engine summary + estimate, trim (single video; playhead buttons), transcript sidecar .srt/.vtt (trim-shifted), ZIP package (incl. "files as they are"), progress + Cancel, results with Show in Finder / Share…; hidden+locked shows a placeholder
- [x] Entry points: playlist row menu "Share…" / "Prepare for Sharing…"; Edit menu (beside Reveal/Trash) "Share…" / "Prepare for Sharing…"
- [x] README bullet
- [ ] Manual UI pass
- [ ] Later: burn captions into the copy

## Priority 4 — Smart Collections

Design: only the question is stored (`profiles/<name>.fvpprofile/smart-collections.json`,
`SmartCollectionFile` v1). Rules are a flat struct (`type`, `op`, `text`, `stars`,
`from`, `to`) so an unknown kind from a newer build loads, is kept on save,
matches nothing and is described. Universe = every video the profile KNOWS
(tags, facts, watch log, resume positions, analysis records, transcripts) —
there is no catalogue of every file on every share; the editor says so.
Stat-needing rules (date added, file state) are prefetched off the main thread
(`Library.warmStats`; existence cached 2 min).

- [x] File fact rule kind (`.fact`: dates, camera, quality, place — user feedback): matches `SmartContext.facts` only; Tag/Person rules now match tags only; editor picker groups facts by kind; combined-playlist Save… turns fact names into fact rules
- [x] Model `Model/SmartCollections.swift`: `SmartCollection`, `SmartRule` (+ `Kind`, `Op`, `fresh`, `values`), `SmartAnalysis`/`SmartVerdict`/`SmartFileState`, `SmartContext`, `SmartEvaluator.members/holds/problem`, `SmartCollectionFile`
- [x] `Library.knownVideoKeys`, `recordedDate(key:)` (from Date facts), `smartContext(adding:)`
- [x] Store `Model/SmartCollectionStore.swift` (MainActor): load per profile, save/duplicate/rename/delete, `problems(in:)`, debounced `refresh()` on library/analysis/transcript changes, `evaluate(_:)` for editor previews
- [x] Controller: `smartCollection`, `playCollection`, `collectionChanged`, members via `collectionMembers` closure; cleared by `start`/`playTag`/query/`closePlaylist`; not saved as session
- [x] App wiring: `@StateObject smart`, env object, attach, profile-change reload, `Window("Smart Collection", id: "smart-collection")`, `AppModel.smartEditTarget/smartEditSeed`
- [x] Sidebar "Smart Collections" section — always shown, even as "Smart Collections (0)" with "New Smart Collection…" (user feedback; `section(... alwaysOpen:)`); counts, context menu Play/Edit/Duplicate/Rename/Delete; combined-playlist band gains "Save…" (query → collection)
- [x] Editor `Views/SmartCollectionEditor.swift` (name, all/any, rule rows with kind/op/value, per-rule problem text, live match count, Delete)
- [x] Tests `Tests/test_smart_collections.swift` (64 checks incl. watch state) + runner + `run.sh`
- [x] README bullet
- [ ] Manual UI pass

## Priority 5 — Watch state and dashboard

- [x] Model `Model/WatchLog.swift` (per profile `watch.json`, keyed by tag key): opening threshold min(30 s, 25%), completion = last min(30 s, 10%); `notePlayback` → none/refreshed/stateChanged; `mark`; `move`; `forget`; lenient load
- [x] Library: `watch` (unpublished) + `@Published watchRevision`; loaded/saved in `setProfileInForce`, `switchProfile`, `closeProfile`, `reopenClosed`; `note(... watching:)` (previews excluded); `itemFinished` notes completion; `watchState`, `lastPlayed`, `markWatched` (unwatched clears resume point); carried by `moveTags`, dropped by `forgetPath`
- [x] Mark Watched / Mark Unwatched in row menu (toggles by state) + Edit menu (multi-selection)
- [x] `WatchMark` on playlist list rows (half circle = in progress, faint tick = watched; unwatched draws nothing on purpose)
- [x] Dashboard as `Window("Library Overview", id: "overview")` (`Views/LibraryOverviewWindow.swift`, View ▸ Library Overview ⌘0): model `Model/LibraryOverview.swift` (pure `build(Input)`), cards open `PlaybackController.playList(title, paths)` (new `namedList`, never saved as session); Housekeeping buttons open Find Missing Files (`AppModel.findMovedEverywhere`) and Find Duplicates (shows recoverable bytes when a scan exists)
- [x] Tests `Tests/test_library_overview.swift` + runner + `run.sh`
- [x] README
- [ ] Manual UI pass
- [ ] Maybe later: an "Overview" row in the library sidebar; tile view (icon grid) watch mark
- (playCount deliberately not added — no predictable definition yet)

## Priority 6 — Moments, bookmarks and clip export

Design: `MomentStore` (MainActor ObservableObject, per profile
`profiles/<name>.fvpprofile/moments.json`, `MomentBook` v1) reloaded on profile
change like the other per-profile stores; moved files carried through the
`Library.pathMoved` hook (now calls journal + moments). Clip export REUSES
Prepare for Sharing: `AppModel.shareTrim` + `shareTargets` → the window takes
the range once (`takeTrim`), so remux-first, progress, cancel, atomic publish
and collision handling are shared.

- [x] Model `Model/Moments.swift`: `Moment` (start, optional end, title, note, created/modified, source manual/transcript/evidence, `problem` validation, `defaultTitle`), `momentClock`, `MomentBook` (sorted per video, upsert keeps createdAt, delete, move, forget, lenient load, save), `MomentStore` (add/update/delete/undoDelete/move, `lastDeleted`)
- [x] App: `@StateObject moments`, env object, reload on appear + profile change, `pathMoved` carries them
- [x] UI `Views/MomentsPanel.swift`: panel in the bottom slot (`AppModel.showMomentsPanel`, transport "Moments" button; the three panels are mutually exclusive), rows with seek, in-place title/note, range (end at playhead / clear), start at playhead, Export Clip…, Delete + Undo Delete; `MomentMarkers` ticks + range bars over the scrubber (click to seek)
- [x] Add Moment: Playback ▸ Add Moment ⌘B (via `AppModel.addMomentNotification`) and the panel button
- [x] "Save as Moment" on transcript lines (ranged, source transcript) and on AI evidence time chips in the tag panel (source evidence)
- [x] Tests `Tests/test_moments.swift` + `Tests/run_moments.sh` written
- [x] Registered in `Tests/model_sources.sh` + `Tests/run.sh`; all pass
- [x] README
- [ ] Manual UI pass

## Priority 7 — Subtitle and audio track controls

Design: embedded tracks via `AVMediaSelectionGroup` (`.audible`, `.legible`) on
the current item — `select(_:in:)` switches without reload/seek, and
`AVPlayerView` draws embedded subtitles in window and full screen alike.
Subtitle files and the transcript are drawn by the existing `SubtitleOverlay`,
now driven by `PlaybackController.subtitleSource`. Per-video choices in
UserDefaults (`subtitleChoices`, `audioChoices`, keyed by tag key — display
preferences like `VideoRotation`). Automatic = embedded (system caption prefs)
if the file has subtitle tracks, else first sidecar, else transcript, else none.
NOTE: that means a file with embedded tracks no longer shows the transcript by
default — pick "Transcript" in the menu.

- [x] Model `Model/MediaTracks.swift`: `SubtitleCue`, `TrackOption`, `SubtitleChoice` (+ stored form), `SubtitleSource`, `SubtitleFile` (SRT/VTT parse: BOM, CRLF, CP1252, markup/entities, NOTE/STYLE/REGION, strict timing with line numbers; `sidecars(for:in:)` incl. `name.lang.srt`; `label`), `TrackPlan.resolve/source/cue`
- [x] Engine: `PlayerEngine` protocol gains track API; `AVPlayerEngine` loads groups per item (forced-only variants hidden), `selectAudio`, `selectEmbeddedSubtitle`, `selectSubtitlesAutomatically`, `onTracks`. Verified with a scratch probe on an ffmpeg-made MP4 (2 audio + 2 mov_text tracks).
- [x] Controller: `prepareTracks(for:)` after every `engine.load` (folder listing off-main), `applyTracks()`, `loadSidecar` (off-main parse; failure → `trackNote`, playback unaffected), `chooseSubtitles`, `chooseAudio`, `hasTranscript` closure, `transcriptAvailabilityChanged`
- [x] UI: `TrackMenu` in the transport bar (Off/Automatic/embedded/sidecars/Transcript/Choose Subtitle File…; Audio section explains when there is only one; note shown); overlay switches source
- [x] Tests `Tests/test_media_tracks.swift` + runner + `run.sh` (incl. exporter round trip)
- [x] README
- [ ] Manual UI pass

## Priority 8 — Opt-in background maintenance

Design: per profile `profiles/<name>.fvpprofile/maintenance.json`
(`MaintenanceFile` v1: settings, per-folder snapshot `relpath → size`,
lastScan, queue, failed). Only PINNED folders can be opted in. Default work is
posters + dates only; AI kinds are opt-in and skip themselves when the model
is not installed. Classification goes through `AppModel.classify` → the job
ledger; tag suggestions and transcripts go through their existing
notifications (`suggestTagsNotification`, `transcribeNotification`) and the
worker waits on `suggestingPath` / `transcribingPath`. A move the scan is sure
of (unique name+size) calls `library.moveTags` (which also carries facts,
transcript, moments, watch state).

- [x] Model `Model/Maintenance.swift`: `MaintenanceWork`, `MaintenanceSettings` (folders, work, pauseWhilePlaying, pauseOnBattery, schedule anytime/overnight, concurrency 1–4, rescanMinutes), `MaintenanceItem`, `MaintenanceFile`, `MaintenancePlanner` (diff with safe moves, enqueue skipping hidden + widening, drop, move, pauseReason, afterFailure (3 attempts), isDue, snapshot)
- [x] Worker `Playback/MaintenanceWorker.swift` (app target only — uses AppModel): loop (pause → scan due folders with a 60 s unreachable timeout, off-main walk → work queue), light work in parallel up to `concurrency`, AI work one video at a time, `.later` when the engine is busy with something asked for, missing/hidden files dropped, IOKit battery check, status line text
- [x] App: `AppModel.maintenance`, attached on appear, reloaded on profile change
- [x] UI: Settings tab "Background" (`MaintenanceSettingsView`, `SettingsTab.background`), pinned-folder context menu toggle (Unpin also opts out), `MaintenanceStatusLine` under the library sidebar (click → settings)
- [x] Tests `Tests/test_maintenance.swift` + runner + `run.sh`
- [x] README
- [ ] Exercise end-to-end in the app (opt in a scratch folder, add/move/remove files, watch the status line)

## Priority 9 — Direct playback of additional formats

**KIV (kept in view) — the user put this on hold on 2026-09-27. Do not start it without asking.**

Not started: needs a decision on the second engine (VLCKit vs libmpv —
licensing (LGPL/GPL), binary size, signing/notarisation, SwiftPM vs vendored
framework). The `PlayerEngine` protocol now also carries the track API (P7),
so a second engine must implement `audioOptions`, `subtitleOptions`,
`onTracks`, `selectAudio`, `selectEmbeddedSubtitle`,
`selectSubtitlesAutomatically`. Views still reach `AVPlayerEngine` concretely
in places (`PlaybackController.engine`, `VideoSurface(player:)`,
`TrackMenu(engine:)`) — those need an engine-agnostic seam first.

## Known gaps / decisions to revisit

- The Apple TV builds of 2026-09-28 were verified only by simulator builds and
  standalone checks of their readers (pins, `faces.json` against every real
  file on the NAS, subtitle files); the simulator cannot log in to `~/TVShare`
  (guest logins are refused) and the user's password is not used. The user
  checks on the real TV. Embedded subtitle tracks on the TV are AVKit's own
  info panel, not verified.
- Tag headings (`headings.json`) do not travel to other Macs or the TV — the
  user decided that is not needed (2026-09-28).

- Share sync (`SharedExtras.syncTranscripts`) only sends a transcript for a
  video the share does not yet have ("transcripts only accumulate"), so a
  correction made after the first publish does not propagate to other Macs.
  Left unchanged in P1; changing it needs a merge rule (file facts, 1.1.22,
  show one: three-way per video against the last sync).
- Still per Mac, not shared through the NAS: watch history, moments, smart
  collections. The user has not yet said whether they should sync.
- A file-facts first meeting where BOTH Macs hold different readings for a
  video converges to one of them after a couple of syncs (by design: this
  Mac's own stands on the first sync, then the three-way rule applies).
- PR #1's page on GitHub still caches its original commits (with the old
  personal email) until GitHub Support purges them; `main` itself is clean.
- The login Keychain holds two identical Developer ID certificates;
  `scripts/release.sh` copes by signing by SHA-1, other tools may not.
- The clean-account walkthrough (`docs/clean-start-checklist.md`) has not been
  done for 1.1.21 or 1.1.22.

## Session log

- 2026-09-27 — Session 1: surveyed codebase, baseline Debug build OK, wrote this plan. Implemented P1–P8 (+ the My Tags / File Facts label refinement). Final full `sh Tests/run.sh`: 2,782 checks, exit 0 (model-dependent stages skip without downloaded models). App Debug build succeeds with no new warnings. NOT done: any hand-driven UI pass (the user's own FolderVideoPlayer instances share the bundle id; a dev copy can be built with `PRODUCT_BUNDLE_IDENTIFIER=com.tangrick.foldervideoplayer.dev` into `build/dd-dev`, but screen control was declined), P9 (awaiting an engine decision). Nothing committed — all work is uncommitted in the working tree.

- 2026-09-27 — Session 1 (cont.): user testing feedback addressed — Smart Collections section always visible with New…; File fact rule kind; transcript editing moved into the transcript panel.

- 2026-09-27 — Session 1 (cont.): fixed a launch stall reported in testing — a smart collection with a Date added rule stat-ed every known video on the NAS 8-at-a-time at launch (now a 15 s-delayed 2-at-a-time background trickle; stat rules answer from the warm cache), and `knownVideoKeys` natural-sorted ~12k keys on the main thread every refresh (now a plain sort; only results are naturally sorted). User confirmed the test copy works.

- 2026-09-27 — This public repo is now THE working repo. The old private working repo (`tangrick/FolderVideoPlayerSwift`, which published snapshots here) is archived on GitHub and no longer used. Release tooling moved here: `scripts/release.sh`, `scripts/exportOptions.plist`, `docs/releasing.md`. Commit as `tangrick <40586271+tangrick@users.noreply.github.com>` (set in this checkout's git config) — never a personal address.

- 2026-09-27 — 1.1.22: file facts now sync between Macs through the profile's share folder (`facts.json`, `SharedExtras.syncFacts`/`mergeFacts`, three-way per video; `Library.takeSharedFacts` applies only to videos unchanged during the sync; `factsDirty` schedules a sync after a scan or correction; `SharedExtras.State` decodes older files). Tests in `test_shared_extras.swift` and `test_smart_collections.swift`. Verified before: on the real NAS, facts for 3,505 videos were not shared at all.

- 2026-09-27 — Published 1.1.21 and 1.1.22: notarized DMGs as GitHub releases (Check for Updates offers them) and the website's download buttons deployed. Full `Tests/run.sh` before 1.1.22: 2,806 checks, exit 0. Both public repos' histories rewritten to the noreply identity (app repo: the 6 feature-branch commits; website repo: all 56 author/committer entries) and force-pushed with `--force-with-lease`.

- 2026-09-28 — Pinned folders now published for the Apple TV (user request; the TV side lives in `~/FolderVideoPlayerTV`, uncommitted with that repo's in-progress Home work). Mac: `SharedExtras.Pins` / `syncPins` write `.FolderVideoPlayer/<profile>/pins.json` (`{format: 1, folders: [share-relative paths]}`, sidebar order) on each mounted share; one-way, no lock, written only when this Mac's list for that share differs from `State.pinsSent` (or the file went missing), and never over a newer format. `Library.pin/unpin/movePinned` set `pinsDirty` and schedule the usual auto-publish. TV: `TagStore.readPins` (same cadence and rules as `readFacts`) → `PinStore.takeFromMac`; Home shows this box's pins then the Mac's, captioned "From the Mac"; unpinning a Mac pin on the TV hides it on that TV only (`hiddenMacPins`). Verified: `run_shared_extras.sh` (8 new pin checks), Mac Debug build, tvOS simulator build, the Mac publisher run against `~/TVShare` and its file read by the TV's `PinStore` compiled standalone (12 checks). NOT verified: a live SMB connection from the TV (the test share rejects guest logins).

- 2026-09-28 — 1.1.23 released (pins published one-way); TV 1.1 (7) uploaded to TestFlight (archive + `xcodebuild -exportArchive` with `method app-store-connect`, `destination upload`, team 4DMMS5733P). The first `release.sh` run failed silently in the disk-image step (`hdiutil -quiet`); a rerun with `--skip-tests` passed — likely hdiutil's intermittent busy error.

- 2026-09-28 — Profile survives on other Macs and the TV (user request: pinned folders, tags, people, file facts). Audit: tags (`tags.json`), people (`faces.json`) and file facts (`facts.json`) already reached a second Mac through `openProfile` → `adoptProfileOnShares` → `syncSharedExtras`; pins did not (1.1.23 only published them). Now `SharedExtras.mergePins` merges each share's list three ways (facts' rule; order counts; first meeting = this Mac's then the share's), `Library.takeSharedPins` applies it when the pins did not change during the sync, and `MaintenanceWorker` skips opted-in folders no longer pinned. New end-to-end `Tests/test_profile_travels.swift` (two Libraries, two support roots, one share; mutation-checked). TV: `TagStore.readPeople` reads the names in `faces.json` (only when its time moves); Home gets a People shelf and Tags/All Tags leave people out (the player's chips still offer them). Tag headings (`headings.json`) never reach the share; the user decided that is not needed.

- 2026-09-28 — Released Mac 1.1.24 (tests passed, `release.sh --skip-tests` right after; GitHub release + website). TV 1.1 (8) and 1.1 (9) uploaded to TestFlight. Build 9 (user request): the transcript's Transcript / Captions On buttons that sat over the picture are gone; a Subtitles menu in the transport bar (only when the video has something) offers Off, Transcript, and subtitle files beside the video found and read by `Models/SubtitleFile.swift`, a copy of the Mac's `SubtitleFile` ("change both together"), plus Show Transcript. Off by default; `player.subtitles` remembers off / transcript / a file's language label. A file that will not read is said for 4 s and not shown.

- 2026-09-28 — TV 1.1 (10) uploaded (user requests from testing): captions were `.title2` (57 pt), now 38 pt with a Size choice (`player.subtitleSize`); Settings redesigned as rows with sub-screens; picking a name applies it (`PersonPicker.onChoose`, a Use button only for a typed name); Home's Change connection opens `ConnectionSettings` (shares on this server via `library.shares(on:)`, skipped via relay; saved connections; Edit details; Add a new server) and switches with `Library.switchTo`, which keeps the current connection until the new one opens; the connect flow's saved list and add steps are cards in `Shelf`s with a Step N of 4 header, a found server skips the name/address screen, and each step focuses its first card (`@FocusState`). Verified in the simulator: step 1 and its initial focus only (no remote input possible from here); the rest is for the user to test on the TV.

## Next steps for whoever continues

1. P9 is on hold (KIV) — skip it unless the user reopens it.
2. Run 1.1.22 on two real Macs sharing the NAS and confirm File Facts arrive (the first run on the main Mac writes `facts.json` for ~3,500 videos of the main profile).
3. Hand-test the features not yet exercised (status table above), fixing what is found.
4. The clean-account walkthrough for the current release.
5. Ask whether watch history, moments and smart collections should sync between Macs.
6. Optional follow-ups listed under each priority ("Later"/"Maybe later").
