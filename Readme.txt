===============================================================================
 FOLDERVIDEOPLAYER — a native macOS media player with autoplay and favorites
===============================================================================

Pick a folder, and every video in it plays back to back in a real player
window. When the last one ends it loops around to the first and keeps going.
Star the ones you like, and they build up into a favorites list that plays
the same way — all the way through, then repeat — no matter which folders
the files came from.

This is a genuine Cocoa app built on AVKit/AVFoundation. Video decoding is
hardware accelerated, and the transport controls, fullscreen and
Picture-in-Picture are the real system ones. No browser and no web server
are involved.


-------------------------------------------------------------------------------
 QUICK START
-------------------------------------------------------------------------------

  1. Double-click "FolderVideoPlayer.app"

  2. A dialog asks what you want to play:

         Resume Holiday     carry on from the folder, video and moment
                            you last quit on — press Return to take it
         Choose Folder…     pick any folder and start playing it
         Favorites (28)     play everything you've starred
         Quit

     "Resume" only appears once you have played something; the first time
     you open the app, it isn't there.

  3. That's it — playback starts on its own and never stops.

  To switch to a different folder, or over to your favorites, click
  "Open New…" in the bottom bar (or press Cmd+N). That brings this same
  menu back without restarting the app — this time with a Cancel button, so
  changing your mind leaves whatever is playing alone.

  To quit: Cmd+Q, or close the window.

  You can drag "FolderVideoPlayer.app" to your Applications folder or keep it in
  the Dock, like any other app. Everything it needs is inside the app.


-------------------------------------------------------------------------------
 CONTROLS
-------------------------------------------------------------------------------

  The bar along the bottom of the window has "◀ Previous", "Next ▶",
  "☆ Favorite", "Tag", "Open New…" and "Playlist" buttons. Everything they do is
  also available from the keyboard:

  Left / Right arrow .......... skip back / forward 15 seconds
  Cmd + Right ................. next video
  Cmd + Left .................. previous video
  Cmd + Shift + D ............. add / remove the current video as a favorite
  Cmd + L ..................... show / hide the playlist
  Cmd + N ..................... back to the opening menu (Open New)
  Cmd + O ..................... open a different folder directly
  File > Open Recent .......... reopen one of the last eight folders
  Cmd + T ..................... tag the current video, or a selection
  Playback menu ............... repeat / shuffle, and playback speed
  Tags menu ................... tag, filter and play by keyword
  Cmd + Shift + F ............. switch to playing your favorites
  Ctrl + Cmd + F .............. fullscreen
  Cmd + Q ..................... quit

  Space bar plays and pauses. The floating on-screen controls give you a
  scrubber, volume, fullscreen and Picture-in-Picture — these are the
  standard macOS video controls, so they behave exactly as you'd expect.

  The window title shows the current filename, your position in the
  playlist (e.g. "14 of 455"), whether you're playing a folder or a tag,
  and a ★ if the current video is a favorite.


-------------------------------------------------------------------------------
 THE PLAYLIST
-------------------------------------------------------------------------------

  Click "Playlist" in the bottom bar, or press Cmd+L, and a list slides in
  from the right showing every file in whatever you're playing — the whole
  folder, or your whole favorites list.

    - The video playing right now is highlighted.
    - Click any row to jump straight to that video.
    - With the list open, the up and down arrow keys walk through it and
      play whatever you land on, so you can browse straight from the
      keyboard.
    - The highlight follows along on its own as playback moves from one
      video to the next, and the list scrolls to keep it in view.
    - A ★ on a row means that video is one of your favorites.
    - A tagged video shows its tags as small chips under its name. Only
      tagged rows take the extra line, so an untagged folder looks exactly
      as it always did.
    - The running time sits on the right of each row. These are measured in
      the background when the folder opens, so a big folder shows up
      straight away and fills in its times a moment later.
    - Videos in subfolders sit under a heading naming the subfolder. When
      playing a tag the heading names the folder each file came from,
      which is often the only way to tell two same-named files apart.

  The box at the top filters the list as you type — useful when a folder
  runs to hundreds of files. It matches on the filename, and headings with
  nothing left underneath them disappear along with their files. Clear the
  box to get everything back.

  Click "Hide List" or press Cmd+L again to slide it away. The list sits on
  top of the video, so hiding it gives you the full picture back.


-------------------------------------------------------------------------------
 ORDER AND SPEED
-------------------------------------------------------------------------------

  The Playback menu decides what happens when a video ends:

      Repeat All .... the whole folder in order, then round again. This is
                      the default, and how the player has always behaved.
      Repeat One .... the current video over and over
      Shuffle ....... a random order
      Play Once ..... stop after the last video

  Shuffle deals the whole folder into a shuffled order rather than picking a
  video at random each time. That means everything gets played before
  anything comes round a second time — which is what people usually want and
  almost never what picking at random gives you. When a pass finishes it
  deals again, and never opens the new pass with the video that just ended
  the last one. Next and Previous follow the shuffled order too.

  Playback > Speed runs from 0.5× up to 2×, which is what you want for a
  recorded talk or lecture. macOS resets playback to normal speed every time
  it resumes, so the player quietly puts your choice back: it survives
  changing video, pausing, and the floating on-screen controls.

  Both settings are remembered. Whenever either is set to something other
  than the plain default, the window title says so, so a folder playing out
  of order or sounding odd is never a mystery.


-------------------------------------------------------------------------------
 TAGS AND KEYWORDS
-------------------------------------------------------------------------------

  Favorites answer "do I like this?". Tags answer "what is this?" — label a
  video with any keywords you like, as many as you like, and find it again
  later without remembering which folder it lives in.

  TAGGING

  Click "Tag" in the bottom bar, or press Cmd+T, while something is playing.
  A panel slides up out of the bar with a field for your keywords.

  The video pauses while the panel is open, and carries on from the same spot
  when you close it — so the thing you're looking at is always the thing
  you're labelling. If it was already paused, it stays paused.

  Everything else keeps working while the panel is up: the playlist, the
  transport controls, the menus. It doesn't lock the app the way a normal
  dialog does.

  Tags in that field are chips rather than plain text. Type a word and press
  comma or return and it becomes a chip with its own little x; as you type,
  it offers tags you've used before, so you pick the existing one instead of
  typing a near-miss. Spaces inside a tag are fine — "summer 2026" is one
  tag. Capitalisation doesn't matter for matching, so "Beach" and "beach"
  are the same tag.

  Underneath the field sit the tags you use most, as buttons. Clicking one
  drops it straight into the field, no typing at all. This is the easiest
  way to keep a set of tags tidy — every time you click rather than type,
  you can't accidentally invent "holidays" alongside "holiday".

  The field shows what the video already has, and what's in it is what the
  video ends up with. Click a chip's x to remove that tag; empty the field
  to remove them all.

  To tag a batch, open the playlist (Cmd+L), click the first video, then
  shift-click or Cmd-click the others, and press Cmd+T. This case *adds*
  the tags you type to whatever each video already has — it never replaces,
  because that would quietly wipe tags the other videos had and the one you
  were looking at didn't. Selecting a range doesn't disturb what's playing;
  only clicking a single row jumps to it.

  Quickest of all: the Tags menu lists every tag you've ever used, with a
  tick beside the ones the playing video carries. Clicking one adds or
  removes it there and then, no typing.

  FINDING THINGS AGAIN

  Tags > Play Tag plays everything carrying a tag, from every folder, as one
  looping queue — exactly the way Favorites plays. The number beside each
  name is how many videos carry it.

  The filter box at the top of the playlist searches tags as well as
  filenames, so typing "beach" finds videos named beach-something *and*
  videos tagged beach.

  MANAGING TAGS

  Tags > Manage Tags… lists every tag and how many videos carry it.

    - Rename… changes it on every video at once. Renaming a tag onto one
      that already exists merges them, which is the easy way to fix
      "holiday" and "holidays" having drifted apart.

    - Delete removes the tag from every video. The videos are untouched.

    - Tags are stored against the video's full path, so renaming or moving
      a video leaves its tags pointing at nothing. Those show up in red as
      "missing", and "Clear Missing (n)" tidies them away.

  As with favorites, clearing missing tags is something you have to ask for
  and never happens on its own — an unmounted drive makes every file on it
  look deleted, and tidying up at that moment would throw away tags that are
  perfectly fine.

  Tags live in this file, well away from the app:

      ~/Library/Application Support/FolderVideoPlayer/tags.json


-------------------------------------------------------------------------------
 UPDATING
-------------------------------------------------------------------------------

  FolderVideoPlayer > Check for Updates... asks GitHub whether a newer
  release exists.

  If there is one, you're told what version it is and asked whether to
  install it. Say yes and the app downloads the new disk image, quits,
  swaps itself for the new copy and reopens. You don't have to do anything
  else, and your favorites are untouched.

  Nothing is downloaded or changed unless you agree to it, and the check
  only happens when you ask for it — the app never phones home on its own.

  If GitHub can't be reached, or the release has no disk image, you're
  offered the releases page in your browser instead.


-------------------------------------------------------------------------------
 WHICH VIDEOS PLAY
-------------------------------------------------------------------------------

  .mp4  .m4v  .mov

  That is what AVFoundation, the macOS media engine, can decode. .mkv,
  .avi and .webm are not supported — for those, VLC remains the better
  tool.

  Subfolders are included automatically, as deep as they go. Files from the
  same subfolder stay grouped together, and numbered filenames sort the way
  you'd expect (clip2 before clip10, not after it). Hidden files — anything
  starting with a dot, including macOS "._" junk files — are ignored.

  A file that won't play is skipped and playback carries on. Only if every
  file in the list fails does the player stop and tell you why.


-------------------------------------------------------------------------------
 IF VIDEOS ON YOUR NAS OR AN EXTERNAL DRIVE WON'T PLAY
-------------------------------------------------------------------------------

  macOS blocks apps from reading network and external drives until you say
  otherwise. If your videos live on a NAS, a mounted SMB share or an
  external disk and nothing plays, this is why.

  macOS may prompt you the first time, in which case just click OK. If it
  doesn't, grant access by hand — this is a one-time thing:

      1. Open System Settings
      2. Go to Privacy & Security > Full Disk Access
      3. Click the + button
      4. Select "FolderVideoPlayer.app" and add it
      5. Make sure its switch is turned ON
      6. Quit the player and open it again

  The player detects this specific problem and says so, rather than
  silently skipping every file.

  Videos on your Mac's own internal disk are unaffected and need no setup.

  A note on why: this app is not signed by a registered Apple developer,
  because that requires a paid Apple account. macOS therefore gives it no
  disk access of its own. Adding it to Full Disk Access is you overriding
  that.


-------------------------------------------------------------------------------
 REQUIREMENTS
-------------------------------------------------------------------------------

  macOS 10.15 or later. Nothing else.

  The app is fully self-contained: it carries its own copy of Python and
  every library it needs inside the bundle. Python does NOT have to be
  installed on the Mac running it. It is a universal build, so it runs
  natively on both Apple Silicon and Intel Macs.


-------------------------------------------------------------------------------
 GIVING IT TO SOMEONE ELSE
-------------------------------------------------------------------------------

  Send them "FolderVideoPlayer.dmg". They open it and drag FolderVideoPlayer across
  to the Applications shortcut in the same window. That's the whole
  install.

  IMPORTANT — the first launch on their Mac will be blocked.

  The app is signed, but only with an ad-hoc signature, not with a paid
  Apple Developer ID. macOS therefore refuses to open it the first time,
  with a message like "Apple could not verify FolderVideoPlayer is free of
  malware". This is expected and says nothing about the app. To get past
  it, once:

      1. Try to open the app normally, and dismiss the warning
      2. Open System Settings > Privacy & Security
      3. Scroll down — there'll be a line about FolderVideoPlayer being blocked
      4. Click "Open Anyway"

  On older versions of macOS, right-clicking the app and choosing Open is
  usually enough.

  Anyone comfortable in Terminal can skip all of that by running:

      xattr -d com.apple.quarantine "/Applications/FolderVideoPlayer.app"

  Paying for an Apple Developer ID and notarizing the app is the only way
  to remove this step for good.

  Note that favorites are per-Mac. Whoever you send it to starts with an
  empty list; yours stays on your machine.


-------------------------------------------------------------------------------
 REBUILDING THE APP AND THE DMG
-------------------------------------------------------------------------------

  Only needed if you change player.py.

  Building requires Python 3.12 from python.org installed at
  /Library/Frameworks (the build copies it into the app; the finished app
  no longer needs it). Then:

      python3 -m venv venv
      ./venv/bin/pip install py2app pyobjc-framework-AVKit \
                             pyobjc-framework-AVFoundation
      ./venv/bin/python setup.py py2app
      codesign --force --deep --sign - "dist/FolderVideoPlayer.app"

  The finished app lands in dist/. To wrap it back into a DMG, put the app,
  Readme.txt and a symlink to /Applications into one folder and run:

      hdiutil create -volname "FolderVideoPlayer" -srcfolder <that folder> \
                     -ov -format UDZO -fs HFS+ "FolderVideoPlayer.dmg"

  Always re-sign after changing anything inside the bundle, or macOS will
  refuse to launch it.


-------------------------------------------------------------------------------
 FILES IN THIS FOLDER
-------------------------------------------------------------------------------

  FolderVideoPlayer.app ........ the app. This is the one you want.
  FolderVideoPlayer.dmg ........ the same app, packaged to give to other people
  Readme.txt .............. this file
  player.py ............... the app's source code
  setup.py ................ the recipe that builds the app from that source

  icon.icns ............... the app icon, used when building

  favorites.json .......... older copies of your favorites, superseded by
  favorites.json.backup ... the live one in Application Support. Both are
                            just backups; deleting them is safe.


-------------------------------------------------------------------------------
 PRIVACY
-------------------------------------------------------------------------------

  Your videos never leave this Mac. Nothing is uploaded, and nothing
  listens on any port. The app only ever reads the folders you point it at
  and the files in your favorites list.

  The one time it uses the network is when you click Check for Updates: it
  asks GitHub for the latest release, and downloads it only if you agree.
  It never does this on its own.

  It does keep a record on this Mac of what you have watched: the paths of
  recently played folders and how far into recent videos you got, in

      ~/Library/Application Support/FolderVideoPlayer/state.json

  Quit the player and delete that file to clear the lot; the app makes a
  fresh one next time and simply won't offer to resume anything. Any tags
  you have typed live beside it in tags.json, and go the same way.

===============================================================================
