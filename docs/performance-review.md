# Performance review — module by module

A read of the Model, Playback and Views layers (~90 Swift files) looking for
cost that scales with library size, playlist length or model size.

**Re-verified against v1.2.5 (`113a10d`), in both directions.** The first draft
was written against a v1.1.20 checkout, 46 commits behind. Re-checking confirmed
all 13 original findings still reproduce (only line numbers moved) — and a
second pass over what v1.2.5 *added* found one more, recorded as finding 14.

Two recent performance commits cover ground this review would otherwise have
raised, and are credited rather than duplicated:

- `8e1d57c` "the cursor crossing the tag list no longer redraws every chip"
  hoisted `targets`/`applied` out of the per-tag closures and gave each chip its
  own hover — the O(tags × selections) scan in `TagPanel.body` is gone.
- `f0b721d` "no re-sort, recount or filter count on every answer and redraw"
  fixed re-sorting and recounting in the triage views (`TriageSession`,
  `TriageBar`), with its own measured figures (97 ms / 20 ms / 80 ms at 11,400
  videos). It does **not** touch `Library.recount()` itself, so finding 8 stands.

What v1.2.5 added is a substantial amount of new surface — 13,581 lines across
68 files, including 11 new Model types the first pass never saw
(`SmartCollections`, `TriageSession`, `MaintenanceWorker`, `WatchLog`,
`TranscriptEdit`, `LibraryFolder*`). Finding 14 comes from that new surface.

**This is a code review, not a profile.** No code was executed and nothing was
measured. The severity ranking is derived from the algorithmic shape of each
call path and from the measured comments already in the source — not from fresh
instrumentation. Every finding cites the file and line it came from so it can be
checked.

Worth saying plainly: this codebase is already unusually well optimized. Several
comments record measured fixes that would otherwise be obvious defects —

- the 254 ms sort fixed by decorate-sort-undecorate in `Library.sorted`
- `attributesOfItem` → `lstat` in `MediaCache.fileSize` (5.5 s → one round trip)
- the `AnalysisStore` write clock (2.1 GB dirtied in 608 s → 15 s debounce)
- the `dupeGroupCount` lazy derivation, off the video-start path

What follows is what remains on top of that work.

---

## High impact

### 1. `TagPrototypes.baseline` re-reads every cached vector, per suggestion

`FolderVideoPlayer/Model/CoreMLClassifier.swift:383`

```swift
let cached = store.hashes()                  // full directory walk of the cache
let baseline = TagPrototypes.baseline(
    hashes: cached, dim: table.dim, read: read)   // reads EVERY .f32 in it
```

`baseline` (`TagPrototypes.swift:96`) loops every hash, reads the file, and
accumulates a 768-double mean. It is called from `CoreMLClassifier.suggest`,
which runs automatically on every video opened.

On the library this repo describes elsewhere (12,008 analysed videos, 40 frames
each) that is roughly **480,000 file reads and 368 million float additions per
video suggestion**.

The code already documents the fix and does not apply it:

> engine.py memoises this in `_library_mean`, which is easy to be bitten by […]
> This port is pure — the caller caches it if it wants to (the suggester runs it
> once per video, so it should).

**Fix.** Keep a running `(count, [Double])` accumulator in the `CoreMLClassifier`
actor. Every `cache.write(hash, vector)` already happens inside that actor — add
the vector to the accumulator there. Recompute from scratch only when the
accumulator is `nil` (first launch) or the space digest changes. Turns O(cache)
per video into O(1).

### 2. `EmbeddingCache.read` is a blocking file read, with no memory tier

`FolderVideoPlayer/Model/EmbeddingCache.swift:145`

```swift
func read(_ hash: String) -> [Float]? {
    guard let raw = FileManager.default.contents(atPath: p), … else { return nil }
```

Every read is a synchronous file open + read + `[Float]` heap allocation, executed
**on the `CoreMLClassifier` actor**. It backs `baseline`, `TagPrototypes.prototypes`,
`tagCandidates` and `explain` — thousands of calls per pass (see #1). Because it
runs inside the actor, it also blocks any concurrent `analyse`.

The embedding cache is read far more than it is written, which is the textbook
case for a memory tier.

**Fix.** An in-memory map in front of the disk read, capped by count (768 floats
= 3 KB each, so 2,000 entries ≈ 6 MB). Invalidate wholesale on a space change —
the namespace already guarantees vectors from different spaces never mix.

### 3. `CoreMLClassifier.warm()` re-reads the model registry per video

`FolderVideoPlayer/Model/CoreMLClassifier.swift:173`

`warm()` is called at the top of `analyse()`, `suggest()`, `explain()` and
`sightings()` — that is, per video. Unconditionally it calls:

- `ModelSpace.readForInference(root:)` — stat + read + JSON decode of the marker
- `ModelSpace.activeTower(root:)` — which calls `ModelRegistry.read(root:)`, a
  JSON file read, plus an `isInstalled` directory check per tower

**One correction to the obvious suspicion:** the 176 MB model hash is *not*
recomputed per pass. `matchesInstalledBytes` → `digestOfDirectory`, which
SHA-256s every byte of the model, sits inside the `else` branch and only runs
when `embedder == nil`:

```swift
if let embedder {
    preparedEmbedder = embedder          // warm path: no hash
} else {
    if let installed = installedSpace,
       !installed.matchesInstalledBytes(root: root) { … }
    preparedEmbedder = try VisionEmbedder(root: root)
}
```

That gate is correct and should stay. The residual cost is the marker and
registry reads — small, but per video and on the actor.

**Fix.** Cache the resolved tower directory alongside `loadedSpaceKey` and
`loadedTower`, revalidating only when the digest marker changes or a tower switch
is requested. `readForInference` must stay live — it is what detects a model
swap mid-run.

---

## Medium impact

### 4. `Library.rating(_:)` — five case-insensitive scans, called 3× per row body

`FolderVideoPlayer/Model/Library.swift:1927`

```swift
func rating(_ path: String) -> Int {
    for stars in [5, 4, 3, 2, 1] where hasTag(path, starTag(stars)) { return stars }
    return 0
}
```

`hasTag` → `tagsFor` → `Paths.tagKey(path)`, which allocates a fresh string per
call. `VideoRow.body` (`PlaylistSidebar.swift:2429`) calls `rating(path)` three
times — `> 0`, `count:`, and inside `.help(…)`. `IconTile.body` calls it twice.
A 20-row visible list therefore does up to 100 dictionary lookups, string
allocations and `caseInsensitiveCompare` runs **per redraw**.

v1.2.5 added a joined `facts` string to the same row, so the row body now does
strictly more per redraw than when this was first written — the finding is if
anything slightly stronger now.

**Fix, cheap.** Hoist to a local in each body:

```swift
let stars = library.rating(path)
```

**Fix, better.** Build a `[String: Int]` ratings map in `recount()`, next to
`tagCounts`. That function already walks every tag entry on every change, and a
star tag is just another tag — this is nearly free once it is there.

### 5. `Library.handTaggableTags()` allocates two arrays, twice per row menu

`FolderVideoPlayer/Model/Library.swift:1593`

```swift
func handTaggableTags() -> [String] {
    assignableTags().filter { !provenance.isMetadataTagAnywhere($0) }
}
```

`assignableTags()` is itself `sortedTags.filter { !isStarTag($0) }`. So each call
is two full passes over the vocabulary producing two arrays.

`RowMenu.body` (`PlaylistSidebar.swift`) calls it **twice** — once for
`if !library.handTaggableTags().isEmpty` and again for the `ForEach`. `RowMenu`
is constructed for every visible row. `TagPanel.body` calls it too.

**Fix.** Cache the result as `private(set) var handTaggable: [String]`, computed in
`recount()` next to `sortedTags`. One property, one computation, zero allocation
per row.

### 6. `PlaybackController.tagsInPlaylist` is rebuilt on every `rebuildRows`

`FolderVideoPlayer/Playback/PlaybackController.swift`

`pruneTagFilter()` runs at the top of `rebuildRows()` and calls `tagsInPlaylist`,
which walks the **entire playlist**, reads every video's tags, counts and sorts.
`rebuildRows()` fires on every filter keystroke (120 ms debounce), every tag
toggle, every sort change, every `refreshMembership()`, and every
`refreshAfterTagRepair()`. The filter strip also reads it per redraw.

**Fix.** Compute once at the top of `rebuildRows` and hand it to `pruneTagFilter`
rather than letting it re-derive, or memoize it against the tag-filter state that
produced it.

### 7. `buildRows()` allocates NSString bridges per path, per rebuild

`FolderVideoPlayer/Playback/PlaybackController.swift`

```swift
let folder = (path as NSString).deletingLastPathComponent
```

per video, plus `lastPathComponent.lowercased().contains(needle)` for the filter
and `library.tagsFor(path)` for the tag filter (itself another `tagKey` bridge).
A 5,000-video playlist is ~15,000 NSString allocations per debounced keystroke.

**Fix.** Precompute `(path, folderKey, lowercasedName)` once when `playlist` is
assigned, and reuse that array across filter rebuilds — only the filter predicate
needs re-running, not the string surgery.

### 8. `Library.recount()` is O(all tags) on every save

`FolderVideoPlayer/Model/Library.swift:1037`

`saveTags()` → `recount()` → full walk of every tag entry building `tagCounts`,
`tagDisplay`, `popular` and `sortedTags`, then `recountFacts()`, which does
`facts.byKey.keys.sorted()` — **a sort of every fact key in the library**.

This runs on every single tag write. `setRating(_:for:)` additionally rebuilds
the entire `tags` dictionary (`var updated = tags` … reassign) before recounting.
Tagging 200 videos one at a time is 200 full library walks plus 200 sorts.

The comments show this was deliberately moved off the per-redraw path — the
remaining problem is per-*write*.

**Fix.** Make `recount()` incremental: apply the delta for just the changed keys.
Both `tagCounts` and `tagDisplay` support add/remove symmetrically. Separately,
`recountFacts`'s `.sorted()` exists only to make the displayed spelling stable
across launches — that can sit behind a facts-store revision counter instead of
being recomputed on every tag edit.

---

## Low impact

### 9. `MediaCache.length(_:)` re-asks the disk for never-measured videos

`FolderVideoPlayer/Model/MediaCache.swift`

The design is sound — verify behind the answer, `checking` dedupes in flight, and
`revision` only bumps when the answer was wrong. But `resolved` is only populated
for paths that have a `lengths` entry. A video that was never measured returns
`nil` and is re-asked on every call, and rows call `media.length(path)` as they
draw.

**Fix.** A negative-result set beside `checking`, cleared whenever `lengths`
changes, so an unmeasured path is asked once rather than once per redraw.

### 10. `NeighbourPrior.measure` allocates a `Date` per pool entry

`FolderVideoPlayer/Model/NeighbourPrior.swift:175`

```swift
let sameDay = calendar.isDate(Date(timeIntervalSince1970: entry.when),
                              inSameDayAs: mine)
```

`Date` init plus `Calendar.isDate` per pool entry, per suggestion. Currently
harmless — `NeighbourPrior.enabled` is off by default, so this path is inert —
but it should be fixed before anyone turns it on: compare day numbers derived
from `timeIntervalSince1970` against a precomputed local day boundary instead.

### 11. `TagSuggester.suggest` computes the sort key inside the comparator

`FolderVideoPlayer/Model/TagSuggester.swift`

```swift
ranked.sort { key($0.1) == key($1.1) ? $0.0 < $1.0 : key($0.1) > key($1.1) }
```

Two dictionary lookups plus arithmetic per comparison, O(n log n) times. The
candidate list is small so the real cost is negligible — but this is exactly the
decorate-sort-undecorate pattern `Library.sorted` already applies correctly, and
matching it would be consistent.

### 12. `PromptTable.similarity` bounds-checks its innermost loop

`FolderVideoPlayer/Model/PromptTable.swift`

```swift
for i in 0..<min(dim, vector.count) { sum += matrix[base + i] * vector[i] }
```

`base + i` is recomputed and bounds-checked per element. This is the hottest loop
in the whole suggestion path (frames × tags × rows × dim). Hoisting the length
check and using `withUnsafeBufferPointer` on both sides would be several times
faster for a small, contained change.

### 13. `PlayerWindow` sidebar counts — a full tree walk per new folder

`FolderVideoPlayer/Views/PlayerWindow.swift:1221`

`loadCounts()` calls `Scanner.count(root)` per uncached sidebar folder, off the
main thread and memoized thereafter, so the cost is one walk per folder for the
lifetime of the session. Already as designed; noted only so the walk is not
mistaken for a regression if it ever surfaces.

---

### 14. `SmartCollectionStore.problems(in:)` walks the whole library per rule, from a tooltip

`FolderVideoPlayer/Model/SmartCollectionStore.swift:126` (new in v1.2.5)

```swift
func problems(in collection: SmartCollection) -> [UUID: String] {
    for rule in collection.rules {
        if let why = SmartEvaluator.problem(with: rule,
                                           knownNames: { !library.pathsCarrying($0).isEmpty }) {
```

`pathsCarrying` (`Library.swift:1713`) is not a lookup — it is
`taggedWith(name)` over every tagged key plus `facts.carrying(name)` over every
fact key, each an O(entries) scan with `caseInsensitiveCompare`, followed by a
`naturalLess` sort of the result.

And it is called from a **`.help` tooltip**, once per rule, for **every smart
collection row in the sidebar** (`PlayerWindow.swift:1290`):

```swift
help: smart.problems(in: collection).isEmpty
    ? "Play every video matching “\(collection.name)”"
    : "A rule in “\(collection.name)” needs attention — right-click to edit it",
```

So a sidebar with 10 collections of 3 rules each is 30 full library walks
(plus 30 sorts) **per redraw**, to compute a string SwiftUI will usually never
display. The tag panel's equivalent problem was fixed in `8e1d57c`; this is the
same shape in a view added afterwards.

**Fix.** The store already holds the answer: `evaluate()` builds `context.names`
over `library.smartContext()`. Validation only needs to know whether a name
*exists in the library*, which `Library.count(anyName:)` answers from
`tagCounts`/`factCounts` in O(1) — both already derived in `recount()`. Swap the
`knownNames` closure to that and the whole path becomes dictionary lookups.

Secondary: `.help` strings are evaluated during layout whether or not the
pointer ever lands on the row. Computing `problems` lazily (on hover, cached by
collection revision) is the belt-and-braces fix if the count path is still too
eager.

---

## Suggested order of work

| # | Finding | Effort | Payoff |
|---|---------|--------|--------|
| 2 | `baseline` accumulator | Medium | **Largest.** Already described in the source. |
| 14 | `problems(in:)` per tooltip | **Low** | **Cheapest real win.** One closure swap to an existing O(1) lookup. |
| 5 | `handTaggableTags` cache | Low | Cheap, local, kills two arrays per row menu |
| 4 | `rating` hoist + map | Low | Cheap; the hoist alone fixes the redraw cost |
| 3 | Cache tower/space reads | Low | Removes per-video filesystem work |
| 1 | `EmbeddingCache` memory tier | Medium | Compounds #2 substantially |
| 6 | `tagsInPlaylist` memo | Low | Removes a playlist walk per filter keystroke |
| 7 | Row tuple precomputation | Medium | ~15k allocations → ~5k per rebuild |
| 8 | Incremental `recount` | High | Biggest win for bulk tagging |

## Verifying before acting

Two of these deserve a measurement before anyone spends time on them:

- **#2 / #1** — `SamplingPlan.record` already counts `cacheHits` and
  `framesEmbedded`. Instrumenting a real suggestion pass to report how many
  distinct `.f32` files one invocation opens would confirm the magnitude
  directly. That is the cheapest possible check on the biggest claim here.
- **#4** — a signpost around `VideoRow.body` in the 5,000-video list view,
  scrolled, would separate "noticeable" from "theoretically unfortunate".

Finding 14 needs none of that instrumentation — `count(anyName:)` already
exists and is already O(1), so the change is verifiable by reading the diff.

The rest are structural and can be taken on inspection.