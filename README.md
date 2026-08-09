# FolderVideoPlayer

A native macOS media player that plays a whole folder back to back, loops
forever, and keeps a persistent favorites list that plays the same way.

Built with PyObjC on AVKit/AVFoundation, so playback is hardware accelerated
and the transport controls, fullscreen and Picture-in-Picture are the real
system ones.

![macOS](https://img.shields.io/badge/macOS-10.15%2B-blue)
![universal](https://img.shields.io/badge/arch-universal%20(arm64%20%2B%20x86__64)-lightgrey)
![signed](https://img.shields.io/badge/signed-notarized%20by%20Apple-brightgreen)

> Version 1.0.0 is a renumbering, not a rewrite. Everything the app could do
> at 1.14.1 it still does; the history of how it got there is in the commits.
> The previous repository is archived at
> [FolderVideoPlayer-v1-archive](https://github.com/tangrick/FolderVideoPlayer-v1-archive)
> with its 19 releases intact. **A copy installed from there will not update
> itself to this one** — 1.0.0 is not greater than 1.14.1 — so download it once
> from Releases here and updates resume normally.

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
| `⌘.` | stop — back to the start and staying there |
| `⌘⇧D` | favorite / unfavorite the current video |
| `⌘T` | tag the current video, or the drawer's selection |
| `←` `→` | skip back / forward 15 seconds |
| `⌘←` `⌘→` | previous / next video |
| `⌘L` | show / hide the playlist |
| `⌘N` | back to the opening menu |
| `⌘O` | open a folder directly |
| `⌘⇧F` | play favorites |
| `⌃⌘F` | fullscreen |

Space plays and pauses, and so does clicking anywhere on the picture.

**The transport lives in the floating on-screen controls**, not along the
bottom of the window. Its menu button carries **Previous**, **Next**, **Skip
Back**, **Skip Forward** and **Stop**. macOS gives no way to add transport
buttons of your own to an `AVPlayerView`, and that menu is the only hook it
offers — but once they are there, a second set of the same buttons in the
app's own bar is just a second set of the same buttons. The bar keeps only
what AVKit has no idea about: Favorite, Tag, Open New and Playlist.

The rewind and fast-forward buttons AVKit draws itself are *scan* controls —
they work while held down and do nothing on a click, which is why they never
behaved like skip buttons.

**Stop** is not pause. Pause means "I am coming back to this spot", so the
position is kept; stop means "I am done with this", so the video rewinds and
forgets where it had got to.

## Resuming

Nothing plays on its own. Opening the app leaves the window waiting, because
the app gets opened to look something up at least as often as to carry on
watching, and starting a video unbidden is the wrong default for the first of
those.

**Open New…** offers **Resume** when there is something to carry on with, so
picking up where you left off is one click and a decision rather than an
ambush. Everything is still remembered either way.

Closing the window does not quit — Cmd-Q does. Closing it pauses playback and
saves your place. The Dock icon brings it back, and so does anything that
starts something: **Open New…**, **Play Tag**, **Play Favorites** or
**Resume** all put the picture back on screen first. Changing track does not,
so a folder playing while you work in another app never steals focus. A window close should not
cost you a queue, a place in a video, or a folder scan that is halfway
through.

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
bottom of the video.

**There is no Save.** Click a tag and it is tagged — written, published and
reflected in the list before you have let go of the mouse. Click it again to
take it off. The tags you use most sit along the bottom as one-click chips,
ticked when this video already carries them, which is both the fastest way to
tag and what stops `holiday` and `holidays` drifting apart.

A panel with a Save button is a panel you can leave without saving, and for
something as small as one keyword that is all cost and no benefit. The **Done**
button only closes it; so does Escape, or `⌘T` again.

Typing still works for a tag that is not on a chip yet: the field takes tokens,
a comma or return completes one, and it completes against tags you already
use. What you type lands when you finish typing it rather than on every
keystroke — otherwise typing `Big` would leave you with tags called `B` and
`Bi` on the way.

The video pauses while the panel is open and picks up where it left off when
you close it — so what you are looking at is always what you are labelling.
Anything already paused stays paused. The panel is not modal: the playlist,
the transport controls and the menus all keep working, and the resume-position
timer keeps running.

For one video the field shows what it already has and is the whole truth —
delete a token to remove that tag, clear the field to remove them all.

Select several rows in the playlist drawer and `⌘T` tags them together. That
case *adds* rather than replaces, and the panel says so: replacing would
silently wipe tags the other videos had and this one didn't. A chip clicked a
second time therefore does **not** strip that tag from the whole selection —
with no Save step to catch it, one stray click would otherwise untag fifty
videos. Removing in bulk is what **Manage Tags…** is for. Selecting a range
never disturbs playback; only a selection of exactly one row jumps the player
to it.

Tagged videos show their tags as chips under the filename in the drawer.
Only tagged rows grow the extra line — everything else stays dense.

The **Tags** menu lists every tag you have used, ticked when the playing
video carries it, so clicking one is the quick way to tag without a dialog.
**Tags → Play Tag** plays everything carrying a tag as one looping queue
across folders, in filename order, the way Favorites works. Typing a tag into
the drawer's filter box narrows the list — the box searches names and tags
together.

**Tags → Names on the Share…** lists every name published on your mounted
shares — including names this Mac has never used — with how many videos and
devices stand behind each, and which one is yours. **Use This** adopts a name;
**Delete** takes one off the share.

That last one matters because a name was previously easy to create and
impossible to remove: a folder left behind by a device that has since been
renamed sat in the Apple TV's list of people forever, looking like a person.
Deleting removes the published tags for that name, not the videos, and not the
tags held on the devices themselves — any device still using the name simply
publishes it again.

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

### Tags on the share

Whenever tags change, each share carrying tagged videos gets a copy, filed
under who made them and which machine wrote them:

```
.FolderVideoPlayer/richard/tags-macbook.json
                          /tags-appletv.json
```

**Person**, so several people sharing a NAS never overwrite each other.
**Device**, because one person with a Mac and an Apple TV is still two
writers, and two writers on one file is how tags get quietly lost — whoever
saves last wins and the other's work vanishes with no error.

A folder for the person rather than a longer filename: names are flattened to
letters, digits and dashes, so `tags-richard-*` would also match
`tags-richard-tang-macbook`, and Richard would silently swallow Richard Tang's
library. A directory boundary cannot be ambiguous that way.

Your name defaults to your macOS account name and is only a default — an Apple
TV has no account name to borrow, and renaming a Mac account should not orphan
a library.

**A name on a folder organises tags. It does not hide them:** anyone who can
read the share can read all of it. If you need tags actually private from
other people on the NAS, that is separate shares with separate logins, set up
on the NAS itself.

The file inside is keyed from the share root:

```json
{ "Richard/clips/a.mp4": ["Beach", "Favorite"] }
```

The share name is dropped, because a device talking SMB sees
`Richard/clips/a.mp4` and has no idea what some Mac called the mount point.
The folder starts with a dot, so the app's own scanner never sees it as media.

Publishing is silent — a NAS asleep or mounted read-only is a normal Tuesday,
not something worth a dialog. **Tags → Publish Tags to Share** does the same
thing and reports what happened, which is the way to check it is working.

Tags made on your other devices are taken in at launch and whenever you
publish. Only your own are read — another person's are none of our business,
and folding them in would put words in their mouth. A file newer than the last
merge wins the videos it names, per video rather than per tag: coarser, but a
rule you can hold in your head.

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

Releases built with `Tools/release.sh` are signed with a Developer ID and
notarized by Apple, so they open with no warning.

Older releases — and any build made without a Developer ID certificate — are
ad-hoc signed instead, and **the first launch is blocked by Gatekeeper**. To
get past it once:

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

Once, to set up the environment:

```sh
python3 -m venv venv
./venv/bin/pip install py2app pyobjc-framework-AVKit pyobjc-framework-AVFoundation
```

Then a release is one command — build, sign, notarize, staple, and package the
DMG:

```sh
Tools/release.sh
```

`Tools/release.sh --no-notarize` skips the trip to Apple and signs ad-hoc,
which is what you want while testing a change.

### Notarizing

Notarization is what stops Gatekeeper warning everyone who downloads the app,
and it needs two things set up once. Neither is in this repository and neither
should ever be:

1. A **Developer ID Application** certificate, from Xcode → Settings →
   Accounts → Manage Certificates → **+**. This is not the same as an "Apple
   Development" certificate, which cannot be notarized with — a paid Apple
   Developer account is what makes the Developer ID kind available.

2. An App Store Connect credential, stored under a profile name so no password
   is ever typed into a script:

   ```sh
   xcrun notarytool store-credentials FolderVideoPlayer \
       --apple-id you@example.com --team-id YOURTEAMID
   ```

   It asks for an app-specific password from
   appleid.apple.com → Sign-In and Security. It goes into your keychain and
   Apple's own tool is the only thing that reads it.

Without the certificate, `Tools/release.sh` says so and stops rather than
quietly shipping something that will warn.

Two rough edges Apple's tooling has, both handled: `notarytool` exits 0 for a
submission Apple *rejected*, so the status is read and the run stops there
with Apple's own reasons rather than limping on to a stapler error that
explains nothing. And a submission is accepted slightly before its ticket can
be fetched, so stapling retries instead of failing seconds from the finish
line with all the slow work already done.

### What the script does that a plain codesign does not

- Signs **inside out**, all eighty-odd bundled Python extension modules before
  the app itself. Sign the app first and every nested binary you sign
  afterwards invalidates the signature you just made. (`--deep` does this in
  one go but is deprecated, and applies the app's entitlements to everything
  inside it.)
- Applies the **hardened runtime** and a secure timestamp, both of which
  notarization requires and neither of which works with ad-hoc signing.
- Carries `Tools/entitlements.plist`, which permits loading the bundled
  Python's own extension modules. The hardened runtime otherwise refuses to
  load a library signed by anyone but this app's team, and Python loads those
  at runtime by design.
- Notarizes and staples the **app** before building the DMG, as well as the
  DMG itself. Staple only the DMG and the app works right up until somebody
  drags it out onto a Mac that happens to be offline.

Re-sign after changing anything inside the bundle or macOS will refuse to
launch it. The script always does.

## Duplicates

Its own menu, because finding duplicates has nothing to do with labelling.

Two ways to find the same video twice, both feeding one list. Nothing is ever
deleted — copies go to the Trash, and tags on a discarded copy move to the one
you keep first, because a file can be dragged back out of the Trash and an
afternoon of labelling cannot.

**Tags → Find Duplicates…** sweeps folders you choose. **Notice Duplicates
While Playing** does it without a scan: every video you play is fingerprinted
as it opens, and the index builds up as you watch.

### Why it is a cascade and not a hash of everything

Hashing every file to group by hash is the obvious design. Measured on a real
library on a NAS, it means moving about four terabytes over SMB. So each stage
only pays for what the last one could not rule out:

| | what it costs | what it removes |
|---|---|---|
| **Sizes** | free, arrives with the listing | four files in five |
| **Both ends** | 128 KB and 0.227s per file | everything but real candidates |
| **The whole file** | seconds, on a handful | any doubt before deleting |

Measured on 17,265 videos: only **21.8%** share a size with anything else, and
a file whose size is unique cannot be a byte-for-byte duplicate of anything.
Fingerprinting just those takes about 14 minutes where fingerprinting
everything takes 65.

The fingerprint is the size plus the first and last 64 KB, so a 400 MB file
costs exactly what a 4 MB one does. It is deliberately blind to a difference
in the middle of a file, which is what verifying in full is for, and why that
is on by default.

Filenames are not a signal. In that same library 4,335 files share a name with
something of a different size — more name collisions than size collisions.

### Choosing what to keep

Tags first, then the oldest, then the shortest path — and the reason is shown
on the row, because a suggestion you cannot interrogate is one you cannot
trust. Tags win because they are the only part of a video that is your work
rather than the file's.

The file currently playing is never touched. Where a volume will not accept a
Trash, the app says so rather than deleting.

### What it will not catch

Byte-identical files only. The same video re-encoded, at another quality, or
with different metadata will not match — not on size, not on fingerprint.
Finding those means comparing what frames look like rather than what bytes
say, which is a different and much slower thing.

## Repository layout

| | |
|---|---|
| `player.py` | the whole application |
| `setup.py` | py2app build recipe |
| `icon.icns` | app icon |
| `Readme.txt` | full end-user documentation, shipped inside the DMG |
| `Tools/release.sh` | build, sign, notarize, staple, package |
| `Tools/entitlements.plist` | hardened-runtime entitlements |
