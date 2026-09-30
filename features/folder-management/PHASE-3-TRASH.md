# Phase 3: the Trash keeps tags, hidden; Put Back restores them

**Read `README.md` in this folder first.** Its rules apply here.
**Covers:** R4 and R8, plus the leftover subtitle files that would otherwise block R5.
**No Apple TV change.**

---

## 1. Today's behaviour, and what's wrong with it

`FileOps.trash(_:library:askFolder:)` in `Model/FileOps.swift`:
- sends each video to the Trash (`trashItem`), or on a volume with none, to the nominated folder in `library.discardFolders[volume]`;
- then calls `dropBookkeeping`, which calls `Library.forgetPath`.

The problems:
- **`forgetPath` deletes the tags**, and queues `.remove` for the share. It also deletes facts and watch state, and `dropBookkeeping` deletes progress. **Put Back returns an untagged video.**
- **Only the profile in force is touched.** Other profiles and other people keep tags on a path that no longer exists, so their tag lists count a video that won't play.
- **Subtitle sidecars stay behind.** A leftover `clip.srt` then blocks deleting the folder (R5).
- **A nominated discard folder inside the library is scanned** like any other folder, so trashed videos reappear in the playlist, the counts, the duplicate finder and background upkeep.

---

## 2. Required behaviour

1. **Park, then hide.** When a video is successfully trashed:
   - First record **every** holder's tags for it in the parked store (§3). That means the profile in force, every other bundle on this Mac, and every person folder on its share.
   - Then remove the tags from all of them, so the video appears nowhere: tag lists, counts, Favorites, stars, smart collections, the filter, the Apple TV's shelves.
2. **Keep everything else in place.** Readings, watch state, moments, resume point, transcripts, marks and the hidden flag stay keyed to the original path. They're invisible without the file and come back with it.
3. **Subtitle sidecars go to the Trash with their video.** Same destination, same pass. Find them with `SubtitleFile.sidecars(for:in:)`, exactly as `FileOps.shift` does.
4. **Put Back restores the tags**, for every holder, when the file is at its original path again. After that the parked entry is removed.
5. **Emptying the Trash doesn't forget.** The parked entry stays, invisible. *Find Missing Files* lets the user forget such entries.
6. **Discard folders are not part of the library.** Every folder walk skips them (§6).

---

## 3. The parked store

This is a new file, **`Model/ParkedTags.swift`**, so it must be added to `Tests/model_sources.sh`. It owns `support/trashed-tags.json`; add `Paths.parkedTagsFile` for it.

```json
{
  "format": 1,
  "videos": {
    "NAS/clips/a.mp4": {
      "when": 1790000000.0,
      "where": "/Users/alex/.Trash/a.mp4",
      "profiles": { "alex": ["Beach"], "sam": ["Sunset"] },
      "people":   { "/Volumes/NAS/.FolderVideoPlayer/sam": ["Sunset", "Mum"] }
    }
  }
}
```

- **The key** is the video's **tag key** at its original path.
- **`where`** is where the file went: `trashItem`'s `resultingItemURL` (ignored today, `nil` is passed), or the path inside the discard folder.
- **`profiles`** is profile slug → tags, for local bundles including the one in force.
- **`people`** is person folder → tags, for share folders.
- **Both maps are kept even when the same person appears in each.** Restoring writes both, and that's harmless: a union.
- **Loading is lenient:** a missing or unreadable file means an empty store. Unknown fields are ignored and `format` is checked, following the pattern in `SharedExtras`.
- **It's global, not per profile**, because it holds everyone's entries.

---

## 4. Trashing: the steps

Make `FileOps.trash` **`async`**, following the pattern of `FileOps.move`: file work in `Task.detached`, bookkeeping back on the main actor.

**The order is the safety.** A holder's tags are written into the parked store **before** they're removed from that holder, so a crash at any point loses nothing.

1. **Move the file and its sidecars** to the Trash or the discard folder (`Task.detached`), and capture `where` for each file. `askFolder`, the discard-folder question, is a modal alert. Call it on the main actor between awaits, as today's loop does; only the file move itself goes into the detached task.
2. **Read the local holders and park them.** Read the tags of the profile in force (`library.tagsFor`) and of every other bundle's `tags.json`. Save the parked entry (key, `where`, `profiles`).
3. **Ring 1.** Add a new `Library.parkForTrash(_ path:)`:
   - remove the tags and call `recordSharedEdit(moving: key, to: nil)`, which queues `.remove` for the share;
   - **do not** call `forgetFacts`, touch `watch` or touch `progress`;
   - **do not** call the `pathMoved` hook: nothing moved.
4. **Ring 2.** For every other bundle, remove the key from its `tags.json` and queue `SharedTagEdit.forMove(from: key, to: nil)` in its `shared-sync.json` `pending`. Model this on `ProfileRelocation.carry(_:intoBundle:root:)`.
5. **Ring 3,** off the main thread. For every person folder on the share (`ProfileRelocation.personFolders`) **except the profile in force**:
   - take their lock;
   - read `tags.json`;
   - add their `videos[rest]` to the parked entry's `people` and save it;
   - apply `.remove(rest)`, which also writes `gone[rest]` with no `to`;
   - write, and unlock.

   **Generalise `ProfileRelocation.apply(_:inPersonFolder:device:)`** to take `[SharedTagEdit]` instead of move pairs, and keep the re-keying of `facts.json` and `transcripts.json` for `.move` only. Record a held lock in the owed file as today. **The owed format must then hold edits, not only move pairs.** Extend `Owed` with an optional `edits` field so existing owed files still load. A person whose lock was held still has their tags on the share, so nothing is lost while it's owed.
6. `library.saveTags()` and `library.save()`, once per batch.

**Callers.**
- `AppModel.trashFiles` wraps the call in `runFileOp("Deleted") { await FileOps.trash(...) }`.
- `FileOps.replace` also trashes, which is how a converted copy replaces its original. Make it `async` too, and change `PlaybackController.replaceOriginal`'s type to `async` (`PlaybackController.swift:109`, called at `:923`).
- **The duplicate finder** (`DuplicateFinder.swift:412` and `:472`) moves copies to the Trash on its own path. **Leave it alone.** It merges a discarded copy's tags into the keeper first, which is correct for duplicates.

---

## 5. Put Back

Add `ParkedTags.restore(present:library:)` on the main actor, doing the ring work off it. It takes paths that have been **seen to exist**. For each parked key whose original path is among them:

1. **Profile in force:** `library.setTags(union(existing, parked), for: path)`, then `saveTags`. Its next sync diffs this into a `.set`, and a `.set` on a path in `gone` brings that path back. That's the existing `SharedTagFile` rule.
2. **Other bundles:** write the union into their `tags.json`. Their sync diff sends the `.set` too. Queue nothing.
3. **People on the share:** under their lock, apply `.set(rest, parked)` **only if** `videos[rest]` is empty. Someone who has retagged it since keeps their own tags.
4. Remove the parked entry.

**Where "present" comes from.** Call it from each of these, passing only paths that are parked:
- `PlaybackController` after `Scanner.scan(root)` (lines ~187 and ~1225);
- once at launch, in the background, from `AppModel.recoverRelocationsOnce` or next to it. It checks each parked entry's original path, **two at a time** (the NAS trickle rule);
- the Organize tree walk in phase 5.

**Finder's Put Back** restores to the original path, so detecting existence is enough. There's no need to watch the Trash.

---

## 6. Discard folders are not library

The folders in `library.discardFolders` values must be skipped by every walk that builds a view of the library:

| Walk | Where |
|---|---|
| `Scanner.scan`, `Scanner.count` | `Model/Scanner.swift:9`, `:41`. Add a `skipping: [String] = []` parameter and use `walk.skipDescendants()` on a match. Callers pass `Array(library.discardFolders.values)`: `PlaybackController` `:187` and `:1225`, `FolderVideoPlayerApp.swift` `:877` (tag all), `PlayerWindow.swift` `:1190` (sidebar counts) |
| Duplicate finder | `Model/DuplicateFinder.swift:120` |
| Moved-file search | `Model/MovedScan.swift:473` |
| Background upkeep snapshot | `Playback/MaintenanceWorker.swift:236` |

Match by path prefix with a `/` boundary. Reuse `PathMap(from: discard, to: discard, isFolder: true).map(path) != nil`, or write a small `isUnder` helper.

---

## 7. Find Missing Files

In `Views/MissingFilesWindow.swift`, add a section, **"Deleted videos kept for Put Back"**:
- It lists parked entries whose `where` no longer exists **and** whose original path doesn't exist either (the Trash has been emptied).
- Each row has **Forget**, and there's a **Forget All**. Forgetting removes the parked entry.
- Nothing else is touched: the other stores keep their old-path entries, as today.
- **Keep the model logic in `ParkedTags`**, for example `func forgettable(exists:) -> [String]` and `mutating func forget(_ key:)`, so it can be tested.

---

## 8. Tests

Create `Tests/test_trash_park.swift` and its runner, and add a line in `Tests/run.sh`. **Set up the two Macs and the NAS the way `Tests/test_profile_relocation.swift` does.**

| # | Check |
|---|---|
| 1 | Trashing a tagged video removes its tags from the profile in force: `tagsFor`, `taggedWith`, `count(of:)` and Favorites |
| 2 | …and from another bundle's `tags.json`, with `.remove` queued in its `shared-sync.json` |
| 3 | …and from another person's share `tags.json`, as `gone[rest]` with no `to`. Their other videos are untouched |
| 4 | Readings, watch state, resume point and the hidden flag are **still there** at the original key |
| 5 | The parked file holds every holder's tags **word for word**, and `where` points at the file in the Trash or discard folder |
| 6 | Subtitle sidecars went with the video |
| 7 | **Put Back** (move the file back by hand): `restore(present:)` brings the tags back for the profile in force, the other bundle and the other person. The parked entry is gone |
| 8 | A person who retagged the path while it was in the Trash keeps their own tags |
| 9 | Trash emptied (delete the file from the fake Trash): the entry stays; `forgettable` lists it; `forget` removes it |
| 10 | A discard folder inside the library isn't in `Scanner.scan` or `Scanner.count` |
| 11 | A held lock during trashing leaves that person's tags untouched and the edit owed; the retry delivers it |
| 12 | Crash safety: after step 2 alone, run by calling the parking helper directly, the parked file holds the tags **and** the stores still hold them too. Nothing is removed before it's parked |

**Mutation-check.** Disable parking and checks 5 and 7 fail. Disable ring 3 and checks 3 and 7 fail.

**Existing tests** in `Tests/main.swift` call `FileOps.trash` synchronously. Update them to `await`, as phase 1 did for `move` and `rename`.

---

## 9. Done when

- Checks 1–12 pass, and the full suite and the app build pass with no new warnings.
- `features/PROGRESS.md` is updated.
- **Hand-test list for the user:**
  1. Trash a tagged video from the playlist; check its tag count drops.
  2. Put it back in Finder and reopen the folder; the tags are back.
  3. On a NAS with no Trash, choose a discard folder **inside** the library; check the trashed video doesn't reappear in the playlist.
