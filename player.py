#!/usr/bin/env python3
"""FolderVideoPlayer — a native macOS media player.

Plays every video in a folder back to back, loops at the end, and keeps a
persistent favorites list that plays the same way.

Built on AVKit/AVFoundation, so playback is hardware accelerated and the
transport controls, fullscreen and Picture-in-Picture are the real system
ones.
"""

import json
import os
import re
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.request

try:
    import certifi                  # bundled; python.org builds have no system CA file
except ImportError:
    certifi = None

import objc
from AVFoundation import (
    AVPlayer,
    AVPlayerItem,
    AVPlayerItemDidPlayToEndTimeNotification,
)
from AVKit import AVPlayerView
from CoreMedia import CMTimeGetSeconds, CMTimeMakeWithSeconds, kCMTimeZero
from Cocoa import (
    NSAlert,
    NSAnimationContext,
    NSApplication,
    NSAutoreleasePool,
    NSBundle,
    NSApplicationActivationPolicyRegular,
    NSBackingStoreBuffered,
    NSBezelStyleRounded,
    NSButton,
    NSIndexSet,
    NSEventModifierFlagCommand,
    NSEventModifierFlagControl,
    NSEventModifierFlagShift,
    NSMakeRect,
    NSMakeSize,
    NSImage,
    NSMenu,
    NSMenuItem,
    NSNotificationCenter,
    NSObject,
    NSOpenPanel,
    NSScrollView,
    NSTableColumn,
    NSTableView,
    NSTimer,
    NSURL,
    NSView,
    NSViewHeightSizable,
    NSViewMaxYMargin,
    NSViewMinXMargin,
    NSViewWidthSizable,
    NSVisualEffectView,
    NSWorkspace,
    NSWindow,
    NSWindowCollectionBehaviorFullScreenPrimary,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
)
from PyObjCTools import AppHelper

APP_NAME = "FolderVideoPlayer"

REPO = "tangrick/FolderVideoPlayer"
API_LATEST = "https://api.github.com/repos/%s/releases/latest" % REPO
RELEASES_PAGE = "https://github.com/%s/releases/latest" % REPO

SUPPORT = os.path.expanduser("~/Library/Application Support/" + APP_NAME)
FAV_FILE = os.path.join(SUPPORT, "favorites.json")
STATE_FILE = os.path.join(SUPPORT, "state.json")

# What AVFoundation can actually decode. .mkv and .avi are deliberately absent.
VIDEO_EXT = {".mp4", ".m4v", ".mov"}

SKIP_SECONDS = 15

PROGRESS_TICK = 5.0           # seconds between samples of the playhead
PROGRESS_FLUSH = 6            # ...and samples between writes to disk
RESUME_MIN = 30               # a video barely started just starts over
RESUME_TAIL = 30              # ...and so does one that was all but finished
RECENT_MAX = 8
PROGRESS_MAX = 500            # newest positions win; older ones age out

CONTROLS_FLOATING = 1
BAR_HEIGHT = 48
BUTTON_W, BUTTON_H = 116, 30
SIDEBAR_W = 320
SIDEBAR_SLIDE = 0.22          # seconds

VIBRANCY_SIDEBAR = 7          # NSVisualEffectMaterialSidebar
VIBRANCY_ACTIVE = 0           # NSVisualEffectStateFollowsWindowActiveState
STATUS_READY, STATUS_FAILED = 1, 2
NS_OK = 1
FIRST_BUTTON = 1000

RIGHT_ARROW = chr(0xF703)
LEFT_ARROW = chr(0xF702)


@objc.python_method
def natural_key(s):
    # digit runs compare numerically, so clip2 sorts before clip10
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", s)]


@objc.python_method
def scan(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted((d for d in dirnames if not d.startswith(".")), key=natural_key)
        for name in filenames:
            if name.startswith("."):
                continue
            if os.path.splitext(name)[1].lower() in VIDEO_EXT:
                found.append(os.path.join(dirpath, name))
    found.sort(key=lambda p: natural_key(os.path.relpath(p, root)))
    return found


@objc.python_method
def load_json(path, fallback):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return fallback
    # A file hand-edited into the wrong shape must not take the app down
    return data if isinstance(data, type(fallback)) else fallback


@objc.python_method
def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)         # never leave a half-written file


class AppDelegate(NSObject):

    # -- lifecycle -------------------------------------------------------

    def applicationDidFinishLaunching_(self, notification):
        self.playlist = []
        self.index = 0
        self.mode = "folder"
        self.root = None
        self.item = None
        self.itemPath = None
        self.failures = 0
        self.pendingResume = 0
        self.ticks = 0
        self.favorites = self.loadFavorites()
        self.loadState()

        self.setDockIcon()
        self.buildMenu()
        self.buildWindow()
        self.updateUI()
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            PROGRESS_TICK, self, "recordProgress:", None, True)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self.performSelector_withObject_afterDelay_("showOpeningChoice", None, 0.1)

    def applicationShouldTerminateAfterLastWindowClosed_(self, sender):
        return True

    def applicationWillTerminate_(self, notification):
        self.notePosition()
        self.saveState()
        self.timer.invalidate()
        self.detachItem()

    @objc.python_method
    def setDockIcon(self):
        # The bundle launches through a shell wrapper, so the interpreter does
        # not reliably inherit the bundle's icon. Set it explicitly.
        icon = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon.icns")
        if not os.path.exists(icon):
            return
        image = NSImage.alloc().initWithContentsOfFile_(icon)
        if image is not None:
            NSApplication.sharedApplication().setApplicationIconImage_(image)

    # -- favorites -------------------------------------------------------

    @objc.python_method
    def loadFavorites(self):
        return load_json(FAV_FILE, [])

    @objc.python_method
    def saveFavorites(self):
        save_json(FAV_FILE, self.favorites)

    # -- resume positions, recent folders, last session ------------------

    @objc.python_method
    def loadState(self):
        """Everything the app remembers between launches, bar favorites.

        Nothing here is checked against the filesystem on the way in: a folder
        on an unmounted NAS would stat slowly, or hang, and that would show up
        as a stall on every launch. Dead entries are dropped when something
        actually tries to use them.
        """
        state = load_json(STATE_FILE, {})
        try:
            self.recent = [p for p in state.get("recent", []) if isinstance(p, str)]
            self.progress = {p: t for p, t in state.get("progress", {}).items()
                             if isinstance(t, (int, float))}
            session = state.get("session") or {}
            self.session = session if isinstance(session, dict) else {}
        except (AttributeError, TypeError):
            # A file this badly mangled is not worth salvaging, but it must not
            # stop the app launching — there would be no way back from that.
            self.recent, self.progress, self.session = [], {}, {}

    @objc.python_method
    def saveState(self):
        path = self.currentPath()
        session = {"mode": self.mode, "root": self.root, "path": path} if path else {}
        save_json(STATE_FILE, {
            "recent": self.recent[:RECENT_MAX],
            # dicts keep insertion order, and notePosition re-inserts, so the
            # tail of this is exactly the most recently watched
            "progress": dict(list(self.progress.items())[-PROGRESS_MAX:]),
            "session": session,
        })

    @objc.python_method
    def currentPath(self):
        return self.playlist[self.index] if self.playlist else None

    def toggleFavorite_(self, sender):
        path = self.currentPath()
        if not path:
            return
        if path in self.favorites:
            self.favorites.remove(path)
            # in favorites mode the list IS the queue, so drop it from playback
            if self.mode == "favorites" and len(self.playlist) > 1:
                del self.playlist[self.index]
                if self.index >= len(self.playlist):
                    self.index = 0
                self.saveFavorites()
                self.table.reloadData()
                return self.playIndex(self.index)
        else:
            self.favorites.append(path)
        self.saveFavorites()
        self.updateUI()

    # -- building the UI -------------------------------------------------

    @objc.python_method
    def menu(self, parent, title):
        holder = NSMenuItem.alloc().init()
        # Menu bar items take their name from the submenu, but a nested one is
        # labelled by the item that holds it, so both need setting.
        holder.setTitle_(title)
        parent.addItem_(holder)
        sub = NSMenu.alloc().initWithTitle_(title)
        holder.setSubmenu_(sub)
        return sub

    @objc.python_method
    def add(self, menu, title, action, key="", mask=None):
        item = menu.addItemWithTitle_action_keyEquivalent_(title, action, key)
        if mask is not None:
            item.setKeyEquivalentModifierMask_(mask)
        item.setTarget_(self)
        return item

    @objc.python_method
    def buildMenu(self):
        bar = NSMenu.alloc().init()

        app = self.menu(bar, APP_NAME)
        about = app.addItemWithTitle_action_keyEquivalent_(
            "About " + APP_NAME, "orderFrontStandardAboutPanel:", "")
        about.setTarget_(None)
        app.addItem_(NSMenuItem.separatorItem())
        self.add(app, "Check for Updates…", "checkForUpdates:")
        app.addItem_(NSMenuItem.separatorItem())
        app.addItemWithTitle_action_keyEquivalent_("Hide " + APP_NAME, "hide:", "h")
        app.addItem_(NSMenuItem.separatorItem())
        app.addItemWithTitle_action_keyEquivalent_("Quit " + APP_NAME, "terminate:", "q")

        files = self.menu(bar, "File")
        self.add(files, "Open New…", "openNew:", "n", NSEventModifierFlagCommand)
        files.addItem_(NSMenuItem.separatorItem())
        self.add(files, "Open Folder…", "chooseFolder:", "o", NSEventModifierFlagCommand)
        self.recentMenu = self.menu(files, "Open Recent")
        self.rebuildRecentMenu()
        self.add(files, "Play Favorites", "playFavorites:", "f",
                 NSEventModifierFlagCommand | NSEventModifierFlagShift)

        play = self.menu(bar, "Playback")
        # Bare arrows scrub within the video; add Command to change video.
        self.add(play, "Skip Back %d Seconds" % SKIP_SECONDS, "skipBack:", LEFT_ARROW, 0)
        self.add(play, "Skip Forward %d Seconds" % SKIP_SECONDS, "skipForward:", RIGHT_ARROW, 0)
        play.addItem_(NSMenuItem.separatorItem())
        self.add(play, "Next Video", "nextItem:", RIGHT_ARROW, NSEventModifierFlagCommand)
        self.add(play, "Previous Video", "prevItem:", LEFT_ARROW, NSEventModifierFlagCommand)
        play.addItem_(NSMenuItem.separatorItem())
        # Shift is deliberate: plain Cmd+D is claimed by the system in several
        # contexts, so the app never reliably received it.
        self.favItem = self.add(play, "Add to Favorites", "toggleFavorite:", "d",
                                NSEventModifierFlagCommand | NSEventModifierFlagShift)

        view = self.menu(bar, "View")
        self.listItem = self.add(view, "Show Playlist", "togglePlaylist:", "l",
                                 NSEventModifierFlagCommand)

        window = self.menu(bar, "Window")
        window.addItemWithTitle_action_keyEquivalent_("Minimize", "performMiniaturize:", "m")
        # ⌃⌘F is the system-standard fullscreen shortcut; ⌘⇧F is Play Favorites
        window.addItemWithTitle_action_keyEquivalent_(
            "Enter Full Screen", "toggleFullScreen:", "f").setKeyEquivalentModifierMask_(
                NSEventModifierFlagCommand | NSEventModifierFlagControl)

        NSApplication.sharedApplication().setMainMenu_(bar)

    @objc.python_method
    def barButton(self, title, action, x):
        button = NSButton.alloc().initWithFrame_(
            NSMakeRect(x, (BAR_HEIGHT - BUTTON_H) / 2, BUTTON_W, BUTTON_H))
        button.setTitle_(title)
        button.setBezelStyle_(NSBezelStyleRounded)
        button.setTarget_(self)
        button.setAction_(action)
        return button

    @objc.python_method
    def buildWindow(self):
        rect = NSMakeRect(0, 0, 1100, 700)
        style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                 | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, style, NSBackingStoreBuffered, False)
        self.window.setCollectionBehavior_(NSWindowCollectionBehaviorFullScreenPrimary)
        self.window.setFrameAutosaveName_("VideoPlayerWindow")
        # narrow enough and the left-hand buttons would run into the right-hand pair
        self.window.setMinSize_(NSMakeSize(680, 380))
        self.window.center()

        content = NSView.alloc().initWithFrame_(rect)

        # Video fills everything above the control bar and grows with the window.
        self.playerView = AVPlayerView.alloc().initWithFrame_(
            NSMakeRect(0, BAR_HEIGHT, rect.size.width, rect.size.height - BAR_HEIGHT))
        self.playerView.setControlsStyle_(CONTROLS_FLOATING)
        self.playerView.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        self.playerView.setVideoGravity_("AVLayerVideoGravityResizeAspect")

        self.player = AVPlayer.alloc().init()
        self.playerView.setPlayer_(self.player)
        content.addSubview_(self.playerView)

        # Control bar pinned to the bottom, stretching only horizontally. It sits
        # below the video so it never collides with the floating AVKit controls.
        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, rect.size.width, BAR_HEIGHT))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        self.prevButton = self.barButton("◀  Previous", "prevItem:", 14)
        self.nextButton = self.barButton("Next  ▶", "nextItem:", 14 + BUTTON_W + 8)
        self.favButton = self.barButton("☆  Favorite", "toggleFavorite:",
                                        14 + 2 * (BUTTON_W + 8))
        bar.addSubview_(self.prevButton)
        bar.addSubview_(self.nextButton)
        bar.addSubview_(self.favButton)

        # right-hand group, both pinned to the right edge
        self.openButton = self.barButton(
            "Open New…", "openNew:", rect.size.width - 2 * BUTTON_W - 22)
        self.openButton.setAutoresizingMask_(NSViewMinXMargin)
        self.listButton = self.barButton(
            "Playlist", "togglePlaylist:", rect.size.width - BUTTON_W - 14)
        self.listButton.setAutoresizingMask_(NSViewMinXMargin)
        bar.addSubview_(self.openButton)
        bar.addSubview_(self.listButton)
        content.addSubview_(bar)

        self.buildSidebar(content, rect)

        self.window.setContentView_(content)
        self.window.setDelegate_(self)
        self.window.makeFirstResponder_(self.playerView)
        self.window.makeKeyAndOrderFront_(None)

    @objc.python_method
    def buildSidebar(self, content, rect):
        """A drawer that slides in over the right edge of the video."""
        self.sidebarOpen = False
        height = rect.size.height - BAR_HEIGHT

        self.sidebar = NSVisualEffectView.alloc().initWithFrame_(
            NSMakeRect(rect.size.width, BAR_HEIGHT, SIDEBAR_W, height))
        self.sidebar.setMaterial_(VIBRANCY_SIDEBAR)
        self.sidebar.setState_(VIBRANCY_ACTIVE)
        self.sidebar.setAutoresizingMask_(NSViewHeightSizable | NSViewMinXMargin)

        self.table = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, SIDEBAR_W, height))
        column = NSTableColumn.alloc().initWithIdentifier_("name")
        column.setWidth_(SIDEBAR_W - 24)
        self.table.addTableColumn_(column)
        self.table.setHeaderView_(None)
        self.table.setRowHeight_(24)
        self.table.setUsesAlternatingRowBackgroundColors_(True)
        self.table.setDataSource_(self)
        # Selection drives playback, so clicking and arrowing behave identically.
        self.table.setDelegate_(self)
        self.syncing = False

        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, 0, SIDEBAR_W, height))
        scroll.setDocumentView_(self.table)
        scroll.setHasVerticalScroller_(True)
        scroll.setDrawsBackground_(False)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)

        self.sidebar.addSubview_(scroll)
        content.addSubview_(self.sidebar)

    # -- the playlist drawer ---------------------------------------------

    @objc.python_method
    def sidebarFrame(self):
        content = self.window.contentView().frame()
        x = content.size.width - (SIDEBAR_W if self.sidebarOpen else 0)
        return NSMakeRect(x, BAR_HEIGHT, SIDEBAR_W, content.size.height - BAR_HEIGHT)

    def togglePlaylist_(self, sender):
        self.sidebarOpen = not self.sidebarOpen
        self.listButton.setTitle_("Hide List" if self.sidebarOpen else "Playlist")
        self.listItem.setTitle_("Hide Playlist" if self.sidebarOpen else "Show Playlist")

        NSAnimationContext.beginGrouping()
        NSAnimationContext.currentContext().setDuration_(SIDEBAR_SLIDE)
        self.sidebar.animator().setFrame_(self.sidebarFrame())
        NSAnimationContext.endGrouping()
        if self.sidebarOpen:
            self.revealCurrentRow()
            # focus the list so the arrow keys drive it straight away
            self.window.makeFirstResponder_(self.table)
        else:
            self.window.makeFirstResponder_(self.playerView)

    def windowDidResize_(self, notification):
        self.sidebar.setFrame_(self.sidebarFrame())

    def tableViewSelectionDidChange_(self, notification):
        # Ignore selection we set ourselves while following playback, otherwise
        # every track change would re-trigger itself.
        if self.syncing:
            return
        self.jumpToRow(self.table.selectedRow())

    @objc.python_method
    def jumpToRow(self, row):
        if 0 <= row < len(self.playlist) and row != self.index:
            self.playIndex(row)

    # NSTableView data source
    def numberOfRowsInTableView_(self, tableView):
        return len(self.playlist)

    def tableView_objectValueForTableColumn_row_(self, tableView, column, row):
        if 0 <= row < len(self.playlist):
            return os.path.basename(self.playlist[row])
        return ""

    @objc.python_method
    def revealCurrentRow(self):
        if not self.playlist:
            return
        self.syncing = True
        try:
            self.table.selectRowIndexes_byExtendingSelection_(
                NSIndexSet.indexSetWithIndex_(self.index), False)
            self.table.scrollRowToVisible_(self.index)
        finally:
            self.syncing = False

    # -- choosing what to play -------------------------------------------

    def openNew_(self, sender):
        self.showOpeningChoice()

    @objc.python_method
    def rebuildRecentMenu(self):
        self.recentMenu.removeAllItems()
        for path in self.recent:
            # Several folders can share a basename, so the full path is the
            # tooltip rather than the title, which would be unreadably long.
            item = self.add(self.recentMenu, os.path.basename(path) or path, "openRecent:")
            item.setRepresentedObject_(path)
            item.setToolTip_(path)
        if not self.recent:
            # No action means AppKit greys it out for us
            self.recentMenu.addItemWithTitle_action_keyEquivalent_(
                "No Recent Folders", None, "")
            return
        self.recentMenu.addItem_(NSMenuItem.separatorItem())
        self.add(self.recentMenu, "Clear Menu", "clearRecent:")

    @objc.python_method
    def rememberFolder(self, root):
        self.recent = [root] + [p for p in self.recent if p != root]
        del self.recent[RECENT_MAX:]
        self.rebuildRecentMenu()

    @objc.python_method
    def forgetFolder(self, root):
        self.recent = [p for p in self.recent if p != root]
        self.rebuildRecentMenu()
        self.saveState()

    def openRecent_(self, sender):
        self.openFolder(str(sender.representedObject()))

    def clearRecent_(self, sender):
        self.recent = []
        self.rebuildRecentMenu()
        self.saveState()

    @objc.python_method
    def sessionLabel(self):
        """What the last session would be called, or None if it cannot resume."""
        if not self.session.get("path"):
            return None
        if self.session.get("mode") == "favorites":
            return "Favorites" if self.favorites else None
        root = self.session.get("root")
        return (os.path.basename(root) or root) if root else None

    @objc.python_method
    def openingChoices(self):
        """Buttons for the opening dialog, paired with what each one does.

        Neither the resume nor the favorites button always exists, so the
        positions shift; keeping titles and actions together avoids matching
        on button index.
        """
        live = [p for p in self.favorites if os.path.isfile(p)]
        choices = []
        # Only worth offering at startup — mid-playback the last session is
        # whatever is already on screen.
        resume = self.sessionLabel() if not self.playlist else None
        if resume:
            choices.append(("Resume %s" % resume, "resume"))
        choices.append(("Choose Folder…", "folder"))
        if live:
            choices.append(("Favorites (%d)" % len(live), "favorites"))
        # Backing out mid-playback must not kill the app, only at startup.
        choices.append(("Cancel" if self.playlist else "Quit", "dismiss"))
        return choices

    def showOpeningChoice(self):
        playing = bool(self.playlist)

        # At startup there is nothing behind this dialog, so a choice that ends
        # with nothing playing — an empty folder, a drive that isn't mounted,
        # a cancelled file picker — has to ask again rather than leave a dead
        # window. Mid-playback there is always something to fall back to.
        while True:
            alert = NSAlert.alloc().init()
            alert.setMessageText_(APP_NAME)
            alert.setInformativeText_(
                "Choose a folder and every video in it plays in order, then repeats.")

            choices = self.openingChoices()
            for title, _ in choices:
                alert.addButtonWithTitle_(title)

            choice = choices[alert.runModal() - FIRST_BUTTON][1]
            if choice == "resume":
                self.resumeSession()
            elif choice == "folder":
                self.chooseFolder_(None)
            elif choice == "favorites":
                self.playFavorites_(None)
            elif not playing:
                return NSApplication.sharedApplication().terminate_(None)
            else:
                return                    # Cancel, with something already on
            if playing or self.playlist:
                return

    @objc.python_method
    def resumeSession(self):
        """Pick up the folder, the video and the position we left off at."""
        session, self.session = self.session, {}
        # One attempt only: if that folder has gone, the dialog comes back
        # without a Resume button rather than offering it over and over.
        if session.get("mode") == "favorites":
            return self.startFavorites(session.get("path"))
        self.openFolder(session.get("root"), session.get("path"))

    def chooseFolder_(self, sender):
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseFiles_(False)
        panel.setCanChooseDirectories_(True)
        panel.setAllowsMultipleSelection_(False)
        panel.setMessage_("Select a folder of videos")
        panel.setPrompt_("Play")
        if panel.runModal() != NS_OK:
            return
        self.openFolder(panel.URL().path())

    @objc.python_method
    def openFolder(self, root, resume=None):
        root = str(root)
        if not os.path.isdir(root):
            self.forgetFolder(root)
            return self.say("That folder is not available.",
                            "%s could not be opened. It may have been renamed or "
                            "moved, or it may be on a drive that is not mounted "
                            "right now." % root)
        found = scan(root)
        if not found:
            return self.say("No playable videos in that folder.",
                            "Looked for %s files, including subfolders."
                            % ", ".join(sorted(VIDEO_EXT)))
        self.rememberFolder(root)
        self.startPlaylist(found, "folder", root, resume)

    def playFavorites_(self, sender):
        self.startFavorites()

    @objc.python_method
    def startFavorites(self, resume=None):
        live = [p for p in self.favorites if os.path.isfile(p)]
        if not live:
            return self.say("No favorites yet.",
                            "Press ⌘⇧D while a video is playing to add it.")
        self.startPlaylist(live, "favorites", None, resume)

    @objc.python_method
    def startPlaylist(self, items, mode, root=None, resume=None):
        self.playlist = items
        self.mode = mode
        self.root = root
        self.failures = 0
        self.table.reloadData()
        # A folder can change between sessions; falling back to the top is the
        # only sane answer when the video we left off on is gone.
        self.playIndex(items.index(resume) if resume in items else 0)
        self.saveState()

    # -- playback --------------------------------------------------------

    @objc.python_method
    def detachItem(self):
        if self.item is None:
            return
        NSNotificationCenter.defaultCenter().removeObserver_name_object_(
            self, AVPlayerItemDidPlayToEndTimeNotification, self.item)
        try:
            self.item.removeObserver_forKeyPath_(self, "status")
        except Exception:
            pass
        self.item = None

    @objc.python_method
    def playIndex(self, i):
        if not self.playlist:
            return
        self.notePosition()             # the outgoing video keeps its place
        self.index = i % len(self.playlist)
        self.detachItem()

        self.itemPath = self.playlist[self.index]
        self.pendingResume = self.progress.get(self.itemPath, 0)
        url = NSURL.fileURLWithPath_(self.itemPath)
        self.item = AVPlayerItem.playerItemWithURL_(url)
        self.item.addObserver_forKeyPath_options_context_(self, "status", 0, None)
        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "itemDidFinish:", AVPlayerItemDidPlayToEndTimeNotification, self.item)

        self.player.replaceCurrentItemWithPlayerItem_(self.item)
        self.player.play()
        self.updateUI()

    def itemDidFinish_(self, notification):
        self.playIndex(self.index + 1)      # wraps at the end, so it repeats

    def nextItem_(self, sender):
        self.playIndex(self.index + 1)

    def prevItem_(self, sender):
        self.playIndex(self.index - 1)

    def skipBack_(self, sender):
        self.seekBy(-SKIP_SECONDS)

    def skipForward_(self, sender):
        self.seekBy(SKIP_SECONDS)

    @objc.python_method
    def seekBy(self, seconds):
        if self.item is None:
            return
        now = CMTimeGetSeconds(self.player.currentTime())
        if now != now:                      # NaN until the item is ready
            return
        target = max(0.0, now + seconds)
        total = CMTimeGetSeconds(self.item.duration())
        if total == total and total > 0:    # clamp so we never seek past the end
            target = min(target, max(0.0, total - 0.25))
        # Zero tolerance, otherwise the seek snaps to the nearest keyframe and a
        # "15 second" skip can land 20+ seconds away.
        self.player.seekToTime_toleranceBefore_toleranceAfter_(
            CMTimeMakeWithSeconds(target, 600), kCMTimeZero, kCMTimeZero)
        return target

    def observeValueForKeyPath_ofObject_change_context_(self, keyPath, obj, change, ctx):
        # A notification already in flight when we moved on must not be acted on
        if keyPath != "status" or self.item is None or not obj.isEqual_(self.item):
            return
        if obj.status() == STATUS_READY:
            self.failures = 0
            self.applyResume()
        elif obj.status() == STATUS_FAILED:
            self.skipBroken()

    # -- remembering where each video got to -----------------------------

    def recordProgress_(self, timer):
        self.notePosition()
        self.ticks += 1
        # Sampling is cheap, writing is not; a crash costs half a minute at most
        if self.ticks % PROGRESS_FLUSH == 0:
            self.saveState()

    @objc.python_method
    def notePosition(self):
        path = self.itemPath
        if path is None or self.item is None or self.item.status() != STATUS_READY:
            return
        now = CMTimeGetSeconds(self.player.currentTime())
        if now != now:                      # NaN while the item is still loading
            return
        total = CMTimeGetSeconds(self.item.duration())
        finished = total == total and total > 0 and now > total - RESUME_TAIL
        # Only the middle of a video is worth remembering: at either end the
        # right thing to do next time is start from the beginning. Re-inserting
        # rather than assigning keeps the newest entries at the end of the dict,
        # which is what saveState trims against.
        self.progress.pop(path, None)
        if now >= RESUME_MIN and not finished:
            self.progress[path] = round(now, 1)

    @objc.python_method
    def applyResume(self):
        seconds, self.pendingResume = self.pendingResume, 0
        if seconds < RESUME_MIN:
            return
        total = CMTimeGetSeconds(self.item.duration())
        if total == total and total > 0:
            seconds = min(seconds, max(0.0, total - 0.25))
        self.player.seekToTime_toleranceBefore_toleranceAfter_(
            CMTimeMakeWithSeconds(seconds, 600), kCMTimeZero, kCMTimeZero)

    @objc.python_method
    def skipBroken(self):
        # One bad file shouldn't stop playback, but if the whole list fails we
        # must stop rather than spin through it forever.
        self.failures += 1
        if self.failures >= len(self.playlist):
            return self.reportTrouble()
        self.playIndex(self.index + 1)

    @objc.python_method
    def reportTrouble(self):
        path = self.currentPath()
        detail = ("None of these files could be played. They may be in a format "
                  "this player cannot decode.")
        try:
            with open(path, "rb") as f:
                f.read(1)
        except PermissionError:
            detail = (
                "macOS is blocking access to these files. They are on a network "
                "or external drive that this app has not been given permission "
                "to read.\n\n"
                "1.  Open System Settings › Privacy & Security › "
                "Full Disk Access\n"
                "2.  Click +, then add Video Player\n"
                "3.  Quit the player and open it again")
        except OSError:
            pass
        self.say("Cannot play these videos", detail)

    # -- updates ---------------------------------------------------------

    @objc.python_method
    def currentVersion(self):
        info = NSBundle.mainBundle().objectForInfoDictionaryKey_("CFBundleShortVersionString")
        return str(info) if info else "0"

    @objc.python_method
    def versionTuple(self, text):
        # "v1.2" and "1.2" must compare equal; missing parts count as zero
        return tuple(int(n) for n in re.findall(r"\d+", text or "")) or (0,)

    @objc.python_method
    def sslContext(self):
        if certifi is not None:
            return ssl.create_default_context(cafile=certifi.where())
        return ssl.create_default_context()

    @objc.python_method
    def fetchLatestRelease(self):
        request = urllib.request.Request(API_LATEST, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": APP_NAME,
        })
        with urllib.request.urlopen(request, timeout=20, context=self.sslContext()) as response:
            return json.load(response)

    def checkForUpdates_(self, sender):
        try:
            release = self.fetchLatestRelease()
        except urllib.error.HTTPError as err:
            if err.code in (401, 403, 404):
                return self.offerBrowser(
                    "Cannot check for updates",
                    "The releases for %s could not be read. If the repository is "
                    "private, the app cannot check on its own.\n\n"
                    "Open the releases page in your browser instead?" % APP_NAME)
            return self.say("Update check failed", "GitHub returned HTTP %d." % err.code)
        except Exception as err:
            return self.say("Update check failed",
                            "Could not reach GitHub.\n\n%s" % err)

        latest, here = release.get("tag_name", ""), self.currentVersion()
        if self.versionTuple(latest) <= self.versionTuple(here):
            return self.say("You're up to date",
                            "%s %s is the latest version." % (APP_NAME, here))

        asset = next((a for a in release.get("assets", [])
                      if a.get("name", "").lower().endswith(".dmg")), None)
        if asset is None:
            return self.offerBrowser(
                "Update available",
                "%s is available, but that release has no disk image to install "
                "automatically.\n\nOpen the releases page?" % latest)

        if not self.confirm(
                "Update available",
                "%s is available — you have %s.\n\nDownload and install it now? "
                "%s will quit, update itself and reopen."
                % (latest, here, APP_NAME), "Update"):
            return

        self.pendingURL = asset["browser_download_url"]
        self.window.setTitle_("Downloading update…")
        self.performSelectorInBackground_withObject_("downloadUpdate:", None)

    def downloadUpdate_(self, _):
        # Runs off the main thread; a 25MB download would otherwise freeze the UI.
        pool = NSAutoreleasePool.alloc().init()
        try:
            request = urllib.request.Request(self.pendingURL,
                                             headers={"User-Agent": APP_NAME})
            handle, path = tempfile.mkstemp(suffix=".dmg")
            with urllib.request.urlopen(request, timeout=300,
                                        context=self.sslContext()) as response, \
                    os.fdopen(handle, "wb") as out:
                while True:
                    chunk = response.read(262144)
                    if not chunk:
                        break
                    out.write(chunk)
            self.pendingDMG = path
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "applyUpdate:", None, False)
        except Exception as err:
            self.pendingError = str(err)
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "updateFailed:", None, False)
        finally:
            del pool

    def updateFailed_(self, _):
        self.updateUI()                       # puts the real title back
        self.say("Update failed", "The download did not complete.\n\n%s"
                 % getattr(self, "pendingError", ""))

    @objc.python_method
    def updateScript(self, dmg, app):
        # An app cannot replace itself while running, so hand the swap to a
        # detached script that waits for us to quit first.
        return """#!/bin/bash
APP=%s
DMG=%s
MOUNT=$(mktemp -d)

while kill -0 %d 2>/dev/null; do sleep 0.2; done

hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT" || exit 1
if [ ! -d "$MOUNT/%s.app" ]; then hdiutil detach "$MOUNT" -quiet; exit 1; fi

rm -rf "$APP.new"
cp -R "$MOUNT/%s.app" "$APP.new" || { hdiutil detach "$MOUNT" -quiet; exit 1; }
hdiutil detach "$MOUNT" -quiet

# Swap rather than delete-then-copy, so a failure never leaves you with no app.
rm -rf "$APP.old"
mv "$APP" "$APP.old" && mv "$APP.new" "$APP" && rm -rf "$APP.old"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
rm -f "$DMG"
open "$APP"
""" % (json.dumps(app), json.dumps(dmg), os.getpid(), APP_NAME, APP_NAME)

    def applyUpdate_(self, _):
        app = NSBundle.mainBundle().bundlePath()
        script = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
        script.write(self.updateScript(self.pendingDMG, app))
        script.close()
        os.chmod(script.name, 0o755)
        subprocess.Popen(["/bin/bash", script.name], start_new_session=True)
        NSApplication.sharedApplication().terminate_(None)

    # -- chrome ----------------------------------------------------------

    @objc.python_method
    def say(self, title, detail):
        alert = NSAlert.alloc().init()
        alert.setMessageText_(title)
        alert.setInformativeText_(detail)
        alert.addButtonWithTitle_("OK")
        alert.runModal()

    @objc.python_method
    def confirm(self, title, detail, proceed="OK"):
        alert = NSAlert.alloc().init()
        alert.setMessageText_(title)
        alert.setInformativeText_(detail)
        alert.addButtonWithTitle_(proceed)
        alert.addButtonWithTitle_("Cancel")
        return alert.runModal() == FIRST_BUTTON

    @objc.python_method
    def offerBrowser(self, title, detail):
        if self.confirm(title, detail, "Open Releases Page"):
            NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(RELEASES_PAGE))

    @objc.python_method
    def updateUI(self):
        path = self.currentPath()
        enabled = len(self.playlist) > 1
        self.prevButton.setEnabled_(enabled)
        self.nextButton.setEnabled_(enabled)
        self.listButton.setEnabled_(bool(self.playlist))
        self.favButton.setEnabled_(bool(self.playlist))
        self.revealCurrentRow()          # keep the highlight on what's playing

        if not path:
            self.window.setTitle_(APP_NAME)
            self.favItem.setTitle_("Add to Favorites")
            self.favButton.setTitle_("☆  Favorite")
            return

        starred = path in self.favorites
        label = "Favorites" if self.mode == "favorites" else "Folder"
        self.window.setTitle_("%s%s  —  %d of %d  —  %s" % (
            "★ " if starred else "",
            os.path.basename(path), self.index + 1, len(self.playlist), label))
        self.favItem.setTitle_("Remove from Favorites" if starred else "Add to Favorites")
        self.favButton.setTitle_(("★" if starred else "☆") + "  Favorite")


def main():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)
    objc.retainedLocals = delegate      # keep the delegate alive
    AppHelper.runEventLoop()


if __name__ == "__main__":
    main()
