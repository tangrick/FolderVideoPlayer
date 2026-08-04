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
- **Picks up where you left off.** Each video remembers how far in you got,
  and the opening dialog offers to resume the folder and the video you quit
  on — press Return and you are back exactly where you were.
- **Recent folders.** **File → Open Recent** lists the last eight folders you
  played, so a folder you come back to is two clicks away.
- **Repeat All, Repeat One, Shuffle or Play Once.** Shuffle deals the folder
  into a random order and plays all of it before anything comes round again.
- **Speed from 0.5× to 2×**, and it stays put across track changes and the
  system play/pause controls.
- **Favorites.** Star anything while it's playing. Favorites can span any
  number of folders and play as one looping list, and **File → Manage
  Favorites…** prunes them without playing anything.
- **Playlist drawer.** Slides in from the right, highlights what's playing.
  Click a row, or arrow up and down it, to jump straight to that video. Rows
  show a ★ and a running time, subfolders get headings, and the filter box at
  the top makes a 300-file folder navigable.
- **Open New…** returns to the opening menu to switch folders or jump to
  favorites, without restarting.

Everything the app remembers lives in
`~/Library/Application Support/FolderVideoPlayer/`, outside the app bundle, so
replacing the app never loses it: `favorites.json` for the starred list, and
`state.json` for recent folders, resume positions and the last session.

## Controls

| | |
|---|---|
| `⌘⇧D` | favorite / unfavorite the current video |
| `←` `→` | skip back / forward 15 seconds |
| `⌘←` `⌘→` | previous / next video |
| `⌘L` | show / hide the playlist |
| `⌘N` | back to the opening menu |
| `⌘O` | open a folder directly |
| `⌘⇧F` | play favorites |
| `⌃⌘F` | fullscreen |

Space plays and pauses.

## Resuming

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
the subfolder, and in Favorites mode the heading is the folder each file came
from. The filter box at the top narrows the list as you type, matching on
filename; headings with nothing left under them disappear with their files.

Running times are measured in the background when a folder opens, so the list
appears immediately and fills in its numbers a moment later. They are not
cached between launches.

## Managing favorites

**File → Manage Favorites…** lists them without playing anything. Select and
**Remove**, or use **Remove Missing** to clear out entries whose file has been
deleted or renamed — favorites are stored as full paths, so moving a file
orphans its entry.

Removing missing entries is deliberately manual and never happens on its own:
a network or external drive that simply is not mounted makes every file on it
look deleted, and pruning then would throw away favorites that are perfectly
fine. Check the drive is mounted before using it.

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
