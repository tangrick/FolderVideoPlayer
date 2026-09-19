# Hidden videos — design

**Asked for (2026-09-12):** "hide file and to access hidden file one needs
password".

**Decided, in the user's words:** hiding is **in the app only** (the file is not
touched — no rename, no flag, no move, no encryption); the hidden set is
**app-wide** (not per tag profile); **individual videos** (not folders); and the
password is asked **once per app session**.

## The honest limit, first

This keeps videos out of the app's sight, not off the disk. Anyone with Finder
can still see and play the file. That is the trade the user chose, and every
piece of UI must say so rather than imply protection it does not have — a
password prompt that suggests otherwise is the worst kind of lie. Real
protection (rename, flag, vault, encryption) is a later decision, and this
design keeps the door open by owning no file bytes.

## The contract

A hidden video is **invisible to the app** everywhere it would otherwise appear
or be acted on — `Scanner.scan` results, folder counts, tag counts, duplicate
groups, moved-file results, the AI's candidate pools — and appears **only** in
the Hidden view, which requires the password.

The list is **not** destroyed by hiding: tags, favourites, progress, duration
and Safe/NSFW marks all survive, so unhiding restores the video exactly as it
was. Hiding is a visibility flag, never a delete.

## Storage

Two things, deliberately separate, because they answer different questions:

| What | Where | Why there |
|---|---|---|
| The hidden paths | `state.json` → `hidden: [String]?` | It is library state, like `sparedDupes`. Optional (pitfall 7), and keyed **share-relative** exactly like tags (`Paths.tagKey`), so a remount or a different device sees the same list. |
| The password record | `<support>/hidden.json` | It is a credential, not a preference: salt, iteration count, hash, version, and nothing else. Separate file so "forgot the password" is one file to remove, and so the credential never travels with shared tags. |

**Backwards compatibility:** the hidden list lives in `state.json` and the
credential in `hidden.json`; either can be missing, and a library written before
this feature loads as "nothing hidden, no password". The files are plain JSON,
so the list is recoverable by hand — which is the honest answer for app-only
hiding, and is documented in Help rather than hidden.

### The password record

```json
{ "version": 1, "iterations": 200000, "salt": "<base64>", "hash": "<base64>" }
```

`hash = SHA256^iterations(salt || password)`, narrowed to the standard 32 bytes.
CryptoKit is already linked, so no new dependency. Iterations are stored so they
can be raised later without invalidating an existing password. Comparison is
constant-time. Wrong passwords are not counted or rate-limited in v1 — the file
is readable anyway, so throttling would be theatre; it is noted here so nobody
mistakes it for a missing feature.

## Session

* Locked at launch. Unlocked once, stays unlocked until the app quits — the
  user's choice, so no idle timeout in v1.
* `isUnlocked` is **never persisted**: a relaunch locks, always.
* The **filter does not depend on the lock.** A locked app still hides hidden
  videos; the lock only gates *revealing* them (the Hidden view, unhiding, and
  the Settings count).

## Where each side is filtered (the checklist)

| Surface | Filter |
|---|---|
| Playlist rows (folder / tag / favourites / duplicates-as-playlist) | `HiddenFilter.omit` at the scan → playlist seam |
| Sidebar folder counts | subtract the hidden keys under that root |
| Tag counts + `taggedWith` | skip hidden keys when counting and listing |
| Duplicate groups | drop hidden members (and a group that empties) |
| Moved-file results | drop hidden entries |
| The sidebar's Resume row | `Library.resumable` refuses a hidden video and a session left by the Hidden view — this row prints a FILE NAME, in the left panel, while the app may be locked |
| AI: analysis queue, suggestions, look-alike pools | hidden videos never enter a pool or a queue |
| Hidden view (unlocked only) | `HiddenFilter.only` |
| Anywhere else | a `state.json` list nobody reads is a bug report waiting; the gate below is how this table stays true |

## UI

* **Hide / Unhide** on the row context menu and in the Files menu, acting on the
  whole selection exactly like Move and Trash do.
* Hiding with no password yet prompts to **create** one first (one sheet), then
  hides.
* **View → Show Hidden Videos** asks for the password when locked, then switches
  the playlist to the hidden set only, with a visible "Hidden — unlocked" banner
  and a **Lock Now** action.
* Nothing else on screen leads there: no tag, no tag playlist and no row in
  the library panel — the menu command is the only door (see "As built", 4).
* **Settings → Privacy → Hidden videos**: how many are hidden, Set / Change
  password, and Remove password — each stating in plain words what it does and
  does not protect.

## Gate

`Tests/run_hidden.sh`, standalone (no Xcode), covering: a password set/verify/
wrong/change/remove; the record round-tripping through its file and refusing a
truncated or newer one; a session that locks on relaunch; `HiddenFilter` in all
three modes; share-relative keying across a remount; and the invariant that
matters most — **hiding changes nothing else about a video** (tags, marks and
progress survive a hide/unhide round trip, and the file is not resized).
Wired into `Tests/run.sh`.

## As built (2026-09-12)

Three divergences from the sketch above, all deliberate:

1. **One source of truth for "the Hidden view is on screen".** The sketch had a
   `Library.showingHidden` flag alongside the playback mode. It was dropped:
   the playback controller's new `.hidden` `PlayMode` owns the `.only` filter
   (`start`, `buildRows`, the session label, the moved-scan scope), and
   `Library.hiddenFilter` is simply `.omit(hidden)`. Two flags that must agree
   is one flag too many.
2. **The filter is applied on the way IN and on the way OUT.** `start` filters
   whatever is handed to it (folder scan, tag, favourites, a drop, a resume),
   and `buildRows` filters again — so hiding a video takes effect on the list
   already on screen instead of waiting for the folder to be reopened.
3. **Three more surfaces than the sketch listed**, found by grepping for
   enumerations rather than trusting the table: `MetadataTagger.run` grew a
   `hidden:` parameter ("Tag from Metadata" walked the folder itself), the
   look-alike search skips hidden keys when it builds its pool, and
   `LibraryTagPayload` prototypes are built from visible tags only. The AI
   training set (`TrainingSetBuilder`) filters in one place so playlist, tag,
   folder and Tag-Profiles scopes all agree.

4. **No tag, no tag playlist, and no row in the library panel** — decided
   2026-09-12, after a first cut that put a `Hidden` entry beside Favorites.
   **View → Show Hidden Videos…** in the menu bar is the only way in.

   Tagging them was the obvious reading, and it cannot work: `recount()` and
   `taggedWith` skip hidden keys by design, so a real `Hidden` tag would list a
   count of 0 and `playTag` would open an empty playlist — and if it did not
   skip them, every other tag surface would leak the videos the password is
   there to gate. A sidebar row could have been a pseudo-collection like
   Favorites instead, but that still leaves a door (and the number of hidden
   videos) on screen for somebody who has not given the password. Hiding means
   hidden: no chip, no playlist, no row, and no count anywhere but Settings →
   Privacy, which is where a forgotten password is dealt with.

5. **The Resume row was handing out hidden file names.** Hiding the video that
   was playing left its name in the sidebar's Open section — printed on screen
   while the app is locked, and a row that could not be resumed anyway. Which
   sessions may be offered is now `Library.resumable(_:)`: never a video that
   is hidden, never a session left by the Hidden view. `PlayMode` moved from
   `PlaybackController` to `AppState` so the model can name the Hidden case and
   the hidden gate can cover the rule; it was the only type both the model and
   a gate needed and neither could see. Hiding the playing video still lets it
   finish — being watched is not a leak — but nothing on screen names it.

The password record is `hidden.json` next to `state.json`; forgetting it is
removing that one file, and the Help window says so. The hidden list is
recoverable by hand from `state.json` — the honest answer for app-only hiding,
which is also why the Help page says plainly that Finder can still open the
file.
