# FolderVideoPlayer 1.2.5 — performance review and possible solutions

Reviewed on **2 October 2026**. This report covers the main user-facing sections and their supporting Model, Playback and Views call paths. It proposes changes; no application source was modified.

## Scope and evidence

- Both Debug and Release settings identify **version 1.2.5, build 5** in `FolderVideoPlayer.xcodeproj/project.pbxproj:267,282,297,312`.
- Reviewed checkout: **`d0fc52c`**. Its application code matches the **`113a10d`** 1.2.5 release commit; the intervening changes only add `docs/performance-review.md`.
- Evidence combines source inspection, **nine existing test suites**, and small synthetic experiments using the actual optimized model module. Measurements were taken on an **arm64 Mac running macOS 26.6.2**.
- This is **not a complete runtime profile of the installed app**. No production library, real AI model pack, NAS workload, video playback session, or WhisperKit inference was profiled. Findings identify real work in the code; user-visible severity still depends on library size, storage latency and hardware.
- Source references below are repository-relative `file:line` locations in this checkout. Historical timings in source comments are not treated as new measurements.

**Recommendation:** first remove library-wide work and synchronous filesystem calls from interface paths, then bound speech memory and fix background cancellation. Avoid starting with minor arithmetic optimizations.

Priority meanings: **P1** = address first, because the path can block interaction, scale across the library, or defeat stopping work; **P2** = address next for larger libraries or sustained use; **P3** = measure before investing substantially. These are performance priorities, not security ratings.

## Section-by-section verification

| App section | What is already handled | Remaining concern / possible solution |
| --- | --- | --- |
| Launch and resume | Folder walks and AVFoundation asset inspection happen asynchronously; AVPlayer uses a load generation. | Large local stores still load/decode synchronously during object construction and profile opening. Stage heavy stores after the first usable window; see F18. |
| Video playback | AVFoundation player, a separate `Playhead`, 0.25-second time updates, and asynchronous track loading. | The time callback can synchronously stat a new video when remembering duration. Move this check out of the callback; F05. |
| Transport, seeking and watch state | Seek occurs when slider editing ends; progress persists every 30 seconds rather than every tick. Watch-state revision changes are separated from quiet history updates. | Published resume updates still invalidate library observers every five seconds, and scrubber moments scan the whole moment book. F10, F15. No verified decoding/rendering throughput defect in the player itself. |
| Full screen, Picture-in-Picture and rotation | Full-screen overlay hiding uses a cancellable three-second task; the surface delegates video drawing to AVKit. | No material bottleneck established by inspection. Profile animation and dropped frames with AI enabled before changing these paths. |
| Playlist list/grid, thumbnails and sorting | Lazy rows/grids, held playlist rows, cached posters, cached stats and precomputed sort keys in `Library.sorted`. | Filtering repeats name/path work; some tag query sorts still build natural keys inside comparisons. Poster/stat requests can overlap without shared admission control. F13, F17. |
| Library sidebar: folders, stars, tags, people and facts | Tag/fact counts are derived on changes; folder counts are off-thread and cached. | Smart-collection tooltips walk and sort the library. Folder-count walks duplicate opening scans and can finish after their view task was cancelled. F03, F14. |
| Combined playlists and tag filters | Filename filter is debounced by 120 ms; row building is retained. | `pathsCarrying` scans/sorts once per name, and filter chips/pruning repeatedly derive the playlist vocabulary. Cache inverted membership and playlist vocabulary; F17. |
| Tags, favorites, ratings and bulk edits | Selection rating is assigned and saved as one batch; chip hover work was already reduced. | Whole-library recounts and whole-file writes still run on individual edits; rows ask for the same rating repeatedly. F08, F09, F17. |
| Triage | Cached remaining counts, a session-specific undo history, and deferred tag-file writes. | `saveTagsSoon` still recounts immediately, and evidence decisions can issue several synchronous SQLite updates per answer. F04, F08, F09. Existing triage tests passed. |
| Tag profiles, opening/closing, import/export and sync | Share synchronization is serialized and its main share work is off-thread; profile context guards exist. | Profile loads and some sync setup still touch disk on the main actor. Folder moves can cause repeated whole-map snapshots in the suggestions store. F18. |
| Metadata / automatic tagging | Separate fast/detail passes, bounded concurrency, cached file dates, and cached/throttled geocoding. | Full facts saves/count sorts remain expensive as facts grow; background metadata saves once per processed video. F08, F09. Geocoding latency should remain visible as a separate stage. |
| Safe/NSFW classification | Shared decoded frames, 40-frame classification cap, model reuse and a delayed off-thread machine-file write. | Main-actor snapshot creation still scales with all records; other stores do not share the same off-thread write discipline. F08. No measured model-throughput regression established. |
| AI tag suggestions and explanations | Embeddings are cached by frame content and model space; classify-before-suggest reuses decoded frames. | Each suggestion enumerates and rereads the full embedding cache and rebuilds prototypes. F01, F02. This is the largest structural growth risk. |
| Look-alike suggestions and training | Ranking/training heavy work generally runs away from the UI; offered candidates are bounded. | Video means are repeatedly reconstructed from disk; candidate existence checks return to the UI thread. F02, F05. |
| People / Add Faces / face search | Cached per-video detections, shared decoded frames, detached identity lookup, and bounded chooser results. | Library face searches still enumerate vectors and compare against references; keep an indexed memory tier and invalidate on registry changes. F02. No evidence justifies replacing the bounded Add Faces path. |
| Transcript generation | Batch jobs reuse a loaded transcriber; speech models unload afterward; source revision and cancellation are checked before saving. | `SpeechPass` reads the entire audio into memory; decoding itself lacks a cancellation check in its buffer loop. F11. Speech tests passed outside the sandbox. |
| Transcript panel, editing, search and subtitle overlay | Transcript SQL has a path index and FTS5 where available; editing retains the original; the panel reloads on relevant changes. | SQLite reads/searches are synchronous at UI callers; punctuation queries use substring `LIKE`; the overlay scans lines every playhead update. F04, F15. |
| Embedded audio/subtitles and sidecar subtitles | Asynchronous AVFoundation track loading, off-thread sidecar discovery/parsing, remembered choices. | Subtitle line/cue lookup is linear for long transcripts/sidecars. Index by start time; F15. Existing track tests passed. |
| Library Overview: all seven cards | Builds from memory first, warms dates with two concurrent stats, then rebuilds. Hidden videos are excluded. | Building all card lists and sorting recent results still occurs on the UI thread; overlapping warms continue after cancellation. Use snapshots, shared stat admission and generation guards. F10, F13. Existing overview tests passed. |
| Smart collections / editor | Debounced results, one transcript query per distinct phrase per evaluation, delayed two-worker disk warming and cached existence. | Tooltip validation, broad invalidation, synchronous evaluation/SQL, and detached work that outlives cancellation. F03, F04, F10, F13. Existing rule tests passed. |
| Moments / bookmarks / range export | Profile isolation, stable ordering, batch save on moves, AVFoundation/FFmpeg range export. | The scrubber queries a flat all-video array every tick; moving many videos repeatedly scans that array. Index by video and retain ordered lists; F15, F18. |
| Sharing / Prepare for Sharing / conversion | Sequential exports, remux when suitable, async export/process completion, partial outputs and cancellation handlers. ZIP uses storage without unnecessary recompression. | Process output is accumulated for the entire run; throttle progress and bound diagnostic buffers. Some destination preflight stats occur on the UI thread. F05 and P3 notes. No synchronous wait for the entire FFmpeg export was found. |
| Duplicate finder | Sweep and result existence checks are off-thread; grouping is revision-cached; keepers are derived from held data. | Actual bulk Trash/fallback moves are synchronous on the main actor. Duplicate sibling mapping can use quadratic memory for one huge group. F07. |
| Missing-file repair | Orphan collection, target hunting and candidate stats mostly happen off-thread with progress. | The cached name-index branch reads NAS JSON and verifies its hits on the main actor. Move that entire branch to a worker; F06. |
| Organize Folders / Library Folders / relocation | Folder trees/listings are off-thread; touched-subtree refreshes and batched library saves exist; profile propagation is detached. | Preflight filesystem operations still occur on the main actor, and per-video outside-store moves repeat scans/snapshots. F05, F18. |
| Hidden videos and password settings | Set-based visibility filtering; password **unlock** derivation is detached. | Password **creation/change** derives synchronously on the main actor despite the async function. F16. |
| Background upkeep | Opt-in, battery/playback pause policies, bounded light-work batch and serialized AI passes. | The scan timeout waits for the detached worker; whole maintenance state persists after each work step, and scans do not check cancellation between entries. F08, F12. |
| Settings, AI pack downloads and app updates | Download files stream to disk; checksums stream; install recovery/version-copy operations use workers; update download/tool completion is async. | Archive watchdog repeatedly walks/stat-checks the growing extraction directory. Some local capability/log probes run during view construction. F19 and P3 notes. |
| Help and static menus | Mostly static content and ordinary controls. | No major concern established. Dynamic menu/tooltip values must use held counts rather than library scans; preserve that rule as features are added. |

## Findings and possible solutions

### F01 — P1: every AI suggestion rereads the entire embedding cache

**Evidence:** `FolderVideoPlayer/Model/CoreMLClassifier.swift:381–385`, `FolderVideoPlayer/Model/EmbeddingCache.swift:87,145`, `FolderVideoPlayer/Model/TagPrototypes.swift:96`. `suggest` builds prototypes, calls `store.hashes()`, then calculates a baseline by reading every usable `.f32` vector. This happens even when only one video needs new suggestions. These synchronous loops occupy the classifier actor and contain no cancellation checkpoints.

**Impact:** cost is approximately O(F × D) per suggestion, where F is the number of cached frames and D is the vector dimension. For illustration, 12,000 distinct videos × 40 distinct cached frames could produce 480,000 entries: about **1.47 GB of float payload** read per baseline, plus hundreds of thousands of small file operations. That is a capacity scenario, not the measured cache size on this machine; content deduplication and failed frames change the count.

**Solution:** keep a namespace-specific baseline accumulator and normalized result, with a cache revision. Account for each unique hash once; update only when a new vector is successfully stored. Rebuild after namespace changes, deletion, corruption or external cache modifications. Store an index/checkpoint so cold launch does not require a blocking rebuild before suggestions appear. Preserve the current mean and normalization semantics. Cancellation should be checked in long rebuild loops.

**Verification:** count directory walks, vector read calls and baseline rebuilds across ten consecutive videos. After initialization, an unchanged library should perform **no full-cache baseline scan** per video. Compare resulting suggestions against existing prototype/suggester parity fixtures.

### F02 — P2: prototypes, look-alike means and face searches lack reusable derived caches

**Evidence:** `FolderVideoPlayer/Model/TagPrototypes.swift:123`, `FolderVideoPlayer/Model/LookAlikes.swift:94`, `FolderVideoPlayer/Model/EmbeddingCache.swift:145`, `FolderVideoPlayer/Model/FaceRegistry.swift:445`, `FolderVideoPlayer/Model/FaceLookAlikes.swift:75`. Look-alike ranking reads vectors to build tagged means, corpus means and pool scores; overlapping inputs can be read several times in one search. Suggestion prototypes are rebuilt on every video. Face searches reread their vector corpus as well.

**Solution:** first memoize hash reads and per-video means within each pass. Then add a bounded memory tier keyed by **namespace + hash** and a derived mean cache keyed by namespace + ordered frame hashes. Cache prototypes against tag/analysis revisions and the active profile. Cache face vectors against registry/cache revision. A 2,000-entry tier of 768-float vectors holds about **6.14 MB of raw floats**, plus container overhead.

An LRU alone does not solve F01: scanning a cache much larger than the LRU can evict the whole working set every pass. Keep the aggregate/index solution separate. Do not assume a `[Float]` cache avoids all allocation or I/O on cold reads.

**Verification:** record repeated reads of the same hash and end-to-end search latency. Require unchanged ranking and profile/model-space isolation.

### F03 — P1: smart-collection tooltip validation scans and sorts the library

**Evidence:** `FolderVideoPlayer/Model/SmartCollectionStore.swift:122–126`, `FolderVideoPlayer/Views/PlayerWindow.swift:1290`, `FolderVideoPlayer/Model/Library.swift:1713`. The sidebar computes `.help` strings using `problems(in:)`. Name validation calls `pathsCarrying(name)`, which scans tag/fact membership and naturally sorts all results just to test whether any exist.

**Measured primitive:** 30 `pathsCarrying` calls over a synthetic 10,000-video library took **1,909 ms**. Thirty membership checks in a previously built folded vocabulary set took **0.002 ms**. This measures the primitive the tooltip uses, not an instrumented SwiftUI redraw.

**Solution:** retain a case-insensitive known-name set derived when tag/fact visibility changes, and answer existence from it. Cache per-collection problems by collection and vocabulary revision. The existing `count(anyName:)` is fast but uses **exact dictionary spelling** (`FolderVideoPlayer/Model/Library.swift:1791`); replacing the current case-insensitive lookup with it directly could flag valid mixed-case rules. Preserve case-insensitive behavior and hidden-video exclusion. Validation needs existence, not a union count of videos.

**Verification:** mixed-case tag/fact rules must remain valid; hidden-only names must follow existing behavior. Measure tooltip construction with 10 collections × 3 name rules: it should contain no library walk or sort.

### F04 — P1: evidence display and transcript operations perform synchronous I/O at UI callers

**Evidence:** `FolderVideoPlayer/Views/TagPanel.swift:746`, `FolderVideoPlayer/Model/EvidenceJournal.swift:275–278,317`. Every `spans(for:)` call checks `SourceRevision.of(path)` **before** consulting the span cache. One chip per suggestion therefore repeats the source-file stat during body evaluation, even when the SQLite rows are cached.

`FolderVideoPlayer/Model/EvidenceJournal.swift:123,184,246` also exposes synchronous transcript/search/decision operations. `FolderVideoPlayer/Model/SmartCollectionStore.swift:175` requests up to 100,000 matching lines on the main actor. `FolderVideoPlayer/Model/EvidenceStore.swift:904` uses FTS5 for word queries, but falls back to `%substring%` `LIKE` for other queries. `decide` updates matching evidence rows individually; `setDecision` also rereads each updated row.

**Solution:** fetch one video's spans and source revision asynchronously when the path or evidence revision changes; pass held results to chips. Refresh staleness through explicit invalidation or a bounded background check rather than a stat per chip. Give SQLite work a serialized worker with profile/context validation before publishing. Batch decisions in one transaction and return only necessary data. For smart collections, query distinct matching video paths rather than materializing complete transcript lines.

**Verification:** render a suggestion panel on a delayed filesystem and confirm zero file stats/SQL from its body. Preserve staleness detection and edited transcript search. Measure word and punctuation searches separately.

### F05 — P1 on slow shares: remaining UI-thread file checks can block playback/navigation

**Evidence:** `FolderVideoPlayer/Playback/PlaybackController.swift:171–177` calls `MediaCache.remember`, which synchronously calls `fileSize`/`lstat` at `FolderVideoPlayer/Model/MediaCache.swift:75`. It is reached when playback first discovers an uncached duration, from the quarter-second player callback.

Other examples are `FolderVideoPlayer/Playback/PlaybackController.swift:509,1387` (existence checks for transcript playlists), `FolderVideoPlayer/Views/PlaylistSidebar.swift:1241,1516` (look-alike candidate existence), and `FolderVideoPlayer/Model/FolderOps.swift:139,167,204` (folder preflight/symlink resolution). An async outer function or `Task` created on the main actor does not make its synchronous code background work.

**Solution:** gather byte size/revision and existence in explicit workers with shared concurrency limits. Publish only if the video/navigation generation still matches. Keep duration display optimistic while a background size check validates it. Avoid moving every check into a separate unbounded detached task.

**Verification:** test first playback of an uncached NAS video and opening 30 look-alike candidates with injected metadata latency. Time Profiler should show no filesystem wait on the UI thread for these paths.

### F06 — P1: the missing-file index fast path can freeze the interface

**Evidence:** `FolderVideoPlayer/Model/MovedScan.swift:175–186` runs after an await inside its main-actor task. It calls `Paths.networkShares()`, `NameIndex.freshAcrossShares`, then `NameIndex.resolve` with synchronous `fileExists`. `FolderVideoPlayer/Model/NameIndex.swift:26–38` reads and decodes index files stored on the shares. `NameIndex.absorb` later writes shared indexes from the same task.

**Solution:** move mounted-share discovery, index loading/decoding, cached-hit verification and index publication into a worker stage. Snapshot discard/hidden inputs before dispatch. Check cancellation and the scan/profile generation before applying results. Keep hit verification; a cached index must not make a moved path appear live.

**Verification:** use a sleeping/unreachable share with an existing name index. Start/Stop and the rest of the window should remain responsive during index reads and hit checks.

### F07 — P1: duplicate removal is synchronous; large duplicate groups also duplicate memory

**Evidence:** `FolderVideoPlayer/Model/DuplicateFinder.swift:373–432` loops through every doomed copy on the main actor and calls `trashItem` or its fallback filesystem move. Off-thread sweeping and `derive()` do not protect this action. `mergeTags` also changes published tags per copy.

`FolderVideoPlayer/Model/Library.swift:2542–2550` constructs every member's array of all other members. A group of G copies stores O(G²) references. A synthetic size example of G = 1,000 means nearly one million sibling entries, even though they describe one group.

**Solution:** resolve the user's fallback folder choice on the UI thread, then run bounded file operations in a worker, showing progress. Commit tag/index changes in batches for successful operations, preserving merge and undo behavior. Store `key → group ID` plus one member list per group, deriving siblings only for the requested row.

**Verification:** remove a large selection from a delayed share and keep the window interactive. Check cancellation/failure reporting and tag preservation. Measure peak memory with one very large duplicate group.

### F08 — P1/P2: whole-file persistence still runs on the main actor in several stores

**Evidence:** `FolderVideoPlayer/Model/Library.swift:670,727,775,826,2450` saves state, tags, facts and fingerprints synchronously. `FolderVideoPlayer/Model/MediaCache.swift:120` saves durations there. `FolderVideoPlayer/Model/SuggestionStore.swift:464–473` debounces for 400 ms but performs JSON encoding/writing in its inherited main-actor task. `FolderVideoPlayer/Playback/MaintenanceWorker.swift:140,330–345` saves its queue and full known-folder state after individual work steps.

`FolderVideoPlayer/Model/JSONStore.swift:57–65` can sleep for 50 + 200 + 500 ms retrying rename. When reached from a main-actor writer, that retry sequence alone can block it for **750 ms**, in addition to storage latency. Most of these stores normally live on local storage, so this is a possible failure path rather than a claim that each edit incurs NAS retries.

**Solution:** use an ordered persistence worker per target file. Capture immutable snapshots on the owning actor; encode/write off-thread; coalesce replaceable snapshots. Maintain generations so an older snapshot cannot overwrite a newer one. For user decisions, define a durability strategy: a small append-only journal can acknowledge edits promptly while full snapshots are compacted later. Flush pending work on profile switch and quit, and keep dirty state on failure.

`AnalysisStore` already writes its large machine file off-thread every 15 seconds (`FolderVideoPlayer/Model/AnalysisStore.swift:141–156`), so preserve that improvement. Its `mapValues(machineOnly)` snapshot is still constructed on the main actor and should be measured separately. A debounce reduces frequency; it does not move encoding off-thread.

**Verification:** trace encoding time, write count/bytes and UI-thread stalls during 200 edits and a 1,000-video upkeep run. Verify ordered persistence, failure recovery, profile isolation and quit flush before changing durability.

### F09 — P2: every tag answer still recounts the whole library and sorts all fact keys

**Evidence:** `FolderVideoPlayer/Model/Library.swift:727,756,1037,1067`. Both immediate and deferred tag saves call `recount()`. It scans all visible tag entries, then calls `recountFacts()`, which sorts all fact keys even when only a hand tag changed.

**Solution:** separate tag, fact and visibility revisions. First stop recounting facts for pure tag edits. Next update counts from changed video keys rather than rebuild the whole library. Keep a full rebuild for load, repair and validation. Retain stable display spellings and handle hidden/unhidden videos explicitly.

**Verification:** compare incremental counts/vocabularies to a full rebuild after mixed tag/fact edits, rating changes and hide/unhide. Measure p95 answer time at 1,000, 10,000 and 30,000 videos. Existing triage batching is useful and should remain.

### F10 — P2: broad library notifications trigger expensive derived work during ordinary playback

**Evidence:** `FolderVideoPlayer/Model/Library.swift:72,2172` publishes resume mutations. `FolderVideoPlayer/Playback/PlaybackController.swift:1173` samples every **five seconds**, including a paused video whose position remains positive. `FolderVideoPlayer/Model/SmartCollectionStore.swift:41–42` observes entire objects and schedules reevaluation after two seconds; `evaluate` and collection sorting then execute on the main actor.

This is not the already-fixed four-times-per-second playlist playhead problem. It is a separate, slower invalidation path that can still re-answer all collections on unrelated preference or resume updates. Continuous changes can also keep postponing a pure debounce.

**Solution:** observe rule-relevant revisions, not every `objectWillChange`. Reevaluate watch-state rules on semantic watch changes; keep precise resume tracking separate. Use debounce plus a maximum wait where continuous changes must eventually appear. Evaluate immutable context snapshots off-thread and publish under a generation guard. For the overview, bound recent-list sorting with top-K selection if profiles show it matters; its current 200-item result cap applies after sorting.

**Verification:** count evaluations during one minute of playing, pausing, changing volume and tagging. Unrelated changes should not re-answer all rules, while membership remains correct after relevant edits.

### F11 — P1: transcription buffers entire audio; early cancellation cannot stop decoding

**Evidence:** `FolderVideoPlayer/Model/SpeechPass.swift:88` calls `AudioExtraction.samples(path:)` with no range. `FolderVideoPlayer/Model/AudioExtraction.swift:67,108` then accumulates all 16 kHz mono Float samples. The helper supports `from`/`to`, but the actual speech pass does not use them. The buffer-reading loop has no cancellation check. The UI cancel route in `FolderVideoPlayer/Views/PlayerWindow.swift:303` raises the transcriber's flag, which is only read by the model stage.

**Impact:** raw float audio requires **230.4 MB per hour**, or **460.8 MB for two hours**, before model tensors, decoding buffers and other app caches. WhisperKit's internal windows do not remove that input allocation.

**Solution:** decode bounded audio windows or a streaming/file-backed input supported by the pinned transcriber. For windowed transcription, handle overlap, sentence boundaries, global timestamps and language consistency; do not simply concatenate overlapping results. Keep transcript publication atomic after a successful complete pass. Add a shared cancellation signal to decoding, check between buffers, call `reader.cancelReading`, and retain the source-revision guards. Reserve audio capacity based on the bounded window, rather than repeatedly requesting capacity as the entire track grows.

**Verification:** compare a long recording's peak resident memory and Stop acknowledgement against a short one. Memory should plateau with window size. Verify boundary words/timestamps and that cancellation or source changes never publish a partial transcript. The passing fake-transcriber tests do not verify WhisperKit memory behavior.

### F12 — P1: the background scanner's one-minute timeout does not bound completion

**Evidence:** `FolderVideoPlayer/Playback/MaintenanceWorker.swift:214–223` races a child awaiting `Task.detached { walk(folder) }.value` against a 60-second sleep, then calls `group.cancelAll()`. Leaving a task-group scope waits for its children. The detached walk is not automatically cancelled by cancelling the child awaiting it, and `walk` has no cancellation checks.

**Measured reproduction of that structure:** a 50 ms timeout racing 300 ms detached work returned the timeout result after **320 ms**, not around 50 ms. This demonstrates the concurrency issue independently of NAS variability.

**Solution:** give scans an explicit owner, cancellation signal and generation. Check cancellation between directory entries and discard late results. For a hard deadline on a blocked SMB syscall, use an independently managed worker or cancellable helper process; adding a task check cannot interrupt a syscall already waiting in the kernel. If the UI detaches from a timed-out worker, retain/limit workers so retries cannot accumulate orphan scans. Recheck profile identity, cancellation and pause policy before adopting a scan result.

**Verification:** inject a blocked scanner; timeout reporting and Stop should occur within their defined budgets. Repeated retries must not increase live worker count or let stale results alter the next profile.

### F13 — P2: poster/stat work needs shared in-flight deduplication and backpressure

**Evidence:** `FolderVideoPlayer/Model/MediaCache.swift:219` checks completed memory entries but keeps no in-flight poster map. Multiple surfaces can request the same poster before it completes. `FolderVideoPlayer/Model/Library.swift:2330` similarly caches only completed stats. `warmStats` has a per-call limit, but separate overview, sort and collection warms each create detached task groups (`FolderVideoPlayer/Model/Library.swift:2359`, `FolderVideoPlayer/Model/SmartCollectionStore.swift:246`). Per-call limits do not impose a global limit, and cancellation of the awaiting UI task does not automatically cancel detached work.

**Solution:** share `(path, revision, size class) → in-flight request` handles and a storage admission controller. Prefer current playback over prefetch; lower priority for maintenance and offscreen posters. Allow bounded local/NAS limits separately. Drop queued obsolete requests on cancellation. Use the minimum required attributes: poster byte-size lookup currently asks for the whole attribute dictionary (`FolderVideoPlayer/Model/MediaCache.swift:237`).

**Verification:** open the same video in several surfaces while scrolling quickly. Each cold poster/stat should be fetched once per revision, and total concurrent NAS requests should remain within the configured limit.

### F14 — P2: rapid navigation can leave obsolete scans consuming resources

**Evidence:** `FolderVideoPlayer/Playback/PlaybackController.swift:195` starts an untracked folder scan and accepts its result without a navigation generation. `refreshAfterFileChanges` repeats the pattern at line 1362. `FolderVideoPlayer/Views/PlayerWindow.swift:1221` walks every uncached sidebar root and awaits an unstructured detached task without cancellation checks. There can be simultaneous opening, sidebar-count and maintenance walks of the same tree.

**Solution:** track scan handles/generations as `AVPlayerEngine.load` already does. Discard results for a folder that is no longer current and cancel between entries. Reuse an opening scan's count instead of immediately walking the same tree for the sidebar. Publish counts per completed root so one sleeping share does not delay all other roots' labels. Bound and coalesce simultaneous rescans.

**Verification:** select three large folders rapidly and refresh twice. Only the last request should own the playlist; obsolete scans should stop issuing new work, and counts for responsive roots should arrive promptly.

### F15 — P2: moments and subtitles repeat linear scans at playback frequency

**Evidence:** `FolderVideoPlayer/Views/TransportBar.swift:38` asks `moments.moments(for:)` during playhead updates. `FolderVideoPlayer/Model/Moments.swift:82` filters the entire all-video array and sorts the selected moments. `FolderVideoPlayer/Views/TranscriptPanel.swift:263` finds the active line with a reverse linear search. Sidecar cue selection is also linear in `Model/MediaTracks.swift`.

**Measured:** 100 actual moment lookups over a 50,000-moment book with 100 selected moments took **13.94 ms**. This small local result makes indexing a scaling improvement, not proof that normal playback currently stutters.

**Solution:** keep ordered per-video moment lists, rebuilt only on moment edits/moves. For sorted transcript/cue start times, use a binary search plus a last-active cursor for normal forward playback, resetting on seek. Preserve the current latest-started behavior for overlaps and gaps.

**Verification:** compare active subtitles after forward/backward seeking and overlapping cues. Measure a long transcript and a large moment book at the normal four updates per second.

### F16 — P2: password creation hashes on the UI thread

**Evidence:** `FolderVideoPlayer/Model/HiddenVideos.swift:201–205`: main-actor `setPassword` calls the 200,000-iteration synchronous `derive` before any await. `unlock` already dispatches the same derivation to a detached task at line 221. Password change calls `setPassword` after unlocking.

**Measured:** the actual default derivation took **110.14 ms** on this Mac in the optimized model build. Slower hardware or Debug builds can take longer.

**Solution:** follow the unlock pattern for creation/change: derive off-thread, then validate the operation generation and commit on the main actor. Show busy state and prevent overlapping password operations. Keep the existing credential format/work factor; this is a scheduling fix.

**Verification:** measure UI responsiveness when creating/changing a password at the default iteration count. Password round-trip and locked-state behavior must be unchanged.

### F17 — P2: membership queries, filters and row helpers still repeat derivation

**Evidence:** `FolderVideoPlayer/Model/Library.swift:1553,1713,1727` scans and sorts each name's members, including sorts using the String `naturalLess` overload. `FolderVideoPlayer/Playback/PlaybackController.swift:1279,1331,1415` rederives playlist tag counts and path/name filter data. `FolderVideoPlayer/Views/PlaylistSidebar.swift:2429–2433` calls `rating(path)` three times; line 2699 calls `handTaggableTags()` twice for one menu.

**Measured sort primitive:** sorting 5,000 synthetic full paths took **641.61 ms** with String `naturalLess`, versus **22.27 ms** with actual `Library.naturallySorted`; outputs were identical. This is not a measured whole folder-open duration. `FolderVideoPlayer/Model/Scanner.swift:63` precomputes relative strings but still uses the String overload, so it still tokenizes inside comparisons, although that sort is off-thread.

**Solution:** retain folded `name → video key set` indexes; combine sets and sort once. Memoize playlist vocabulary against playlist/tag revisions, not filter text. Precompute canonical keys, parent folders and folded filenames when membership changes. Hoist rating/menu values locally first; add revision-backed caches only if profiling supports them. Cache fact grouping/order too if it shows in sidebar profiles.

**Verification:** Any/All, case folding, hidden exclusion and natural ordering must remain identical. Typing a filename filter should not rebuild tag vocabulary or tokenize every path repeatedly.

### F18 — P2: startup and folder relocation still scale with whole stores

**Evidence:** app-level state objects construct stores in `FolderVideoPlayer/FolderVideoPlayerApp.swift:55–80`; `FolderVideoPlayer/Model/Library.swift:401,431` and `FolderVideoPlayer/Model/FaceStore.swift:80` load/parse local maps synchronously. `FolderVideoPlayer/FolderVideoPlayerApp.swift:159–166` batches several stores' moves but still calls `suggestions.move` once per video. `FolderVideoPlayer/Model/SuggestionStore.swift:464–469` retains a whole dictionary snapshot for each scheduled write; subsequent mutation can trigger copy-on-write while that snapshot remains retained. `FolderVideoPlayer/Model/Moments.swift:230–233` rescans the complete moment book once per moved video.

Some share sync setup also remains synchronous: `FolderVideoPlayer/Model/TagSharing.swift:166` calls `Paths.networkShares` when building inputs before detached share work; volume enumeration/probing itself can touch storage.

**Solution:** stage large store loads after essential preferences/profile identity, with an explicit ready state. Capture only the final suggestions snapshot for a folder batch and move all moment keys through a lookup map in one pass. Extend batching to outside stores. Gather mounted-volume information asynchronously and reuse a recent snapshot. Preserve relocation journaling, crash recovery and propagation to other profiles.

**Verification:** measure first usable frame and profile-switch delay at large JSON/index sizes. Rename a folder containing 1,000 videos and count dictionary copies, moment visits and actual writes; these should grow approximately linearly with data plus moves, rather than data × moves.

### F19 — P3: model archive watchdog repeatedly traverses the extraction tree

**Evidence:** `FolderVideoPlayer/Model/ModelDownloader.swift:905–935,962` polls every 100 ms while extraction runs and calls `grown(in:)`, which enumerates the tree and stats each entry. This is off the UI's direct execution path, but can create avoidable CPU/storage contention during model installs, especially packages with many files.

**Solution:** measure the watchdog's share of install time. If material, use incremental file-growth accounting or adaptive polling with a conservative remaining-budget calculation. Retain the growth ceiling and final verification; simply making checks infrequent can allow substantial overshoot. Keep process stderr drained so a verbose extractor cannot block on a full pipe while being watched.

**Verification:** install a large legitimate package and a controlled over-budget fixture. Record metadata calls/CPU and ensure the bounded-growth behavior still holds.

## Smaller items: profile before changing

- **Warm model metadata:** `FolderVideoPlayer/Model/CoreMLClassifier.swift:173` rereads the space marker and registry on repeated calls. Resolve stable tower metadata by installation revision, preserving live replacement detection. The large model digest is checked on a cold embedder load, **not on every warm call**.
- **Prompt math:** `FolderVideoPlayer/Model/PromptTable.swift:351` is a scalar dot product. Compare it against Accelerate/batched multiplication before replacing it. An optimized Swift compiler may remove checks or vectorize loops; the earlier report's promised multi-fold gain from unsafe pointers has not been established. Validate score tolerances and final rankings.
- **Suggestion sorting:** `FolderVideoPlayer/Model/TagSuggester.swift:250` recomputes the ranking key in the comparator, but candidate lists are small. Precompute only if it registers in a profile.
- **Optional neighbour prior:** `FolderVideoPlayer/Model/NeighbourPrior.swift:175` performs calendar same-day comparisons per candidate. Cache local day boundaries if needed, preserving time-zone/daylight-saving semantics. `Date` is a value type; creating it is not by itself proof of a heap allocation. This prior is disabled by default.
- **Poster cache accounting:** `FolderVideoPlayer/Model/MediaCache.swift:50,279` supplies pixel counts as NSCache costs while its configured limit resembles bytes. Use decoded byte cost, e.g. bytes-per-row × height. The existing 500-image count cap and modest requested sizes already constrain normal use; no actual memory leak was measured.
- **Export logs/progress:** `FolderVideoPlayer/Model/PlayableCopy.swift:269` accumulates entire stdout/stderr buffers, including FFmpeg progress. Keep a bounded diagnostic tail and stream progress separately; preserve full output where required for short ffprobe JSON. Throttle download/transcription progress publications if view-update profiles show a problem.
- **Small view file probes:** Settings log size/availability and People photo previews read disk during view construction (`FolderVideoPlayer/Views/SettingsWindow.swift:852,879`, `FolderVideoPlayer/Views/PeopleWindow.swift:779`). Hold results per file revision. They are usually local and small, so rank them below the confirmed library/NAS paths.

## Corrections to the existing performance review

The existing `docs/performance-review.md` is useful background, but these conclusions require adjustment in this checkout:

1. **Unknown duration is not a repeated stat:** `MediaCache.length` at line 140 returns nil immediately when there is no duration entry. Its `verifySize` only runs for an existing cached entry, and deduplicates in flight. Do not add a negative-result cache solely to fix the earlier finding #9. The separate synchronous `remember` stat in F05 is real.
2. **Duplicate derivation is already off-thread:** `DuplicateFinder.derive` at line 237 checks candidate existence in a detached task. Its disk checks are not a UI-thread defect in 1.2.5. Actual duplicate removal remains synchronous (F07).
3. **Name existence replacement must preserve case folding:** the earlier one-line `count(anyName:)` recommendation needs a normalized lookup/set, since its dictionaries use displayed spelling. F03 gives a behavior-preserving alternative.
4. **Avoid unsupported precision:** exact counts of NSString allocations, guaranteed compiler bounds checks, Date heap allocations and promised speedups are not established by source inspection. The synthetic measurements above support particular primitives; they do not prove equivalent whole-app speedups.
5. **Async and debounce do not imply off-thread execution:** password creation, suggestions saves and main-actor scan setup show why the full call path needs review.

## Validation performed

The following existing runners passed:

| Runner | What its passing result establishes | Important limit |
| --- | --- | --- |
| `Tests/run_maintenance.sh` | Planner diffs, queue persistence/retry, hidden exclusion and pause rules. | Does not compile/test `Playback/MaintenanceWorker` or its timeout. |
| `Tests/run_smart_collections.sh` | Watch behavior, rule combinations, storage, visibility and forward-compatible rule handling. | Does not measure tooltip redraws or broad observer reevaluation. |
| `Tests/run_library_overview.sh` | Correct members/order and hidden exclusion for the seven card kinds. | No large UI rebuild/NAS benchmark. |
| `Tests/run_evidence_journal.sh` | Evidence decisions, replacement, staleness, profile handling and suggestion hooks. | No UI-thread I/O timing. |
| `Tests/run_speech_pass.sh` | Fake-transcriber replacement, source-revision refusal, cancellation and transcript search. | No real WhisperKit inference or long-audio memory measurement. |
| `Tests/run_moments.sh` | Validation, ordering, edits, moves, persistence, undo and profile isolation. | No scrubber rendering measurement. |
| `Tests/run_tag_query.sh` | Any/All, case-insensitive names, stars/people/facts and hidden exclusion. | No large membership-query benchmark. |
| `Tests/run_triage.sh` | Queue/answer/undo semantics and deferred tag persistence. | No large-library response-time measurement. |
| `Tests/run_media_tracks.sh` | Subtitle parsing, cue choice, track fallback and persistence. | No real playback throughput measurement. |

The sandbox initially blocked the test harness's CPU query; the model module compiled successfully when run with approval outside it. The speech suite initially failed to decode audio in the sandbox and then **passed outside it**. That failure is treated as an execution-environment issue, not an application regression. Compiler warnings included deprecated framework calls and capture/unused-result warnings; warnings alone do not establish performance defects.

### Synthetic measurement method

The temporary benchmark used `@testable import FVPModel`, the existing harness's `swiftc -O` module, isolated `/private/tmp` files and redirected `Paths.support`/`Paths.volumes`. No user library was read or changed. Timings are single observed runs, not p95 figures or cold-storage estimates.

| Experiment | Inputs and actual code used | Observed result |
| --- | --- | --- |
| Name existence | 10,000 nonexistent local video paths, each tagged `Trip`, `Tag(i % 40)`, `4 Stars`; 30 `Library.pathsCarrying` checks. | 1,909.23 ms; 7,500 total matching paths constructed. |
| Cached existence alternative | A prebuilt lowercase set from `knownTags` + `factsInUse`; the same 30 names. | 0.002 ms; vocabulary construction excluded. |
| Baseline reads | 2,000 unique pinned-cache `.f32` files of 768 floats; three calls to `hashes` + actual `TagPrototypes.baseline` + actual cache reads. | 122.57 ms total, **6,000 read calls**. Files were recently written/local; no linear NAS latency extrapolation is claimed. |
| Natural sort | 5,000 full paths with varying folder/clip numbers; String `naturalLess` versus `Library.naturallySorted`. | 641.61 ms versus 22.27 ms; identical output. |
| Moment lookup | 50,000 moments across 500 video keys; 100 calls to actual `MomentBook.moments(for:)`, returning 100 moments each. | 13.94 ms total. |
| Password derivation | Actual `HiddenLock.derive`, fixed 32-byte salt and default 200,000 iterations. | 110.14 ms. |
| Timeout structure | Same task-group/detached-await pattern as upkeep; timeout 50 ms, detached work 300 ms. | Returned timeout only after 320.20 ms. This tests the structure, not the private scanner. |

## Implementation order and acceptance plan

1. **Quick interface fixes:** F03 normalized existence, F04 held evidence/revision, F05 worker preflight and F06 name-index worker stage. Move password derivation too (F16). Validate existing case/visibility/profile rules before shipping.
2. **Largest AI scaling fix:** F01 aggregate baseline, then F02 per-pass/derived caches. Use current parity tests; avoid changing thresholds or training semantics as part of performance work.
3. **Persistence and tagging:** F08 ordered background writers and F09 separate/incremental recounts. Extend batch relocation in F18. Verify crash/quit/profile-switch behavior.
4. **Bound resources and cancellation:** F11 streaming/windowed audio, F12 scan ownership/deadline, F13 shared admission and F14 navigation generations. Test unreachable shares and long recordings.
5. **Measured follow-ups:** F10 relevant revisions, F15 timeline indexes, F17 membership/row derivation. Optimize F19 and numeric loops only if their contribution remains significant.

For an actual app profile, build **Release** and record these separate scenarios: 1,000/10,000/30,000 known videos; cold and warm local storage; a healthy and sleeping SMB share; AI off/on; a short and two-hour recording. Include folder opening, first playback, fast scrolling, typing filters, 200 triage answers, 10 smart collections, bulk duplicate disposal and a 1,000-video folder rename.

Record main-thread stalls, p50/p95 interaction latency, time to first frame/suggestions, peak resident memory, disk bytes/writes, vector read counts, concurrent storage requests, live task count and Stop acknowledgement. Suggested initial targets—not measured guarantees—are **under 100 ms p95 for ordinary edits/filter feedback**, **no avoidable filesystem waits in view bodies/player callbacks**, **Stop acknowledged within one second before an uncancellable OS operation**, and memory that plateaus with configured cache/audio windows. NAS availability still governs video-opening latency.

Retain the working optimizations: lazy rows, separate playhead, shared decoded frames, model-space validation, batched edits, background duplicate derivation, two-worker collection stat warming and delayed analysis writes. The proposed work should improve their remaining edges without discarding their correctness protections.
