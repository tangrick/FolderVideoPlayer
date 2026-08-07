# FolderVideoPlayer

A native macOS media player that plays a whole folder back to back, loops
forever, and keeps a persistent favorites list that plays the same way.

Built with PyObjC on AVKit/AVFoundation, so playback is hardware accelerated
and the transport controls, fullscreen and Picture-in-Picture are the real
system ones.

![macOS](https://img.shields.io/badge/macOS-10.15%2B-blue)
![universal](https://img.shields.io/badge/arch-universal%20(arm64%20%2B%20x86__64)-lightgrey)

## What it does

- **Pick a folder → it plays.** Every video in it, in order, subfolders
  included. After the last one it wraps to the first and keeps going.
- **Opens straight into playing.** No dialog on the way in: it carries on
  from the folder, video and moment you last quit on. Each video remembers
  how far in you got.
- **Recent folders.** **File → Open Recent** lists the last eight folders you
  played, so a folder you come back to is two clicks away.
- **Repeat All, Repeat One, Shuffle or Play Once.** Shuffle deals the folder
  into a random order and plays all of it before anything comes round again.
- **Speed from 0.5× to 2×**, and it stays put across track changes and the
  system play/pause controls.
- **Tags.** Label videos with any keywords you like, one at a time or a
  whole selection at once, then filter by them or play everything carrying a
  tag as one queue across folders.
- **Favorites.** Star anything while it's playing. Favorites can span any
  number of folders and play as one looping list. A favorite is just a video
  tagged `Favorite`, so it lives alongside your other tags.
- **Playlist drawer.** Slides in from the right, highlights what's playing.
  Click a row, or arrow up and down it, to jump straight to that video. Rows
  show a ★ and a running time, subfolders get headings, and the filter box at
  the top makes a 300-file folder navigable.
- **Open New…** switches folders or jumps to a tag without restarting.

Everything the app remembers lives in
`~/Library/Application Support/FolderVideoPlayer/`, outside the app bundle, so
replacing the app never loses it: `tags.json` for tags and favorites, and
`state.json` for recent folders, resume positions and the last session.
`favorites.json` is only read once, to migrate an older version's stars.

## Controls

| | |
|---|---|
| `⌘⇧D` | favorite / unfavorite the current video |
| `⌘T` | tag the current video, or the drawer's selection |
| `←` `→` | skip back / forward 15 seconds |
| `⌘←` `⌘→` | previous / next video |
| `⌘L` | show / hide the playlist |
| `⌘N` | back to the opening menu |
| `⌘O` | open a folder directly |
| `⌘⇧F` | play favorites |
| `⌃⌘F` | fullscreen |

Space plays and pauses.

## Resuming

Opening the app carries on where you left off — same folder, same video,
same moment — without asking. If that folder has since been renamed, moved,
or lives on a drive that is not mounted, the app says nothing and simply
waits with an empty window; being met by an error before you have even seen
the app is worse than being met by nothing.

A video you leave part-way through is remembered, and starts from there the
next time you reach it — whether that is later in the same session, or after a
relaunch. Positions are sampled every few seconds while playing and written to
disk periodically, so a crash costs at most half a minute.

Two ends of a video are deliberately not remembered: the first 30 seconds,
and the last 30. Barely-started and just-finished both mean "start from the
beginning", which is what you want when a folder loops around to a video you
have already watched.

## Order and speed

The Playback menu picks what happens when a video ends:

| | |
|---|---|
| **Repeat All** | the whole folder in order, then round again (the default) |
| **Repeat One** | the current video, over and over |
| **Shuffle** | a random order that plays every video before repeating any |
| **Play Once** | stop after the last one |

Shuffle deals the folder into a shuffled order rather than picking at random
each time, so nothing comes round twice while something else has not been
played at all. When a pass finishes it deals again, never opening with the
video that just closed the previous pass. Next and Previous walk the shuffled
order too. Explicit Next still wraps past the end in Play Once — the mode
governs what happens on its own, not what you ask for.

**Playback → Speed** runs 0.5× to 2×. macOS resets the rate to normal every
time playback resumes, so the app reasserts the choice; it survives changing
video, pausing, and the floating on-screen controls.

Both settings are remembered between launches, and the window title names
them whenever they are not the plain defaults.

## The playlist drawer

`⌘L` slides it in. Each row shows a ★ if the video is a favorite and its
running time on the right. Videos in subfolders sit under a heading naming
the subfolder, and when playing a tag the heading is the folder each file
came from. The filter box at the top narrows the list as you type, matching on
filename; headings with nothing left under them disappear with their files.

Each row also carries a poster frame, grabbed a little way into the video
because opening frames are so often black. **View → Show Thumbnails** turns
them off — they make every row taller, which is a fair trade only if you want
them. With them off, rows go back to being dense and only a tagged video pays
for a second line.

Running times and frames are both produced in the background when a folder
opens, in one pass that opens each file once, so the list appears immediately
and fills in a moment later. Neither is cached between launches.

## Tags

The **Tag** button in the control bar, or `⌘T`, slides a panel up over the
bottom of the video. Tags are chips, not text: type and a comma or return
completes one, each carries its own delete button, and typing completes
against tags you already use. Underneath, the tags you use most sit as
one-click chips, which is what stops `holiday` and `holidays` drifting apart
in the first place.

The video pauses while the panel is open and picks up where it left off when
you close it — so what you are looking at is always what you are labelling.
Anything already paused stays paused. The panel is not modal: the playlist,
the transport controls and the menus all keep working, and the resume-position
timer keeps running.

For one video the field shows what it already has and is the whole truth —
delete a chip to remove that tag, clear the field to remove them all.

Select several rows in the playlist drawer and `⌘T` tags them together. That
case *adds* rather than replaces, and the sheet says so: replacing would
silently wipe tags the other videos had and this one didn't. Selecting a
range never disturbs playback; only a selection of exactly one row jumps the
player to it.

Tagged videos show their tags as chips under the filename in the drawer.
Only tagged rows grow the extra line — everything else stays dense.

The **Tags** menu lists every tag you have used, ticked when the playing
video carries it, so clicking one is the quick way to tag without a dialog.
**Tags → Play Tag** plays everything carrying a tag as one looping queue
across folders, in filename order, the way Favorites works. Typing a tag into
the drawer's filter box narrows the list — the box searches names and tags
together.

**Tags → Manage Tags…** lists every tag with how many videos carry it.
Rename one and every video updates; renaming onto an existing tag merges the
two. Delete removes the tag from every video without touching the videos.

Tags live in `tags.json` keyed on the video's path, which means renaming or
moving a video orphans its tags. The manager flags those and **Clear
Missing** removes them — deliberately manual, for the same reason as
favorites: an unmounted drive makes every file on it look deleted.

A video on a mounted share is keyed **share-relative** — `private/clips/a.mp4`
rather than `/Volumes/private/clips/a.mp4` — because that is the one form
every machine reaching the same NAS arrives at for the same file, whether it
mounts the share or talks SMB directly. Anything outside a share keeps its
absolute path, which is the honest answer: a video in your home folder is not
portable, and pretending otherwise would lose tags rather than move them. An
older `tags.json` full of `/Volumes` paths is rewritten in place the first
time it is read.

## Favorites are a tag

`⌘⇧D` and the ★ button work exactly as they always have — one keystroke, a
star in the window title, `⌘⇧F` to play them all. Underneath, starring a
video now tags it `Favorite` rather than keeping a second list, so there is
one store, one manager, and one place missing files get cleaned up.

Everything else follows from that: favorites show up in the drawer's filter,
under **Tags → Play Tag**, and as a row in **Manage Tags** with a count.

Upgrading from an older version migrates `favorites.json` into the tag
automatically on first launch — no prompt, nothing to do. A starred video
that lives on a drive you haven't plugged in migrates too; it is a favorite
whether or not the file can be seen right now. The old `favorites.json` is
left exactly where it is rather than deleted, so nothing is lost and an
older build still reads it.

Deleting the `Favorite` tag in Manage Tags is allowed — it is a tag like any
other — but the confirmation says plainly that it will unstar everything.

## Updating

**FolderVideoPlayer → Check for Updates…** asks GitHub for the latest release. If one is
newer than the running version it offers to install it: the app downloads the
disk image, quits, replaces itself and reopens. The check only runs when you
ask for it.

The version in `setup.py` must match the release tag — release `vN.M` ships
`CFBundleShortVersionString` `N.M`. If they drift apart the comparison is
meaningless and updates are never offered.

## Supported formats

`.mp4` `.m4v` `.mov` — what AVFoundation can decode. `.mkv`, `.avi` and
`.webm` are not supported; VLC is the better tool for those.

## Install

Grab the `.dmg` from [Releases](../../releases), open it, and drag the app to
Applications.

The app is ad-hoc signed rather than notarized with a paid Apple Developer
ID, so **the first launch is blocked by Gatekeeper**. To get past it once:

1. Try to open it, dismiss the warning
2. **System Settings → Privacy & Security**
3. Click **Open Anyway** next to the FolderVideoPlayer message

Or from Terminal: `xattr -d com.apple.quarantine "/Applications/FolderVideoPlayer.app"`

### Videos on a NAS or external drive

macOS blocks apps from reading network and removable volumes until you allow
it. If nothing plays, add the app to **System Settings → Privacy & Security →
Full Disk Access**. The player detects this specific failure and says so
rather than silently skipping every file.

## Building

Needs Python 3.12 from python.org at `/Library/Frameworks` — the build copies
it into the bundle, so the finished app has no external dependency and runs on
a Mac with no Python installed.

```sh
python3 -m venv venv
./venv/bin/pip install py2app pyobjc-framework-AVKit pyobjc-framework-AVFoundation
./venv/bin/python setup.py py2app
codesign --force --deep --sign - "dist/FolderVideoPlayer.app"
```

To package a DMG, put the app, `Readme.txt` and a symlink to `/Applications`
in one folder and run:

```sh
hdiutil create -volname "FolderVideoPlayer" -srcfolder <that folder> \
               -ov -format UDZO -fs HFS+ "FolderVideoPlayer.dmg"
```

Re-sign after changing anything inside the bundle or macOS will refuse to
launch it.

## Repository layout

| | |
|---|---|
| `player.py` | the whole application |
| `setup.py` | py2app build recipe |
| `icon.icns` | app icon |
| `Readme.txt` | full end-user documentation, shipped inside the DMG |
