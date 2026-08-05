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
    AVAssetImageGenerator,
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
    NSImageView,
    NSMenu,
    NSMenuItem,
    NSNotificationCenter,
    NSObject,
    NSOpenPanel,
    NSPopUpButton,
    NSCharacterSet,
    NSScrollView,
    NSSearchField,
    NSTableColumn,
    NSTableView,
    NSTextField,
    NSTokenField,
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

# Starring a video is just tagging it with this. The ★ button and ⌘⇧D stay
# exactly as they were; underneath there is now one store instead of two.
FAVORITE_TAG = "Favorite"

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

# 2, not 1. AVPlayerViewControlsStyleInline is 1 and is also the default, so
# the old value quietly asked for inline controls glued to the bottom edge of
# the video — right where this app puts its own bar — instead of the floating
# HUD that appears wherever the pointer is.
CONTROLS_FLOATING = 2         # AVPlayerViewControlsStyleFloating
BAR_HEIGHT = 48
# 96 rather than a roomier width so a fourth button fits on the left at the
# 680pt minimum window size, instead of making everyone's window bigger.
BUTTON_W, BUTTON_H = 96, 30
SIDEBAR_W = 320
SIDEBAR_SLIDE = 0.22          # seconds
FILTER_H = 24
ROW_H, GROUP_H = 22, 20
DURATION_W = 52
NAME_TAG, TIME_TAG, CHIPS_TAG, THUMB_TAG = 1, 2, 3, 4
THUMB_W, THUMB_H = 64, 36     # 16:9, generated at twice this for retina
THUMB_ROW_H = 44              # a row carrying a poster frame
IMAGE_SCALE_FIT = 3           # NSImageScaleProportionallyUpOrDown
DURATION_BATCH = 25           # rows to measure between table refreshes
THUMB_BATCH = 4               # ...and when each row also costs a decoded frame
FAV_W, FAV_H = 460, 420
FAV_NOTE_W = 130

TAG_PANEL_H = 136             # the tag editor, sliding up over the video
CHIP_H = 17
CHIP_PAD = 7
SUGGEST_MAX = 12              # tags offered as one-click chips; type for the rest
TAG_ROW_H = 38                # a row showing its tags; untagged rows stay ROW_H

VIBRANCY_SIDEBAR = 7          # NSVisualEffectMaterialSidebar
VIBRANCY_ACTIVE = 0           # NSVisualEffectStateFollowsWindowActiveState
STATUS_READY, STATUS_FAILED = 1, 2
NS_OK = 1
FIRST_BUTTON = 1000
STATE_ON, STATE_OFF = 1, 0    # NSControlStateValue
BEZEL_INLINE = 15             # NSBezelStyleInline — the small pill look
ALIGN_RIGHT = 2               # NSTextAlignmentRight
ALIGN_CENTER = 1              # NSTextAlignmentCenter
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
    # The scratch name carries the pid: two copies of the app running at once
    # would otherwise race for one ".tmp" and whichever lost would blow up
    # renaming a file the other had already moved.
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w") as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, path)     # never leave a half-written file
    except OSError:
        try:
            os.remove(tmp)        # don't litter if the write failed
        except OSError:
            pass
        raise


class ChipHolder(NSView):
    """Holds a row's tag chips.

    A plain NSView's tag is read-only — only controls can be given one — so
    viewWithTag_ could never find this. Answering for itself is the cheapest
    way to stay findable in a reused row.
    """

    def tag(self):
        return CHIPS_TAG


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
        self.thumbs = {}
        self.durationGen = 0
        self.tagName = None           # which tag is playing, in tag mode
        self.tagWindow = None
        self.tagTable = None
        self.tagRows = []
        self.tagItems = []
        self.loadTags()
        self.loadState()
        self.migrateFavorites()

        self.setDockIcon()
        self.buildMenu()
        self.buildWindow()
        self.updateUI()
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            PROGRESS_TICK, self, "recordProgress:", None, True)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        # No dialog on the way in. If there is something to carry on with, it
        # just carries on; if not, the window says what to do and waits.
        self.performSelector_withObject_afterDelay_("resumeLastSession", None, 0.1)

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
    def favoriteList(self):
        return self.taggedWith(FAVORITE_TAG)

    @objc.python_method
    def isFavorite(self, path):
        return self.hasTag(path, FAVORITE_TAG)

    @objc.python_method
    def migrateFavorites(self):
        """Fold an older version's favorites.json into the Favorite tag.

        Runs once, unprompted, at launch. favorites.json is left exactly where
        it is rather than deleted: it costs nothing to keep, it is the obvious
        thing to restore from, and an older build still reads it.

        Deliberately no isfile() check — a starred video on a drive that
        happens to be unmounted is still a favorite, and dropping it here
        would be the one migration bug there is no way back from.
        """
        if self.migrated or not os.path.exists(FAV_FILE):
            return
        starred = load_json(FAV_FILE, [])
        moved = 0
        for path in starred:
            if isinstance(path, str) and not self.hasTag(path, FAVORITE_TAG):
                self.setTagsFor(path, self.tagsFor(path) + [FAVORITE_TAG])
                moved += 1
        self.migrated = True
        if moved:
            self.saveTags()
        self.saveState()          # remember it is done, so it never re-runs

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
        self.migrated = bool(state.get("favoritesMigrated"))
        self.showThumbs = state.get("thumbnails") is not False

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
            "favoritesMigrated": self.migrated,
            "thumbnails": self.showThumbs,
        })

    @objc.python_method
    def currentPath(self):
        return self.playlist[self.index] if self.playlist else None

    def toggleFavorite_(self, sender):
        path = self.currentPath()
        if not path:
            return
        if self.isFavorite(path):
            self.setTagsFor(path, [n for n in self.tagsFor(path)
                                   if n.lower() != FAVORITE_TAG.lower()])
            # Playing the favorites, the list IS the queue, so unstarring
            # something has to take it out of the queue too.
            if self.tagName == FAVORITE_TAG and len(self.playlist) > 1:
                del self.playlist[self.index]
                if self.index >= len(self.playlist):
                    self.index = 0
                self.tagsChanged()
                self.reshuffle()
                return self.playIndex(self.index)
        else:
            self.setTagsFor(path, self.tagsFor(path) + [FAVORITE_TAG])
        self.tagsChanged()

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
        self.thumbItem = self.add(view, "Show Thumbnails", "toggleThumbnails:")
        self.thumbItem.setState_(STATE_ON if self.showThumbs else STATE_OFF)

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
        # Without this the floating controls only wake on a click, not on the
        # pointer moving across the video, which is what people expect.
        self.window.setAcceptsMouseMovedEvents_(True)
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
        self.prevButton = self.barButton("◀ Previous", "prevItem:", 14)
        self.nextButton = self.barButton("Next ▶", "nextItem:", 14 + BUTTON_W + 8)
        self.favButton = self.barButton("☆ Favorite", "toggleFavorite:",
                                        14 + 2 * (BUTTON_W + 8))
        self.tagButton = self.barButton("Tag ⌃", "toggleTagPanel:",
                                        14 + 3 * (BUTTON_W + 8))
        bar.addSubview_(self.prevButton)
        bar.addSubview_(self.nextButton)
        bar.addSubview_(self.favButton)
        bar.addSubview_(self.tagButton)

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

        # What an empty window says, instead of a dialog demanding an answer
        # before you have even seen the app.
        self.emptyHint = self.label(
            NSMakeRect(0, rect.size.height / 2 - 20, rect.size.width, 40),
            15, 0, dim=True)
        self.emptyHint.setAlignment_(ALIGN_CENTER)
        self.emptyHint.setStringValue_("Open a folder to start playing   ⌘O")
        self.emptyHint.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin
                                            | NSViewMaxYMargin)
        content.addSubview_(self.emptyHint)

        self.buildSidebar(content, rect)
        self.buildTagPanel(content, rect)

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

    # -- the tag panel ---------------------------------------------------

    @objc.python_method
    def buildTagPanel(self, content, rect):
        """A drawer that slides up out of the control bar.

        Non-modal on purpose: a modal sheet freezes every other control, and
        its run loop mode stops the progress timer, so a long edit quietly
        loses the position of whatever is playing.
        """
        self.tagPanelOpen = False
        self.tagTargets = []
        self.heldAdvance = False
        self.wasPlaying = False

        self.tagPanel = NSVisualEffectView.alloc().initWithFrame_(
            NSMakeRect(0, -TAG_PANEL_H, rect.size.width, TAG_PANEL_H))
        self.tagPanel.setMaterial_(VIBRANCY_SIDEBAR)
        self.tagPanel.setState_(VIBRANCY_ACTIVE)
        self.tagPanel.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)

        width = rect.size.width
        self.tagSubject = self.label(
            NSMakeRect(14, TAG_PANEL_H - 24, width - 28, 16), 11, 0, dim=True)
        self.tagSubject.setAutoresizingMask_(NSViewWidthSizable)

        self.tagField = NSTokenField.alloc().initWithFrame_(
            NSMakeRect(14, TAG_PANEL_H - 56, width - 28, 26))
        self.tagField.setAutoresizingMask_(NSViewWidthSizable)
        self.tagField.setTokenizingCharacterSet_(
            NSCharacterSet.characterSetWithCharactersInString_(","))
        self.tagField.setDelegate_(self)

        self.tagCaption = self.label(
            NSMakeRect(14, TAG_PANEL_H - 76, width - 28, 14), 11, 0, dim=True)
        self.tagCaption.setStringValue_("Tags you already use")
        self.tagCaption.setAutoresizingMask_(NSViewWidthSizable)

        self.chipRow = NSView.alloc().initWithFrame_(
            NSMakeRect(14, TAG_PANEL_H - 98, width - 28, CHIP_H))
        self.chipRow.setAutoresizingMask_(NSViewWidthSizable)

        self.tagSave = self.barButton("Save", "saveTagPanel:", width - 14 - BUTTON_W)
        self.tagSave.setFrameOrigin_((width - 14 - BUTTON_W, 10))
        self.tagSave.setAutoresizingMask_(NSViewMinXMargin)
        cancel = self.barButton("Cancel", "closeTagPanel:",
                                width - 22 - 2 * BUTTON_W)
        cancel.setFrameOrigin_((width - 22 - 2 * BUTTON_W, 10))
        cancel.setAutoresizingMask_(NSViewMinXMargin)
        cancel.setKeyEquivalent_("\033")          # Escape backs out

        for view in [self.tagSubject, self.tagField, self.tagCaption,
                     self.chipRow, self.tagSave, cancel]:
            self.tagPanel.addSubview_(view)
        content.addSubview_(self.tagPanel)

    @objc.python_method
    def tagPanelFrame(self):
        content = self.window.contentView().frame()
        # Stop short of the playlist drawer rather than sliding underneath it
        width = content.size.width - (SIDEBAR_W if self.sidebarOpen else 0)
        y = BAR_HEIGHT if self.tagPanelOpen else -TAG_PANEL_H
        return NSMakeRect(0, y, width, TAG_PANEL_H)

    def toggleTagPanel_(self, sender):
        if self.tagPanelOpen:
            return self.closeTagPanel_(sender)
        paths = self.selectedPaths()
        if not paths:
            return self.say("Nothing to tag", "Play a video first, or pick rows "
                                              "in the playlist.")
        # Pinned to what was playing when it opened: the video can move on
        # underneath a non-modal panel, and Save must land where you meant it.
        self.tagTargets = paths
        if len(paths) == 1:
            self.tagSubject.setStringValue_(os.path.basename(paths[0]))
            self.tagField.setObjectValue_(list(self.tagsFor(paths[0])))
            self.tagSave.setTitle_("Save")
        else:
            self.tagSubject.setStringValue_(
                "%d videos — tags are added, nothing is removed" % len(paths))
            self.tagField.setObjectValue_([])
            self.tagSave.setTitle_("Add Tags")
        # Hold the video still while you label it. Anything that was already
        # paused stays paused, so closing never starts something unbidden.
        self.wasPlaying = self.player.rate() != 0
        if self.wasPlaying:
            self.player.pause()
        self.fillSuggestions()
        self.slideTagPanel(True)
        self.window.makeFirstResponder_(self.tagField)

    def closeTagPanel_(self, sender):
        self.slideTagPanel(False)
        self.tagTargets = []
        self.window.makeFirstResponder_(self.playerView)
        resume, self.wasPlaying = self.wasPlaying, False
        if self.heldAdvance:
            # You set it playing again from the on-screen controls and it ran
            # to the end while the panel was up. Move on now instead.
            self.heldAdvance = False
            nxt = self.followOn()
            if nxt is not None:
                return self.playIndex(nxt)
        elif resume:
            self.player.play()

    def saveTagPanel_(self, sender):
        names = parse_tags(", ".join(str(t) for t in self.tagField.objectValue() or []))
        self.applyTags(self.tagTargets, names)
        self.closeTagPanel_(sender)
        self.tagsChanged()

    @objc.python_method
    def applyTags(self, paths, names):
        if len(paths) == 1:
            # One video: the field is the whole truth, so a tag removed from
            # it is removed from the video.
            self.setTagsFor(paths[0], names)
            return
        # Several: only ever add. Replacing would wipe tags the others had.
        for name in names:
            for path in paths:
                if not self.hasTag(path, name):
                    self.setTagsFor(path, self.tagsFor(path) + [name])

    @objc.python_method
    def slideTagPanel(self, open_):
        self.tagPanelOpen = open_
        self.tagButton.setTitle_("Tag ⌄" if open_ else "Tag ⌃")
        NSAnimationContext.beginGrouping()
        NSAnimationContext.currentContext().setDuration_(SIDEBAR_SLIDE)
        self.tagPanel.animator().setFrame_(self.tagPanelFrame())
        NSAnimationContext.endGrouping()

    @objc.python_method
    def fillSuggestions(self):
        """Chips for tags already in use, most-used first, laid out to fit."""
        for old in list(self.chipRow.subviews()):
            old.removeFromSuperview()
        already = [str(t).lower() for t in self.tagField.objectValue() or []]
        self.suggestButtons = []
        width = self.chipRow.frame().size.width
        x = 0
        for name in self.popularTags():
            if name.lower() in already:
                continue
            chip = self.suggestionChip(name)
            chipWidth = chip.frame().size.width + CHIP_PAD
            if x and x + chipWidth > width:
                break                     # one row; the rest are reachable by typing
            chip.setFrame_(NSMakeRect(x, 0, chipWidth, CHIP_H))
            self.chipRow.addSubview_(chip)
            x += chipWidth + 5
        self.tagCaption.setHidden_(not self.chipRow.subviews())

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
        # The tag panel stops at the drawer's edge, so it moves with it
        self.tagPanel.animator().setFrame_(self.tagPanelFrame())
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
            self.tagPanel.setFrame_(self.tagPanelFrame())

    def tableViewSelectionDidChange_(self, notification):
        # Ignore selection we set ourselves while following playback, otherwise
        # every track change would re-trigger itself.
        table = notification.object()
        if self.syncing or self.isTagTable(table):
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

    def numberOfRowsInTableView_(self, tableView):
        if self.isTagTable(tableView):
            return len(self.tagRows)
        return len(self.rows)

    def tableView_isGroupRow_(self, tableView, row):
        return self.isPlainRow(tableView, row) is None

    def tableView_shouldSelectRow_(self, tableView, row):
        return self.isPlainRow(tableView, row) is not None

    def tableView_heightOfRow_(self, tableView, row):
        index = self.isPlainRow(tableView, row)
        if index is None:
            return GROUP_H
        if self.isTagTable(tableView):
            return ROW_H
        if self.showThumbs:
            return THUMB_ROW_H            # a poster frame needs the same room either way
        # Only a tagged video pays for the second line; the rest stay dense.
        return TAG_ROW_H if self.tagsFor(self.playlist[index]) else ROW_H

    @objc.python_method
    def isPlainRow(self, tableView, row):
        """The playlist index for a selectable row, or None for a heading."""
        if self.isTagTable(tableView):
            return row                    # the manager is all plain rows
        if not 0 <= row < len(self.rows):
            return None
        return self.rows[row][0]

    def tableView_viewForTableColumn_row_(self, tableView, column, row):
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
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, SIDEBAR_W, THUMB_ROW_H))
        shot = NSImageView.alloc().initWithFrame_(
            NSMakeRect(6, 4, THUMB_W, THUMB_H))
        shot.setImageScaling_(IMAGE_SCALE_FIT)
        shot.setTag_(THUMB_TAG)
        name = self.label(NSMakeRect(8, 0, SIDEBAR_W - DURATION_W - 40, ROW_H - 2),
                          12, NAME_TAG)
        length = self.label(
            NSMakeRect(SIDEBAR_W - DURATION_W - 24, 0, DURATION_W, ROW_H - 2),
            11, TIME_TAG, align=ALIGN_RIGHT, dim=True)
        length.setAutoresizingMask_(NSViewMinXMargin | NSViewMinYMargin)
        chips = ChipHolder.alloc().initWithFrame_(
            NSMakeRect(8, 2, SIDEBAR_W - 30, CHIP_H))
        for part in [shot, name, length, chips]:
            view.addSubview_(part)
        return view

    @objc.python_method
    def videoRow(self, tableView, index, name):
        view = self.reuse(tableView, "video", self.buildVideoRow)
        path = self.playlist[index]
        view.viewWithTag_(NAME_TAG).setStringValue_(
            ("★  " if self.isFavorite(path) else "") + name)
        seconds = self.durations.get(path)
        view.viewWithTag_(TIME_TAG).setStringValue_(clock(seconds) if seconds else "")
        shot = view.viewWithTag_(THUMB_TAG)
        shot.setHidden_(not self.showThumbs)
        shot.setImage_(self.thumbs.get(path) if self.showThumbs else None)
        self.fillChips(view, self.tagsFor(path))
        return view

    @objc.python_method
    def fillChips(self, view, names):
        """Lay a row's tags out as chips. Rows are reused, so start clean."""
        chips = view.viewWithTag_(CHIPS_TAG)
        for old in list(chips.subviews()):
            old.removeFromSuperview()
        height = view.frame().size.height
        width = view.frame().size.width
        left = 8
        if self.showThumbs:
            view.viewWithTag_(THUMB_TAG).setFrame_(
                NSMakeRect(6, (height - THUMB_H) / 2, THUMB_W, THUMB_H))
            left = 6 + THUMB_W + 8

        # The name shares the row with its chips, so it rides the upper line
        # when there are any and sits centred when there are not.
        top = height - ROW_H + 1 if names else (height - ROW_H) / 2 + 1
        name = view.viewWithTag_(NAME_TAG)
        name.setFrame_(NSMakeRect(left, top, width - left - DURATION_W - 26,
                                  ROW_H - 2))
        length = view.viewWithTag_(TIME_TAG)
        length.setFrameOrigin_((length.frame().origin.x, top))
        chips.setFrame_(NSMakeRect(left, 3, width - left - 22, CHIP_H))
        if not names:
            return
        x = 0
        for chip in [self.chip(n) for n in names]:
            width = chip.frame().size.width
            if x and x + width > chips.frame().size.width:
                break                       # a narrow drawer shows what fits
            chip.setFrameOrigin_((x, 0))
            chips.addSubview_(chip)
            x += width + 4

    @objc.python_method
    def chip(self, name):
        field = self.label(NSMakeRect(0, 0, 10, CHIP_H), 10, 0, dim=True)
        field.setStringValue_(" %s " % name)
        field.setDrawsBackground_(True)
        field.setBackgroundColor_(NSColor.quaternaryLabelColor())
        field.sizeToFit()
        field.setWantsLayer_(True)
        field.layer().setCornerRadius_(CHIP_H / 2.0)
        field.layer().setMasksToBounds_(True)
        return field

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

    @objc.python_method
    def wanted(self, path):
        return path not in self.durations or (self.showThumbs
                                              and path not in self.thumbs)

    @objc.python_method
    def posterFrame(self, asset, seconds):
        """A frame from a little way in — opening frames are so often black."""
        maker = AVAssetImageGenerator.assetImageGeneratorWithAsset_(asset)
        maker.setAppliesPreferredTrackTransform_(True)
        maker.setMaximumSize_((THUMB_W * 2, THUMB_H * 2))
        at = min(max(seconds * 0.1, 1.0), 20.0) if seconds else 1.0
        try:
            image, _ = maker.copyCGImageAtTime_actualTime_error_(
                CMTimeMakeWithSeconds(at, 600), None, None)
        except Exception:
            return None                   # unreadable, or no video track at all
        return NSImage.alloc().initWithCGImage_size_(image, (0, 0)) if image else None

    def scanDurations_(self, generation):
        pool = NSAutoreleasePool.alloc().init()
        try:
            generation = int(generation)
            # One asset per file, answering both questions, rather than opening
            # everything twice.
            todo = [p for p in self.playlist if self.wanted(p)]
            for n, path in enumerate(todo):
                if generation != self.durationGen:
                    return                # the playlist moved on; drop this pass
                asset = AVURLAsset.URLAssetWithURL_options_(
                    NSURL.fileURLWithPath_(path), None)
                seconds = CMTimeGetSeconds(asset.duration())
                seconds = seconds if seconds == seconds and seconds > 0 else 0
                self.durations[path] = seconds
                if self.showThumbs and path not in self.thumbs:
                    self.thumbs[path] = self.posterFrame(asset, seconds)
                batch = THUMB_BATCH if self.showThumbs else DURATION_BATCH
                if n % batch == batch - 1:
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "durationsArrived:", None, False)
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "durationsArrived:", None, False)
        finally:
            del pool

    def durationsArrived_(self, _):
        self.refreshRows()

    def toggleThumbnails_(self, sender):
        self.showThumbs = not self.showThumbs
        self.thumbItem.setState_(STATE_ON if self.showThumbs else STATE_OFF)
        if self.showThumbs:
            self.loadDurations()          # collect the frames we skipped before
        self.refreshRows()
        self.saveState()

    @objc.python_method
    def refreshRows(self):
        """Redraw the rows we already have — a star changed, or a duration."""
        self.syncing = True           # reloading must not look like a click
        try:
            self.table.reloadData()
        finally:
            self.syncing = False
        self.revealCurrentRow()

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
        if mode == "tag":
            tag = self.session.get("tag")
            return "“%s”" % tag if tag and self.taggedWith(tag) else None
        root = self.session.get("root")
        return (os.path.basename(root) or root) if root else None

    @objc.python_method
    def playableTags(self):
        """Tags with something left to play, favorites first, then alphabetical."""
        counts = []
        for name in self.knownTags():
            live = sum(1 for p in self.taggedWith(name) if os.path.isfile(p))
            if live:
                counts.append((name, live))
        counts.sort(key=lambda t: (t[0].lower() != FAVORITE_TAG.lower(), t[0].lower()))
        return counts

    @objc.python_method
    def openingChoices(self, tags=()):
        """Buttons for the opening dialog, paired with what each one does.

        Neither the resume nor the tag button always exists, so the positions
        shift; keeping titles and actions together avoids matching on button
        index.
        """
        choices = []
        # Only worth offering at startup — mid-playback the last session is
        # whatever is already on screen.
        resume = self.sessionLabel() if not self.playlist else None
        if resume:
            choices.append(("Resume %s" % resume, "resume"))
        choices.append(("Choose Folder…", "folder"))
        if tags:
            # One button plus a popup, rather than a button per tag: the list
            # grows without limit and an alert's buttons do not.
            choices.append(("Play Tag", "tag"))
        # Always just backing out: this dialog is only ever opened on purpose,
        # so it has no business quitting the app.
        choices.append(("Cancel", "dismiss"))
        return choices

    def resumeLastSession(self):
        """Carry on from last time, quietly, or leave the window waiting.

        Nothing is announced here. A folder that has since been renamed, or
        sits on a drive that is not mounted, must not greet you with an error
        the moment you open the app — the empty window already says what to do.
        """
        if self.sessionLabel():
            self.resumeSession(quiet=True)

    def showOpeningChoice(self):
        """Only ever reached on purpose now, from Open New… or ⌘N."""
        alert = NSAlert.alloc().init()
        alert.setMessageText_(APP_NAME)
        alert.setInformativeText_(
            "Choose a folder and every video in it plays in order, then repeats.")

        tags = self.playableTags()
        if tags:
            picker = NSPopUpButton.alloc().initWithFrame_pullsDown_(
                NSMakeRect(0, 0, 260, 25), False)
            for name, count in tags:
                picker.addItemWithTitle_("%s  (%d)" % (name, count))
            picker.selectItemAtIndex_(0)      # favorites, when there are any
            alert.setAccessoryView_(picker)

        choices = self.openingChoices(tags)
        for title, _ in choices:
            alert.addButtonWithTitle_(title)

        choice = choices[alert.runModal() - FIRST_BUTTON][1]
        if choice == "resume":
            self.resumeSession()
        elif choice == "folder":
            self.chooseFolder_(None)
        elif choice == "tag":
            self.startTag(tags[picker.indexOfSelectedItem()][0])

    @objc.python_method
    def resumeSession(self, quiet=False):
        """Pick up the folder, the video and the position we left off at."""
        session, self.session = self.session, {}
        # One attempt only: if that folder has gone, Open New… comes back
        # without a Resume button rather than offering it over and over.
        if session.get("mode") == "tag":
            return self.startTag(session.get("tag"), session.get("path"), quiet)
        self.openFolder(session.get("root"), session.get("path"), quiet)

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
    def openFolder(self, root, resume=None, quiet=False):
        root = str(root)
        if not os.path.isdir(root):
            self.forgetFolder(root)
            if quiet:
                return
            return self.say("That folder is not available.",
                            "%s could not be opened. It may have been renamed or "
                            "moved, or it may be on a drive that is not mounted "
                            "right now." % root)
        found = scan(root)
        if not found:
            if quiet:
                return
            return self.say("No playable videos in that folder.",
                            "Looked for %s files, including subfolders."
                            % ", ".join(sorted(VIDEO_EXT)))
        self.rememberFolder(root)
        self.startPlaylist(found, "folder", root, resume)

    def playTag_(self, sender):
        self.startTag(str(sender.representedObject()))

    @objc.python_method
    def startTag(self, tag, resume=None, quiet=False):
        live = [p for p in self.taggedWith(tag) if os.path.isfile(p)]
        if not live:
            if quiet:
                return
            return self.say(
                "Nothing to play for “%s”" % tag,
                "Every video with that tag has been moved, renamed or deleted. "
                "Manage Tags will clear out the entries that no longer point "
                "at anything.")
        live.sort(key=lambda p: natural_key(os.path.basename(p)))
        self.tagName = tag
        self.startPlaylist(live, "tag", None, resume)

    def playFavorites_(self, sender):
        self.startTag(FAVORITE_TAG)

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
        if self.tagPanelOpen:
            # Hold here rather than moving on under an open tag panel: you are
            # looking at this video because you are labelling it.
            self.heldAdvance = True
            return self.player.pause()
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
        self.add(self.tagsMenu, "Edit Tags…", "toggleTagPanel:", "t",
                 NSEventModifierFlagCommand)

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

    @objc.python_method
    def suggestionChip(self, name):
        button = NSButton.alloc().initWithFrame_(NSMakeRect(0, 0, 10, CHIP_H))
        button.setTitle_(name)
        button.setBezelStyle_(BEZEL_INLINE)
        button.setFont_(NSFont.systemFontOfSize_(11))
        button.setTarget_(self)
        button.setAction_("addSuggestedTag:")
        button.sizeToFit()
        return button

    def addSuggestedTag_(self, sender):
        name = str(sender.title())
        current = [str(t) for t in self.tagField.objectValue() or []]
        if not any(n.lower() == name.lower() for n in current):
            self.tagField.setObjectValue_(current + [name])
        sender.setEnabled_(False)         # it is in the field now

    @objc.python_method
    def popularTags(self):
        """Most-used first, so the chips stay useful once there are dozens."""
        return sorted(self.knownTags(),
                      key=lambda n: (-len(self.taggedWith(n)), n.lower()))[:SUGGEST_MAX]

    def tokenField_completionsForSubstring_indexOfToken_indexOfSelectedItem_(
            self, field, substring, index, selected):
        needle = str(substring).lower()
        return [n for n in self.knownTags() if n.lower().startswith(needle)]

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

    def windowWillClose_(self, notification):
        closing = notification.object()
        if self.tagWindow is not None and closing.isEqual_(self.tagWindow):
            # Drop the table first: every shared table callback keys off it
            self.tagTable = None
            self.tagWindow = None
        elif closing.isEqual_(self.window) and self.tagWindow is not None:
            # Otherwise closing the player leaves the app alive behind a stray
            # utility window instead of quitting.
            self.tagWindow.close()

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
    def buildManagerRow(self):
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
    def tagManagerRow(self, tableView, row):
        view = self.reuse(tableView, "tagrow", self.buildManagerRow)
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
        detail = ("It is removed from %d video%s. The videos themselves are not "
                  "touched." % (len(paths), "" if len(paths) == 1 else "s"))
        if name.lower() == FAVORITE_TAG.lower():
            # This one is the ★ button's tag. Deleting it is allowed — it is a
            # tag like any other — but it must never be a surprise.
            detail += ("\n\nThis is the tag behind the ★ button, so every one "
                       "of your favorites would be unstarred.")
        if not self.confirm("Delete the tag “%s”?" % name, detail, "Delete"):
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
        self.tagButton.setEnabled_(bool(self.playlist))
        self.emptyHint.setHidden_(bool(self.playlist))
        self.revealCurrentRow()          # keep the highlight on what's playing
        self.syncTagsMenu()              # ...and the ticks on its tags

        if not path:
            self.window.setTitle_(APP_NAME)
            self.favItem.setTitle_("Add to Favorites")
            self.favButton.setTitle_("☆  Favorite")
            return

        starred = self.isFavorite(path)
        label = ("“%s”" % (self.tagName or "") if self.mode == "tag" else "Folder")
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
