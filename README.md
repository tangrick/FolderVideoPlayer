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
- **Favorites.** Star anything while it's playing. Favorites can span any
  number of folders and play as one looping list.
- **Playlist drawer.** Slides in from the right, highlights what's playing.
  Click a row, or arrow up and down it, to jump straight to that video.
- **Open New…** returns to the opening menu to switch folders or jump to
  favorites, without restarting.

Favorites persist in `~/Library/Application Support/FolderVideoPlayer/favorites.json`,
outside the app bundle, so replacing the app never loses them.

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
