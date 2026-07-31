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

         Choose Folder…     pick any folder and start playing it
         Favorites (28)     play everything you've starred
         Quit

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
  "☆ Favorite", "Open New…" and "Playlist" buttons. Everything they do is
  also available from the keyboard:

  Left / Right arrow .......... skip back / forward 15 seconds
  Cmd + Right ................. next video
  Cmd + Left .................. previous video
  Cmd + Shift + D ............. add / remove the current video as a favorite
  Cmd + L ..................... show / hide the playlist
  Cmd + N ..................... back to the opening menu (Open New)
  Cmd + O ..................... open a different folder directly
  Cmd + Shift + F ............. switch to playing your favorites
  Ctrl + Cmd + F .............. fullscreen
  Cmd + Q ..................... quit

  Space bar plays and pauses. The floating on-screen controls give you a
  scrubber, volume, fullscreen and Picture-in-Picture — these are the
  standard macOS video controls, so they behave exactly as you'd expect.

  The window title shows the current filename, your position in the
  playlist (e.g. "14 of 455"), whether you're in Folder or Favorites mode,
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

  Click "Hide List" or press Cmd+L again to slide it away. The list sits on
  top of the video, so hiding it gives you the full picture back.


-------------------------------------------------------------------------------
 FAVORITES
-------------------------------------------------------------------------------

  Click the "☆ Favorite" button in the bottom bar, or press Cmd+Shift+D,
  while any video is playing. The star fills in (★ Favorite), a ★ appears in the
  window title, and the Playback menu switches to "Remove from Favorites".
  The star shows you at a glance whether whatever is playing right now is
  already a favorite.

  To play them, press Cmd+Shift+F, or click "Open New…" and pick Favorites.
  Favorites behave exactly like a folder: they play in order, and after the
  last one they loop back to the first.

  Things worth knowing:

    - Favorites can come from as many different folders as you like. They
      all land in one flat playlist.

    - The list is permanent. It survives quitting the app, restarting your
      Mac, and even replacing the app with a newer copy — because it's
      stored outside the app, here:

          ~/Library/Application Support/FolderVideoPlayer/favorites.json

    - Clicking ★ Favorite (or Cmd+Shift+D) on a video you've already
      favorited removes it. If you do that while it's the one currently
      playing in Favorites mode, it drops out of the queue and the next one
      starts immediately.

    - Favorites are stored as full file paths. If you later move or rename
      a favorited video, that entry can't be found any more — it's quietly
      skipped instead of stalling the playlist. Delete and re-add it if you
      want it back.

    - To wipe all favorites, quit the player and delete the favorites.json
      file at the path above.


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

  Everything below is the earlier browser-based version, kept only as a
  fallback. It works, but it plays video in a browser tab rather than in a
  real window. It shares the same favorites list as the app. Safe to delete
  if you don't want it:

      Video Player.command .... launcher (opens a Terminal window that must
                                stay open while watching)
      serve.py ................ the local server it runs
      app.html ................ the web interface it serves
      player.html ............. the original standalone page, no favorites

  favorites.json .......... your favorites in their original location, now
  favorites.json.backup ... superseded by the copy in Application Support.
                            Both are backups; deleting them is safe.


-------------------------------------------------------------------------------
 PRIVACY
-------------------------------------------------------------------------------

  Everything happens on this Mac. Nothing is uploaded, no network
  connection is made, and — unlike the older browser version — nothing
  listens on any port. The app only ever reads the folders you point it at
  and the files in your favorites list.

===============================================================================
