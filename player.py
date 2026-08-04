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
import random
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
    AVURLAsset,
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
    NSColor,
    NSFont,
    NSMakeRect,
    NSMakeSize,
    NSImage,
    NSMenu,
    NSMenuItem,
    NSNotificationCenter,
    NSObject,
    NSOpenPanel,
    NSScrollView,
    NSSearchField,
    NSTableColumn,
    NSTableView,
    NSTextField,
    NSTimer,
    NSURL,
    NSView,
    NSViewHeightSizable,
    NSViewMaxYMargin,
    NSViewMinXMargin,
    NSViewMinYMargin,
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
TAGS_FILE = os.path.join(SUPPORT, "tags.json")

# What AVFoundation can actually decode. .mkv and .avi are deliberately absent.
VIDEO_EXT = {".mp4", ".m4v", ".mov"}

SKIP_SECONDS = 15

PROGRESS_TICK = 5.0           # seconds between samples of the playhead
PROGRESS_FLUSH = 6            # ...and samples between writes to disk
RESUME_MIN = 30               # a video barely started just starts over
RESUME_TAIL = 30              # ...and so does one that was all but finished
RECENT_MAX = 8
PROGRESS_MAX = 500            # newest positions win; older ones age out

# What happens when a video ends.
REPEAT_ALL, REPEAT_ONE, SHUFFLE, PLAY_ONCE = "all", "one", "shuffle", "once"
ORDERS = [("Repeat All", REPEAT_ALL), ("Repeat One", REPEAT_ONE),
          ("Shuffle", SHUFFLE), ("Play Once", PLAY_ONCE)]
ORDER_NAMES = {value: title for title, value in ORDERS}

SPEEDS = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
NORMAL_SPEED = 1.0

CONTROLS_FLOATING = 1
BAR_HEIGHT = 48
BUTTON_W, BUTTON_H = 116, 30
SIDEBAR_W = 320
SIDEBAR_SLIDE = 0.22          # seconds
FILTER_H = 24
ROW_H, GROUP_H = 22, 20
DURATION_W = 52
NAME_TAG, TIME_TAG = 1, 2
DURATION_BATCH = 25           # rows to measure between table refreshes
FAV_W, FAV_H = 460, 420
FAV_NOTE_W = 130

VIBRANCY_SIDEBAR = 7          # NSVisualEffectMaterialSidebar
VIBRANCY_ACTIVE = 0           # NSVisualEffectStateFollowsWindowActiveState
STATUS_READY, STATUS_FAILED = 1, 2
NS_OK = 1
FIRST_BUTTON = 1000
STATE_ON, STATE_OFF = 1, 0    # NSControlStateValue
ALIGN_RIGHT = 2               # NSTextAlignmentRight
NS_TRUNCATE_TAIL = 4          # NSLineBreakByTruncatingTail

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
def parse_tags(text):
    """Split what someone typed into clean tag names, in the order given.

    Commas or semicolons separate, runs of whitespace collapse, and a name
    repeated in different case counts once — "Beach, beach" is one tag.
    """
    seen, names = set(), []
    for part in text.replace(";", ",").split(","):
        name = " ".join(part.split())
        if name and name.lower() not in seen:
            seen.add(name.lower())
            names.append(name)
    return names


@objc.python_method
def clock(seconds):
    """Seconds as 4:07, or 1:02:30 once there is an hour to show."""
    seconds = int(seconds)
    hours, rest = divmod(seconds, 3600)
    minutes, seconds = divmod(rest, 60)
    if hours:
        return "%d:%02d:%02d" % (hours, minutes, seconds)
    return "%d:%02d" % (minutes, seconds)


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
        self.bag = []                 # playlist indices, shuffled
        self.rows = []                # what the sidebar actually shows
        self.filterText = ""
        self.durations = {}
        self.durationGen = 0
        self.favWindow = None
        self.favTable = None
        self.tagName = None           # which tag is playing, in tag mode
        self.tagWindow = None
        self.tagTable = None
        self.tagRows = []
        self.tagItems = []
        self.favorites = self.loadFavorites()
        self.loadTags()
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
        self.durationGen += 1         # tell any duration scan to give up
        self.detachItem()
        try:
            self.player.removeObserver_forKeyPath_(self, "rate")
        except Exception:
            pass

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

    # -- tags ------------------------------------------------------------
    #
    # Kept in their own file, keyed on the video's path, and never trimmed:
    # a resume position that ages out costs you nothing, a tag you typed is
    # work. The cost of keying on path is that renaming a video orphans its
    # tags, which is what Manage Tags is there to clean up.

    @objc.python_method
    def loadTags(self):
        stored = load_json(TAGS_FILE, {})
        self.tags = {}
        for path, names in stored.items():
            if isinstance(names, list):
                clean = parse_tags(",".join(str(n) for n in names))
                if clean:
                    self.tags[path] = clean

    @objc.python_method
    def saveTags(self):
        save_json(TAGS_FILE, self.tags)

    @objc.python_method
    def tagsFor(self, path):
        return self.tags.get(path, [])

    @objc.python_method
    def setTagsFor(self, path, names):
        if names:
            self.tags[path] = names
        else:
            self.tags.pop(path, None)     # no empty lists left lying around

    @objc.python_method
    def knownTags(self):
        """Every tag in use, case-insensitively unique, alphabetical."""
        seen = {}
        for names in self.tags.values():
            for name in names:
                seen.setdefault(name.lower(), name)
        return [seen[key] for key in sorted(seen)]

    @objc.python_method
    def taggedWith(self, tag):
        wanted = tag.lower()
        return [path for path, names in self.tags.items()
                if any(n.lower() == wanted for n in names)]

    @objc.python_method
    def hasTag(self, path, tag):
        wanted = tag.lower()
        return any(n.lower() == wanted for n in self.tagsFor(path))

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
        # Both fall back to the old hardcoded behaviour if they are anything
        # other than a value the app actually offers.
        self.repeat = state.get("repeat")
        if self.repeat not in [value for _, value in ORDERS]:
            self.repeat = REPEAT_ALL
        self.speed = state.get("speed")
        if self.speed not in SPEEDS:
            self.speed = NORMAL_SPEED

    @objc.python_method
    def saveState(self):
        path = self.currentPath()
        session = {"mode": self.mode, "root": self.root, "path": path,
                   "tag": self.tagName} if path else {}
        save_json(STATE_FILE, {
            "recent": self.recent[:RECENT_MAX],
            # dicts keep insertion order, and notePosition re-inserts, so the
            # tail of this is exactly the most recently watched
            "progress": dict(list(self.progress.items())[-PROGRESS_MAX:]),
            "session": session,
            "repeat": self.repeat,
            "speed": self.speed,
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
                self.reshuffle()
                self.rebuildRows()
                return self.playIndex(self.index)
        else:
            self.favorites.append(path)
        self.saveFavorites()
        self.refreshRows()
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
        self.add(files, "Manage Favorites…", "manageFavorites:")

        play = self.menu(bar, "Playback")
        # Bare arrows scrub within the video; add Command to change video.
        self.add(play, "Skip Back %d Seconds" % SKIP_SECONDS, "skipBack:", LEFT_ARROW, 0)
        self.add(play, "Skip Forward %d Seconds" % SKIP_SECONDS, "skipForward:", RIGHT_ARROW, 0)
        play.addItem_(NSMenuItem.separatorItem())
        self.add(play, "Next Video", "nextItem:", RIGHT_ARROW, NSEventModifierFlagCommand)
        self.add(play, "Previous Video", "prevItem:", LEFT_ARROW, NSEventModifierFlagCommand)

        play.addItem_(NSMenuItem.separatorItem())
        self.orderItems = []
        for title, value in ORDERS:
            item = self.add(play, title, "setOrder:")
            item.setRepresentedObject_(value)
            self.orderItems.append(item)

        play.addItem_(NSMenuItem.separatorItem())
        speeds = self.menu(play, "Speed")
        self.speedItems = []
        for rate in SPEEDS:
            item = self.add(speeds, "Normal" if rate == NORMAL_SPEED else "%g×" % rate,
                            "setSpeed:")
            item.setRepresentedObject_(rate)
            self.speedItems.append(item)

        play.addItem_(NSMenuItem.separatorItem())
        # Shift is deliberate: plain Cmd+D is claimed by the system in several
        # contexts, so the app never reliably received it.
        self.favItem = self.add(play, "Add to Favorites", "toggleFavorite:", "d",
                                NSEventModifierFlagCommand | NSEventModifierFlagShift)
        self.syncPlaybackMenu()

        self.tagsMenu = self.menu(bar, "Tags")
        self.rebuildTagsMenu()

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
        self.player.addObserver_forKeyPath_options_context_(self, "rate", 0, None)
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

        # Filter pinned to the top of the drawer. A folder of 300 files is not
        # navigable by scrolling alone.
        self.filterField = NSSearchField.alloc().initWithFrame_(
            NSMakeRect(8, height - FILTER_H - 8, SIDEBAR_W - 16, FILTER_H))
        self.filterField.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        self.filterField.setPlaceholderString_("Filter")
        self.filterField.setDelegate_(self)
        self.sidebar.addSubview_(self.filterField)

        listHeight = height - FILTER_H - 16
        self.table = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, SIDEBAR_W, listHeight))
        column = NSTableColumn.alloc().initWithIdentifier_("name")
        column.setWidth_(SIDEBAR_W - 24)
        self.table.addTableColumn_(column)
        self.table.setHeaderView_(None)
        self.table.setRowHeight_(ROW_H)
        self.table.setUsesAlternatingRowBackgroundColors_(True)
        # Several rows can be picked so they can be tagged together; playback
        # only follows a selection of exactly one, so shift-clicking a range
        # does not send the player chasing down the list.
        self.table.setAllowsMultipleSelection_(True)
        self.table.setDataSource_(self)
        # Selection drives playback, so clicking and arrowing behave identically.
        self.table.setDelegate_(self)
        self.syncing = False

        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, 0, SIDEBAR_W, listHeight))
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
        # The favorites window shares this delegate and lays itself out
        if notification.object().isEqual_(self.window):
            self.sidebar.setFrame_(self.sidebarFrame())

    def tableViewSelectionDidChange_(self, notification):
        # Ignore selection we set ourselves while following playback, otherwise
        # every track change would re-trigger itself.
        table = notification.object()
        if self.syncing or self.isFavTable(table) or self.isTagTable(table):
            return
        if self.table.numberOfSelectedRows() == 1:
            self.jumpToRow(self.table.selectedRow())

    @objc.python_method
    def jumpToRow(self, row):
        if not 0 <= row < len(self.rows):
            return
        index = self.rows[row][0]
        if index is not None and index != self.index:
            self.playIndex(index)

    # -- what the drawer actually shows ----------------------------------
    #
    # Filtering and folder headings mean a table row is no longer a playlist
    # index, so self.rows maps one to the other: (index, name) for a video,
    # (None, label) for a folder heading.

    @objc.python_method
    def groupLabel(self, path):
        """The folder a file should be filed under, or None if it needs none."""
        folder = os.path.dirname(path)
        if self.mode == "folder" and self.root:
            rel = os.path.relpath(folder, self.root)
            return None if rel == "." else rel
        return os.path.basename(folder) or folder

    @objc.python_method
    def matches(self, path, name, needle):
        """The filter box searches names and tags together, as a search box should."""
        return needle in name.lower() or any(needle in n.lower()
                                             for n in self.tagsFor(path))

    @objc.python_method
    def rebuildRows(self):
        needle = self.filterText.lower()
        self.rows = []
        heading = object()            # a sentinel no real label can equal
        for i, path in enumerate(self.playlist):
            name = os.path.basename(path)
            if needle and not self.matches(path, name, needle):
                continue
            label = self.groupLabel(path)
            if label != heading:
                heading = label
                if label is not None:
                    self.rows.append((None, label))
            self.rows.append((i, name))
        self.table.reloadData()
        self.revealCurrentRow()

    def controlTextDidChange_(self, notification):
        if not notification.object().isEqual_(self.filterField):
            return
        self.filterText = str(self.filterField.stringValue())
        self.rebuildRows()

    @objc.python_method
    def revealCurrentRow(self):
        """Highlight whatever is playing — unless the filter has hidden it."""
        row = next((r for r, (i, _) in enumerate(self.rows) if i == self.index), None)
        self.syncing = True
        try:
            if row is None:
                self.table.deselectAll_(None)
            else:
                self.table.selectRowIndexes_byExtendingSelection_(
                    NSIndexSet.indexSetWithIndex_(row), False)
                self.table.scrollRowToVisible_(row)
        finally:
            self.syncing = False

    # -- table plumbing, shared with the favorites window ----------------

    @objc.python_method
    def isFavTable(self, view):
        return self.favTable is not None and view.isEqual_(self.favTable)

    def numberOfRowsInTableView_(self, tableView):
        if self.isFavTable(tableView):
            return len(self.favorites)
        if self.isTagTable(tableView):
            return len(self.tagRows)
        return len(self.rows)

    def tableView_isGroupRow_(self, tableView, row):
        return self.isPlainRow(tableView, row) is None

    def tableView_shouldSelectRow_(self, tableView, row):
        return self.isPlainRow(tableView, row) is not None

    def tableView_heightOfRow_(self, tableView, row):
        return ROW_H if self.isPlainRow(tableView, row) is not None else GROUP_H

    @objc.python_method
    def isPlainRow(self, tableView, row):
        """The playlist index for a selectable row, or None for a heading."""
        if self.isFavTable(tableView) or self.isTagTable(tableView):
            return row                    # those lists are all plain rows
        if not 0 <= row < len(self.rows):
            return None
        return self.rows[row][0]

    def tableView_viewForTableColumn_row_(self, tableView, column, row):
        if self.isFavTable(tableView):
            return self.favoriteRow(tableView, row)
        if self.isTagTable(tableView):
            return self.tagManagerRow(tableView, row)
        if not 0 <= row < len(self.rows):
            return None
        index, label = self.rows[row]
        if index is None:
            return self.headingRow(tableView, label)
        return self.videoRow(tableView, index, label)

    @objc.python_method
    def label(self, frame, size, tag, align=None, dim=False, bold=False):
        field = NSTextField.alloc().initWithFrame_(frame)
        field.setBezeled_(False)
        field.setDrawsBackground_(False)
        field.setEditable_(False)
        field.setSelectable_(False)
        field.setLineBreakMode_(NS_TRUNCATE_TAIL)
        field.setFont_(NSFont.boldSystemFontOfSize_(size) if bold
                       else NSFont.systemFontOfSize_(size))
        field.setTag_(tag)
        if align is not None:
            field.setAlignment_(align)
        if dim:
            field.setTextColor_(NSColor.secondaryLabelColor())
        return field

    @objc.python_method
    def reuse(self, tableView, identifier, build):
        view = tableView.makeViewWithIdentifier_owner_(identifier, self)
        if view is None:
            view = build()
            view.setIdentifier_(identifier)
        return view

    @objc.python_method
    def buildVideoRow(self):
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, SIDEBAR_W, ROW_H))
        name = self.label(NSMakeRect(8, 1, SIDEBAR_W - DURATION_W - 40, ROW_H - 2),
                          12, NAME_TAG)
        name.setAutoresizingMask_(NSViewWidthSizable)
        length = self.label(
            NSMakeRect(SIDEBAR_W - DURATION_W - 24, 1, DURATION_W, ROW_H - 2),
            11, TIME_TAG, align=ALIGN_RIGHT, dim=True)
        length.setAutoresizingMask_(NSViewMinXMargin)
        view.addSubview_(name)
        view.addSubview_(length)
        return view

    @objc.python_method
    def videoRow(self, tableView, index, name):
        view = self.reuse(tableView, "video", self.buildVideoRow)
        path = self.playlist[index]
        view.viewWithTag_(NAME_TAG).setStringValue_(
            ("★  " if path in self.favorites else "") + name)
        seconds = self.durations.get(path)
        view.viewWithTag_(TIME_TAG).setStringValue_(clock(seconds) if seconds else "")
        return view

    @objc.python_method
    def buildHeadingRow(self):
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, SIDEBAR_W, GROUP_H))
        field = self.label(NSMakeRect(8, 0, SIDEBAR_W - 16, GROUP_H - 2), 11,
                           NAME_TAG, dim=True, bold=True)
        field.setAutoresizingMask_(NSViewWidthSizable)
        view.addSubview_(field)
        return view

    @objc.python_method
    def headingRow(self, tableView, label):
        view = self.reuse(tableView, "heading", self.buildHeadingRow)
        view.viewWithTag_(NAME_TAG).setStringValue_(label)
        return view

    # -- measuring how long each video is --------------------------------

    @objc.python_method
    def loadDurations(self):
        # Reading 300 files' headers on the main thread would lock the window,
        # so it happens on a worker and the table refreshes as answers arrive.
        self.durationGen += 1
        self.performSelectorInBackground_withObject_("scanDurations:", self.durationGen)

    def scanDurations_(self, generation):
        pool = NSAutoreleasePool.alloc().init()
        try:
            generation = int(generation)
            todo = [p for p in self.playlist if p not in self.durations]
            for n, path in enumerate(todo):
                if generation != self.durationGen:
                    return                # the playlist moved on; drop this pass
                asset = AVURLAsset.URLAssetWithURL_options_(
                    NSURL.fileURLWithPath_(path), None)
                seconds = CMTimeGetSeconds(asset.duration())
                self.durations[path] = seconds if seconds == seconds and seconds > 0 else 0
                if n % DURATION_BATCH == DURATION_BATCH - 1:
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "durationsArrived:", None, False)
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "durationsArrived:", None, False)
        finally:
            del pool

    def durationsArrived_(self, _):
        self.refreshRows()

    @objc.python_method
    def refreshRows(self):
        """Redraw the rows we already have — a star changed, or a duration."""
        self.syncing = True           # reloading must not look like a click
        try:
            self.table.reloadData()
        finally:
            self.syncing = False
        self.revealCurrentRow()
        if self.favTable is not None:
            self.favTable.reloadData()

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
        mode = self.session.get("mode")
        if mode == "favorites":
            return "Favorites" if self.favorites else None
        if mode == "tag":
            tag = self.session.get("tag")
            return "“%s”" % tag if tag and self.taggedWith(tag) else None
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
        if session.get("mode") == "tag":
            return self.startTag(session.get("tag"), session.get("path"))
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

    def playTag_(self, sender):
        self.startTag(str(sender.representedObject()))

    @objc.python_method
    def startTag(self, tag, resume=None):
        live = [p for p in self.taggedWith(tag) if os.path.isfile(p)]
        if not live:
            return self.say(
                "Nothing to play for “%s”" % tag,
                "Every video with that tag has been moved, renamed or deleted. "
                "Manage Tags will clear out the entries that no longer point "
                "at anything.")
        live.sort(key=lambda p: natural_key(os.path.basename(p)))
        self.tagName = tag
        self.startPlaylist(live, "tag", None, resume)

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
        if mode != "tag":
            self.tagName = None
        self.failures = 0
        self.reshuffle()
        self.filterText = ""
        self.filterField.setStringValue_("")
        self.rebuildRows()
        self.loadDurations()
        if resume in items:
            # A folder can change between sessions; falling back to the top is
            # the only sane answer when the video we left off on is gone.
            start = items.index(resume)
        elif self.repeat == SHUFFLE and self.bag:
            start = self.bag[0]
        else:
            start = 0
        self.playIndex(start)
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
        nxt = self.followOn()
        if nxt is None:
            return self.player.pause()      # Play Once, and that was the last
        self.playIndex(nxt)

    def nextItem_(self, sender):
        self.playIndex(self.step(1))

    def prevItem_(self, sender):
        self.playIndex(self.step(-1))

    # -- what plays next -------------------------------------------------

    @objc.python_method
    def followOn(self):
        """The index to play when the current video ends, or None to stop."""
        if self.repeat == REPEAT_ONE:
            return self.index
        if self.repeat == PLAY_ONCE:
            nxt = self.index + 1
            return nxt if nxt < len(self.playlist) else None
        return self.step(1)

    @objc.python_method
    def step(self, delta):
        """The index delta videos away, in whatever order is in force.

        Explicit Next and Previous use this too, so in Shuffle they walk the
        shuffled order rather than the folder order — which is what you mean
        by "next" once you have asked for shuffle.
        """
        if not self.playlist:
            return 0
        if self.repeat != SHUFFLE:
            return (self.index + delta) % len(self.playlist)

        if not self.bag:
            self.reshuffle()
        where = self.bag.index(self.index) if self.index in self.bag else -1
        landing = where + delta
        if landing >= len(self.bag):
            # The whole folder has been played: deal again rather than let a
            # video come round twice before the rest have had a turn.
            self.reshuffle(after=self.index)
            return self.bag[0]
        return self.bag[landing % len(self.bag)]

    @objc.python_method
    def reshuffle(self, after=None):
        self.bag = list(range(len(self.playlist)))
        random.shuffle(self.bag)
        # Don't open a fresh pass with the video that just closed the last one
        if after is not None and len(self.bag) > 1 and self.bag[0] == after:
            self.bag[0], self.bag[-1] = self.bag[-1], self.bag[0]

    def setOrder_(self, sender):
        self.repeat = str(sender.representedObject())
        if self.repeat == SHUFFLE:
            self.reshuffle()
        self.syncPlaybackMenu()
        self.updateUI()
        self.saveState()

    def setSpeed_(self, sender):
        self.speed = float(sender.representedObject())
        self.applySpeed()
        self.syncPlaybackMenu()
        self.updateUI()
        self.saveState()

    @objc.python_method
    def applySpeed(self):
        # Setting a rate on a paused player would start it playing, so the
        # choice is only pushed through while something is actually running.
        if self.player.rate() not in (0.0, self.speed):
            self.player.setRate_(self.speed)

    @objc.python_method
    def syncPlaybackMenu(self):
        for item in self.orderItems:
            item.setState_(STATE_ON if str(item.representedObject()) == self.repeat
                           else STATE_OFF)
        for item in self.speedItems:
            item.setState_(STATE_ON if float(item.representedObject()) == self.speed
                           else STATE_OFF)

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
        if keyPath == "rate":
            # play(), and the floating AVKit controls, both reset the rate to 1,
            # so a chosen speed has to be reasserted rather than set once.
            return self.applySpeed()
        # A notification already in flight when we moved on must not be acted on
        if keyPath != "status" or self.item is None or not obj.isEqual_(self.item):
            return
        if obj.status() == STATUS_READY:
            self.failures = 0
            self.applyResume()
            self.applySpeed()
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

    # -- tagging ---------------------------------------------------------

    @objc.python_method
    def selectedPaths(self):
        """What a tag command should act on: the drawer's selection, or what's playing."""
        rows = [self.rows[r][0] for r in self.table.selectedRowIndexes()
                if 0 <= r < len(self.rows) and self.rows[r][0] is not None]
        if len(rows) > 1:
            return [self.playlist[i] for i in rows]
        path = self.currentPath()
        return [path] if path else []

    @objc.python_method
    def rebuildTagsMenu(self):
        """Every known tag, ticked when the playing video carries it."""
        self.tagsMenu.removeAllItems()
        self.add(self.tagsMenu, "Edit Tags…", "editTags:", "t", NSEventModifierFlagCommand)

        known = self.knownTags()
        self.tagItems = []
        if known:
            self.tagsMenu.addItem_(NSMenuItem.separatorItem())
            for name in known:
                # Ticking one here toggles it on whatever is playing, which is
                # the quick path; the dialog is for anything more involved.
                item = self.add(self.tagsMenu, name, "toggleTag:")
                item.setRepresentedObject_(name)
                self.tagItems.append(item)
            self.syncTagsMenu()

            self.tagsMenu.addItem_(NSMenuItem.separatorItem())
            play = self.menu(self.tagsMenu, "Play Tag")
            for name in known:
                item = self.add(play, "%s (%d)" % (name, len(self.taggedWith(name))),
                                "playTag:")
                item.setRepresentedObject_(name)

        self.tagsMenu.addItem_(NSMenuItem.separatorItem())
        self.add(self.tagsMenu, "Manage Tags…", "manageTags:")

    @objc.python_method
    def syncTagsMenu(self):
        """Tick the tags the playing video carries. Cheap enough per track change."""
        playing = self.currentPath()
        for item in self.tagItems:
            item.setState_(
                STATE_ON if playing and self.hasTag(playing, str(item.representedObject()))
                else STATE_OFF)

    def editTags_(self, sender):
        paths = self.selectedPaths()
        if not paths:
            return self.say("Nothing to tag", "Play a video first, or pick rows "
                                              "in the playlist.")
        if len(paths) == 1:
            # One video: show what it has and let the field be the truth, so
            # clearing the box removes its tags.
            typed = self.askText(
                "Tags for %s" % os.path.basename(paths[0]),
                "Separate tags with commas. Clearing the box removes them all.",
                ", ".join(self.tagsFor(paths[0])))
            if typed is None:
                return
            self.setTagsFor(paths[0], parse_tags(typed))
        else:
            # Several: adding is the only safe reading, since replacing would
            # silently wipe tags the others had and this one did not.
            typed = self.askText(
                "Tag %d videos" % len(paths),
                "Separate tags with commas. These are added to whatever each "
                "video already has.", "")
            if typed is None:
                return
            for name in parse_tags(typed):
                for path in paths:
                    if not self.hasTag(path, name):
                        self.setTagsFor(path, self.tagsFor(path) + [name])
        self.tagsChanged()

    def toggleTag_(self, sender):
        path = self.currentPath()
        if not path:
            return
        name = str(sender.representedObject())
        if self.hasTag(path, name):
            self.setTagsFor(path, [n for n in self.tagsFor(path)
                                   if n.lower() != name.lower()])
        else:
            self.setTagsFor(path, self.tagsFor(path) + [name])
        self.tagsChanged()

    @objc.python_method
    def tagsChanged(self):
        self.saveTags()
        self.rebuildTagsMenu()
        self.refreshTagManager()
        # A tag is part of what the filter matches, so the rows can change
        self.rebuildRows()
        self.updateUI()

    # -- the tag manager -------------------------------------------------

    @objc.python_method
    def orphanedTags(self):
        """Tagged videos that are no longer where we left them."""
        return [p for p in self.tags if not os.path.isfile(p)]

    def manageTags_(self, sender):
        if self.tagWindow is not None:
            self.refreshTagManager()
            return self.tagWindow.makeKeyAndOrderFront_(None)

        rect = NSMakeRect(0, 0, FAV_W, FAV_H)
        self.tagWindow = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskResizable, NSBackingStoreBuffered, False)
        self.tagWindow.setTitle_("Tags")
        self.tagWindow.setMinSize_(NSMakeSize(360, 240))
        self.tagWindow.center()
        self.tagWindow.setReleasedWhenClosed_(False)
        self.tagWindow.setDelegate_(self)

        content = NSView.alloc().initWithFrame_(rect)
        self.tagTable = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, FAV_W, rect.size.height - BAR_HEIGHT))
        column = NSTableColumn.alloc().initWithIdentifier_("name")
        column.setWidth_(FAV_W - 24)
        self.tagTable.addTableColumn_(column)
        self.tagTable.setHeaderView_(None)
        self.tagTable.setRowHeight_(ROW_H)
        self.tagTable.setUsesAlternatingRowBackgroundColors_(True)
        self.tagTable.setDataSource_(self)
        self.tagTable.setDelegate_(self)

        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, BAR_HEIGHT, FAV_W, rect.size.height - BAR_HEIGHT))
        scroll.setDocumentView_(self.tagTable)
        scroll.setHasVerticalScroller_(True)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        content.addSubview_(scroll)

        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, FAV_W, BAR_HEIGHT))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        bar.addSubview_(self.barButton("Rename…", "renameTag:", 14))
        bar.addSubview_(self.barButton("Delete", "deleteTag:", 14 + BUTTON_W + 8))
        self.orphanButton = self.barButton("Clear Missing", "clearOrphans:",
                                           14 + 2 * (BUTTON_W + 8))
        self.orphanButton.setFrame_(NSMakeRect(14 + 2 * (BUTTON_W + 8),
                                               (BAR_HEIGHT - BUTTON_H) / 2,
                                               BUTTON_W + 30, BUTTON_H))
        bar.addSubview_(self.orphanButton)
        content.addSubview_(bar)

        self.tagWindow.setContentView_(content)
        self.refreshTagManager()
        self.tagWindow.makeKeyAndOrderFront_(None)

    @objc.python_method
    def refreshTagManager(self):
        if self.tagTable is None:
            return
        self.tagRows = self.knownTags()
        self.tagTable.reloadData()
        orphans = len(self.orphanedTags())
        self.orphanButton.setTitle_("Clear Missing (%d)" % orphans if orphans
                                    else "Clear Missing")
        self.orphanButton.setEnabled_(bool(orphans))

    @objc.python_method
    def isTagTable(self, view):
        return self.tagTable is not None and view.isEqual_(self.tagTable)

    @objc.python_method
    def tagManagerRow(self, tableView, row):
        view = self.reuse(tableView, "tagrow", self.buildFavoriteRow)
        name = self.tagRows[row]
        paths = self.taggedWith(name)
        missing = sum(1 for p in paths if not os.path.isfile(p))
        view.viewWithTag_(NAME_TAG).setStringValue_(name)
        note = view.viewWithTag_(TIME_TAG)
        note.setStringValue_("%d video%s%s" % (
            len(paths), "" if len(paths) == 1 else "s",
            ", %d missing" % missing if missing else ""))
        note.setTextColor_(NSColor.systemRedColor() if missing
                           else NSColor.secondaryLabelColor())
        return view

    @objc.python_method
    def selectedTag(self):
        row = self.tagTable.selectedRow()
        return self.tagRows[row] if 0 <= row < len(self.tagRows) else None

    def renameTag_(self, sender):
        old = self.selectedTag()
        if old is None:
            return self.say("Nothing selected", "Pick a tag to rename first.")
        typed = self.askText("Rename “%s”" % old,
                             "Every video carrying it is updated. Renaming onto "
                             "an existing tag merges the two.", old)
        if typed is None:
            return
        names = parse_tags(typed)
        if not names:
            return
        new = names[0]
        for path, current in list(self.tags.items()):
            if any(n.lower() == old.lower() for n in current):
                kept = [n for n in current if n.lower() != old.lower()]
                if not any(n.lower() == new.lower() for n in kept):
                    kept.append(new)
                self.setTagsFor(path, kept)
        self.tagsChanged()

    def deleteTag_(self, sender):
        name = self.selectedTag()
        if name is None:
            return self.say("Nothing selected", "Pick a tag to delete first.")
        paths = self.taggedWith(name)
        if not self.confirm(
                "Delete the tag “%s”?" % name,
                "It is removed from %d video%s. The videos themselves are not "
                "touched." % (len(paths), "" if len(paths) == 1 else "s"),
                "Delete"):
            return
        for path in paths:
            self.setTagsFor(path, [n for n in self.tagsFor(path)
                                   if n.lower() != name.lower()])
        self.tagsChanged()

    def clearOrphans_(self, sender):
        orphans = self.orphanedTags()
        if not orphans:
            return
        # Same hazard as pruning favorites, and the same answer: never do it
        # unasked, because an unmounted drive looks exactly like a deletion.
        if not self.confirm(
                "Clear tags for %d missing video%s?"
                % (len(orphans), "" if len(orphans) == 1 else "s"),
                "These files are no longer where they were tagged:\n\n%s\n\n"
                "If they are on a drive that is not mounted, plug it in first "
                "— the tags are fine, the files just cannot be seen."
                % "\n".join(os.path.basename(p) for p in orphans[:12]),
                "Clear"):
            return
        for path in orphans:
            self.tags.pop(path, None)
        self.tagsChanged()

    # -- managing favorites without playing them -------------------------

    @objc.python_method
    def missingFavorites(self):
        return [p for p in self.favorites if not os.path.isfile(p)]

    def manageFavorites_(self, sender):
        if self.favWindow is not None:
            self.refreshFavorites()
            return self.favWindow.makeKeyAndOrderFront_(None)

        rect = NSMakeRect(0, 0, FAV_W, FAV_H)
        self.favWindow = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskResizable, NSBackingStoreBuffered, False)
        self.favWindow.setTitle_("Favorites")
        self.favWindow.setMinSize_(NSMakeSize(360, 240))
        self.favWindow.center()
        # Closing must not leave a dead window behind for the next open
        self.favWindow.setReleasedWhenClosed_(False)
        self.favWindow.setDelegate_(self)

        content = NSView.alloc().initWithFrame_(rect)

        self.favTable = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, FAV_W, rect.size.height - BAR_HEIGHT))
        column = NSTableColumn.alloc().initWithIdentifier_("name")
        column.setWidth_(FAV_W - 24)
        self.favTable.addTableColumn_(column)
        self.favTable.setHeaderView_(None)
        self.favTable.setRowHeight_(ROW_H)
        self.favTable.setUsesAlternatingRowBackgroundColors_(True)
        self.favTable.setAllowsMultipleSelection_(True)
        self.favTable.setDataSource_(self)
        self.favTable.setDelegate_(self)

        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, BAR_HEIGHT, FAV_W, rect.size.height - BAR_HEIGHT))
        scroll.setDocumentView_(self.favTable)
        scroll.setHasVerticalScroller_(True)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        content.addSubview_(scroll)

        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, FAV_W, BAR_HEIGHT))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        remove = self.barButton("Remove", "removeFavorites:", 14)
        self.pruneButton = self.barButton("Remove Missing", "pruneFavorites:",
                                          14 + BUTTON_W + 8)
        self.pruneButton.setFrame_(NSMakeRect(14 + BUTTON_W + 8,
                                              (BAR_HEIGHT - BUTTON_H) / 2,
                                              BUTTON_W + 40, BUTTON_H))
        bar.addSubview_(remove)
        bar.addSubview_(self.pruneButton)
        content.addSubview_(bar)

        self.favWindow.setContentView_(content)
        self.refreshFavorites()
        self.favWindow.makeKeyAndOrderFront_(None)

    def windowWillClose_(self, notification):
        closing = notification.object()
        if self.favWindow is not None and closing.isEqual_(self.favWindow):
            # Drop the table first: every shared table callback keys off it
            self.favTable = None
            self.favWindow = None
        elif self.tagWindow is not None and closing.isEqual_(self.tagWindow):
            self.tagTable = None
            self.tagWindow = None
        elif closing.isEqual_(self.window):
            # Otherwise closing the player would leave the app alive behind a
            # stray utility window instead of quitting.
            for window in [self.favWindow, self.tagWindow]:
                if window is not None:
                    window.close()

    @objc.python_method
    def refreshFavorites(self):
        if self.favTable is None:
            return
        self.favTable.reloadData()
        missing = len(self.missingFavorites())
        self.pruneButton.setTitle_("Remove Missing (%d)" % missing if missing
                                   else "Remove Missing")
        self.pruneButton.setEnabled_(bool(missing))

    @objc.python_method
    def buildFavoriteRow(self):
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, FAV_W, ROW_H))
        name = self.label(NSMakeRect(8, 1, FAV_W - FAV_NOTE_W - 26, ROW_H - 2),
                          12, NAME_TAG)
        name.setAutoresizingMask_(NSViewWidthSizable)
        note = self.label(NSMakeRect(FAV_W - FAV_NOTE_W - 12, 1, FAV_NOTE_W, ROW_H - 2),
                          11, TIME_TAG, align=ALIGN_RIGHT, dim=True)
        note.setAutoresizingMask_(NSViewMinXMargin)
        view.addSubview_(name)
        view.addSubview_(note)
        return view

    @objc.python_method
    def favoriteRow(self, tableView, row):
        view = self.reuse(tableView, "favorite", self.buildFavoriteRow)
        path = self.favorites[row]
        gone = not os.path.isfile(path)
        view.viewWithTag_(NAME_TAG).setStringValue_(os.path.basename(path))
        note = view.viewWithTag_(TIME_TAG)
        note.setStringValue_("missing" if gone else
                             os.path.basename(os.path.dirname(path)))
        note.setTextColor_(NSColor.systemRedColor() if gone
                           else NSColor.secondaryLabelColor())
        return view

    def removeFavorites_(self, sender):
        rows = sorted(self.favTable.selectedRowIndexes(), reverse=True)
        if not rows:
            return self.say("Nothing selected",
                            "Pick the favorites you want to remove first.")
        for row in rows:
            if 0 <= row < len(self.favorites):
                del self.favorites[row]
        self.finishFavoriteEdit()

    def pruneFavorites_(self, sender):
        missing = self.missingFavorites()
        if not missing:
            return
        # This is the one that can lose real data: a NAS that happens to be
        # offline makes every file on it look deleted.
        if not self.confirm(
                "Remove %d missing favorite%s?" % (len(missing),
                                                   "" if len(missing) == 1 else "s"),
                "These files could not be found:\n\n%s\n\nIf they live on a "
                "network or external drive, check it is plugged in and mounted "
                "first — an unmounted drive looks exactly like a deleted file."
                % "\n".join(os.path.basename(p) for p in missing[:12]),
                "Remove"):
            return
        gone = set(missing)
        self.favorites = [p for p in self.favorites if p not in gone]
        self.finishFavoriteEdit()

    @objc.python_method
    def finishFavoriteEdit(self):
        self.saveFavorites()
        self.refreshFavorites()
        self.syncFavoritesQueue()
        self.refreshRows()
        self.updateUI()

    @objc.python_method
    def syncFavoritesQueue(self):
        """Keep the playing queue in step when favorites mode is what's on."""
        if self.mode != "favorites":
            return
        playing = self.currentPath()
        live = [p for p in self.favorites if os.path.isfile(p)]
        self.playlist = live
        self.reshuffle()
        if playing in live:
            self.index = live.index(playing)    # untouched, so don't restart it
            self.rebuildRows()
        elif live:
            self.index = min(self.index, len(live) - 1)
            self.rebuildRows()
            self.playIndex(self.index)
        else:
            self.index = 0
            self.rebuildRows()

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
    def askText(self, title, detail, initial=""):
        """A one-line text prompt. Returns None if it was cancelled."""
        alert = NSAlert.alloc().init()
        alert.setMessageText_(title)
        alert.setInformativeText_(detail)
        alert.addButtonWithTitle_("Save")
        alert.addButtonWithTitle_("Cancel")
        field = NSTextField.alloc().initWithFrame_(NSMakeRect(0, 0, 300, 24))
        field.setStringValue_(initial)
        alert.setAccessoryView_(field)
        # Otherwise the buttons take focus and you have to click into the box
        alert.window().setInitialFirstResponder_(field)
        if alert.runModal() != FIRST_BUTTON:
            return None
        return str(field.stringValue())

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
        self.syncTagsMenu()              # ...and the ticks on its tags

        if not path:
            self.window.setTitle_(APP_NAME)
            self.favItem.setTitle_("Add to Favorites")
            self.favButton.setTitle_("☆  Favorite")
            return

        starred = path in self.favorites
        label = {"favorites": "Favorites",
                 "tag": "“%s”" % (self.tagName or "")}.get(self.mode, "Folder")
        # Anything other than the plain defaults is worth saying out loud, so
        # nobody wonders why a folder is playing out of order or sounds odd.
        if self.repeat != REPEAT_ALL:
            label += " · " + ORDER_NAMES[self.repeat]
        if self.speed != NORMAL_SPEED:
            label += " · %g×" % self.speed
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
