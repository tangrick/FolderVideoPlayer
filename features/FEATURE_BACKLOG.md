# FolderVideoPlayer Feature Backlog

This document is an implementation brief for agents extending FolderVideoPlayer.
Work from the top unless the user selects a different feature. Each feature should
be delivered independently, with model tests and UI behavior consistent with the
existing app.

## Product direction

FolderVideoPlayer is a private, local-first macOS video library for folders and
NAS shares. New features should strengthen that identity:

- Keep video, tags, faces, transcripts, and analysis on the Mac.
- Preserve the original video unless the user explicitly approves a file action.
- Keep network shares responsive; never block the main thread on file I/O.
- Explain unavailable or disabled actions rather than silently hiding them.
- Reuse profile-aware, share-relative storage conventions where applicable.
- Make destructive actions reversible whenever possible.

Before implementing a feature, inspect `README.md`, `docs/architecture.md`, and
the relevant existing model and view files. Preserve existing user changes and
data-file compatibility.

## Requested enhancements — implementation status

The following requests were reviewed against the current application. Agents
must not rebuild the parts marked complete:

- **Transcription is already implemented.** A user can transcribe or
  re-transcribe one video, batch-transcribe selected videos, search transcripts
  across the library, seek by clicking a transcript line, and display transcript
  lines over the video. The missing work is editing and export, described below.
- **Multiple-tag filtering already exists in the playlist panel.** It supports
  included tags, excluded tags, and `All`/`Any` matching. The missing work is
  selecting several tags directly from the left library panel to create a
  library-wide playlist.
- **Manual tags and metadata-derived facts are already separated.** The library
  presents ordinary tags separately from Date, Camera & Quality, and Place facts,
  backed by tag provenance. Only naming and visual clarity may need refinement.
- **Video sharing is not implemented.** Add native sharing and preparation of a
  smaller or more compatible copy. Do not present ZIP as a useful way to reduce
  the size of a single already-compressed video.

## Priority 1 — Transcript Editor and Export

### Goal

Let users correct the local machine-generated transcript and export it in common
subtitle, caption, and text formats.

### Editing scope

- Edit the text of an individual timed line.
- Edit a line's start and end times.
- Insert a new timed line before or after another line.
- Delete a line.
- Split one line at the playhead or cursor position.
- Merge adjacent lines.
- Shift selected lines earlier or later by a typed offset.
- Shift the entire transcript to correct a consistent synchronization error.
- Provide undo and redo for an editing session.
- Offer **Restore Original Transcription** after user edits have been saved.

The editor should support direct time entry and adjustment against the video
playhead. Playing a line or short surrounding range must make synchronization
easy to verify without closing the editor.

### Export scope

Support these formats initially:

- `.txt` — transcript text without timing.
- `.srt` — SubRip subtitles.
- `.vtt` — WebVTT captions.
- `.csv` — start, end, and text for review or further editing.
- `.json` — a documented lossless interchange representation.

Consider `.lrc` later if music and lyric workflows prove useful. Label exports by
their actual purpose; do not call ordinary speech transcripts lyrics.

Export must use the saved, user-corrected transcript. Let the user choose the
destination and filename, and never overwrite an existing file without explicit
confirmation.

### Data and safety requirements

- Keep the original machine-generated transcript or a recoverable revision so
  user corrections can be reverted.
- Store edits in the active profile and preserve profile isolation.
- Carry transcripts and their edits through the existing moved-file repair flow.
- Validate that times are finite, non-negative, and ordered.
- Clearly flag overlaps and gaps; do not silently rewrite user-entered times.
- Transcript search, subtitle overlay, and shared transcript data must read the
  corrected current revision after a save.
- Retranscribing a video with user edits must ask whether to replace the edited
  version or keep it.

### Acceptance criteria

- A user can edit text and timing, add and delete lines, save, relaunch, and see
  the corrected transcript in search and the subtitle overlay.
- Undo and redo cover text, timing, insertion, deletion, split, merge, and shift.
- Exported SRT and VTT pass format validation and preserve Unicode text.
- TXT, CSV, and JSON exports represent the same saved transcript.
- Invalid time ranges produce an actionable inline message and are not saved.
- Hidden videos do not leak transcript text or export availability while locked.
- Tests cover each edit operation, revision recovery, serialization, export
  escaping, Unicode, overlapping times, and moved-file repair.

### Likely integration points

- `FolderVideoPlayer/Views/TranscriptPanel.swift`
- `FolderVideoPlayer/Model/EvidenceJournal.swift`
- `FolderVideoPlayer/Model/EvidenceStore.swift`
- `FolderVideoPlayer/Model/TimedEvidence.swift`
- `FolderVideoPlayer/Model/SharedExtras.swift`
- `FolderVideoPlayer/Views/Menus.swift`

## Priority 2 — Multi-tag Selection from the Library Sidebar

### Goal

Let users combine several tags directly from the left library panel and open one
playlist containing the union or intersection of those tags.

This is distinct from the existing playlist tag filter: the left panel builds a
playlist from the whole profile, while the right-side filter narrows the playlist
already open.

### Interaction

- A normal click keeps the existing behavior: open one tag immediately.
- Command-click adds or removes a tag from the active library query.
- Show selected tags as removable chips in a clearly named query band.
- Provide an **Any / All** selector:
  - **Any** shows videos carrying at least one selected tag and is the default
    when the user asks for “more items.”
  - **All** shows only videos carrying every selected tag.
- Provide a clear action that returns to ordinary single-tag navigation.
- Consider an explicit **Exclude** action after the initial include workflow is
  stable; if added, use the same visual language as the existing playlist filter.
- A later enhancement may save the query as a Smart Collection.

### Behavior requirements

- Query membership is library-wide for the active profile.
- Hidden videos remain excluded while locked.
- Star ratings, named people, user-filed headings, and file facts may participate
  if they resolve through the same library membership mechanism.
- Changing a tag on a video updates the active result set without unexpectedly
  changing the playing video.
- Selected tags must be distinguishable from an ordinary highlighted/current
  tag and must work with keyboard and VoiceOver navigation.

### Acceptance criteria

- Command-clicking two tags can produce either their union or intersection.
- Removing a selected tag updates the playlist and counts immediately.
- Profile switching clears or safely restores only that profile's query.
- A deleted or renamed tag does not leave an invisible active constraint.
- Large libraries remain responsive and do not perform file I/O while evaluating
  or rendering the query.
- Tests cover Any, All, case-insensitive names, rename/delete, hidden videos,
  ratings, people, and file facts.

### Likely integration points

- `FolderVideoPlayer/Views/PlayerWindow.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`
- `FolderVideoPlayer/Model/Library.swift`
- `FolderVideoPlayer/Views/PlaylistSidebar.swift`

## Priority 3 — Share and Prepare Video

### Goal

Let users share the original video through macOS or prepare a compatible,
smaller copy without modifying the source.

### Actions

- **Share Original…** presents the standard macOS sharing services for one video.
- For several selected videos, share them individually when the target supports
  multiple files or offer to prepare a package.
- **Prepare for Sharing…** creates a new copy with selectable presets:
  - Original quality/compatible container where remuxing is sufficient.
  - 1080p.
  - 720p.
  - Smaller file.
- Let the user optionally trim to a selected time range when moment/range support
  is available.
- Let the user optionally include a corrected `.srt` or `.vtt` transcript beside
  the video, or burn captions into the prepared copy as a later enhancement.
- Offer **Create ZIP Package** for multiple videos or a video plus subtitle and
  supporting files. Do not imply that ZIP materially compresses a single video.

### Safety and workflow requirements

- Never alter or replace the original.
- Let the user choose the destination and filename for prepared copies.
- Prefer remuxing when it satisfies the chosen preset; otherwise transcode with
  visible progress and cancellation.
- Write to a temporary destination and publish the final file atomically so a
  cancelled or failed job is not presented as complete.
- Estimate output compatibility and size when practical, but label estimates as
  estimates.
- Sharing a hidden video is available only from the unlocked hidden-video view
  and must not expose its name elsewhere.
- Report when a receiving macOS sharing service refuses a file because of size or
  type, without deleting the prepared copy.

### Acceptance criteria

- One selected video can be sent to the macOS share sheet.
- A prepared copy plays independently and leaves the original byte-for-byte
  unchanged.
- Remux, transcode, cancellation, name collision, and insufficient-space paths
  are handled clearly.
- A ZIP package can contain multiple selected videos and optional subtitle files.
- Temporary partial outputs are cleaned up after failure or cancellation.
- Tests cover preset planning, target naming, package contents, cancellation, and
  original-file preservation.

### Likely integration points

- `FolderVideoPlayer/Views/PlaylistSidebar.swift`
- `FolderVideoPlayer/Views/Menus.swift`
- `FolderVideoPlayer/Model/FileOps.swift`
- `FolderVideoPlayer/Model/PlayableCopy.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`

## Completed foundation — Manual Tags and File Facts

The requested separation between manual tags and metadata tags is already
present. Ordinary tags appear before metadata-derived facts; facts are grouped
as Date, Camera & Quality, and Place and use restricted actions appropriate to
read-only facts.

Do not replace this model with two incompatible tag systems. If usability review
shows that the distinction is unclear, make only these presentation refinements:

- Label the ordinary section **My Tags** rather than merely **Tags**.
- Label the metadata section **From the File** or **File Facts**.
- Add a short tooltip explaining that file facts are read from metadata and
  cannot be trained or manually removed like ordinary tags.
- Keep provenance and existing storage compatibility unchanged.

## Priority 4 — Smart Collections

### Goal

Let users save dynamic library queries that automatically update as tags,
ratings, transcripts, metadata, analysis, and playback state change.

### Initial rule vocabulary

- Tag includes or excludes a value.
- Person includes or excludes a value.
- Rating is equal to, at least, or at most a value.
- Date added or recording date is before, after, or within a range.
- Transcript contains text.
- Playback state is unwatched, in progress, or completed.
- Analysis state is pending, failed, or complete.
- Safe/NSFW verdict is a selected value or needs review.
- File is missing, playable, or requires conversion.

Rules within a collection must support `all` and `any` matching. Results should
exclude hidden videos while the hidden library is locked.

### UX

- Add a **Smart Collections** section to the library sidebar.
- Provide create, edit, duplicate, rename, and delete actions.
- Show the live result count beside each collection.
- Opening a collection creates a normal playable and filterable playlist.
- Clearly describe an invalid rule when its referenced tag or person was removed.

### Storage

Store collection definitions in the active profile because they can reference
profile-owned tags, people, and verdicts. Use a versioned, forward-compatible
JSON format. Do not store derived membership; compute it from current library
state.

### Acceptance criteria

- A collection can combine at least two different rule types.
- Results update after tagging, rating, transcript, or playback-state changes.
- Collections survive relaunch and profile switching without leaking between
  profiles.
- Hidden videos never appear through a smart collection while locked.
- A collection of several thousand videos does not perform disk I/O during row
  rendering or freeze the main window.
- Unit tests cover serialization, `all`/`any`, exclusion rules, missing values,
  and hidden-video behavior.

### Likely integration points

- `FolderVideoPlayer/Model/Library.swift`
- `FolderVideoPlayer/Model/ProfileBundle.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`
- `FolderVideoPlayer/Views/PlayerWindow.swift`
- `FolderVideoPlayer/Views/PlaylistSidebar.swift`

## Priority 5 — Watch State and Library Dashboard

### Goal

Turn the app's existing resume information into a clear library-level view of
what is new, unfinished, watched, or awaiting attention.

### Watch state

Add explicit derived states:

- **Unwatched:** no meaningful playback progress.
- **In progress:** playback passed the opening threshold but did not reach the
  completion threshold.
- **Watched:** playback reached the completion threshold or the user marked it
  watched.

Support **Mark Watched** and **Mark Unwatched** for one or many selected videos.
Record `lastPlayedAt`; add `playCount` only if it can be defined predictably and
tested without surprising increments during seeking or previewing.

### Dashboard

Add a library home view containing:

- Continue Watching.
- Recently Added.
- Recently Watched.
- Unwatched.
- AI suggestions awaiting review.
- Failed or incomplete analysis jobs.
- Missing files.
- Duplicate storage that may be recoverable.

Dashboard sections should open ordinary playlists or the existing management
window rather than inventing parallel workflows.

### Acceptance criteria

- Watch state survives relaunch and works with share-relative paths.
- Previewing a file does not accidentally mark it watched.
- Manual watched/unwatched changes are available for multi-selection.
- Dashboard counts update after relevant operations.
- Empty sections explain how they become populated and do not dominate the UI.
- Tests cover state thresholds, manual overrides, replay, and renamed/moved files.

### Likely integration points

- `FolderVideoPlayer/Model/Library.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`
- `FolderVideoPlayer/Views/PlayerWindow.swift`
- `FolderVideoPlayer/Views/Menus.swift`

## Priority 6 — Moments, Bookmarks, and Clip Export

### Goal

Allow users to preserve and revisit meaningful timestamps, including timestamps
found through transcript search or AI evidence.

### Moment model

A moment should contain:

- Video path key.
- Timestamp.
- Optional end timestamp.
- User-visible title.
- Optional note.
- Creation and modification timestamps.
- Optional provenance such as manual, transcript, or AI evidence.

Moments belong to the active profile. Moving or repairing a video path must carry
its moments with it.

### UX

- Add **Add Moment** at the current playhead.
- Show moments as markers on the scrubber and as a list for the current video.
- Clicking a moment seeks to it.
- Allow a transcript match or AI evidence timestamp to become a moment.
- Provide rename, edit note, change range, and delete actions with undo where
  practical.
- If a moment has a range, offer **Export Clip…**.

### Clip export constraints

- Never modify the source.
- Let the user choose the destination and filename.
- Prefer a fast stream copy when safe; otherwise transcode with visible progress.
- Cancellation must not leave a partial output presented as complete.
- Keep export separate from tags and library membership unless the user chooses
  to open the exported file's folder afterward.

### Acceptance criteria

- Moments survive relaunch, profile switching, and moved-file repair.
- Seeking from a moment is frame-time accurate within the underlying player's
  practical tolerance.
- Hidden videos do not leak moment titles while locked.
- Clip export handles cancellation and filename collisions safely.
- Tests cover serialization, sorting, path migration, range validation, and
  deletion.

### Likely integration points

- `FolderVideoPlayer/Model/ProfileBundle.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`
- `FolderVideoPlayer/Views/TransportBar.swift`
- `FolderVideoPlayer/Views/TranscriptPanel.swift`
- `FolderVideoPlayer/Views/TagPanel.swift`
- `FolderVideoPlayer/Model/PlayableCopy.swift`

## Priority 7 — Subtitle and Audio Track Controls

### Goal

Expose media tracks that AVFoundation already makes available and support common
external subtitle files.

### Scope

- List embedded audio tracks and languages.
- List embedded subtitle and closed-caption tracks.
- Allow selecting `Off`, `Automatic`, or a specific subtitle track.
- Load adjacent `.srt` and `.vtt` subtitle files when supported safely.
- Offer an existing local transcript as subtitles when timing data is adequate.
- Remember per-video choices where useful; do not apply a language choice to a
  file that lacks it without a clear fallback.

### Acceptance criteria

- Track controls are unavailable with an explanation when no tracks exist.
- Audio and subtitle changes do not restart playback or lose the playhead.
- Full-screen and windowed playback show the same selected subtitles.
- External subtitle decoding failures are reported without disrupting playback.
- Tests cover track selection state and sidecar discovery independently of the UI.

### Likely integration points

- `FolderVideoPlayer/Playback/PlayerEngine.swift`
- `FolderVideoPlayer/Playback/AVPlayerEngine.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`
- `FolderVideoPlayer/Views/TransportBar.swift`
- `FolderVideoPlayer/Views/VideoSurface.swift`

## Priority 8 — Opt-in Background Library Maintenance

### Goal

Keep selected folders indexed without requiring every video to be played first,
while retaining the app's privacy and resource-use promises.

### Scope

- Users explicitly opt in per pinned folder.
- Detect additions, removals, and moves.
- Queue poster generation, metadata reads, transcription, face analysis, and tag
  analysis according to enabled AI capabilities.
- Settings control allowed work, schedule, battery behavior, and concurrency.
- Pause during active playback by default.
- Reuse the existing job ledger, cancellation, retry, and progress UI.

### Safety and performance requirements

- Default remains playback-only analysis.
- Never scan hidden videos.
- Never upload content or metadata.
- Limit concurrent network-share operations.
- A sleeping or disconnected NAS must not freeze launch or the main window.
- Store resumable progress so quitting does not restart an entire folder.

### Acceptance criteria

- No background work begins before explicit opt-in.
- Jobs pause and resume predictably across playback, sleep, disconnect, and
  relaunch.
- Removed files are not repeatedly retried.
- The UI identifies the current file, overall progress, and reason for pausing.
- Tests cover queue persistence, cancellation, hidden exclusions, and reconnects.

### Likely integration points

- `FolderVideoPlayer/Model/JobLedger.swift`
- `FolderVideoPlayer/Model/AnalysisEngine.swift`
- `FolderVideoPlayer/Model/Scanner.swift`
- `FolderVideoPlayer/Views/SettingsWindow.swift`
- `FolderVideoPlayer/Views/PlaylistSidebar.swift`

## Priority 9 — Direct Playback of Additional Formats

### Goal

Play common MKV, WebM, AVI, and FLV files without replacing or converting the
original.

### Approach

Implement a second `PlayerEngine` backend, then select an engine based on actual
playability. Keep the existing conversion flow as a fallback rather than removing
it. Evaluate VLCKit and libmpv for codec coverage, macOS integration, licensing,
binary size, signing, accessibility, full-screen behavior, and ongoing upkeep
before choosing one.

### Acceptance criteria

- Existing MP4/M4V/MOV playback remains on AVFoundation unless testing supports a
  different choice.
- Engine selection is invisible during normal playback.
- Play, pause, seek, speed, volume, duration, completion, full screen, and playlist
  navigation behave consistently across engines.
- Unsupported or damaged media still produces a clear error and advances safely.
- Original files are never changed merely to play them.
- Automated contract tests exercise both engine implementations.

### Likely integration points

- `FolderVideoPlayer/Playback/PlayerEngine.swift`
- `FolderVideoPlayer/Playback/AVPlayerEngine.swift`
- `FolderVideoPlayer/Playback/PlaybackController.swift`
- `FolderVideoPlayer/Views/VideoSurface.swift`
- `FolderVideoPlayer.xcodeproj/project.pbxproj`

## Later candidates

Consider these after the priority features have validated demand:

- Calendar and timeline browsing by recording date.
- A people gallery with unnamed-face review and merge/split tools.
- Contact-sheet generation for a video, folder, or smart collection.
- Export playlists as M3U or gather them as Finder aliases/copies.
- Import/export tags, ratings, transcripts, and moments in documented sidecars.
- A spreadsheet-style bulk metadata review view.
- A consolidated library health report.
- Spotlight indexing for tags, people, and transcript text.
- Explicit AirPlay and Picture-in-Picture controls.

## Definition of done for every feature

- The feature has focused model tests and regression coverage.
- Large local libraries and slow NAS shares remain responsive.
- Profile boundaries and hidden-video rules are preserved.
- New stored data is versioned or backward-compatible and written atomically.
- Empty, loading, unavailable, cancelled, and failed states are visible and
  understandable.
- Keyboard navigation, VoiceOver labels, and standard macOS behavior are checked.
- Help text and `README.md` are updated when the feature is user-facing.
- The full relevant test suite passes, and no unrelated user changes are removed.
