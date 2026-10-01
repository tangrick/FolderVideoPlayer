# Triage mode: design and plan

**Status:** all three phases built on `feature/triage-mode`, uncommitted. Phases 2 and 3 were tried by hand on generated videos in an isolated copy (§8). Not yet in a release.
**Target:** FolderVideoPlayer (this repo) after 1.2.1. Mac only; the Apple TV is untouched.
**Written:** 2026-10-01.

File and line references are to `main` at `5c87e03`.

---

## 1. What is being asked

A huge library gets tagged one video at a time: open it, open the tag panel, click or type, move on. Triage mode is a **keyboard-driven review loop** that walks the videos on screen, shows each one with the machine's suggestions and your usual tags beside it as a numbered strip, and moves on the moment you answer.

| # | Requirement |
|---|---|
| T1 | Walk the playlist on screen, one video at a time, in its on-screen order |
| T2 | Show only what still needs an answer (default: videos with no tags), with a live "N left" count |
| T3 | Answer entirely from the keyboard: accept a suggestion, apply a usual tag, type a new tag, skip, go back, finish |
| T4 | A mistake is one `⌘Z` away, however far into the session |
| T5 | Accepting and rejecting suggestions keeps its training meaning exactly (§4.2) |
| T6 | A video you decided has nothing to tag stops coming back |
| T7 | Looking at a video here does not mark it watched or move its resume point |

**Not in v1** (§9): star-rating keys, prefetching analysis ahead of the cursor, a smart-collection "untagged" rule, stable user-assigned hotkey tags.

---

## 2. What already exists, and what gets in the way

| Piece | Where | What triage takes from it |
|---|---|---|
| Suggestions, pending and decided | `Model/SuggestionStore.swift` | `pending(_:)`, `decide(_:tag:verdict:)`, `undecide`, `dismissRest`. Per profile, and it already follows a moved file (`move(from:to:)`) |
| Applying a tag | `TagPanel.accept(_:on:)` (`TagPanel.swift:852`), `Library.addTag(_:to:)`, `setTags`, `saveTags` | The same two calls: add the tag, then record `.accepted` |
| The playlist and its order | `PlaybackController.visibleVideos`, `rows` | The queue. Hidden videos are already filtered out when a playlist starts (`start`, `PlaybackController.swift:553`) |
| Preview | `PlaybackController.preview(_:)` | Plays a file without changing the playlist. It does **not** keep a glance out of the resume store: `Library.note` writes a resume point whether or not `watching` is true, so a preview still moves it (see hazard 5) |
| Auto-suggest on open | `PlayerWindow.swift:314`, `autoWork(path)` | Opening a video asks for suggestions once, if the engine is free and "analyse while playing" is on. About 75 frames, a few seconds of CPU per video |
| Key monitors | `Views/FullScreen.swift:53,79,107` | The pattern for keys the menu would otherwise eat, with "typing wins" |
| Bottom slot | `PlayerWindow.swift:682` (tag panel), transcript panel | Triage takes the same slot; the slot already holds one panel at a time |
| Library Overview | `Model/LibraryOverview.swift` | The "Tag Suggestions to Review" list is a ready-made triage scope |

**Five things in the existing code that triage must design around.** Each has a section below.

1. **A finished preview re-points `currentPath`.** When a preview ends, `itemFinished` sets `previewPath = nil` (`PlaybackController.swift:836`), and `currentPath` falls back to the playlist's own item. `TagPanel.targets` reads `currentPath`, so a tag typed after a preview ended would land on the wrong video. Triage owns its own current path and never reads `currentPath` (§5.2).
2. **Undo is one whole-dictionary snapshot.** `Library.rememberForUndo` copies all tags and writes two files to disk; there is one slot. Using it per decision would overwrite the user's real last undo and cost a full write each time. Triage keeps its own step log (§5.3).
3. **`saveTags()` rewrites the whole tag file** and recounts (`Library.swift:716`). At one decision a second on a large library that needs measuring, not assuming (§6).
4. **Suggestions arrive late.** The pass runs a few seconds after a video opens, one at a time. If chips appear and renumber while a key is on its way, `2` means something else. Numbering is frozen per video (§4.1).
5. **A preview still records a resume point, and leaving one mis-files it.** `Library.note(position:total:for:watching:)` writes `progress` and `progressSeen` for a preview exactly as for a watch (only the watch log is skipped), so a few seconds on each of a hundred videos would fill Continue Watching. Separately, `play(at:)` clears `previewPath` and *then* calls `notePosition()`, which files the preview's position against the playlist's own video. Both are old behaviour of `preview`; triage avoids both (§5.2).

---

## 3. The model: a pure queue

Two files, no UI, no file I/O, so the rules are tested without a window.

- `Model/TriageQueue.swift`: pure values. `TriageFilter`, `TriageReader` (the library as plain closures, the same idea as `LibraryOverview.Input`), `TriageQueue` (navigation: current, skipped, finished, back), `TriageStrip` (the numbered row and the quick tags).
- `Model/TriageSession.swift`: `@MainActor`, holds the queue and the strip, and applies each answer to `Library` and `SuggestionStore`. It also owns the undo log (`TriageStep`), because undoing means writing to those two stores.

**Scope.** The queue is a snapshot of `playback.visibleVideos` when the session starts. It is not a new universe: the app has no list of every file on every share (`Library.knownVideoKeys` says so), and the playlist on screen already is one folder, tag, smart collection or Overview section. Folder order keeps clips shot together next to each other.

**What "needs tags" means.** A video needs tags when it carries no tag other than a star rating. Star tags are tags (`isStarTag`, `Model/Paths.swift:467`), so a video rated 4★ and nothing else still needs tags. A **person** tag counts as a tag. **Readings** (Date, Camera & Quality, Place) never count: they live in `facts`, are read off the file, and say nothing about what the video shows.

**The predicate is live.** It is evaluated when the cursor reaches a video, not once at the start. A video another device tagged in the meantime (`adoptSharedTags`), one hidden meanwhile, and one that would not open drop out by themselves. "Would not open" is a closure the app supplies from the playback controller's `problems`; the queue itself stats nothing.

**Filters.**

| Filter | A video is in the queue when |
|---|---|
| Needs tags (default) | it needs tags, and has not been marked reviewed (§4.3) |
| Has suggestions | `suggestions.pending(path)` is non-empty, whatever it carries |
| Unrated | `library.rating(path) == 0` |
| Everything | always |

**Moves through the queue.**

| Action | Effect on the queue |
|---|---|
| Done | the video leaves the queue; cursor moves to the next |
| Skip | the video goes to `skipped`, nothing is recorded; cursor moves on. When only skipped videos remain the bar says "N skipped. Go through them again?" |
| Back | cursor returns to the previous video and re-opens it for judging; works across done and skipped alike |
| Undo | restores the last step exactly (§5.3) and moves the cursor to that video |

---

## 4. The decisions, and what each one records

### 4.1 The strip

One row of numbered chips under the picture, built **when the video opens** and then only ever **appended to**:

1. the video's pending suggestions, strongest first, at most five (dashed border and sparkle, as in the tag panel, so a guess never looks like a tag the user vouched for);
2. then the session's **quick tags**, up to nine slots in all: the nine most-used tags in the scope, chosen at session start and not reshuffled;
3. a tag the video already carries is left out, case-insensitively, as `TagPanel.pendingSuggestions` does.

If the suggestion pass finishes after the video opened, its chips are added **to the right** with the next numbers. They never push an existing chip to a new number, so a key pressed in good faith still does what the screen said a moment ago. While the pass runs the strip shows "Looking…" and the quick tags are already usable.

### 4.2 Keys

Active only while the player window is key, triage is on, and no editable text view has focus. All other keys keep their menu meaning (`Space` plays and pauses, `←` `→` skip in the video, `M` mutes).

| Key | Does | Records |
|---|---|---|
| `1`…`9` | toggle chip N: apply the tag, or take it off again | a suggestion chip: `.accepted` (`SuggestionStore.decide`). A quick tag: just the tag |
| `⌥1`…`⌥9` | reject suggestion N: takes it off if carried, never offer it again | `.rejected`. Same as the tag panel's `⌥`click and ✕. Does nothing on a quick tag |
| `A` | accept every suggestion shown, then move on | `.accepted` for each |
| `Return` | **Done**: move on | a pending suggestion whose tag the video now carries (typed by hand) becomes `.accepted`; every other unruled one becomes `.ignored` (`dismissRest`). If the video has no tags, it is marked reviewed (§4.3) and the bar says so |
| `↓`, `⌘→` | **Skip**: leave it for later | nothing |
| `↑`, `⌘←` | **Back** | nothing |
| `T` or `/` | focus the tag field. Autocompletes from existing tags; `Return` commits (several, comma-separated, as `parseTags` does) and returns focus to the keys | the tags only |
| `⌘Z` | undo the last step | restores it exactly |
| `Esc` | leave triage; inside the tag field, return to the keys | nothing |

**The line that must not move.** `SuggestionVerdict` separates `rejected` (a real negative, safe to train on) from `ignored` (walked away, never trained on). Triage keeps that exactly:

- only `⌥n` ever writes `.rejected`;
- Skip writes **nothing**: the suggestions stay pending;
- Done writes `.ignored` for what was left, as Dismiss All does, except a suggestion whose tag the user put on by hand, which is an explicit yes and is recorded as `.accepted`;
- advancing past a video is never read as a no.

Every key has a visible button on the bar, so triage works with the mouse and with VoiceOver, and each chip's accessibility label says its number and what its key does.

### 4.3 "Nothing to tag"

A video you looked at and chose to leave untagged must not come back every session. Marking it reviewed needs a per-video, per-profile record, and every per-video store has to follow a moved file (`features/folder-management/README.md` §2, rings 1 to 3).

**Recommendation: add `var triagedAt: Date?` to `VideoSuggestions`** rather than a new file. It is optional, so an old `suggestions.json` decodes unchanged. `SuggestionStore.move(from:to:)` already carries the entry, and the profile bundle already carries `suggestions.json` between Macs, so there is no new relocation code. It does not make `hasSuggestions` true (that needs `suggestedAt`), and `exampleCounts` / `labelledExamples` read only `verdicts`.

The cost is that "suggestions" now also holds "has been reviewed". The alternative, a `triage.json` beside it, would be cleaner to read and would need `pathMoved`, `ProfileRelocation.carryIntoBundles` and a test for each. Open question 2.

Reviewed is **not shared** between people or Macs through the NAS: it is one person's judgement and the tags themselves are what sync. It does travel with the profile bundle.

---

## 5. Surface and behaviour

### 5.1 Where it lives

A mode of the main window, not a new window. The architecture note says choosing what to watch must never interrupt what is playing, and triage needs the picture, the scrubber and the sound. A second player would mean a second `AVPlayer` beside the one `PlaybackController` owns.

`TriageBar` takes the bottom slot, so the tag panel and transcript panel are closed while triage runs (the slot already holds one panel at a time). Contents, top to bottom:

- progress: `14 left · 3 skipped · 212 in this view`;
- the video's name and its folder, so a bare `IMG_0412.mov` can be placed;
- the numbered strip, then the tag field;
- Done, Skip, Back, Undo and Exit buttons with their keys in the labels;
- one line of key legend.

The playlist on the right stays. The cursor's video is shown as the single selection (`app.selection = [path]`, so a stray multi-selection cannot become a batch tag target) and the list scrolls to it.

### 5.2 Playback

`PlaybackController.triage(_ path:)` is a sibling of `preview` (they share one private loader, `showApart`), with three differences:

- it starts at 0 rather than the resume point, since you are recognising content, not resuming;
- it **loops** at the end instead of clearing `previewPath` (the §2 hazard). The session holds its own current path and the bar and keys use that, never `currentPath`;
- it remembers **nothing**: `notePosition()` returns at once while `triaging`, which is stronger than a preview (hazard 5). `play(at:)` also skips its `notePosition()` when it is what ended triage.

While triage runs, `PlaybackController.stepOverride` makes Next and Previous mean Skip and Back, whoever asks (the menu's ↓ and ↑, `⌘→` and `⌘←`, the transport bar), so there is no second key handler for them. `M` toggles a triage-only mute, applied to the engine's volume without touching the volume the user chose.

Because `autoWork` is keyed on `playback.currentPath`, which includes the preview path, the "analyse the video you are watching" rule applies unchanged. It respects the "analyse while playing" switch, runs one pass at a time, and charges nothing for a pass it never started.

Anything that takes the player away ends the session: a click on a playlist row, opening a folder or tag, a profile switch or close (`play(at:)` and `closePlaylist()` both clear `triaging`, and `AppModel` tears the session down when it goes false). Leaving triage on purpose pauses on the last video at the top (so the resting position is not written as a resume point), points the list at it, and does not start the next one.

### 5.3 Undo

```swift
struct TriageStep {
    let path: String
    let tagsBefore: [String]
    let verdictsBefore: [String: SuggestionVerdict]
    let triagedBefore: Date?
}
```

Taken just before each decision. Undo writes all three back: tags through `setTags`, verdicts through `undecide` for any key that was absent and `decide` for any that changed, `triagedAt` through `setTriaged`, then moves the cursor back to that video (`TriageQueue.focus`). Skip and Back are navigation, not decisions, and take no step. `SuggestionStore.onVerdict` already tells the evidence journal, so a withdrawn answer reaches its timed evidence too. The log is in memory and ends with the session; a decision already written to disk stays written. This is the same stance as `TagPanel.accept`, which is not snapshot-undoable today either.

---

## 6. Performance and safety

- **A decision is cheap on a large library.** Measured on generated tag files (optimised build, three tags a video): `saveTags()` takes 5.6 ms at 1,000 tagged videos, 41.6 ms at 10,000 and 150 ms at 30,000, and 90% of it is rewriting `tags.json`. Past one frame, so triage saves with the new `Library.saveTagsSoon()`: counts, the sync and the "edited" mark happen at once and the file write waits until answers stop for two seconds. `flushTags()` forces it when the session ends and in `publishOnQuit`, so a crash costs at most two seconds of answers. The shared copy on the NAS goes out from memory as before.
- **No file I/O on the keys.** The queue, the predicate and the strip are built from memory (`tags`, `suggestions.byVideo`). The only disk touches are the video opening and the debounced save.
- **Hidden videos.** The queue is built from the playlist, so hidden videos are out by construction while locked. Triage is **unavailable in the unlocked Hidden view**, with the menu item saying why, so a hidden video's name never reaches the strip or the suggestion pass.
- **Closed profile.** The command is disabled while `!library.profileOpen`, with the same wording as the other Tags items. Switching profile ends the session.
- **Slow shares.** Nothing here stats a file. A video that fails to open shows the existing trouble message and is skipped.
- **Data compatibility.** The only stored change is the optional `triagedAt`. Nothing else in `suggestions.json`, `tags.json` or the shared tag files changes shape, and nothing in the upper part of `SharedTagFile.swift` is touched.

---

## 7. Where the code goes

| File | Change |
|---|---|
| `Model/TriageQueue.swift` (new) | `TriageFilter`, `TriageReader`, `TriageQueue`, `TriageStrip` |
| `Model/TriageSession.swift` (new) | `TriageSession`, `TriageStep`: the answers, and undo |
| `Model/SuggestionStore.swift` | `triagedAt`; `triagedAt(_:)` and `setTriaged(_:to:)` |
| `Model/Library.swift` | `saveTagsSoon()`, `flushTags()`; `saveTags()` cancels a held write; `publishOnQuit()` flushes first |
| `Tests/model_sources.sh`, `Tests/run.sh`, `Tests/run_triage.sh`, `Tests/test_triage.swift` | the model tests |
| `Playback/PlaybackController.swift` | `beginTriage`, `triage(_:)`, `pauseTriage`, `endTriage`, `toggleTriageMute`, `stepOverride`; `showApart` shared with `preview`; `notePosition` and `play(at:)` guards; `closePlaylist` ends triage |
| `Views/TriageBar.swift` (new) | the bar |
| `Views/TriageControl.swift` (new) | `AppModel` extension: `startTriage`, `endTriage`, `setTriageFilter`, `triageKey` |
| `Views/PlayerWindow.swift` | the bar in the bottom slot while `app.triage != nil` |
| `Views/FullScreen.swift` | the key monitor; Esc in full screen is left to triage while it runs |
| `Views/Menus.swift` | Tags ▸ Start Triage / Stop Triage (`⇧⌘T`); Tag This Video is disabled while it runs |
| `FolderVideoPlayerApp.swift` | `AppModel` stored state: `triage`, the key watcher, the observers, the playlist it started from |
| `Views/LibraryOverviewWindow.swift` | phase 3: a Review button on the suggestions section |
| `README.md`, `Views/HelpWindow.swift` | phase 3: the feature, and the key list |

Number keys need an `NSEvent` monitor like the arrows do: the app's own notes say the video surface and rows are not responders, so a SwiftUI key handler would not reliably hear them.

---

## 8. Phases

1. **Model. Built.** `TriageQueue`, `TriageStrip`, `TriageSession`, `triagedAt` on `VideoSuggestions`, 80 checks in `Tests/test_triage.swift` (`sh Tests/run_triage.sh`). No UI. Three deliberate breakages of the code (leftovers not ignored, undo not restoring the mark, late chips renumbering) were each caught by the checks meant to catch them.
2. **The loop. Built.** `triage(_:)`, `stepOverride`, `TriageBar`, `TriageControl.swift` (start, end, the key monitor), the Tags ▸ Start Triage item (`⇧⌘T`), and `saveTagsSoon`. Tried by hand: start, tag by typing, Done, Skip, Back, `⌘Z`, `M`, `Esc`, a row click, numbered suggestions, `1`, `⌥2` and `A` against seeded suggestions, the finished state; the files it wrote were read back and match §4. **Not exercised by hand:** the filter menu (the harness cannot open a menu button), full screen, a video that will not open, late suggestions arriving in the bar, Tab completion, VoiceOver.
3. **Entry points. Built.** The Library Overview gains a **Needs Tags** card, defined by the same `TriageReader` rule triage uses (`TriageSession.reader` is shared, so the two cannot disagree), with a caption saying it counts only the videos the app has seen. It and the Tag Suggestions card each get a **Triage** button: `AppModel.triageList` opens the list in the player, starts triage with the matching filter (`LibraryOverview.Kind.triageFilter`) and brings the player window forward, since the keys only work in the key window. Help gains a Triage shortcuts group, the `⇧⌘T` row and a Quick Start pointer; the README gains a Triage bullet and the new Overview section. Tried by hand: both buttons, the first key press straight after, the Help page.

   Not done, on purpose: counting the videos in background-maintained folders (`MaintenanceFile.known`) toward Needs Tags. It would make the count honest for those folders, but adding them to the Overview's `known` list also adds them to the date stats that Recently Added warms, thousands of extra share round trips for a new card. If wanted, count them for this card only.

---

## 9. Tests and acceptance

**Model tests** (`Tests/test_triage.swift`):

- `needsTags`: no tags → yes; stars only → yes; one person tag → no; readings only → yes
- the predicate is live: tagged from elsewhere mid-session → drops out; file gone → skipped
- Skip then wrap; Back across done and skipped; the "only skipped remain" state
- Done with pending suggestions writes `.ignored`; Skip writes nothing; only the reject action writes `.rejected`
- Done on an untagged video sets `triagedAt`, and the video leaves the queue and stays out in a new session
- Undo restores tags, verdicts and `triagedAt` exactly, including a tag that was newly added and a verdict that was newly written
- the strip: numbering is stable when late suggestions are added; a carried tag is excluded; at most five suggestions and nine entries in all
- hidden videos never enter a queue built from a locked playlist
- `suggestions.json` written without `triagedAt` decodes; an entry holding only `triagedAt` does not read as analysed; `move(from:to:)` carries it
- `exampleCounts` is unchanged by `triagedAt`

**Acceptance, by hand** (the app is the only place these can be checked):

- In a folder of 50 untagged, already-analysed videos, `A` on each tags all 50 with one key apiece, never touching the mouse
- 100 videos tagged by keyboard alone, mixing `1`…`9`, `T` and `⌘Z`
- A video that finished playing, then tagged: the tag lands on that video, not the playlist's current one
- No video touched in triage appears in Recently Watched or Continue Watching, and no resume point moves
- A key pressed as late suggestions arrive still acts on the chip it showed
- Leaving and re-entering: reviewed videos stay out, skipped ones are back
- Every key has a working button, and VoiceOver reads each chip with its number

---

## 10. Open questions, with the default taken if you do not answer

1. **Analyse ahead of the cursor?** The README promises that nothing but the playing video is analysed. Triage over videos with no suggestions is limited by the few seconds each pass takes. *Default: off in v1.* Triage works best over videos the background upkeep has already analysed ("Has suggestions" filter). A later opt-in switch could analyse the next three while a session runs.
2. **Where "reviewed" lives.** *Default: `triagedAt` inside `VideoSuggestions`* (§4.3), to avoid new move-carrying code.
3. **Quick-tag slots.** *Default: the nine most-used tags in the scope, frozen at session start.* The alternative, most recently used first, is friendlier but moves under your fingers.
4. **Sound.** *Default: on, at the current volume, with `M` to mute (built; triage-only, it does not change the saved volume).* Speech helps recognise a clip, and muting by default would hide that.
5. **"What's left" across the whole library.** The Overview can only count videos the app has seen (`knownVideoKeys`: tagged, rated, scanned, played, analysed), so a "6,120 of 8,900 tagged" figure would be wrong for anything never opened. *Taken: phase 3 adds a "Needs Tags" shelf labelled with what it covers.* It can be made real by including each background-maintained folder's last scan (`MaintenanceFile.known`), which is opt-in per folder.
