# FolderVideoPlayer — architecture notes

A native macOS media player: point it at a folder and it plays the lot, with
tags, favorites and a duplicate finder. This is a SwiftUI/Swift rewrite of the
PyObjC app ([FolderVideoPlayer-python](https://github.com/tangrick/FolderVideoPlayer-python)), carrying over its behaviour, its file
formats and its hard-won details.

```bash
open FolderVideoPlayer.xcodeproj      # Xcode 26.5, macOS 14+
Tests/run.sh                          # the model layer, no Xcode needed
```

## What is here

```
FolderVideoPlayer.xcodeproj    the app target, one synchronized source group
FolderVideoPlayer/
  Model/        paths, formatting, scanning, tags, fingerprints, caches
  Playback/     the engine protocol, its AVFoundation implementation, the playlist
  Views/        the player window, playlist, tag panel, duplicate finder, managers
Tests/run.sh    plain-script tests over the model layer
```

## The two sidebars

The playlist has two view modes — ⌘1 a grid of poster frames, ⌘2 a list of
Name, Date Added and Size — and in the list Finder's header: a click sorts by
that column, a click on the column already sorting turns it around, and the
arrow says which way. The panel is dragged wider by its left edge and
remembers where you left it (`playlistWidth` in `state.json`). Folder Order,
which has no column of its own, lives in the header's chevron menu with the
poster-frame switch.

The library sits down the left — a folder to open, where you left off, recent
folders, favorites, and every tag with something behind it — and the playlist
down the right. Both are panels beside the picture rather than screens in front
of it, so choosing what to watch next never interrupts what is playing now.
⌘N shows and hides the library, ⌘L the playlist. The library is always there
when nothing is playing, because then it is the only thing to do.

## Full screen

⌘F, a double click on the picture, the green button or ⌃⌘F — all four end up
in the same place, because the app follows the window's own full-screen
notifications rather than whoever asked. Both panels go, the transport bar
moves over the picture and fades with the pointer after three seconds (and
stays put whenever nothing is playing, since there is nothing for it to be in
the way of). Escape comes back out, which macOS does not do by itself for a
window that went full screen on its own.

## Playback

Playback goes through `PlayerEngine`, a protocol the UI talks to and nothing
else. `AVPlayerEngine` implements it on AVFoundation: hardware accelerated,
with the system's own fullscreen and Picture-in-Picture, and no third-party
framework to fetch or licence.

The cost is formats. The PyObjC build carries VLCKit precisely because
AVFoundation reads `.mp4`, `.m4v` and `.mov` and not `.flv`, `.avi`, `.mkv` or
`.webm`. Those files are still listed and still tagged here; asked to play one,
the app says so out loud and moves on rather than sitting on a black rectangle.
**A `VLCKitEngine` conforming to `PlayerEngine` is the whole of what restoring
those formats takes** — no view knows which engine it is talking to.

## Holding up at a thousand videos

The row views are lazy — `LazyVStack`, `LazyVGrid`, `LazyHStack` build only
what is on screen — and so is the work behind them:

- **The playhead is its own object.** It changes four times a second, and
  published from the controller it had every view observing the controller,
  the whole playlist included, re-evaluating at that rate. Only the transport
  bar observes `Playhead`.
- **Rows are held, not derived.** The list asks for them several times per
  redraw; filtering a thousand paths on each of those showed.
- **Durations are measured per visible row**, as it appears, rather than swept
  over the playlist up front — twenty files opened instead of a thousand
  before the list has drawn once. Writes to `durations.json` are debounced two
  seconds so a scroll is not one rewrite per row.
- **Stats are memoized and warmed off the main thread.** Date Added and File
  Size sort on a stat apiece; a thousand of them from the main thread is a
  thousand SMB round trips with the window frozen behind them. `warmStats`
  does eight at a time off the actor and the list settles when they land.
- **Tag counts are derived once per change.** The library panel draws a count
  beside every tag; counting per tag per redraw walked every tagged video 40
  times a frame.
- **Tagging a selection is one write.** `tags` is published, so assigning per
  video told every view a thousand times.
- **The folder walk happens off the main thread**, with the window saying so.
  A tree of several thousand files takes long enough that walking it on the
  main thread stops the window answering, which macOS draws as a spinning
  wheel.
- **Nothing touches the disk while a row is drawn.** A stat is an SMB round
  trip, and a share that has gone to sleep answers its first one in seconds.
  Each row asks for its Date Added and Size in a `.task` as it appears; the
  accessors return what is already known and never stat.
- **Launch does not wait on the network.** Taking in the other devices' tags
  and publishing this one's both read and write files on the shares — at
  launch, from the main thread, that was a spinning wheel before the window
  had drawn. They now happen behind the resumed session.
- **Sort keys are built once per path**, not inside every comparison. This was
  the wheel's other half: sorting five thousand names cost 254ms before and
  9ms after.

Measured on 1,000 local files (an SMB share multiplies every stat by 5–20×):

| | before | after |
|---|---|---|
| 1,000 stats for a Date Added sort | 58 ms, main thread | 17 ms, off it |
| 20 visible rows asking their length, per second | 2.6 ms of stats | ~0 |
| 40 tag counts, per second | 13 ms | 0.1 ms |
| sorting 5,000 names | 254 ms, main thread | 9 ms |
| walking a 5,000-file tree | main thread | off it, with a progress note |
| launch merge + publish over SMB | main thread, before first draw | behind the resumed session |

Nothing pages: the row stacks are lazy, so a playlist of five thousand still
only ever builds the twenty rows on screen.

What is still eager, deliberately: the duplicate sweep reads every candidate,
and `derive()` stats every copy in every set — but only when the index, the
scan or the spared list actually changes.

## Data

Everything lives in `~/Library/Application Support/FolderVideoPlayer/`,
alongside the PyObjC build and in the same shapes:

| file | what |
|---|---|
| `tags.json` | `{key: [names]}` — interchangeable with the PyObjC build |
| `state.json` | resume positions, recent folders, preferences, scans |
| `durations.json` | `{key: [bytes, seconds]}` — interchangeable |
| `fingerprints.json` | the duplicate index — same shape, **different hashes** |
| `thumbs/` | this Mac's poster frames |
| `analysis.json` | the engine's reading of each video, shared by every profile |
| `frames/` | the content-addressed frame vector cache, likewise shared |
| `models/` | downloaded-model staging, plus the Python engine's scratch |
| `tags/` | the downloaded models themselves, beside the prompt table |
| `profiles/<name>/` | what one tag profile decided for itself |

Keys are share-relative for anything under `/Volumes` and absolute otherwise,
so a tag means the same thing on every device that reaches the same NAS.

**Per-profile AI state.** Everything a profile decides for itself lives under
`profiles/<name>/`: the fitted tag heads (`*_trained_heads.json`), the machine's
suggestions and your accept/reject verdicts (`suggestions.json`), your Safe/NSFW
marks (`marks.json`), and the people you have named (`faces.json`). Training one
profile therefore never changes what another is offered, and a profile that has
never been used starts blank. The frame vector cache and the downloaded models
stay shared — they are a reading of the videos, identical for everybody, and
re-deriving them per profile would mean a second full encode.

`state.json` gains one key, `progressSeen`. The Python build kept its newest
resume positions by dictionary insertion order; Swift dictionaries have none,
so the stamps are written down. The Python build ignores the extra key.

**Fingerprints do not carry over.** The Python build hashes with blake2b, which
CryptoKit does not offer; this one uses SHA-256. The file's shape is identical
but the values disagree, so the two builds will re-fingerprint after each
other. Run them against separate copies, or accept one re-scan per switch.
Tags, durations and resume positions are all shared safely.

Set `FVP_SUPPORT` to point the whole lot somewhere else — what the tests use,
and the way to try this build without touching a real library:

```bash
FVP_SUPPORT=/tmp/fvp-scratch open -n FolderVideoPlayer.app
```

## Tag profiles

A **tag profile** is one person's set of tags. Several people can share a Mac
and a NAS without writing over each other, and one person with a Mac and an
Apple TV is still one profile. Each gets a folder on each mounted share and
each of their devices a file inside it:

```
.FolderVideoPlayer/quincy/tags-macbook.json
                          /tags-appletv.json
```

Profile, so two people never overwrite each other. Device, because one person
with two machines is still two writers, and two writers on one file is how tags
get quietly lost.

**Tag Profiles** (File ▸ Tag Profiles…) is the one window for all of this: the profiles down the
left, the tags inside the selected one down the right. You can look at anybody's
profile; you can only change your own — the tags in another profile are that
person's work, published from their devices, and the window says so rather than
pretending otherwise. Renaming, deleting and clearing out orphaned tags all
live here.

Each profile owns its own tags. The profile in force keeps them in `tags.json`
— the file the PyObjC build reads — and the others wait in `profiles/`;
switching swaps them, so picking a profile shows that profile's tags and
nobody else's. Nothing is merged across profiles: two profiles are two people.

## Nothing is deleted outright

Accidental deletion is a safety problem, not a security one, so instead of
asking who you are the app makes destruction reversible and reserves the
friction for the one act that is not. (The app's only password guards the
hidden-videos list, and it is about visibility, not files — see
[Hidden videos](#hidden-videos).)

- **Deleting a profile takes typing its name.** It is the one act with no way
  back — this Mac's copy and the folder on every mounted share, which is every
  device's tags for that profile, not just this one's. A button nobody reads is
  not a safeguard. The name is remembered as deleted, so a share that was
  offline at the time cannot re-offer the profile when it comes back.
- **Destructive tag edits are undoable.** Deleting a tag, renaming one, or
  clearing orphans snapshots the tag set first — to memory and to
  `tags.previous.json` — so **Undo** is still there after a quit or a crash,
  and says what it would undo.
- **Type-to-confirm, once.** Only Delete Permanently asks you to type the
  profile's name. Friction everywhere else just teaches people to click
  through.
- **Publishing never empties a share's copy.** If this device holds no tags
  for a share that has some, the file is left alone and the reason is
  reported. This is the guard that matters most: it runs at every launch.
- **A settings folder copied to a second Mac gets a new device id.** Both Macs
  would otherwise write the same `tags-<device>.json` and overwrite each
  other — the very thing a file per device prevents.

Nothing here stops somebody determined; without a password there is nothing to
stop them with. It makes accidents recoverable and deliberate destruction slow
and obvious. If you need the determined case covered, that is NAS permissions,
not app UI.

At launch, a Mac holding more than one profile is asked which to use, and the
window offers to make a new one. Turn "Ask which profile at startup" off in
that window and it stops asking. The share is not read to decide this — that
would put network traffic in front of the first frame — so a profile that
exists only on the NAS appears once the window is open.

The app takes in what its other devices have said since last time, then leaves
its own where they can read it — behind the resumed session, and silently,
because a NAS asleep or unplugged is a normal Tuesday. Poster frames are
published beside the tags, unowned: what a video looks like is not anybody's
opinion.

## Hidden videos

Hide a video from its right-click menu (or Edit → Hide Video, ⌃⌘H) and it disappears
from the playlist, folder and tag counts, favourites, duplicates, the
moved-file scan and everything the AI is asked to do — and stays put where it
was. **Hide is not delete**: the tags, the favourite mark and the resume
position are kept, so unhiding restores the video exactly as it was.

The only way in is **View → Show Hidden Videos…** in the menu bar, which asks
for the password whenever the app is locked. The first hide asks for you to
choose one. The password is stored as a salted, iterated hash in `hidden.json`;
the session unlocks once and the next launch locks again.

**Hidden is not a tag.** Nothing hidden is counted, listed, colour-chipped or
trained on — a tag would be all four, and a tag playlist would be a door that
opens without the password. So the hidden set lives outside the tag vocabulary
and has no row in the library panel: the menu command is the only door.

Be clear about what this is: the password keeps the **app's list** out of
sight. It does not touch the file. Finder, or any other app on this Mac, can
still open it. Real protection means renaming or encrypting the file, which is
a different feature and a different decision. The Help window says the same
thing, because a password prompt that implies otherwise is worse than none.

Forgot it? Remove `hidden.json` from the app's support folder (Settings →
Privacy → Remove does the same) and the password is gone; the hidden videos
stay hidden and can be brought back one at a time.

## Duplicates

A scan is a named set of folders. The sweep lists them, throws away everything
whose size nothing else shares — four files in five, for free, because the size
came with the listing — fingerprints what is left from 128 KB at each end, and
then, optionally, reads the survivors end to end.

Results are sets, biggest reclaim first, each with one copy chosen to survive:
the tagged one, else the oldest, else the shortest path. Nothing is ever
deleted. Copies go to the Trash, or — on an SMB share, which has none — to a
folder you nominate once per volume and empty yourself.

Deriving the results asks the disk about every copy in every set, so it is held
until the index, the scan, or the spared list actually changes. Choosing a
keeper edits the set in place instead: that click used to appear to hang.

## Getting videos in

Open Folder (⌘O), or drag a folder onto the window or the app icon — the app
declares `public.folder` and `public.movie` as viewer types, so Finder offers
it. Dropping several video files makes a playlist of just those, rooted at the
folder they share. Anything dropped that is not a video is reported rather than
quietly ignored.

## Settings and Help

⌘, opens Settings: General (skip step, default speed, play order, resume,
ask-which-profile), Appearance (view, poster frames, panel widths), AI &
Privacy (face recognition, the two duplicate switches, and what does and does
not leave this Mac), Library (profile, recent length, a copy of your tags) and
Advanced (engine state, the engine log, where the files are).

The Help menu (Quick start, Keyboard shortcuts, Where my data lives) is the
same window with three pages; the first-run screen's "Take the Tour" opens it
at Quick start.

### AI features are downloads, not part of the app

Nothing AI ships in the DMG. Playing, tags, favorites and the duplicate finder
need no model at all, so the app is useful the moment it is installed, and the
AI features are turned on from Settings → AI by choosing what to fetch:

| Bundle | What it adds | Download |
|---|---|---|
| Tag suggestions | tag chips, look-alikes, training, the library prototypes | ≈344 MB |
| Safe / NSFW | the Safe/NSFW verdict, and the correction it learns from your marks | ≈159 MB |
| Face recognition | finding faces, and the people you name | ≈18 MB |
| Speech transcription | a searchable transcript of what is said (WhisperKit) | ≈646 MB |

The download list is a small `ai-bundles.json` in the public assets repo
(`tangrick/FolderVideoPlayerSwift-AI`), so a new release needs no app update and
no account: the app fetches it unauthenticated, which is why the models live in
a public repo of their own. Every asset is checked against the
SHA-256 that list carries before **any** of it is installed: a bundle is only useful
whole, and a partial install is a feature that claims Ready and then fails on
the first frame. A download that cannot be checked installs nothing at all and
says why.

The empty screen offers the AI features once, and only while none of them is
installed. Face recognition is the smallest bundle and installs like the
rest; its two models are both ports of the ONNX pair the Python engine used, so
the crops — and the match threshold calibrated on them — do not move.

**The engine is Core ML, and there is nothing to switch on.** The AI runs in
this process — no Python, no torch, no ffmpeg — because that is the only thing
that can work on a Mac which has never had them installed. The Python engine is
kept for development and is selected by a file, not by the scheme:

```bash
printf 'mode=python\n' >> ~/.fvp-engine     # the old child process
```

A release must also carry the three bundles, or Settings → AI reports that the
download list could not be read and offers nothing to press. Publishing them is
one command — `docs/coreml-spike/pack_bundles.sh`, then `gh release create`
(see `docs/clean-start-checklist.md`).

## What differs from the PyObjC build

- AVFoundation instead of VLCKit, as above.
- No self-updating installer: the download from this project's releases page is
  the update.
- The duplicate results are one scrolling list rather than a table with a
  progress sheet during trashing; the discard runs and reports at the end.
- No preview-while-playing window pinned beside the results — previewing a
  copy opens a sheet with its own player, which keeps the same promise: your
  place in the playlist is not lost by inspecting a file.
