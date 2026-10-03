# Performance — verified findings (v1.2.5)

This is the consolidated result of checking two earlier reviews against the
source at v1.2.5 (`113a10d`):

- `docs/performance-review.md` — "review A", 14 findings
- `docs/gpt_performancereview1.2.5.md` — "review B", findings F01–F19

Every finding below was re-read in the code at the cited line. Only claims that
hold are kept; what was wrong or overstated in either review is listed in
[Rejected and corrected claims](#rejected-and-corrected-claims).

**What "verified" means here.** The code does what the finding says, at the
line cited. It does not mean the cost was measured: nothing was profiled for
this document, and review B's synthetic timings were not re-run (they are
quoted as "reported"). Priority is a judgement from the shape of the call path:

- **P1** — blocks the main thread on disk, scales with the whole library on a
  common path, or defeats Stop/timeout.
- **P2** — repeated derivation that grows with library or playlist size.
- **P3** — real but small; measure before spending time.

---

## P1

### 1. Every suggestion pass re-reads the whole embedding cache

`Model/CoreMLClassifier.swift:383–385`, `Model/TagPrototypes.swift:96`,
`Model/EmbeddingCache.swift:87,145` — reviews A#1, B F01

`suggest` calls `store.hashes()` (a full directory walk of the cache
namespace) and then `TagPrototypes.baseline`, which reads every `.f32` file and
sums it into a mean. All of it runs synchronously on the `CoreMLClassifier`
actor, with no cancellation check, so a concurrent `analyse` waits behind it.
The source comment at `TagPrototypes.swift:92–95` already says the caller
should cache this.

Scope: the automatic pass runs once per video that has no stored suggestions
yet (`SuggestionStore.wantsAutoSuggestion`, `PlayerWindow.swift:394`), plus
explicit re-suggests — not on every open. The cost per pass is O(cached
frames × dim). As a capacity illustration, 12,000 videos × 40 frames is 480,000
file reads and about 1.47 GB of float payload per pass.

**Fix.** Keep a running `(count, sum)` per namespace in the actor, updated
where a vector is written; rebuild only when it is absent or the space digest
changes. Keep the mean/normalisation semantics so parity fixtures still pass.

### 2. Smart-collection tooltips walk and sort the library, per rule, per redraw

`Views/PlayerWindow.swift:1290`, `Model/SmartCollectionStore.swift:122–126`,
`Model/Library.swift:1713` — reviews A#14, B F03

The sidebar's `.help` string calls `smart.problems(in:)` for every collection
row. Each name rule calls `pathsCarrying(name)` just to test `isEmpty`, and
`pathsCarrying` scans every tag entry (`taggedWith`), scans every fact entry
(`facts.carrying`), and sorts twice with the tokenising `naturalLess`.
Review B reports 1,909 ms for 30 such calls on a synthetic 10,000-video
library.

**Fix.** Existence only needs a case-insensitive name lookup. `Library`
already holds one for tags — `tagDisplay` is keyed by lowercased name
(`Library.swift:53,1049`) and already excludes hidden videos. Keep the same
folded map for facts (it is built and discarded in `recountFacts`) and answer
`knownNames` from the two. Do **not** use `count(anyName:)` as review A
suggests: it is keyed by display spelling (`Library.swift:1791`), so a rule
written `iceland` against a tag `Iceland` would be flagged as broken.

### 3. Synchronous file calls on the main actor

All of these are `@MainActor` code calling the filesystem directly. On a local
disk they are invisible; on a sleeping or slow SMB share each is a potential
beach ball. An enclosing `Task {}` or `async` function does not move them off
the main thread.

| Where | What blocks | Review |
| --- | --- | --- |
| `Playback/PlaybackController.swift:175–177` → `Model/MediaCache.swift:75` | The 0.25 s player time callback calls `media.remember`, which `lstat`s the playing file. Normally once per video with no stored length — but if the `lstat` fails nothing is stored, so it repeats on every tick. | B F05 |
| `Model/EvidenceJournal.swift:275–278` via `Views/TagPanel.swift:747` | `spans(for:)` stats the file (`SourceRevision.of`) **before** looking at its cache, and it is called once per suggestion chip from the view body. | B F04 |
| `Model/MovedScan.swift:175–186`, `Model/NameIndex.swift:26–38` | After the off-thread orphan check, the task is back on the main actor when it enumerates shares, reads and decodes each share's `name-index.json`, and `fileExists`-checks every cached hit. | B F06 |
| `Model/DuplicateFinder.swift:373–432` | `discardDoomed` trashes or moves every doomed copy in a loop on the main actor, and `mergeTags` → `setTags` runs per copy. | B F07 |
| `Model/HiddenVideos.swift:201–204` | `setPassword` runs the 200,000-iteration KDF inline. `unlock` (line 221) already detaches the same work, and its comment explains why. Review B reports 110 ms on its test Mac. | B F16 |
| `Playback/PlaybackController.swift:510,1387`; `Views/PlaylistSidebar.swift:1241,1516` | `fileExists` per transcript-search result and per look-alike candidate. | B F05 |

**Fix.** Same pattern the codebase already uses in `MediaCache.verifySize` and
`HiddenLock.unlock`: do the disk work in a detached task, then apply the result
on the main actor if the video/scan/profile is still the current one. For the
evidence spans, check the cache first and re-validate the revision behind the
answer.

### 4. Transcription reads the whole audio track into memory and cannot be stopped while decoding

`Model/SpeechPass.swift:88`, `Model/AudioExtraction.swift:67,107–119`,
`Views/PlayerWindow.swift:303` — review B F11

`SpeechPass` calls `AudioExtraction.samples(path:)` with no range, so the whole
track is accumulated as 16 kHz mono `Float` — 230 MB per hour of audio. The
`from`/`to` window the function supports is not used by the pass. The read loop
has no cancellation check, and Cancel only raises the transcriber's flag, which
is read later, in the model stage.

**Fix.** Add `Task.checkCancellation()` (and `reader.cancelReading()`) inside
the buffer loop — small and safe. Windowed decoding is the larger change and
needs care at window boundaries (timestamps, split words); publishing must stay
all-or-nothing.

### 5. The background scan's 60-second timeout does not bound anything

`Playback/MaintenanceWorker.swift:214–223,257–273` — review B F12

The timeout races a child task that awaits `Task.detached { walk(folder) }`
against a 60 s sleep, then calls `group.cancelAll()`. A task group does not
return until its children finish; cancelling the child does not cancel the
detached walk it is awaiting; and `walk` never checks for cancellation. So the
scan returns when the walk finishes, however long that is. Review B reproduced
the structure in isolation (50 ms timeout, 300 ms work, returned at 320 ms).

**Fix.** Hold the detached walk's handle, cancel it on timeout, and check
`Task.isCancelled` between directory entries. A walk blocked inside one SMB
syscall still cannot be interrupted; to return on time regardless, stop
awaiting it and discard its late result by generation.

---

## P2

### 6. Every tag write recounts the whole library and sorts every fact key

`Model/Library.swift:727–739,756–759,1037–1088` — reviews A#8, B F09

`saveTags()` and `saveTagsSoon()` both call `recount()`, which walks every tag
entry, then calls `recountFacts()`, which sorts all fact keys
(`facts.byKey.keys.sorted()`, line 1077) — even though a tag edit cannot change
a fact. `saveTagsSoon` defers the file write but not the recount, so triage
still pays it per answer.

**Fix, cheap.** Do not call `recountFacts()` from `recount()` when only tags
changed (hide/unhide and profile switches still need both).
**Fix, larger.** Apply count deltas for the changed keys instead of rebuilding.

### 7. Whole-file JSON writes on the main actor

`Model/Library.swift:670,727,780,826`, `Model/MediaCache.swift:120`,
`Model/SuggestionStore.swift:464–473`, `Playback/MaintenanceWorker.swift:140`,
`Model/JSONStore.swift:61–69` — review B F08

These stores encode and write on the main actor. `SuggestionStore.scheduleSave`
debounces by 400 ms, but its `Task` inherits the main actor, so the encode and
write still happen there. `MaintenanceWorker.persist()` runs after each work
step. If a rename fails, `JSONStore` sleeps 50 + 200 + 500 ms on the calling
thread. The source's own measurement (`Library.swift:748–750`) is 38 ms per
`tags.json` write at 10,000 tagged videos, 150 ms at 30,000.

`AnalysisStore.scheduleMachineSave` (`AnalysisStore.swift:141–156`) already
does this correctly — snapshot on the main actor, write detached — and is the
pattern to copy. Any change here needs ordered writes per file and a flush on
quit and profile switch.

### 8. A resume-position sample every 5 seconds invalidates every `Library` observer

`Model/Library.swift:72,2190`, `Playback/PlaybackController.swift:1173–1183`,
`Model/Paths.swift:420`, `Model/SmartCollectionStore.swift:41,135–158` —
review B F10

`progress` is `@Published` and is written every 5 s while a video is open
(playing or paused, as long as the position is positive). That fires
`library.objectWillChange`, which redraws every view observing the library and
makes `SmartCollectionStore` schedule a full re-evaluation of every collection
2 s later. The comment on `watch` (`Library.swift:73–75`) shows the same
problem was already solved for watch history by keeping it unpublished behind a
revision counter.

**Fix.** Treat `progress` the same way: unpublished, with a revision that moves
only when something a view shows actually changes. Have the smart-collection
store observe the revisions its rules read rather than all of
`objectWillChange`.

### 9. Natural sort that tokenises inside the comparator

`Model/Scanner.swift:62–65`, `Model/Library.swift:1557,1718`,
`Model/Formatting.swift:27` — review B F17

`naturalLess(String, String)` splits both strings on every comparison.
`Library.naturallySorted` (line 1756) exists to avoid exactly that. Three call
sites still use the slow overload:

- `Scanner.scan` — its comment says "the sort key is built once per path", but
  the key it builds is a relative-path *string*, so it still tokenises per
  comparison. Runs on every folder open (off the main thread).
- `Library.taggedWith` and `Library.pathsCarrying` — on the main actor, behind
  every tag, star and fact playlist. `paths(matching:)` then sorts the union a
  further time.

Review B reports 642 ms against 22 ms for 5,000 paths with identical output.

**Fix.** Use the decorate-sort-undecorate form at all three sites; in
`paths(matching:)`, collect unsorted sets and sort once.

### 10. Small repeated derivation in row and menu bodies

- `Views/PlaylistSidebar.swift:2429–2433` — `VideoFacts.body` calls
  `library.rating(path)` three times. Each call is up to five `hasTag` scans,
  each doing a `Paths.tagKey` conversion (`Library.swift:1927`). Hoist to one
  `let`. (review A#4)
- `Views/PlaylistSidebar.swift:2699–2701` — the row menu calls
  `library.handTaggableTags()` twice; each call filters the whole vocabulary
  twice (`Library.swift:1567,1593`). Hoist to one `let`, or cache it in
  `recount()`. (review A#5)
- `Views/PlaylistSidebar.swift:583`, `Playback/PlaybackController.swift:1279`
  — the tag strip recomputes `tagsInPlaylist` (a full playlist walk, count and
  sort) on every redraw of the sidebar. Memoise it against the playlist and tag
  revisions. (reviews A#6, B F17)
- `Playback/PlaybackController.swift:1426–1456` — `buildRows` re-derives the
  lowercased file name per path on each filter keystroke and the parent folder
  per path in folder order. Precompute when the playlist is assigned. Low
  payoff; do it only if filter typing shows in a profile. (review A#7)

### 11. Embedding vectors are re-read from disk with no memory tier

`Model/EmbeddingCache.swift:145`, `Model/TagPrototypes.swift:123–150`,
`Model/LookAlikes.swift:94–99`, `Model/FaceRegistry.swift:445–455` — reviews
A#2, B F02

Every `read` is a synchronous file read plus a `[Float]` allocation. Tag
prototypes are rebuilt from disk on every suggestion pass; look-alike ranking
rebuilds per-video means from disk on every search; `similarFaces` reads its
whole face-vector corpus per search.

**Fix.** A bounded memory tier keyed by namespace + hash (2,000 vectors of 768
floats is about 6 MB), and cache prototypes against a tag/analysis revision.
This does not replace finding 1: a full-cache scan would simply flush an LRU
smaller than the cache.

### 12. Moments and subtitle lookups are linear, at playhead frequency

`Views/TransportBar.swift:38`, `Model/Moments.swift:82–85`,
`Views/TranscriptPanel.swift:263` — review B F15

`TransportBar` observes the playhead, so its body runs four times a second, and
each run filters the entire moment book (all videos) and sorts the result. The
subtitle overlay does a reverse linear search of the transcript per update.
Review B reports 0.14 ms per lookup at 50,000 moments, so this is a scaling
concern rather than a present stutter.

**Fix.** Index moments by video key, rebuilt on edit. Binary-search the
subtitle lines by start time.

### 13. Background work without ownership, deduplication or a shared limit

- `Playback/PlaybackController.swift:199–213,1367–1375` — a folder scan's
  result is applied without checking that it is still the folder the user
  wants; opening three folders quickly lets a slow earlier scan land last.
  `AVPlayerEngine.load` already uses a generation for this. (B F14)
- `Views/PlayerWindow.swift:1226–1237` — sidebar counts for all pending roots
  are walked in one detached task and published together, so one slow share
  delays every other folder's count. (B F14)
- `Model/MediaCache.swift:219–234`, `Model/Library.swift:2330–2344` — posters
  and row stats cache only finished results; two views asking for the same
  cold item both do the work. (B F13)
- `Model/Library.swift:2359`, `Model/SmartCollectionStore.swift:246` — each
  caller has its own concurrency limit; there is no shared limit across the
  overview, sorting and smart collections. (B F13)
- `Model/MediaCache.swift:237` — `fetchPoster` uses `attributesOfItem` to get
  a size; the comment at `MediaCache.swift:58–65` explains why `lstat` replaced
  exactly this elsewhere (it is off the main thread here, so it costs round
  trips, not a freeze). (B F13)

### 14. Folder moves and duplicate maps scale worse than they need to

- `FolderVideoPlayerApp.swift:158–161`, `Model/SuggestionStore.swift:352–357,
  464–468` — a folder move calls `suggestions.move` once per video, and each
  call takes a snapshot of the whole dictionary for a save that is then
  cancelled by the next. Add a batch `move(_ pairs:)` like the other stores.
  (B F18)
- `Model/Moments.swift:230–232,111–118` — `move(pairs)` saves once, but scans
  the whole moment book once per moved video. One pass with a lookup map.
  (B F18)
- `Model/Library.swift:2542–2550` — `dupeSets()` stores, for every member of a
  group, an array of all the other members: O(G²) for a group of G copies.
  Store one list per group and a key → group map. (B F07)

---

## P3 — measure first

- **`CoreMLClassifier.warm()`** (`CoreMLClassifier.swift:173–176`) stats and
  reads the space marker and reads the model registry on every `analyse`,
  `suggest`, `explain` and `sightings` call. Small local reads. The 176 MB
  model digest is **not** recomputed per call — it is inside the
  `embedder == nil` branch (line 199). `readForInference` must stay live; it is
  what detects a model swap. (A#3, B)
- **`ModelDownloader.extract`** (`ModelDownloader.swift:925–936,962`) re-walks
  the extraction tree every 100 ms while `ditto` runs, and only drains
  `ditto`'s stderr after the loop, so a very chatty extractor could block on a
  full pipe. Install-time only. (B F19)
- **`MediaCache` poster cache** (`MediaCache.swift:50,228,279`) — the limit is
  written as bytes (512 MB) but costs are pixel counts, so the byte ceiling is
  about four times looser than it reads. The 500-image count limit still bounds
  it. (B)
- **`PlayableCopy`** (`PlayableCopy.swift:267–273`) keeps all of a process's
  stdout and stderr in memory for the whole run. (B)
- **`PromptTable.similarity`** (`PromptTable.swift:351–355`) is a scalar dot
  product. Compare against Accelerate (`vDSP_dotpr`) before changing; no
  speed-up figure is established. (A#12, B)
- **`TagSuggester`** (`TagSuggester.swift:250`) computes its ranking key inside
  the comparator. The candidate list is small. (A#11, B)
- **`NeighbourPrior.measure`** (`NeighbourPrior.swift:175`) does a
  `Calendar.isDate(_:inSameDayAs:)` per pool entry. Off by default
  (`NeighbourPrior.swift:220`). (A#10, B)
- **View-body file probes** — `SettingsWindow.swift:852,879` and
  `PeopleWindow.swift:779` read local files while building a view. (B)

---

## Rejected and corrected claims

### In review A (`performance-review.md`)

| Claim | Verdict |
| --- | --- |
| #9 — `MediaCache.length` re-asks the disk on every call for never-measured videos | **Wrong.** `length` returns `nil` straight from a dictionary miss (`MediaCache.swift:140–145`); `verifySize` runs only when an entry exists, and is deduplicated. No negative cache is needed. |
| #14 fix — swap to `count(anyName:)` | **Would introduce a bug.** That lookup is by display spelling; rule validation is case-insensitive today. See finding 2. |
| #1 — suggestion "runs automatically on every video opened" | **Overstated.** Once per video without stored suggestions. The per-pass cost is as described. |
| #4 — `VideoRow.body` calls `rating` three times; `IconTile.body` twice | **Misattributed.** The three calls are in `VideoFacts.body`; `IconTile` has no direct `rating` call. |
| #6 — `pruneTagFilter` walks the playlist on every `rebuildRows` | **Overstated.** It returns immediately unless a tag filter is ticked (`PlaybackController.swift:1330`). The per-redraw read from the tag strip is real. |
| #7 — "~15,000 NSString allocations per keystroke" | **Unsupported figure.** The name work runs only with a filter typed, the folder work only in folder order. |
| #8 — `setRating` "rebuilds the entire tags dictionary" as an extra cost | **Misleading.** That is the batch path: one copy and one save for the whole selection. |
| #10 — "allocates a `Date` per pool entry" | **Wrong mechanism.** `Date` is a value type; the cost is the calendar comparison. |
| #12 — unsafe pointers "would be several times faster" | **Unsupported.** Not measured; the optimiser may already remove the checks. |
| #13 | Not a finding (the review says so itself). |
| "Suggested order of work" table | Rows "#2 baseline accumulator" and "#1 EmbeddingCache memory tier" have their numbers swapped relative to the findings. |

Findings #2, #3, #5, #11 hold as written.

### In review B (`gpt_performancereview1.2.5.md`)

| Claim | Verdict |
| --- | --- |
| Correction 2 — "duplicate derivation is already off-thread", presented as fixing review A | Review A never said otherwise. The statement itself is true (`DuplicateFinder.swift:237`). |
| "Reviewed checkout `d0fc52c`" | No such commit exists in this repository. The line references do match `113a10d`. |
| F03 — "retain a case-insensitive known-name set" | Correct in substance; half of it already exists as `tagDisplay`. |
| All timings in "Synthetic measurement method" | **Not re-run** for this document. The code structure each one exercises was confirmed; the numbers are review B's. |
| "Nine existing test suites passed" | Not re-run. |

Its corrections 1, 3, 4 and 5 to review A are right.

### Not independently verified

Read only far enough to confirm the cited line exists, not the full call path:
`FolderOps.swift:139,167,204` (preflight on the main actor),
`TagSharing.swift:166` (whether `Paths.networkShares()` touches the disk),
`EvidenceJournal.decide` re-reading each row after `setDecision` (the per-row
loop at lines 256–262 is confirmed), the `%substring%` `LIKE` fallback beyond
its first line, and the startup-load ordering in
`FolderVideoPlayerApp.swift:55–80` (`Library.init` calling `load()`
synchronously is confirmed).

---

## Fix status

Branch `perf/verified-fixes`, on top of `113a10d`. "Done" means the change is
in and the app builds; see the branch's test run for what was exercised.

| # | Finding | Status |
| --- | --- | --- |
| 1 | Baseline re-read per suggestion | **Done.** Running sum in the classifier, updated on each cache write. The first suggestion after launch still reads the cache once. |
| 2 | Smart-collection tooltip | **Done.** `Library.isNameInUse`, a folded lookup. |
| 3 | Main-actor file calls | **Mostly done.** Player callback, missing-file index, duplicate discard, password creation, transcript-search and look-alike existence checks are off the main thread. Evidence spans are asked once per panel instead of once per chip, but that one `stat` is still synchronous. `FolderOps` preflight not touched. |
| 4 | Transcription | **Half done.** Cancel now stops the audio decode (and a cancel during decode is no longer lost), and the sample buffer is sized once instead of doubling as it fills. The whole track is still held in memory: decoding in windows means stitching the model's output across boundaries, which cannot be checked without real transcription runs. |
| 5 | Scan timeout | **Done.** Real 60 s deadline; the walk checks for cancellation; a folder whose walk is still out is not walked again. |
| 6 | Recount per tag write | **Half done, rest declined.** Facts are recounted only when the readings or the hidden set changed. The tag recount stays a full pass: the source's own figure (`Library.swift`, at `saveTagsSoon`) puts everything but the file write at about 4 ms of a 42 ms save at 10,000 videos, which does not justify an incremental scheme. |
| 7 | Main-actor JSON writes | **Mostly done.** `JSONStore.saveBehind` encodes and writes on one serial queue; every `load`/`save` drains it first, so order holds. Used for the deferred tag write, the fingerprint index, the upkeep file; suggestions and durations have their own queues. A tag edit saved with `saveTags()` (not `saveTagsSoon`) and the state and facts files are still written on the main thread, by design: other code reads those files straight after. |
| 8 | 5-second resume sample | **Half done.** Smart collections re-evaluate only on changes a rule reads. `progress` is still published, because the row's progress bar is drawn from it. |
| 9 | Natural sort in the comparator | **Done** at `Scanner.scan`, `taggedWith`, `pathsCarrying`, `paths(matching:)`, `hiddenPaths`. |
| 10 | Row and menu derivation | **Done** for the rating, the tag menu and the tag strip. `buildRows` precomputation not done. |
| 11 | Embedding reads | **Partly done.** 8,192-vector memory tier in `EmbeddingCache`, which covers the prototype rebuild (at most 80 vectors a tag). Look-alike and face searches still read their corpus per search. |
| 12 | Moments and subtitles | **Half done.** Moments are indexed by video. Subtitle lookup unchanged. |
| 13 | Background work ownership | **Mostly done.** Folder scans drop stale results; sidebar counts land per folder; posters use `lstat`; row stats are asked once per file however many rows ask. Posters are not deduplicated, and there is no shared limit across callers. |
| 14 | Folder moves, duplicate map | **Done.** |
| P3 | All | Poster cache cost is now in bytes. The rest not started — each wants a measurement first. |

## Suggested order

1. **Small, local, low-risk:** finding 2 (folded name lookup), the three
   hoists in finding 10, the password KDF and evidence-span cache order in
   finding 3, the cancellation check in finding 4, `recountFacts` out of
   `recount` in finding 6, the three sort call sites in finding 9.
2. **Largest scaling fix:** finding 1, then finding 11.
3. **Main-thread disk work:** the rest of finding 3; finding 8.
4. **Structural:** finding 5, finding 7, incremental recount (6), finding 13.
5. **When a profile says so:** findings 12, 14 and everything under P3.
