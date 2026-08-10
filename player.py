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
import fnmatch
import getpass
import random
import hashlib
import re
import shutil
import ssl
import subprocess
import uuid
import tempfile
import time
import urllib.error
import urllib.request

try:
    import certifi                  # bundled; python.org builds have no system CA file
except ImportError:
    certifi = None

import objc
from AVFoundation import (
    AVAssetImageGenerator,
    AVURLAsset,
)
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
    NSMutableIndexSet,
    NSProgressIndicator,
    NSEventModifierFlagCommand,
    NSEventModifierFlagControl,
    NSEventModifierFlagShift,
    NSColor,
    NSFileManager,
    NSFont,
    NSMakePoint,
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
    NSClickGestureRecognizer,
    NSScrollView,
    NSSearchField,
    NSSlider,
    NSPanel,
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
    NSWindowStyleMaskUtilityWindow,
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

# Where macOS hangs mounted shares. Stripping it is what makes a tag mean the
# same thing on a Mac and on an Apple TV, which reaches the same NAS over SMB
# and never sees a /Volumes at all.
VOLUMES = "/Volumes/"

# Where a share keeps its copies of the tags, for other devices to read.
# scan() skips dot-directories, so none of this turns up as media.
SHARE_DIR = ".FolderVideoPlayer"
LEGACY_TAGS = os.path.join(SHARE_DIR, "tags.json")

# Each person gets a folder and each of their devices a file inside it:
#
#     .FolderVideoPlayer/richard/tags-macbook.json
#                               /tags-appletv.json
#
# Person, so several people sharing a NAS never overwrite each other. Device,
# because one person with a Mac and an Apple TV is still two writers, and two
# writers on one file is how tags get quietly lost.
#
# A folder rather than a longer filename, because names get flattened to
# alphanumerics and dashes — so "tags-richard-*" would also match
# "tags-richard-tang-macbook", and Richard would quietly swallow Richard
# Tang's library. A directory boundary cannot be ambiguous that way.
#
# Putting a name on a folder organises tags. It does not hide them: anyone who
# can read the share can read all of it.
DEVICE_TAGS = "tags-%s.json"

# What AVFoundation can actually decode. .mkv and .avi are deliberately absent.
# What VLC will play. AVFoundation managed three of these; the rest — .flv
# most of all — is why the app carries VLCKit at all.
VIDEO_EXT = {".mp4", ".m4v", ".mov", ".flv", ".webm", ".avi",
             ".mkv", ".wmv", ".mpg", ".mpeg", ".m2ts", ".ts", ".rm", ".rmvb",
             ".3gp", ".ogv", ".divx", ".vob", ".asf", ".f4v"}

# The three AVFoundation can read. Poster frames and durations use it for
# those, because it does the job in 0.6s where VLC takes 1.5 to 4 — and on a
# library that is mostly .mp4 that difference is the whole scan.
FAST_EXT = {".mp4", ".m4v", ".mov"}

# VLCMediaPlayerState, from VLCMediaPlayer.h
VLC_STOPPED, VLC_ENDED, VLC_ERROR, VLC_PLAYING, VLC_PAUSED = 0, 3, 4, 5, 6

# How close to the end counts as having finished. VLC's last reported time
# sits a little short of the stated length, so this cannot be zero.
END_SLACK = 1.5

# Duplicate detection. 64 KB from each end is enough that two different videos
# colliding is not a thing that happens, and small enough that the cost per
# file is the round trip rather than the file.
FP_CHUNK = 64 * 1024
HASH_BLOCK = 4 * 1024 * 1024      # reading a whole file, for the final check
FP_FILE = os.path.join(SUPPORT, "fingerprints.json")
FP_MAX = 40000                    # older entries age out before the file does

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

BAR_HEIGHT = 48
# The main window's bar is taller: it carries the scrubber on its own row
# above the buttons, because AVKit no longer draws one for us.
MAIN_BAR_H = 74
SCRUB_H = 26
TIME_W = 58
XPORT_W = 42                  # a transport button holds a glyph, not a word
# 96 rather than a roomier width so a fourth button fits on the left at the
# 680pt minimum window size, instead of making everyone's window bigger.
BUTTON_W, BUTTON_H = 96, 30
SIDEBAR_W = 320
SIDEBAR_SLIDE = 0.22          # seconds
FILTER_H = 24
ROW_H, GROUP_H = 22, 20
SELECT_H = 22
DURATION_W = 52
NAME_TAG, TIME_TAG, CHIPS_TAG, THUMB_TAG = 1, 2, 3, 4
THUMB_W, THUMB_H = 64, 36     # 16:9, generated at twice this for retina
THUMB_ROW_H = 44              # a row carrying a poster frame
IMAGE_SCALE_FIT = 3           # NSImageScaleProportionallyUpOrDown
DURATION_BATCH = 25           # rows to measure between table refreshes
THUMB_BATCH = 4               # ...and when each row also costs a decoded frame
FAV_W, FAV_H = 460, 420
DUPE_W, DUPE_H = 780, 640
DUPE_ROW_H = 22
DUPE_HEAD_H = 22              # the column headings above the results
# The columns of a result row. The header strip is laid out from these same
# four numbers, so it cannot drift out of line with the rows beneath it.
DUPE_SN_X, DUPE_SN_W = 10, 40
DUPE_KEEP_X, DUPE_KEEP_W = 58, 72
DUPE_NAME_X = 140
DUPE_DECIDE_W = 110           # the right-hand column: why this copy is the keeper
KEEP_TAG = 5
SN_TAG = 7
RADIO_BUTTON = 4              # NSButtonTypeRadio
SWITCH_BUTTON = 3             # NSButtonTypeSwitch
FAV_NOTE_W = 130

# Previewing a duplicate before deciding its fate. Its own window and its own
# player: loading a candidate into the main one would lose your place in the
# playlist and count as watching something you were only inspecting.
PREVIEW_W, PREVIEW_H = 640, 420
PREVIEW_BAR_H = 44
PREVIEW_TICK = 0.25           # the preview has no delegate, so it is polled

TAG_PANEL_H = 136             # the tag editor, sliding up over the video
CHIP_H = 17
CHIP_PAD = 7
SUGGEST_MAX = 12              # tags offered as one-click chips; type for the rest
TAG_ROW_H = 38                # a row showing its tags; untagged rows stay ROW_H

VIBRANCY_SIDEBAR = 7          # NSVisualEffectMaterialSidebar
VIBRANCY_ACTIVE = 0           # NSVisualEffectStateFollowsWindowActiveState
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
def tag_key(path):
    """What a tagged video is filed under.

    A file on a mounted share is keyed share-relative — "private/clips/a.mp4"
    rather than "/Volumes/private/clips/a.mp4" — because that is the one form
    a Mac and an Apple TV both arrive at for the same file. Anything else
    keeps its absolute path, which is the honest answer: a video in your home
    folder is not portable, and pretending otherwise would lose tags rather
    than move them.
    """
    return path[len(VOLUMES):] if path.startswith(VOLUMES) else path


@objc.python_method
def tag_path(key):
    """Back to something this Mac can actually open."""
    return key if key.startswith("/") else VOLUMES + key


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
def fingerprint(path, size=None):
    """A cheap identity for a video: its size, and both of its ends.

    Reading a whole file to find duplicates is the obvious design and the
    wrong one here. Measured on this library, hashing everything means moving
    about four terabytes over SMB. Reading FP_CHUNK from each end costs the
    same 128 KB whether the file is 4 MB or 400 MB — 0.227s a file over the
    wire — and two videos agreeing on their size and both ends are not
    plausibly different videos.

    Not proof, though, which is why removing anything can still verify in
    full. This is the sieve, not the verdict.
    """
    if size is None:
        size = os.path.getsize(path)
    digest = hashlib.blake2b(str(size).encode(), digest_size=16)
    with open(path, "rb") as handle:
        digest.update(handle.read(FP_CHUNK))
        if size > FP_CHUNK * 2:
            # Only worth a second read when the ends do not already overlap.
            handle.seek(-FP_CHUNK, os.SEEK_END)
            digest.update(handle.read(FP_CHUNK))
    return digest.hexdigest()


@objc.python_method
def full_hash(path, stop=None):
    """The whole file, for the handful that reach the last stage.

    `stop` is checked between blocks so a scan being cancelled does not have
    to finish reading a 4 GB file first.
    """
    digest = hashlib.blake2b(digest_size=16)
    with open(path, "rb") as handle:
        while True:
            if stop is not None and stop():
                return None
            block = handle.read(HASH_BLOCK)
            if not block:
                return digest.hexdigest()
            digest.update(block)


@objc.python_method
def duplicate_groups(index, verified_only=False):
    """The index turned into sets of files that are the same file.

    Grouped on the fingerprint, always. The full hash is a check applied
    inside a group, not a second way of grouping — keying on it meant a group
    that had only been half read, because a verify pass was stopped part way
    through it, split into a verified pair and an unverified leftover and
    then vanished from the results entirely. Losing sight of duplicates is an
    alarming thing for a feature about deleting files to do.

    Where two full hashes inside one group disagree, the fingerprint was
    wrong about at least one of them and the hashes win: the group splits by
    hash, and anything not yet read is left out until it has been, since
    there is no way to say which side it belongs on.
    """
    candidates = {}
    for key, entry in index.items():
        mark = entry.get("fp")
        if mark:
            candidates.setdefault(mark, []).append(key)

    groups = []
    for keys in candidates.values():
        if len(keys) < 2:
            continue
        hashes = set(index[k].get("full") for k in keys if index[k].get("full"))
        if len(hashes) > 1:
            for mark in sorted(hashes):
                agree = sorted(k for k in keys if index[k].get("full") == mark)
                if len(agree) > 1:
                    groups.append(agree)
            continue
        if verified_only and not all(index[k].get("full") for k in keys):
            continue
        groups.append(sorted(keys))
    return groups


@objc.python_method
def size_candidates(sizes):
    """Keys whose size is shared with something else — the only ones worth reading.

    Four files in five are eliminated here, for free, because the size came
    with the directory listing. A file with a size nothing else shares cannot
    be a byte-for-byte duplicate of anything.
    """
    counts = {}
    for size in sizes.values():
        counts[size] = counts.get(size, 0) + 1
    return sorted(key for key, size in sizes.items() if counts[size] > 1)


@objc.python_method
def human_bytes(count):
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if count < 1024 or unit == "TB":
            return "%d %s" % (count, unit) if unit == "bytes" else "%.1f %s" % (count, unit)
        count /= 1024.0


@objc.python_method
def when_words(stamp):
    """How long ago, in the words someone would actually use.

    A date is no use for deciding whether a scan is worth re-running; "three
    days ago" is exactly the question being asked.
    """
    gap = time.time() - stamp
    if gap < 90:
        return "just now"
    for size, unit, limit in ((60, "minute", 3600), (3600, "hour", 86400),
                              (86400, "day", 86400 * 7),
                              (86400 * 7, "week", 86400 * 63)):
        if gap < limit:
            count = int(gap // size)
            return "%d %s%s ago" % (count, unit, "" if count == 1 else "s")
    return "on " + time.strftime("%-d %b %Y", time.localtime(stamp))


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


@objc.python_method
def load_vlc():
    """Load VLCKit, from inside the app or from vendor/ when run from source.

    Not a build-time link: py2app copies the framework into the bundle and
    PyObjC opens it at startup, which keeps the dependency to one directory
    that can be fetched rather than committed.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    inside = NSBundle.mainBundle().privateFrameworksPath()
    for path in [os.path.join(inside, "VLCKit.framework") if inside else "",
                 os.path.join(here, "vendor", "VLCKit.framework"),
                 os.path.join(here, "..", "vendor", "VLCKit.framework")]:
        if path and os.path.isdir(path):
            try:
                objc.loadBundle("VLCKit", globals(), bundle_path=path)
                return True
            except Exception:
                continue
    return False


VLC_READY = load_vlc()


class ChipHolder(NSView):
    """Holds a row's tag chips.

    A plain NSView's tag is read-only — only controls can be given one — so
    viewWithTag_ could never find this. Answering for itself is the cheapest
    way to stay findable in a reused row.
    """

    def tag(self):
        return CHIPS_TAG


class KeyTable(NSTableView):
    """A table that hands the space bar and escape to its delegate.

    The arrow keys are left alone — NSTableView already moves the selection
    with them, which is what walking a group of copies wants. Space normally
    scrolls a page and escape does nothing, and here both mean something: the
    preview, opened and closed the way Quick Look does it.
    """

    def keyDown_(self, event):
        chars = str(event.charactersIgnoringModifiers() or "")
        delegate = self.delegate()
        if delegate is not None and chars == " ":
            return delegate.togglePreviewFromList_(self)
        if delegate is not None and chars == "\x1b":
            return delegate.closePreviewFromList_(self)
        NSTableView.keyDown_(self, event)


class PreviewPanel(NSPanel):
    """The preview window. A panel, so it can float without taking the keyboard.

    That is the whole trick behind Quick Look feeling the way it does: the
    list keeps the focus, so the arrow keys go on walking it and the preview
    follows. A window that made itself key would take the keyboard away and
    leave you clicking back and forth.
    """

    def cancelOperation_(self, sender):
        self.close()          # escape, while the panel itself has the focus


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
        self.revealedIndex = None
        self.scrubbing = False
        self.userPaused = False
        self.selectMode = False
        self.batch = set()          # playlist indices ticked for tagging
        self.batchAnchor = None     # row a shift-click extends from
        self.nameWindow = None
        self.nameTable = None
        self.nameRows = []
        self.prints = {}              # video key -> what we know of its identity
        self.dupeCache = None         # dupeSets(), until the index changes
        self.groupCache = None        # the derived results, until they change
        self.printGen = 0
        self.dupeWindow = None
        self.dupeTable = None
        self.dupeRows = []
        # A scan is a set of folders with a name, kept between launches. What
        # it found is not kept: results are derived from the fingerprint index
        # every time, so they cannot go stale, cannot disagree between two
        # scans that overlap, and cannot be hollowed out when the index ages an
        # entry out. The folders are the only part that could not be recomputed.
        self.scans = []               # [{id, name, folders, ran, seen, groups}]
        self.scanId = None            # the selected one; None is "Everything"
        self.scanPicker = None
        self.scanSummaryLabel = None
        self.sweptCount = 0           # videos the last sweep listed
        self.trashing = False         # a removal is running on another thread
        self.trashStop = False
        self.trashQueue = []
        self.trashSheet = None
        self.trashBar = None
        self.trashLabel = None
        self.trashDone = 0
        self.trashNow = ""
        self.trashMoved = 0
        self.trashFailed = []
        self.trashSkipped = 0
        self.dupeScanning = False
        self.dupeStop = False
        self.dupeStatus = ""
        self.dupeKeep = {}            # group id -> the key to keep
        # Copies you have said to leave alone. Kept between launches because
        # it is a decision, and one that a forgotten setting would undo by
        # quietly re-arming the Trash button against a file you spared.
        self.dupeSpared = set()
        self.verifyDupes = True
        self.dupeStatusLabel = None
        self.folderTable = None
        self.previewWindow = None
        self.previewVLC = None
        self.previewView = None
        self.previewPath = None
        self.previewTimer = None
        self.previewScrub = None
        self.previewPlay = None
        self.previewElapsed = None
        self.previewRemain = None
        self.previewScrubbing = False
        self.previewPausedMain = False
        self.tagName = None           # which tag is playing, in tag mode
        self.tagWindow = None
        self.tagTable = None
        self.tagRows = []
        self.tagItems = []
        self.loadTags()
        self.loadPrints()
        self.loadState()
        self.migrateFavorites()
        self.mergeShared()            # anything tagged on another device
        self.claimName()              # and say who we are, before tagging anything

        self.setDockIcon()
        self.buildMenu()
        self.buildWindow()
        self.updateUI()
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            PROGRESS_TICK, self, "recordProgress:", None, True)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        if not VLC_READY:
            self.emptyHint.setStringValue_(
                "VLCKit is missing — run Tools/fetch-vlckit.sh and rebuild")
            self.say("VLCKit is missing",
                     "This app plays video through VLCKit, which is fetched "
                     "rather than committed because it is 87 MB of somebody "
                     "else's code.\n\nRun Tools/fetch-vlckit.sh and build "
                     "again. Everything except playback still works meanwhile.")
        # Nothing plays on its own. Opening the app used to carry straight on
        # from wherever you stopped, which is the wrong default when the app
        # is opened to look something up rather than to keep watching —
        # File > Open New… offers to resume, and that is a decision, not an
        # ambush.

    def applicationShouldTerminateAfterLastWindowClosed_(self, sender):
        # Quit is Cmd-Q. Closing a window is not a request to lose your place,
        # your queue, or a folder scan that is halfway through.
        return False

    def applicationShouldHandleReopen_hasVisibleWindows_(self, app, visible):
        """Clicking the Dock icon brings the player back."""
        if not visible:
            self.window.makeKeyAndOrderFront_(None)
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        return True

    def applicationWillTerminate_(self, notification):
        self.notePosition()
        self.saveState()
        self.publishTags()                # in case a share came back late
        self.timer.invalidate()
        self.durationGen += 1         # tell any duration scan to give up
        self.detachItem()
        if getattr(self, "vlc", None) is not None:
            self.vlc.stop()

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
                    self.tags[tag_key(path)] = clean
        # An older file keyed on /Volumes paths is rewritten in place. This is
        # idempotent — a key that has already been shortened does not match
        # again — so it needs no flag to remember it was done.
        if self.tags != stored:
            self.saveTags()

    @objc.python_method
    def saveTags(self):
        save_json(TAGS_FILE, self.tags)

    @objc.python_method
    def tagsFor(self, path):
        return self.tags.get(tag_key(path), [])

    @objc.python_method
    def setTagsFor(self, path, names):
        key = tag_key(path)
        if names:
            self.tags[key] = names
        else:
            self.tags.pop(key, None)      # no empty lists left lying around

    @objc.python_method
    def shareTags(self):
        """The tags split by the share they live on, keyed from the share root.

        A device talking SMB sees "Richard/video/a.mp4" and has no idea what
        some Mac decided to call the mount point, so the share's own copy
        drops the share name. Local paths are left out entirely — they mean
        nothing anywhere else.
        """
        by_share = {}
        for key, names in self.tags.items():
            if key.startswith("/"):
                continue                  # a local file, portable nowhere
            share, _, rest = key.partition("/")
            if rest:
                by_share.setdefault(share, {})[rest] = names
        return by_share

    @objc.python_method
    def slug(self, text):
        """A filename-safe form of a name, so a person called "Anne Marie"
        and one called "anne-marie" cannot end up as two people."""
        clean = "".join(c if c.isalnum() else "-" for c in text.lower())
        return "-".join(part for part in clean.split("-") if part) or "unknown"

    @objc.python_method
    def myTagFolder(self):
        return os.path.join(SHARE_DIR, self.slug(self.person))

    @objc.python_method
    def myTagFile(self):
        return os.path.join(self.myTagFolder(), DEVICE_TAGS % self.slug(self.device))

    # -- duplicates ------------------------------------------------------

    @objc.python_method
    def loadPrints(self):
        self.prints = load_json(FP_FILE, {})
        self.dupesChanged()

    @objc.python_method
    def savePrints(self):
        if len(self.prints) > FP_MAX:
            # Oldest first. An index is a convenience, not a record, so it is
            # allowed to forget rather than grow without limit.
            order = sorted(self.prints, key=lambda k: self.prints[k].get("seen", 0))
            for key in order[:len(self.prints) - FP_MAX]:
                del self.prints[key]
        try:
            save_json(FP_FILE, self.prints)
        except OSError:
            pass                      # an index that cannot be saved still works

    @objc.python_method
    def printIsFresh(self, key, path):
        """Whether what we already know about this file is still true."""
        known = self.prints.get(key)
        if not known or not known.get("fp"):
            return False
        try:
            stat = os.stat(path)
        except OSError:
            return False              # gone; leave the entry for the sweep to clear
        return (known.get("size") == stat.st_size
                and abs(known.get("mtime", 0) - stat.st_mtime) < 1)

    @objc.python_method
    def takePrint(self, path, stat=None):
        """Fingerprint one file into the index. Returns its key, or None.

        128 KB of reading, wherever the file is and however big it is.
        """
        key = tag_key(path)
        try:
            stat = stat or os.stat(path)
            mark = fingerprint(path, stat.st_size)
        except OSError:
            return None
        self.prints[key] = {"size": stat.st_size, "mtime": stat.st_mtime,
                            "fp": mark, "full": None, "seen": time.time()}
        return key

    @objc.python_method
    def dupeSets(self):
        """Every group of two or more, as {key: [the others]}.

        Cached, because the playlist asks per row and again for every row
        height — recomputing over an index of tens of thousands on each of
        those would make scrolling crawl. Anything that changes the index
        clears it.
        """
        if self.dupeCache is None:
            out = {}
            for group in duplicate_groups(self.prints):
                # A copy taken out of the list is a decision already made, so
                # the playlist stops badging it and the while-playing notice
                # stops raising it. Nowhere should keep asking.
                live = [k for k in group if k not in self.dupeSpared]
                if len(live) < 2:
                    continue
                for key in live:
                    out[key] = [k for k in live if k != key]
            self.dupeCache = out
        return self.dupeCache

    @objc.python_method
    def dupesChanged(self):
        self.dupeCache = None
        self.groupCache = None        # the results are derived from the index

    @objc.python_method
    def dupesFor(self, path):
        """The other copies of this file that the index knows about."""
        return self.dupeSets().get(tag_key(path), [])

    @objc.python_method
    def noticeWhilePlaying(self, path):
        """Fingerprint what just started playing, off the main thread.

        The whole point of this mode is that it is not a scan: one file, the
        one you are already watching, 128 KB. Anything already known and
        unchanged costs nothing at all.
        """
        if not self.watchDupes or not path:
            return
        if self.printIsFresh(tag_key(path), path):
            return
        self.performSelectorInBackground_withObject_("printOne:", path)

    def printOne_(self, path):
        pool = NSAutoreleasePool.alloc().init()
        try:
            key = self.takePrint(path)
            if key:
                self.performSelectorOnMainThread_withObject_waitUntilDone_(
                    "printArrived:", key, False)
        finally:
            del pool

    def printArrived_(self, key):
        self.dupesChanged()
        self.savePrints()
        self.syncDupeMenu()
        # Only redraw when this actually changed what the list should say.
        if self.dupeSets().get(key):
            self.refreshRows()
        if self.dupeWindow is not None:
            self.refreshDupeManager()

    @objc.python_method
    def syncDupeMenu(self):
        """One item, carrying the count when there is one to carry.

        Counted the cheap way, from the index alone: this runs whenever a
        fingerprint arrives, and checking the disk for every file in every
        group would put a stat storm on a NAS behind a menu title.
        """
        groups = sum(1 for group in duplicate_groups(self.prints)
                     if sum(1 for k in group if k not in self.dupeSpared) > 1)
        self.dupeCountItem.setTitle_(
            "Find Duplicates… (%d found)" % groups if groups else "Find Duplicates…")
        self.watchItem.setState_(STATE_ON if self.watchDupes else STATE_OFF)
        # Titled with the count rather than greyed out when there is none:
        # the menu enables items itself unless the delegate validates them,
        # so setEnabled_ here would be a call that quietly does nothing.
        removed = len(self.dupeSpared)
        self.restoreItem.setTitle_("Put Removed Copies Back… (%d)" % removed
                                   if removed else "Put Removed Copies Back…")

    def toggleWatchDupes_(self, sender):
        self.watchDupes = not self.watchDupes
        self.syncDupeMenu()
        self.saveState()
        if self.watchDupes:
            self.noticeWhilePlaying(self.currentPath())

    # -- the Find Duplicates window ----------------------------------------

    @objc.python_method
    def openDupeWindow(self):
        if self.dupeWindow is not None:
            return self.dupeWindow.makeKeyAndOrderFront_(None)

        rect = NSMakeRect(0, 0, DUPE_W, DUPE_H)
        self.dupeWindow = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskResizable, NSBackingStoreBuffered, False)
        self.dupeWindow.setTitle_("Find Duplicates")
        self.dupeWindow.setMinSize_(NSMakeSize(640, 520))
        self.dupeWindow.center()
        self.dupeWindow.setReleasedWhenClosed_(False)
        self.dupeWindow.setDelegate_(self)

        content = NSView.alloc().initWithFrame_(rect)
        top = DUPE_H

        # which scan is on screen, and what it last did
        top -= BAR_HEIGHT
        picker = NSView.alloc().initWithFrame_(
            NSMakeRect(0, top, DUPE_W, BAR_HEIGHT))
        picker.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        self.scanPicker = NSPopUpButton.alloc().initWithFrame_pullsDown_(
            NSMakeRect(14, (BAR_HEIGHT - BUTTON_H) / 2, 250, BUTTON_H), False)
        self.scanPicker.setTarget_(self)
        self.scanPicker.setAction_("scanChosen:")
        picker.addSubview_(self.scanPicker)
        x = 14 + 250 + 8
        for title, action, width in (("New Scan…", "newScan:", 104),
                                     ("Rename…", "renameScan:", 88),
                                     ("Delete", "deleteScan:", 80)):
            picker.addSubview_(self.barButton(title, action, x, width=width))
            x += width + 8
        content.addSubview_(picker)

        top -= 22
        self.scanSummaryLabel = self.label(NSMakeRect(16, top, DUPE_W - 32, 18),
                                           11, 0, dim=True)
        self.scanSummaryLabel.setAutoresizingMask_(NSViewWidthSizable
                                                   | NSViewMinYMargin)
        content.addSubview_(self.scanSummaryLabel)

        # folders this scan looks through
        top -= 96
        self.folderTable = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, DUPE_W, 96))
        column = NSTableColumn.alloc().initWithIdentifier_("folder")
        column.setWidth_(DUPE_W - 24)
        self.folderTable.addTableColumn_(column)
        self.folderTable.setHeaderView_(None)
        self.folderTable.setRowHeight_(ROW_H)
        self.folderTable.setDataSource_(self)
        self.folderTable.setDelegate_(self)
        folders = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, top, DUPE_W, 96))
        folders.setDocumentView_(self.folderTable)
        folders.setHasVerticalScroller_(True)
        folders.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(folders)

        # the scan bar
        top -= BAR_HEIGHT
        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, top, DUPE_W, BAR_HEIGHT))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        bar.addSubview_(self.barButton("Add Folder…", "addDupeFolder:", 14))
        bar.addSubview_(self.barButton("Remove", "removeDupeFolder:", 14 + BUTTON_W + 8))
        # No Clear here. Emptying a scan's folders and then filling them again
        # is just a different scan, and there is a picker full of those.
        self.verifyBox = NSButton.alloc().initWithFrame_(
            NSMakeRect(14 + 2 * (BUTTON_W + 8), (BAR_HEIGHT - BUTTON_H) / 2,
                       190, BUTTON_H))
        self.verifyBox.setButtonType_(SWITCH_BUTTON)
        self.verifyBox.setTitle_("Verify byte-for-byte")
        self.verifyBox.setState_(STATE_ON if self.verifyDupes else STATE_OFF)
        self.verifyBox.setTarget_(self)
        self.verifyBox.setAction_("toggleVerify:")
        bar.addSubview_(self.verifyBox)
        self.scanButton = self.barButton("Scan", "startDupeScan:", DUPE_W - BUTTON_W - 14)
        self.scanButton.setAutoresizingMask_(NSViewMinXMargin)
        bar.addSubview_(self.scanButton)
        content.addSubview_(bar)

        # progress line
        top -= 24
        self.dupeStatusLabel = self.label(NSMakeRect(14, top, DUPE_W - 28, 20),
                                          11, 0, dim=True)
        self.dupeStatusLabel.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        content.addSubview_(self.dupeStatusLabel)

        # column headings, above the results and outside the scroll view so
        # they stay put rather than scrolling away with the first group
        top -= DUPE_HEAD_H
        content.addSubview_(self.dupeHeaderStrip(top))

        # results
        FOOT_H = 2 * BAR_HEIGHT       # two rows of buttons, laid out below
        self.dupeTable = KeyTable.alloc().initWithFrame_(
            NSMakeRect(0, 0, DUPE_W, top - FOOT_H))
        column = NSTableColumn.alloc().initWithIdentifier_("dupe")
        column.setWidth_(DUPE_W - 24)
        self.dupeTable.addTableColumn_(column)
        self.dupeTable.setHeaderView_(None)
        self.dupeTable.setRowHeight_(DUPE_ROW_H)
        self.dupeTable.setDataSource_(self)
        self.dupeTable.setDelegate_(self)
        self.dupeTable.setTarget_(self)
        self.dupeTable.setDoubleAction_("previewDuplicate:")
        # Several at once, because "keep these three" is one decision and
        # should not be three clicks in three different places.
        self.dupeTable.setAllowsMultipleSelection_(True)
        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, FOOT_H, DUPE_W, top - FOOT_H))
        scroll.setDocumentView_(self.dupeTable)
        scroll.setHasVerticalScroller_(True)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        content.addSubview_(scroll)

        # Two rows: deciding which copy survives, then what to do about it.
        # One row could not hold both without the labels shrinking to initials.
        foot = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, FOOT_H))
        foot.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)

        picks = NSView.alloc().initWithFrame_(
            NSMakeRect(0, BAR_HEIGHT, DUPE_W, BAR_HEIGHT))
        picks.setAutoresizingMask_(NSViewWidthSizable)
        caption = self.label(NSMakeRect(14, (BAR_HEIGHT - 18) / 2, 74, 18),
                             11, 0, dim=True, bold=True)
        caption.setStringValue_("Keep the")
        picks.addSubview_(caption)
        picks.addSubview_(self.barButton("Tagged", "keepTagged:", 92))
        picks.addSubview_(self.barButton("Oldest", "keepOldest:", 92 + BUTTON_W + 8))
        picks.addSubview_(self.barButton("Shortest Path", "keepShortest:",
                                         92 + 2 * (BUTTON_W + 8), width=118))
        foot.addSubview_(picks)

        acts = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, BAR_HEIGHT))
        acts.setAutoresizingMask_(NSViewWidthSizable)
        acts.addSubview_(self.barButton("Preview", "previewDuplicate:", 14))
        acts.addSubview_(self.barButton("Remove from List", "removeFromList:",
                                        14 + BUTTON_W + 8, width=140))
        self.reclaimLabel = self.label(
            NSMakeRect(DUPE_W - 350, (BAR_HEIGHT - 18) / 2, 170, 18),
            11, 0, align=ALIGN_RIGHT, dim=True)
        self.reclaimLabel.setAutoresizingMask_(NSViewMinXMargin)
        acts.addSubview_(self.reclaimLabel)
        self.removeButton = self.barButton("Move to Trash…", "removeDuplicates:",
                                           DUPE_W - 170, width=156)
        self.removeButton.setAutoresizingMask_(NSViewMinXMargin)
        acts.addSubview_(self.removeButton)
        foot.addSubview_(acts)
        content.addSubview_(foot)

        self.dupeWindow.setContentView_(content)
        self.dupeWindow.makeKeyAndOrderFront_(None)

    @objc.python_method
    def dupeHeaderStrip(self, bottom):
        """The row of column names above the results.

        Its own view rather than an NSTableHeaderView: the results are one
        wide column carrying a custom row, so a real header would have one
        title to show. Laid out from the same constants as the rows, so the
        two cannot drift apart.
        """
        strip = NSView.alloc().initWithFrame_(
            NSMakeRect(0, bottom, DUPE_W, DUPE_HEAD_H))
        strip.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        y = (DUPE_HEAD_H - 14) / 2
        columns = [
            ("#", DUPE_SN_X, DUPE_SN_W, ALIGN_RIGHT, 0),
            ("Keep", DUPE_KEEP_X, DUPE_KEEP_W, None, 0),
            ("File", DUPE_NAME_X, DUPE_W - DUPE_NAME_X - DUPE_DECIDE_W - 12,
             None, NSViewWidthSizable),
            ("Status", DUPE_W - DUPE_DECIDE_W - 10, DUPE_DECIDE_W, ALIGN_RIGHT,
             NSViewMinXMargin),
        ]
        for title, x, width, align, mask in columns:
            head = self.label(NSMakeRect(x, y, width, 14), 10, 0,
                              align=align, dim=True, bold=True)
            head.setStringValue_(title)
            if mask:
                head.setAutoresizingMask_(mask)
            strip.addSubview_(head)
        rule = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, 1))
        rule.setWantsLayer_(True)
        rule.layer().setBackgroundColor_(NSColor.separatorColor().CGColor())
        rule.setAutoresizingMask_(NSViewWidthSizable)
        strip.addSubview_(rule)
        return strip

    def toggleVerify_(self, sender):
        self.verifyDupes = self.verifyBox.state() == STATE_ON
        self.saveState()

    @objc.python_method
    def refreshDupeManager(self):
        if self.dupeTable is None:
            return
        # One flat list of rows: a heading, then the files under it. An outline
        # view would nest properly and cost a second data source for no gain
        # when nothing is ever collapsed.
        was = self.selectedDupeKey()      # a redraw must not lose your place
        self.dupeRows = []
        groups = self.dupeGroupsForDisplay()
        reclaim, doomed = 0, 0
        for number, group in enumerate(groups, 1):
            # "band" alternates per group, not per row, so a set reads as one
            # block however many copies are in it.
            band = number % 2
            self.dupeRows.append({"head": group, "sn": "%d" % number,
                                  "band": band})
            # Copies are numbered inside their set — 3.1, 3.2 — rather than
            # straight down the window. A running count would put the same
            # number in the column as the set heading above it, meaning two
            # different things, and it would not tell you which set a row
            # belongs to once its heading has scrolled off.
            for index, key in enumerate(group["keys"], 1):
                self.dupeRows.append({"group": group, "key": key, "band": band,
                                      "sn": "%d.%d" % (number, index)})

        self.syncScanPicker()
        self.folderTable.reloadData()
        self.dupeTable.reloadData()
        self.reselectDupe(was)
        self.updateDupeStatus()
        self.updateDupeTotals()

    @objc.python_method
    def updateDupeTotals(self):
        """The footer's two numbers, and whether the button can be pressed.

        Read off the groups already on screen, so editing one group can put
        this right without rebuilding the list.
        """
        if self.dupeTable is None:
            return
        groups = self.dupeGroupsForDisplay()
        reclaim = sum(g["reclaim"] for g in groups)
        doomed = sum(len(g["doomed"]) for g in groups)
        # What is actually going to happen, in both numbers: everything on
        # screen is a copy still in the running.
        self.reclaimLabel.setStringValue_(
            "%s · %d to remove" % (human_bytes(reclaim), doomed) if groups else
            "nothing left in the list" if self.dupeSpared else "")
        self.removeButton.setEnabled_(bool(doomed) and not self.dupeScanning
                                      and not self.trashing)

    @objc.python_method
    def updateDupeStatus(self):
        if self.dupeStatusLabel is None:
            return
        self.dupeStatusLabel.setStringValue_(self.dupeStatus)
        self.scanButton.setTitle_("Stop" if self.dupeScanning else "Scan")

    @objc.python_method
    def isDupeTable(self, view):
        return self.dupeTable is not None and view.isEqual_(self.dupeTable)

    @objc.python_method
    def isFolderTable(self, view):
        return self.folderTable is not None and view.isEqual_(self.folderTable)

    @objc.python_method
    def dupeManagerRow(self, tableView, row):
        item = self.dupeRows[row]
        if "head" in item:
            return self.dupeHeadRow(tableView, item["head"], item["sn"])

        group, key = item["group"], item["key"]
        keeping = key == group["keeper"]
        view = self.reuse(tableView, "dupefile", self.buildDupeRow)
        view.viewWithTag_(SN_TAG).setStringValue_(item["sn"])
        button = view.viewWithTag_(KEEP_TAG)
        button.setState_(STATE_ON if keeping else STATE_OFF)
        button.setTitle_("  Keep" if keeping else "")
        button.setToolTip_(key)
        button.setTarget_(self)
        button.setAction_("chooseKeeper:")
        name = view.viewWithTag_(NAME_TAG)
        name.setStringValue_("%s  —  %s" % (os.path.basename(key),
                                            os.path.dirname(key)))
        name.setTextColor_(NSColor.labelColor() if keeping
                           else NSColor.secondaryLabelColor())
        note = view.viewWithTag_(TIME_TAG)
        note.setStringValue_(group["why"] if keeping else "to Trash")
        note.setTextColor_(NSColor.secondaryLabelColor() if keeping
                           else NSColor.systemRedColor())
        return view

    @objc.python_method
    def dupeHeadRow(self, tableView, group, number):
        view = self.reuse(tableView, "dupehead", self.buildDupeHeadRow)
        view.viewWithTag_(SN_TAG).setStringValue_(number)
        view.viewWithTag_(NAME_TAG).setStringValue_(
            "%d copies · %s each%s" % (len(group["keys"]),
                                       human_bytes(group["size"]),
                                       "" if group["verified"] else " · not verified"))
        note = view.viewWithTag_(TIME_TAG)
        note.setStringValue_("frees %s" % human_bytes(group["reclaim"]))
        note.setTextColor_(NSColor.secondaryLabelColor())
        return view

    @objc.python_method
    def buildDupeHeadRow(self):
        """A set's heading: its number, what it holds, what it would free."""
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, DUPE_ROW_H))
        number = self.label(NSMakeRect(DUPE_SN_X, 2, DUPE_SN_W, DUPE_ROW_H - 4),
                            11, SN_TAG, align=ALIGN_RIGHT, bold=True)
        view.addSubview_(number)
        name = self.label(
            NSMakeRect(DUPE_KEEP_X, 2,
                       DUPE_W - DUPE_KEEP_X - DUPE_DECIDE_W - 12, DUPE_ROW_H - 4),
            11, NAME_TAG, bold=True)
        name.setAutoresizingMask_(NSViewWidthSizable)
        view.addSubview_(name)
        note = self.label(NSMakeRect(DUPE_W - DUPE_DECIDE_W - 10, 2,
                                     DUPE_DECIDE_W, DUPE_ROW_H - 4),
                          10, TIME_TAG, align=ALIGN_RIGHT, dim=True)
        note.setAutoresizingMask_(NSViewMinXMargin)
        view.addSubview_(note)
        return view

    @objc.python_method
    def buildDupeRow(self):
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, DUPE_ROW_H))
        number = self.label(NSMakeRect(DUPE_SN_X, 2, DUPE_SN_W, DUPE_ROW_H - 4),
                            10, SN_TAG, align=ALIGN_RIGHT, dim=True)
        view.addSubview_(number)
        keep = NSButton.alloc().initWithFrame_(
            NSMakeRect(DUPE_KEEP_X, 2, DUPE_KEEP_W, DUPE_ROW_H - 4))
        keep.setButtonType_(RADIO_BUTTON)
        keep.setTag_(KEEP_TAG)
        view.addSubview_(keep)
        name = self.label(
            NSMakeRect(DUPE_NAME_X, 2,
                       DUPE_W - DUPE_NAME_X - DUPE_DECIDE_W - 12, DUPE_ROW_H - 4),
            11, NAME_TAG)
        name.setAutoresizingMask_(NSViewWidthSizable)
        view.addSubview_(name)
        note = self.label(NSMakeRect(DUPE_W - DUPE_DECIDE_W - 10, 2,
                                     DUPE_DECIDE_W, DUPE_ROW_H - 4),
                          10, TIME_TAG, align=ALIGN_RIGHT, dim=True)
        note.setAutoresizingMask_(NSViewMinXMargin)
        view.addSubview_(note)
        return view

    # -- choosing what survives -------------------------------------------

    @objc.python_method
    def suggestKeeper(self, group):
        """Which copy to keep, and why, in words.

        Tags first, because they are the only part of a video that is your
        work rather than the file's: a re-download can be replaced, an
        afternoon of labelling cannot. Then the oldest, which is usually the
        original. Then the shortest path, which is usually the one filed
        somewhere deliberate rather than dropped in a subfolder.
        """
        tagged = [k for k in group if self.tagsFor(tag_path(k))]
        if len(tagged) == 1:
            return tagged[0], "has tags"
        pool = tagged or list(group)
        dated = [(self.prints.get(k, {}).get("mtime", 0), k) for k in pool]
        oldest = min(dated)[0]
        same_age = [k for age, k in dated if abs(age - oldest) < 2]
        if len(same_age) == 1:
            return same_age[0], "oldest" + (" of the tagged" if tagged else "")
        shortest = min(same_age, key=lambda k: (len(k), k))
        return shortest, "shortest path"

    @objc.python_method
    def dupeGroupsForDisplay(self):
        """The groups on screen, derived once and then held.

        Deriving asks the disk whether every copy in every group still exists.
        Over SMB that is a network round trip each: measured at 300 groups it
        is 900 of them, around a second of dead application per call. It used
        to run on every click, including picking a keeper, which is why doing
        that appeared to hang the app.

        So it is held until something actually changes what the answer would
        be — the index, the scan, or which copies you have taken out. Choosing
        a keeper is not one of those: it edits the group in place instead.
        """
        if self.groupCache is None:
            self.groupCache = self.deriveDupeGroups()
        return self.groupCache

    @objc.python_method
    def deriveDupeGroups(self):
        """Groups, biggest reclaim first, each with its keeper decided.

        A copy you have taken out of the list is gone from here entirely, not
        marked up in some way — which is the point of taking it out. A group
        that drops to one copy that way stops being a group and disappears
        with it, because there is nothing left to choose between.

        With a scan selected, a group is shown when any of its copies is
        inside that scan's folders — and then all of them are, including the
        ones outside it. Hiding those would leave a "group" of one, and the
        thing worth knowing is precisely that the file you scanned also exists
        somewhere you did not.
        """
        rows = []
        folders = self.scanFolders()
        for group in duplicate_groups(self.prints):
            alive = [k for k in group
                     if k not in self.dupeSpared and os.path.isfile(tag_path(k))]
            if len(alive) < 2:
                continue              # one or none left; nothing to choose between
            if folders and not any(self.under(tag_path(k), folders) for k in alive):
                continue
            gid = alive[0]
            keeper = self.dupeKeep.get(gid)
            if keeper not in alive:
                keeper, why = self.suggestKeeper(alive)
            else:
                why = "your choice"
            size = self.prints.get(alive[0], {}).get("size", 0)
            doomed = [k for k in alive if k != keeper]
            rows.append({"id": gid, "keys": alive, "keeper": keeper,
                         "why": why, "size": size, "doomed": doomed,
                         "reclaim": size * len(doomed),
                         "verified": all(self.prints.get(k, {}).get("full")
                                         for k in alive)})
        rows.sort(key=lambda g: -g["reclaim"])
        return rows

    def keepTagged_(self, sender):
        self.applyKeepRule("tags")

    def keepOldest_(self, sender):
        self.applyKeepRule("oldest")

    def keepShortest_(self, sender):
        self.applyKeepRule("shortest")

    @objc.python_method
    def applyKeepRule(self, rule):
        for group in self.dupeGroupsForDisplay():
            keys = group["keys"]
            if rule == "tags":
                tagged = [k for k in keys if self.tagsFor(tag_path(k))]
                pick = tagged[0] if tagged else self.suggestKeeper(keys)[0]
            elif rule == "oldest":
                pick = min(keys, key=lambda k: self.prints.get(k, {}).get("mtime", 0))
            else:
                pick = min(keys, key=lambda k: (len(k), k))
            self.setKeeper(group, pick, "your choice")
        # Every group changed, so the whole table is redrawn — but the groups
        # themselves were edited rather than derived again, so the disk is
        # not asked about a single file.
        if self.dupeTable is not None:
            self.dupeTable.reloadData()
        self.updateDupeTotals()

    @objc.python_method
    def setKeeper(self, group, key, why):
        """Point a group at a different survivor, in place."""
        self.dupeKeep[group["id"]] = key
        group["keeper"] = key
        group["why"] = why
        group["doomed"] = [k for k in group["keys"] if k != key]
        group["reclaim"] = group["size"] * len(group["doomed"])

    def chooseKeeper_(self, sender):
        """A radio button in a row: keep this one, discard the rest of its group.

        The row is found from the key on the button rather than from its tag.
        Cells are reused as the table scrolls, so a tag holding a row number
        goes stale the moment anything moves — and the key does not.

        The group is edited where it sits and only its own rows are redrawn.
        Re-deriving the list instead would re-stat every file in every group,
        which is what made this click stall on a large result.
        """
        key = str(sender.toolTip() or "")
        for item in self.dupeRows:
            if item.get("key") == key:
                group = item["group"]
                self.setKeeper(group, key, "your choice")
                return self.redrawGroup(group)

    @objc.python_method
    def redrawGroup(self, group):
        """Repaint one set's rows, and the totals that answer to them."""
        rows = NSMutableIndexSet.alloc().init()
        for row, item in enumerate(self.dupeRows):
            if item.get("group") is group or item.get("head") is group:
                rows.addIndex_(row)
        if rows.count():
            self.dupeTable.reloadDataForRowIndexes_columnIndexes_(
                rows, NSIndexSet.indexSetWithIndex_(0))
        self.updateDupeTotals()

    def removeFromList_(self, sender):
        """Take the selected copies out of the list, and so out of the run.

        This is how you say "keep this one too". Everything left in a group is
        something you are still choosing between, so a copy you have decided
        to keep does not belong there — leaving it in place with a mark on it
        would mean reading the mark on every row, every time, forever after.

        A group that falls to one copy this way goes with it: one file is not
        a duplicate of anything, and there is nothing left to decide.
        """
        keys = self.selectedDupeKeys()
        if not keys:
            return self.say(
                "Nothing selected",
                "Select the copies you want to keep — ⌘-click or shift-click "
                "for several — and they come out of the list. Whatever is "
                "left is what Move to Trash acts on.")
        self.dupeSpared.update(keys)
        self.saveState()
        self.dupesChanged()           # the playlist should stop flagging them,
                                      # and the results are a copy short
        self.refreshDupeManager()
        self.refreshRows()
        self.syncDupeMenu()

    def restoreRemoved_(self, sender):
        """Put every copy taken out of the list back into it."""
        count = len(self.dupeSpared)
        if not count:
            return self.say("Nothing has been removed",
                            "Every copy the index knows about is still in the "
                            "list.")
        if not self.confirm(
                "Put %d copy%s back in the list?" % (count,
                                                     "" if count == 1 else "ies"),
                "They were taken out because you wanted to keep them. Putting "
                "them back means being asked about them again.\n\nNo file is "
                "moved either way.", "Put Back"):
            return
        self.dupeSpared = set()
        self.saveState()
        self.dupesChanged()
        self.refreshDupeManager()
        self.refreshRows()
        self.syncDupeMenu()

    def removeDuplicates_(self, sender):
        groups = self.dupeGroupsForDisplay()
        doomed = [(g, k) for g in groups for k in g["doomed"]]
        if not doomed:
            return self.say(
                "Nothing to remove",
                "There is nothing left in the list. Everything you took out "
                "of it is where it was; Duplicates → Put Removed Copies Back "
                "brings it all back."
                if self.dupeSpared else "Every group already has one copy.")
        unverified = sum(1 for g, _ in doomed if not g["verified"])
        total = sum(g["size"] for g, _ in doomed)
        detail = ("%d file%s, freeing %s.\n\nThey go to the Trash. A volume "
                  "with no Trash — most shares — asks you once for a folder to "
                  "move them to instead, and remembers it. Nothing is deleted "
                  "either way, and tags on a discarded copy move to the one you "
                  "keep first."
                  % (len(doomed), "" if len(doomed) == 1 else "s",
                     human_bytes(total)))
        known = [(v, f) for v, f in sorted(self.discardFolder.items()) if f]
        if known:
            detail += "\n\nAlready set: " + "; ".join(
                "%s → %s" % (os.path.basename(v.rstrip("/")), f) for v, f in known)
        if unverified:
            detail += ("\n\n%d of them matched on size and both ends but were "
                       "not read in full." % unverified)
        if not self.confirm("Move %d duplicate%s to the Trash?"
                            % (len(doomed), "" if len(doomed) == 1 else "s"),
                            detail, "Move to Trash"):
            return

        playing = self.currentPath()
        queue = [pair for pair in doomed if tag_path(pair[1]) != playing]
        self.trashSkipped = len(doomed) - len(queue)   # never pulled from under
        self.trashMoved, self.trashFailed = 0, []

        # Any volume that still needs somewhere to put discards is settled
        # here, on this thread, because asking is a modal panel and the moving
        # is about to happen on another one. Whether a volume needs the
        # question is only truly answered by trying, so the first file on each
        # unsettled volume goes now.
        queue = self.settleDestinations(queue)

        self.trashQueue = queue
        self.trashDone = 0
        self.trashStop = False
        self.trashing = True
        self.showTrashSheet(len(queue))
        self.performSelectorInBackground_withObject_("trashRun:", None)

    @objc.python_method
    def settleDestinations(self, queue):
        """Move the first file on each volume we have no destination for.

        Returns what is left to do. Anything on a volume you decline to
        nominate a folder for is taken out of the run and reported, rather
        than the whole removal being abandoned: the other volumes are fine.
        """
        rest, refused = [], set()
        # A folder that has since been deleted counts as unsettled: discard()
        # would notice and ask again, and asking from the background thread
        # means a modal panel with no run loop expecting it.
        settled = set(v for v, f in self.discardFolder.items()
                      if f and os.path.isdir(f))
        for group, key in queue:
            volume = self.volumeOf(tag_path(key))
            if volume in refused:
                self.trashFailed.append(
                    "%s — no folder chosen for “%s”"
                    % (os.path.basename(tag_path(key)),
                       os.path.basename(volume.rstrip("/"))))
                continue
            if volume in settled:
                rest.append((group, key))
                continue
            ok, why = self.moveOne(group, key)        # this one may ask
            if ok:
                self.trashMoved += 1
                settled.add(volume)
            elif self.discardFolder.get(volume):
                settled.add(volume)                   # a folder, but this file failed
                self.trashFailed.append(
                    "%s — %s" % (os.path.basename(tag_path(key)), why))
            else:
                refused.add(volume)
                self.trashFailed.append(
                    "%s — %s" % (os.path.basename(tag_path(key)), why))
        return rest

    @objc.python_method
    def moveOne(self, group, key):
        """One copy: its tags to the keeper first, then the file itself."""
        # Tags first: a file in the Trash can be dragged back, but labelling
        # thrown away with it cannot.
        self.mergeTagsInto(group["keeper"], key)
        ok, why = self.discard(tag_path(key))
        if ok:
            self.prints.pop(key, None)
        return ok, why

    def trashRun_(self, _):
        """The moving itself, off the main thread so the app stays alive.

        Three hundred files over SMB is half a minute of nothing, and an app
        that draws nothing for half a minute has hung as far as anyone can
        tell. The work reports itself after every file.
        """
        pool = NSAutoreleasePool.alloc().init()
        try:
            for group, key in self.trashQueue:
                if self.trashStop:
                    break
                self.trashNow = os.path.basename(tag_path(key))
                self.performSelectorOnMainThread_withObject_waitUntilDone_(
                    "trashProgress:", None, False)
                ok, why = self.moveOne(group, key)
                if ok:
                    self.trashMoved += 1
                else:
                    self.trashFailed.append(
                        "%s — %s" % (os.path.basename(tag_path(key)), why))
                self.trashDone += 1
        finally:
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "trashFinished:", None, False)
            del pool

    def trashProgress_(self, _):
        if self.trashBar is None:
            return
        self.trashBar.setDoubleValue_(self.trashDone)
        self.trashLabel.setStringValue_(
            "%s of %s · %s" % (f"{self.trashDone + 1:,}",
                               f"{len(self.trashQueue):,}", self.trashNow))

    def stopTrashing_(self, sender):
        self.trashStop = True
        if self.trashLabel is not None:
            self.trashLabel.setStringValue_("Stopping after this file…")

    def trashFinished_(self, _):
        self.trashing = False
        self.closeTrashSheet()
        self.dupesChanged()
        self.savePrints()
        self.saveTags()
        self.dupeKeep = {}
        self.refreshDupeManager()
        self.refreshRows()
        self.rebuildTagsMenu()
        self.syncDupeMenu()

        moved = self.trashMoved
        where = set(f for f in self.discardFolder.values() if f)
        note = "%d moved to the Trash." % moved if not where else (
            "%d moved — to the Trash, and to %s."
            % (moved, ", ".join(sorted(where))))
        if self.trashStop:
            left = len(self.trashQueue) - self.trashDone
            note += "\n\nStopped: %d not touched." % max(0, left)
        if self.trashSkipped:
            note += "\n\n%d skipped: still playing." % self.trashSkipped
        if self.trashFailed:
            note += "\n\nCould not move:\n" + "\n".join(self.trashFailed[:8])
            if len(self.trashFailed) > 8:
                note += "\n…and %d more." % (len(self.trashFailed) - 8)
        self.say("Duplicates removed" if moved else "Nothing was moved", note)

    # -- the progress sheet -------------------------------------------------

    @objc.python_method
    def showTrashSheet(self, total):
        """A sheet, so the list underneath cannot be edited mid-move."""
        if self.dupeWindow is None:
            return
        rect = NSMakeRect(0, 0, 440, 130)
        self.trashSheet = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, NSWindowStyleMaskTitled, NSBackingStoreBuffered, False)
        content = NSView.alloc().initWithFrame_(rect)
        title = self.label(NSMakeRect(20, 92, 400, 20), 13, 0, bold=True)
        title.setStringValue_("Moving %s to the Trash" % (
            "1 duplicate" if total == 1 else "%s duplicates" % f"{total:,}"))
        content.addSubview_(title)
        self.trashBar = NSProgressIndicator.alloc().initWithFrame_(
            NSMakeRect(20, 66, 400, 16))
        self.trashBar.setIndeterminate_(False)
        self.trashBar.setMinValue_(0.0)
        self.trashBar.setMaxValue_(float(max(1, total)))
        self.trashBar.setDoubleValue_(0.0)
        content.addSubview_(self.trashBar)
        self.trashLabel = self.label(NSMakeRect(20, 44, 400, 18), 11, 0, dim=True)
        self.trashLabel.setStringValue_("Starting…")
        content.addSubview_(self.trashLabel)
        stop = self.barButton("Stop", "stopTrashing:", 440 - BUTTON_W - 20,
                              ypos=8)
        content.addSubview_(stop)
        self.trashSheet.setContentView_(content)
        self.dupeWindow.beginSheet_completionHandler_(self.trashSheet, None)

    @objc.python_method
    def closeTrashSheet(self):
        if self.trashSheet is None:
            return
        if self.dupeWindow is not None:
            self.dupeWindow.endSheet_(self.trashSheet)
        self.trashSheet.orderOut_(None)
        self.trashSheet = None
        self.trashBar = None
        self.trashLabel = None

    @objc.python_method
    def mergeTagsInto(self, keeper, doomed):
        """Carry a discarded copy's tags over to the one being kept."""
        extra = [n for n in self.tagsFor(tag_path(doomed))
                 if not self.hasTag(tag_path(keeper), n)]
        if extra:
            self.setTagsFor(tag_path(keeper), self.tagsFor(tag_path(keeper)) + extra)
        self.setTagsFor(tag_path(doomed), [])

    @objc.python_method
    def trash(self, path):
        """The Trash, if this volume has one."""
        url = NSURL.fileURLWithPath_(path)
        ok, _, err = NSFileManager.defaultManager().trashItemAtURL_resultingItemURL_error_(
            url, None, None)
        if ok:
            return True, ""
        reason = err.localizedDescription() if err else "the volume refused it"
        return False, str(reason)

    @objc.python_method
    def volumeOf(self, path):
        """The mount a file lives on, so each is only asked about once."""
        if path.startswith(VOLUMES):
            return VOLUMES + path[len(VOLUMES):].split("/")[0]
        return "/"

    @objc.python_method
    def discard(self, path):
        """To the Trash — or, on a volume that has none, to a folder you pick.

        SMB shares generally have no Trash, which is most of this app's
        library. Refusing to remove anything there would make the whole
        feature useless on a NAS; deleting instead would be worse. So the
        third option: move them somewhere you nominate, once per volume, and
        you delete them yourself when you are satisfied.
        """
        ok, why = self.trash(path)
        if ok:
            return True, ""
        volume = self.volumeOf(path)
        folder = self.discardFolder.get(volume)
        if folder and not os.path.isdir(folder):
            folder = None                 # renamed, moved, or the share went away
        if folder is None:
            folder = self.askDiscardFolder(volume, why)
            self.discardFolder[volume] = folder
            self.saveState()              # remembered for next time, not just this run
        if not folder:
            return False, why
        return self.moveInto(folder, path)

    @objc.python_method
    def askDiscardFolder(self, volume, why):
        """Where discards go on a volume with no Trash. False if declined."""
        if not self.confirm(
                "“%s” has no Trash" % os.path.basename(volume.rstrip("/")),
                "%s\n\nThe duplicates can be moved to a folder on that same "
                "volume instead, which is instant and changes nothing else. "
                "You delete them yourself once you are happy.\n\nNothing is "
                "deleted either way." % why, "Choose Folder…"):
            return False
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseFiles_(False)
        panel.setCanChooseDirectories_(True)
        panel.setCanCreateDirectories_(True)
        panel.setPrompt_("Move Here")
        panel.setMessage_("Where should duplicates from this volume go?")
        panel.setDirectoryURL_(NSURL.fileURLWithPath_(volume))
        if panel.runModal() != 1 or not panel.URLs():
            return False
        return str(panel.URLs()[0].path())

    @objc.python_method
    def moveInto(self, folder, path):
        """Move a file into a folder, without ever overwriting what is there.

        Two folders can hold different videos with the same name, and one
        quietly replacing the other is exactly the data loss this feature is
        supposed to prevent.
        """
        base = os.path.basename(path)
        stem, ext = os.path.splitext(base)
        target = os.path.join(folder, base)
        n = 2
        while os.path.exists(target):
            target = os.path.join(folder, "%s (%d)%s" % (stem, n, ext))
            n += 1
        try:
            shutil.move(path, target)
            return True, ""
        except (OSError, shutil.Error) as err:
            return False, str(err)

    # -- looking at a copy before deciding ---------------------------------
    #
    # Size and a hash say two files are identical; they do not say which one
    # you want to keep, and they say nothing at all about a pair that only
    # nearly match. So the list can be watched, one copy at a time, in its own
    # window with its own player — the main one keeps your place in the
    # playlist, and inspecting a file is not the same as watching it.

    @objc.python_method
    def selectedDupeKey(self):
        """The key of the copy highlighted in the results, if it is a file."""
        if self.dupeTable is None:
            return None
        row = self.dupeTable.selectedRow()
        if 0 <= row < len(self.dupeRows):
            return self.dupeRows[row].get("key")
        return None

    @objc.python_method
    def selectedDupeKeys(self):
        """Every highlighted copy. Headings are not selectable, so all files."""
        if self.dupeTable is None:
            return []
        return [self.dupeRows[row]["key"]
                for row in self.dupeTable.selectedRowIndexes()
                if 0 <= row < len(self.dupeRows) and "key" in self.dupeRows[row]]

    @objc.python_method
    def reselectDupe(self, key):
        """Put the highlight back on a key after the table was rebuilt."""
        if key is None or self.dupeTable is None:
            return
        for row, item in enumerate(self.dupeRows):
            if item.get("key") == key:
                self.dupeTable.selectRowIndexes_byExtendingSelection_(
                    NSIndexSet.indexSetWithIndex_(row), False)
                return

    def togglePreviewFromList_(self, sender):
        """Space, from the results list: open the preview, or close it."""
        if self.previewWindow is not None:
            return self.previewWindow.close()
        self.previewDuplicate_(sender)

    def closePreviewFromList_(self, sender):
        """Escape, from the results list."""
        if self.previewWindow is not None:
            self.previewWindow.close()

    def previewDuplicate_(self, sender):
        key = self.selectedDupeKey()
        if key is None:
            return self.say("Nothing to preview",
                            "Select one of the copies in the list first. Once "
                            "the preview is open it follows the list, so the "
                            "arrow keys walk you through a group.")
        if self.openPreviewWindow():
            self.showInPreview(tag_path(key))

    @objc.python_method
    def openPreviewWindow(self):
        """The preview window, built on first use. False if it cannot be."""
        if self.previewWindow is not None:
            self.previewWindow.orderFront_(None)     # front, but not focused
            return True
        if not VLC_READY:
            self.say("Nothing to preview with",
                     "Playback needs VLCKit, which is not in this build.")
            return False

        rect = NSMakeRect(0, 0, PREVIEW_W, PREVIEW_H)
        self.previewWindow = PreviewPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow,
            NSBackingStoreBuffered, False)
        self.previewWindow.setTitle_("Preview")
        self.previewWindow.setMinSize_(NSMakeSize(360, 240))
        self.previewWindow.setReleasedWhenClosed_(False)
        self.previewWindow.setDelegate_(self)
        # Floats above the list, and only takes the keyboard when something
        # in it actually needs it — clicking the scrubber, say. Until then the
        # list keeps the focus and the arrow keys go on walking the group.
        self.previewWindow.setFloatingPanel_(True)
        self.previewWindow.setBecomesKeyOnlyIfNeeded_(True)
        self.placePreviewWindow()

        content = NSView.alloc().initWithFrame_(rect)
        self.previewView = VLCVideoView.alloc().initWithFrame_(
            NSMakeRect(0, PREVIEW_BAR_H, PREVIEW_W, PREVIEW_H - PREVIEW_BAR_H))
        self.previewView.setBackColor_(NSColor.blackColor())
        self.previewView.setFillScreen_(False)
        self.previewView.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        content.addSubview_(self.previewView)

        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, PREVIEW_W, PREVIEW_BAR_H))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        y = (PREVIEW_BAR_H - BUTTON_H) / 2
        self.previewPlay = self.xportButton("▶", "togglePreview:", 12, y)
        bar.addSubview_(self.previewPlay)
        self.previewElapsed = self.label(
            NSMakeRect(12 + XPORT_W + 8, y + 6, TIME_W, 18), 11, 0,
            align=ALIGN_RIGHT, dim=True)
        self.previewRemain = self.label(
            NSMakeRect(PREVIEW_W - 12 - TIME_W, y + 6, TIME_W, 18), 11, 0, dim=True)
        self.previewRemain.setAutoresizingMask_(NSViewMinXMargin)
        left = 12 + XPORT_W + 8 + TIME_W + 8
        self.previewScrub = NSSlider.alloc().initWithFrame_(
            NSMakeRect(left, y + 5, PREVIEW_W - left - (12 + TIME_W + 8), 20))
        self.previewScrub.setMinValue_(0.0)
        self.previewScrub.setMaxValue_(1.0)
        self.previewScrub.setDoubleValue_(0.0)
        self.previewScrub.setContinuous_(True)
        self.previewScrub.setAutoresizingMask_(NSViewWidthSizable)
        self.previewScrub.setTarget_(self)
        self.previewScrub.setAction_("previewScrubbed:")
        for v in (self.previewElapsed, self.previewRemain, self.previewScrub):
            bar.addSubview_(v)
        content.addSubview_(bar)

        # No delegate on this player, deliberately. The app delegate's
        # mediaPlayerStateChanged_ reads self.vlc and decides things like "the
        # video ended, play the next one" — pointed at the preview it would
        # advance the playlist because a thumbnail-sized inspection finished.
        # A quarter-second poll drives the two labels and the slider instead.
        self.previewVLC = VLCMediaPlayer.alloc().init()
        self.previewWindow.setContentView_(content)
        self.previewWindow.orderFront_(None)
        # Whatever opened it, the list is what you want to be typing at.
        if self.dupeWindow is not None and self.dupeTable is not None:
            self.dupeWindow.makeFirstResponder_(self.dupeTable)
        self.previewTimer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            PREVIEW_TICK, self, "previewTick:", None, True)
        return True

    @objc.python_method
    def placePreviewWindow(self):
        """Beside the duplicates list if it fits, so both can be seen."""
        # The duplicates window's screen, not the preview's: the preview is not
        # on screen yet and so is on no screen at all.
        screen = self.dupeWindow.screen() if self.dupeWindow is not None else None
        if screen is not None:
            room = screen.visibleFrame()
            frame = self.dupeWindow.frame()
            x = frame.origin.x + frame.size.width + 12
            if x + PREVIEW_W <= room.origin.x + room.size.width:
                return self.previewWindow.setFrameTopLeftPoint_(
                    NSMakePoint(x, frame.origin.y + frame.size.height))
        self.previewWindow.center()

    @objc.python_method
    def showInPreview(self, path):
        """Load one file into the preview, if it is not already there."""
        if self.previewVLC is None or self.previewWindow is None:
            return
        if not path or not os.path.isfile(path):
            self.previewVLC.stop()
            self.previewPath = None
            self.previewWindow.setTitle_("Preview — that file is gone")
            return
        if path == self.previewPath:
            return
        self.pauseMainForPreview()
        self.previewPath = path
        # The basename is the same in every copy of a group; the folder above
        # it is the only part that tells them apart.
        parent = os.path.basename(os.path.dirname(path))
        self.previewWindow.setTitle_(
            "Preview — %s" % os.path.join(parent, os.path.basename(path)))
        if self.previewVLC.drawable() is not self.previewView:
            self.previewVLC.setDrawable_(self.previewView)
        self.previewVLC.setMedia_(
            VLCMedia.alloc().initWithURL_(NSURL.fileURLWithPath_(path)))
        self.previewVLC.play()
        audio = self.previewVLC.audio()
        if audio:
            audio.setVolume_(self.volume)

    @objc.python_method
    def pauseMainForPreview(self):
        """Two videos playing at once is two soundtracks at once."""
        if self.vlc is None or not self.vlc.isPlaying():
            return
        self.previewPausedMain = True
        self.userPaused = True
        self.vlc.pause()
        self.syncTransport()

    @objc.python_method
    def previewSelection(self):
        """The preview follows the list: one copy at a time, arrow by arrow.

        Only when one row is highlighted. Dragging a selection across five
        rows would otherwise open five videos on the way past.
        """
        if self.previewWindow is None or self.dupeTable is None:
            return
        if self.dupeTable.numberOfSelectedRows() != 1:
            return
        key = self.selectedDupeKey()
        if key:
            self.showInPreview(tag_path(key))

    def previewTick_(self, timer):
        if self.previewVLC is None or self.previewScrub is None:
            return
        self.previewPlay.setTitle_("❚❚" if self.previewVLC.isPlaying() else "▶")
        if self.previewScrubbing:
            return
        total = self.lengthOf(self.previewVLC)
        now = self.headOf(self.previewVLC)
        self.previewScrub.setEnabled_(total > 0)
        self.previewScrub.setDoubleValue_(now / total if total > 0 else 0.0)
        self.previewElapsed.setStringValue_(clock(now) if total > 0 else "")
        self.previewRemain.setStringValue_(
            "-" + clock(max(0.0, total - now)) if total > 0 else "")

    def togglePreview_(self, sender):
        if self.previewVLC is None or self.previewPath is None:
            return
        if self.previewVLC.isPlaying():
            self.previewVLC.pause()
        else:
            self.previewVLC.play()
        self.previewTick_(None)

    def previewScrubbed_(self, sender):
        total = self.lengthOf(self.previewVLC)
        if self.previewPath is None or total <= 0:
            return
        self.previewScrubbing = True
        self.seekPreview(total * float(sender.doubleValue()))
        self.previewElapsed.setStringValue_(
            clock(total * float(sender.doubleValue())))
        self.performSelector_withObject_afterDelay_("endPreviewScrub:", None, 0.35)

    def endPreviewScrub_(self, _):
        self.previewScrubbing = False

    @objc.python_method
    def seekPreview(self, seconds):
        """Same trick as the main player: VLC ignores a seek while paused."""
        if self.previewVLC is None or not self.previewVLC.isSeekable():
            return
        paused = not self.previewVLC.isPlaying()
        if paused:
            self.previewVLC.play()
        self.previewVLC.setTime_(
            VLCTime.timeWithInt_(int(max(0.0, seconds) * 1000)))
        if paused:
            self.performSelector_withObject_afterDelay_("repausePreview:", None, 0.35)

    def repausePreview_(self, _):
        if self.previewVLC is not None:
            self.previewVLC.pause()

    @objc.python_method
    def closePreview(self):
        """Tear the preview down, and give the main player back what it lost."""
        if self.previewTimer is not None:
            self.previewTimer.invalidate()
        if self.previewVLC is not None:
            self.previewVLC.stop()
        self.previewTimer = None
        self.previewVLC = None
        self.previewView = None
        self.previewScrub = None
        self.previewPlay = None
        self.previewElapsed = None
        self.previewRemain = None
        self.previewWindow = None
        self.previewPath = None
        self.previewScrubbing = False
        resume, self.previewPausedMain = self.previewPausedMain, False
        if resume and self.item is not None and self.window.isVisible():
            self.userPaused = False
            self.vlc.play()
            self.syncTransport()

    # -- scans: a set of folders, with a name and a history -----------------
    #
    # "Everything" is not a scan and is not stored. It is the whole index —
    # every scan that ever ran plus whatever Notice While Playing picked up —
    # and it is what this window used to show, undifferentiated.

    @objc.python_method
    def currentScan(self):
        """The selected scan, or None for Everything."""
        for scan in self.scans:
            if scan["id"] == self.scanId:
                return scan
        return None

    @objc.python_method
    def scanFolders(self):
        scan = self.currentScan()
        return scan["folders"] if scan else []

    @objc.python_method
    def defaultScanName(self, folders):
        if not folders:
            return "New Scan"
        first = os.path.basename(folders[0].rstrip("/")) or folders[0]
        return first if len(folders) == 1 else "%s + %d more" % (first,
                                                                 len(folders) - 1)

    @objc.python_method
    def addScan(self, folders, name=None):
        scan = {"id": uuid.uuid4().hex[:8],
                "name": name or self.defaultScanName(folders),
                "folders": list(folders), "ran": 0, "seen": 0, "groups": 0}
        self.scans.append(scan)
        self.scanId = scan["id"]
        self.saveState()
        self.dupesChanged()       # a new selection is a different list
        return scan

    @objc.python_method
    def under(self, path, folders):
        """Is this file inside any of those folders?"""
        for folder in folders:
            root = folder.rstrip("/")
            if path == root or path.startswith(root + "/"):
                return True
        return False

    def newScan_(self, sender):
        name = self.askText("New scan", "What should it be called? Add the "
                                        "folders it covers next.",
                            "Scan %d" % (len(self.scans) + 1))
        if name is None:
            return
        self.addScan([], name.strip() or None)
        self.refreshDupeManager()
        self.addDupeFolder_(sender)     # a scan with no folders does nothing

    def renameScan_(self, sender):
        scan = self.currentScan()
        if scan is None:
            return self.say("Everything cannot be renamed",
                            "It is the whole index rather than a scan you "
                            "made. Choose one of your own scans to rename.")
        name = self.askText("Rename scan", "", scan["name"])
        if name is None or not name.strip():
            return
        scan["name"] = name.strip()
        self.saveState()
        self.refreshDupeManager()

    def deleteScan_(self, sender):
        scan = self.currentScan()
        if scan is None:
            return self.say("Everything cannot be deleted",
                            "It is the whole index rather than a scan you made.")
        if not self.confirm(
                "Delete the scan “%s”?" % scan["name"],
                "Only the list of folders goes. Every fingerprint it took is "
                "kept, so its duplicates are still in Everything and nothing "
                "has to be read again.", "Delete"):
            return
        self.scans = [s for s in self.scans if s["id"] != scan["id"]]
        self.scanId = None
        self.saveState()
        self.dupesChanged()
        self.refreshDupeManager()

    def scanChosen_(self, sender):
        item = sender.selectedItem()
        chosen = item.representedObject() if item else None
        self.scanId = str(chosen) if chosen else None
        self.dupesChanged()           # a different scan is a different list
        self.refreshDupeManager()

    @objc.python_method
    def syncScanPicker(self):
        """Rebuild the picker, and say what the selected scan last did."""
        if self.scanPicker is None:
            return
        self.scanPicker.removeAllItems()
        titles = ["Everything"] + ["%s  (%d folder%s)"
                                   % (s["name"], len(s["folders"]),
                                      "" if len(s["folders"]) == 1 else "s")
                                   for s in self.scans]
        for index, title in enumerate(titles):
            # Titles can repeat — two scans may share a name — and
            # addItemWithTitle_ silently refuses a duplicate, so each is added
            # against a unique placeholder and then given its real title.
            self.scanPicker.addItemWithTitle_("row-%d" % index)
            entry = self.scanPicker.itemAtIndex_(index)
            entry.setTitle_(title)
            entry.setRepresentedObject_(None if index == 0
                                        else self.scans[index - 1]["id"])
        here = next((i for i, s in enumerate(self.scans)
                     if s["id"] == self.scanId), -1)
        self.scanPicker.selectItemAtIndex_(here + 1)
        self.scanSummaryLabel.setStringValue_(self.scanSummary())

    @objc.python_method
    def scanSummary(self):
        scan = self.currentScan()
        if scan is None:
            return ("everything fingerprinted so far, from every scan and "
                    "from watching")
        if not scan["ran"]:
            return "never run" + ("" if scan["folders"] else
                                  " · add a folder for it to look through")
        return "last run %s · %s videos seen · %s duplicate group%s" % (
            when_words(scan["ran"]), f"{scan['seen']:,}", f"{scan['groups']:,}",
            "" if scan["groups"] == 1 else "s")

    # -- the deliberate sweep ---------------------------------------------

    def findDuplicates_(self, sender):
        self.openDupeWindow()
        # Derive afresh on the way in. Files come and go outside this app, and
        # opening the window is the one moment where paying to ask the disk
        # about all of them is worth it — as against doing it on every click,
        # which is what made a large list unusable.
        self.dupesChanged()
        # A first run has nothing saved, so the folder already open is a
        # better opening offer than an empty window.
        if not self.scans and self.folder:
            self.addScan([self.folder])
        self.refreshDupeManager()

    def addDupeFolder_(self, sender):
        if self.currentScan() is None:
            return self.say(
                "Everything has no folders",
                "It is the whole index rather than a scan you made. Make a "
                "scan with New Scan… and add folders to that.")
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseFiles_(False)
        panel.setCanChooseDirectories_(True)
        panel.setAllowsMultipleSelection_(True)
        if panel.runModal() != 1:
            return
        folders = self.currentScan()["folders"]
        for url in panel.URLs():
            folder = str(url.path())
            if folder not in folders:
                folders.append(folder)
        self.saveState()
        self.dupesChanged()           # a wider scan may take in more groups
        self.refreshDupeManager()

    def removeDupeFolder_(self, sender):
        # Every selected row, not just the first: the table has always allowed
        # a multiple selection and taking one folder per click from it was
        # only ever an oversight.
        folders = self.scanFolders()
        rows = sorted(self.folderTable.selectedRowIndexes(), reverse=True)
        for row in rows:
            if 0 <= row < len(folders):
                del folders[row]
        if rows:
            self.saveState()
            self.dupesChanged()
            self.refreshDupeManager()

    def startDupeScan_(self, sender):
        if self.dupeScanning:
            self.dupeStop = True
            return
        if not self.scanFolders():
            return self.say(
                "Nothing to search",
                "Everything is the whole index, not a scan — choose or make a "
                "scan and give it a folder."
                if self.currentScan() is None else
                "Add at least one folder for this scan to look through.")
        self.dupeScanning = True
        self.dupeStop = False
        self.sweptCount = 0           # not last run's figure, if this one stops
        self.printGen += 1
        self.dupeStatus = "Listing files…"
        self.refreshDupeManager()
        self.performSelectorInBackground_withObject_("sweep:", self.printGen)

    def sweep_(self, generation):
        """List, sieve by size, fingerprint, verify. All off the main thread."""
        pool = NSAutoreleasePool.alloc().init()
        try:
            self.sweepStages(generation)
        finally:
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "sweepDone:", generation, False)
            del pool

    @objc.python_method
    def sweepStages(self, generation):
        def cancelled():
            return self.dupeStop or generation != self.printGen

        def report(text):
            self.dupeStatus = text
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "sweepProgress:", None, False)

        # 1 — list, taking the size that comes free with the listing
        sizes, seen = {}, 0
        for folder in list(self.scanFolders()):
            for root, dirs, names in os.walk(folder):
                if cancelled():
                    return
                dirs[:] = [d for d in dirs if not d.startswith(".")]
                for name in names:
                    if os.path.splitext(name)[1].lower() not in VIDEO_EXT:
                        continue
                    path = os.path.join(root, name)
                    try:
                        sizes[tag_key(path)] = os.path.getsize(path)
                    except OSError:
                        continue
                    seen += 1
                    if seen % 200 == 0:
                        report("Listed %s videos…" % f"{seen:,}")

        # Recorded here rather than at the end, so a scan you stopped halfway
        # still says honestly how much of the library it had got through.
        self.sweptCount = seen

        # 2 — only files whose size is shared with something can be duplicates
        candidates = size_candidates(sizes)
        report("%s of %s share a size — fingerprinting…"
               % (f"{len(candidates):,}", f"{seen:,}"))

        done = 0
        for key in candidates:
            if cancelled():
                return
            path = tag_path(key)
            if not self.printIsFresh(key, path):
                self.takePrint(path)
            done += 1
            if done % 25 == 0:
                report("Fingerprinting %s of %s…"
                       % (f"{done:,}", f"{len(candidates):,}"))

        # Anything whose size is unique cannot be a duplicate, so a stale entry
        # claiming otherwise has to go or it will haunt the results.
        for key in list(self.prints):
            if key in sizes and key not in set(candidates):
                del self.prints[key]

        # 3 — read in full, but only what the fingerprints already agree on
        if self.verifyDupes:
            groups = [g for g in duplicate_groups(self.prints)
                      if any(k in sizes for k in g)]
            total = sum(len(g) for g in groups)
            checked = 0
            for group in groups:
                for key in group:
                    if cancelled():
                        return
                    entry = self.prints.get(key)
                    if entry is None or entry.get("full"):
                        checked += 1
                        continue
                    mark = full_hash(tag_path(key), stop=cancelled)
                    if mark is None:
                        return
                    entry["full"] = mark
                    checked += 1
                    report("Verifying %s of %s…" % (f"{checked:,}", f"{total:,}"))

    def sweepProgress_(self, _):
        self.updateDupeStatus()

    def sweepDone_(self, generation):
        # A sweep that was superseded has nothing to report: the live one owns
        # the scanning flag and the scan's record now.
        if generation is not None and generation != self.printGen:
            return
        self.dupeScanning = False
        self.dupesChanged()
        self.savePrints()             # what was learned is kept either way
        stopped = self.dupeStop
        self.dupeStatus = (
            "Stopped — fingerprints taken are kept, and the scan still shows "
            "its last full run." if stopped else "Done.")
        # What the scan did, so its line can say whether it is worth running
        # again. Only a run that finished writes it: stamping a stopped one
        # would claim the library had just been covered when a fraction of it
        # had, which is exactly backwards from what that line is for.
        scan = self.currentScan()
        if scan is not None and not stopped:
            scan["ran"] = time.time()
            scan["seen"] = self.sweptCount
            scan["groups"] = len(self.dupeGroupsForDisplay())
            self.saveState()
        self.syncDupeMenu()
        self.refreshDupeManager()
        self.refreshRows()

    @objc.python_method
    def sharePeople(self):
        """Every name published on the mounted shares, and what stands behind it.

        Read from the shares rather than remembered, because the whole point
        of the list is to show what other devices are actually filing under —
        including names this Mac has never used, and names left behind by a
        device that has since been renamed.
        """
        found = {}
        for share in self.mountedShares():
            root = os.path.join(VOLUMES, share, SHARE_DIR)
            try:
                names = sorted(os.listdir(root))
            except OSError:
                continue                  # no tags on this share, or not readable
            for name in names:
                folder = os.path.join(root, name)
                if name.startswith(".") or not os.path.isdir(folder):
                    continue
                entry = found.setdefault(name, {
                    "name": name, "shares": [], "devices": 0,
                    "videos": set(), "changed": 0})
                entry["shares"].append(share)
                try:
                    files = sorted(os.listdir(folder))
                except OSError:
                    continue
                for leaf in files:
                    if not fnmatch.fnmatch(leaf, DEVICE_TAGS % "*"):
                        continue
                    entry["devices"] += 1
                    path = os.path.join(folder, leaf)
                    try:
                        entry["changed"] = max(entry["changed"],
                                               os.path.getmtime(path))
                    except OSError:
                        pass
                    for rest in (load_json(path, {}) or {}):
                        entry["videos"].add("%s/%s" % (share, rest))
        return [found[k] for k in sorted(found)]

    @objc.python_method
    def isMyName(self, name):
        return self.slug(name) == self.slug(self.person)

    @objc.python_method
    def claimName(self):
        """Make this person's folder exist on every mounted share.

        Without this a name is invisible to your other devices until tags
        happen to flow, because the folder is only ever created as a
        side effect of publishing. So a machine that has been given a name but
        has not yet tagged anything on the share does not appear in the Apple
        TV's list of people at all — and the only symptom is an empty list,
        which points at nothing.

        An empty folder is a cheap way to say "this name exists here".
        """
        claimed = []
        for share in self.mountedShares():
            try:
                os.makedirs(os.path.join(VOLUMES, share, self.myTagFolder()),
                            exist_ok=True)
                claimed.append(share)
            except OSError:
                continue          # read-only, or gone since we listed it
        return claimed

    @objc.python_method
    def publishTags(self):
        """Leave this device's tags on each share. Returns what happened.

        Silent by design: a NAS asleep, unplugged, or mounted read-only is a
        normal Tuesday, not something to interrupt anyone about.
        """
        written, skipped = [], []
        for share, entries in sorted(self.shareTags().items()):
            root = os.path.join(VOLUMES, share)
            if not os.path.isdir(root):
                skipped.append((share, "not mounted"))
                continue
            try:
                save_json(os.path.join(root, self.myTagFile()), entries)
                written.append((share, len(entries)))
                self.retireLegacy(root)
            except OSError as err:
                skipped.append((share, err.strerror or "could not be written"))
        return written, skipped

    @objc.python_method
    def retireLegacy(self, root):
        """Drop the old un-owned tags.json once this person has a folder.

        It has to go rather than linger: it belongs to nobody, so every person
        on the share would keep reading it and see tags that are not theirs.
        Only ever removed straight after its contents have been written into
        the person's own file, so nothing is lost by it.
        """
        legacy = os.path.join(root, LEGACY_TAGS)
        if os.path.exists(legacy) and os.path.exists(os.path.join(root, self.myTagFile())):
            try:
                os.remove(legacy)
            except OSError:
                pass                      # read-only share; harmless to leave

    @objc.python_method
    def mergeShared(self):
        """Take in tags this person made on their other devices.

        Only this person's files are read. Another person's tags are none of
        our business, and merging them would put words in their mouth.

        A file newer than our last merge wins for the videos it names. Coarse
        — per video, not per tag — but it is a rule you can hold in your head,
        and the alternative needs bookkeeping this does not have.
        """
        newest = self.lastMerge
        adopted = 0
        mine = os.path.basename(self.myTagFile())
        for share in sorted(self.shareTags()) or self.mountedShares():
            folder = os.path.join(VOLUMES, share, self.myTagFolder())
            if not os.path.isdir(folder):
                continue
            for name in sorted(os.listdir(folder)):
                if name == mine or not fnmatch.fnmatch(name, DEVICE_TAGS % "*"):
                    continue
                path = os.path.join(folder, name)
                try:
                    changed = os.path.getmtime(path)
                except OSError:
                    continue
                if changed <= self.lastMerge:
                    continue              # already taken in, on an earlier run
                newest = max(newest, changed)
                for rest, names in (load_json(path, {}) or {}).items():
                    if not isinstance(names, list):
                        continue
                    clean = parse_tags(",".join(str(n) for n in names))
                    key = "%s/%s" % (share, rest)
                    # An empty list is a real statement — "that device says no
                    # tags" — so it removes rather than being ignored.
                    if clean:
                        self.tags[key] = clean
                    else:
                        self.tags.pop(key, None)
                    adopted += 1
        if adopted:
            self.lastMerge = newest
            self.saveTags()
            self.saveState()
        return adopted

    @objc.python_method
    def mountedShares(self):
        try:
            return sorted(n for n in os.listdir(VOLUMES)
                          if os.path.isdir(os.path.join(VOLUMES, n)))
        except OSError:
            return []

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
        return [tag_path(key) for key, names in self.tags.items()
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
        # Whose tags these are. The account name is only a default — it is a
        # setting because an Apple TV has no account name to borrow, and
        # renaming a Mac account should not orphan a library.
        self.person = str(state.get("person") or getpass.getuser())
        # And which machine wrote them, so this Mac never fights its own TV.
        self.device = str(state.get("device") or uuid.uuid4().hex[:8])
        self.lastMerge = state.get("lastMerge") or 0
        self.showThumbs = state.get("thumbnails") is not False
        self.volume = int(state.get("volume", 100))
        # Where discards go on volumes with no Trash. Remembered so the
        # question is asked once, not once a session.
        saved = state.get("discardFolders")
        self.discardFolder = dict(saved) if isinstance(saved, dict) else {}
        self.watchDupes = state.get("watchDupes") is not False
        self.verifyDupes = state.get("verifyDupes") is not False
        spared = state.get("sparedDupes")
        self.dupeSpared = set(k for k in spared if isinstance(k, str)) \
            if isinstance(spared, list) else set()
        # Every field is checked, because a scan with no id or no folder list
        # would break the window rather than the scan — and a "scans" that is
        # not a list at all would stop the app launching, which there is no
        # way back from.
        self.scans = []
        saved_scans = state.get("scans")
        for saved in (saved_scans if isinstance(saved_scans, list) else []):
            if not isinstance(saved, dict) or not saved.get("id"):
                continue
            folders = saved.get("folders")
            self.scans.append({
                "id": str(saved["id"]),
                "name": str(saved.get("name") or "Scan"),
                "folders": [f for f in folders if isinstance(f, str)]
                           if isinstance(folders, list) else [],
                "ran": saved.get("ran") if isinstance(saved.get("ran"), (int, float)) else 0,
                "seen": saved.get("seen") if isinstance(saved.get("seen"), int) else 0,
                "groups": saved.get("groups") if isinstance(saved.get("groups"), int) else 0,
            })
        chosen = state.get("scan")
        self.scanId = str(chosen) if any(s["id"] == chosen for s in self.scans) \
            else None

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
            "person": self.person,
            "device": self.device,
            "lastMerge": self.lastMerge,
            "thumbnails": self.showThumbs,
            "volume": self.volume,
            "discardFolders": {v: f for v, f in self.discardFolder.items() if f},
            "watchDupes": self.watchDupes,
            "verifyDupes": self.verifyDupes,
            "sparedDupes": sorted(self.dupeSpared),
            "scans": self.scans,
            "scan": self.scanId,
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
        self.add(play, "Stop", "stopPlayback:", ".", NSEventModifierFlagCommand)

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

        # Its own menu rather than a corner of Tags. Finding duplicates has
        # nothing to do with labelling, and it had grown to three items and a
        # window of its own while hiding under a heading that did not mention
        # it. Built once — only the count changes, and syncDupeMenu does that.
        dupes = self.menu(bar, "Duplicates")
        # One item, not two. "Find Duplicates…" and the count opened the same
        # window, which is a menu offering you a choice it does not have.
        self.dupeCountItem = self.add(dupes, "Find Duplicates…", "findDuplicates:")
        dupes.addItem_(NSMenuItem.separatorItem())
        self.watchItem = self.add(dupes, "Notice Duplicates While Playing",
                                  "toggleWatchDupes:")
        # The way back from Remove from List. It lives here rather than in the
        # window because it undoes work rather than doing any, and because a
        # decision with no way back is not one anybody should have to make in
        # a hurry.
        self.restoreItem = self.add(dupes, "Put Removed Copies Back…",
                                    "restoreRemoved:")
        self.add(dupes, "Forget Where Duplicates Go…", "forgetDiscardFolders:")
        self.syncDupeMenu()

        view = self.menu(bar, "View")
        self.listItem = self.add(view, "Show Playlist", "togglePlaylist:", "l",
                                 NSEventModifierFlagCommand)
        self.thumbItem = self.add(view, "Show Thumbnails", "toggleThumbnails:")
        self.thumbItem.setState_(STATE_ON if self.showThumbs else STATE_OFF)

        window = self.menu(bar, "Window")
        # Closing the window stopped quitting the app, so there has to be a way
        # back that is not the Dock icon — the Window menu is where anyone
        # would look for it, and it is the one menu that stays usable when
        # there is no window on screen.
        self.add(window, "FolderVideoPlayer", "showPlayerWindow:", "0",
                 NSEventModifierFlagCommand)
        window.addItem_(NSMenuItem.separatorItem())
        window.addItemWithTitle_action_keyEquivalent_("Minimize", "performMiniaturize:", "m")
        # ⌃⌘F is the system-standard fullscreen shortcut; ⌘⇧F is Play Favorites
        window.addItemWithTitle_action_keyEquivalent_(
            "Enter Full Screen", "toggleFullScreen:", "f").setKeyEquivalentModifierMask_(
                NSEventModifierFlagCommand | NSEventModifierFlagControl)

        NSApplication.sharedApplication().setMainMenu_(bar)

    @objc.python_method
    @objc.python_method
    def buildScrubber(self, bar, width):
        """The position slider and its two clocks, on their own row."""
        y = 48 + (SCRUB_H - 20) / 2
        self.elapsedLabel = self.label(NSMakeRect(14, y, TIME_W, 18), 11, 0,
                                       align=ALIGN_RIGHT, dim=True)
        self.remainLabel = self.label(NSMakeRect(width - 14 - TIME_W, y, TIME_W, 18),
                                      11, 0, dim=True)
        self.remainLabel.setAutoresizingMask_(NSViewMinXMargin)
        self.scrubber = NSSlider.alloc().initWithFrame_(
            NSMakeRect(14 + TIME_W + 8, y - 1, width - 2 * (14 + TIME_W + 8), 20))
        self.scrubber.setMinValue_(0.0)
        self.scrubber.setMaxValue_(1.0)
        self.scrubber.setDoubleValue_(0.0)
        self.scrubber.setAutoresizingMask_(NSViewWidthSizable)
        self.scrubber.setTarget_(self)
        self.scrubber.setAction_("scrubbed:")
        # Fires while the knob moves, so the picture follows the drag rather
        # than jumping once it is let go.
        self.scrubber.setContinuous_(True)
        for v in (self.elapsedLabel, self.remainLabel, self.scrubber):
            bar.addSubview_(v)

    @objc.python_method
    def xportButton(self, glyph, action, x, y):
        """A transport button: a glyph, narrow enough that four fit."""
        button = NSButton.alloc().initWithFrame_(NSMakeRect(x, y, XPORT_W, BUTTON_H))
        button.setTitle_(glyph)
        button.setBezelStyle_(NSBezelStyleRounded)
        button.setFont_(NSFont.systemFontOfSize_(11))
        button.setTarget_(self)
        button.setAction_(action)
        return button

    def scrubbed_(self, sender):
        """Drag the slider, move the video."""
        total = self.mediaLength()
        if self.item is None or total <= 0:
            return
        self.scrubbing = True
        self.seekTo(total * float(sender.doubleValue()))
        self.showTimes(total * float(sender.doubleValue()), total)
        self.performSelector_withObject_afterDelay_("endScrub:", None, 0.35)

    def endScrub_(self, _):
        self.scrubbing = False

    def togglePlayPause_(self, sender):
        if self.item is None or self.vlc is None:
            return
        if self.vlc.isPlaying():
            self.userPaused = True
            self.vlc.pause()
        else:
            self.userPaused = False
            self.vlc.play()
        self.syncTransport()

    def volumeChanged_(self, sender):
        self.volume = int(sender.doubleValue())
        audio = self.vlc.audio() if self.vlc else None
        if audio:
            audio.setVolume_(self.volume)
        self.saveState()

    @objc.python_method
    def syncTransport(self):
        """Keep the play button and the transport in step with reality."""
        if getattr(self, "playButton", None) is None:
            return
        playing = bool(self.vlc.isPlaying()) if self.vlc else False
        self.playButton.setTitle_("❚❚" if playing else "▶")
        more = len(self.playlist) > 1
        self.prevButton.setEnabled_(more)
        self.nextButton.setEnabled_(more)
        self.stopButton.setEnabled_(bool(self.playlist))
        self.playButton.setEnabled_(bool(self.playlist))

    @objc.python_method
    def syncScrubber(self):
        """Follow the playhead, unless the knob is under someone's finger."""
        if getattr(self, "scrubber", None) is None or self.scrubbing:
            return
        total = self.mediaLength()
        now = self.playhead()
        self.scrubber.setEnabled_(total > 0)
        self.scrubber.setDoubleValue_(now / total if total > 0 else 0.0)
        self.showTimes(now, total)

    @objc.python_method
    def showTimes(self, now, total):
        self.elapsedLabel.setStringValue_(clock(now) if total > 0 else "")
        self.remainLabel.setStringValue_(
            "-" + clock(max(0.0, total - now)) if total > 0 else "")

    @objc.python_method
    def barButton(self, title, action, x, width=None, ypos=None):
        button = NSButton.alloc().initWithFrame_(
            NSMakeRect(x, (BAR_HEIGHT - BUTTON_H) / 2 if ypos is None else ypos,
                       width or BUTTON_W, BUTTON_H))
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
        # Closing it no longer quits, so it has to outlive the close.
        self.window.setReleasedWhenClosed_(False)
        # narrow enough and the left-hand buttons would run into the right-hand pair
        self.window.setMinSize_(NSMakeSize(680, 380))
        # A remembered frame is restored as-is, minimum size or not, so a
        # window saved smaller than the minimum comes back too small and the
        # bar overlaps itself. Cheap to rule out.
        was = self.window.frame()
        least = self.window.minSize()
        if was.size.width < least.width or was.size.height < least.height:
            self.window.setFrame_display_(
                NSMakeRect(was.origin.x, was.origin.y,
                           max(was.size.width, least.width),
                           max(was.size.height, least.height)), False)
        self.window.center()

        content = NSView.alloc().initWithFrame_(rect)

        # Video fills everything above the control bar and grows with the window.
        # VLCVideoView, not a plain NSView: VLCKit ships it for exactly this
        # and it is the drawable the framework expects on macOS. A bare view
        # gets a vout attached and shows nothing — the picture goes somewhere
        # you cannot see.
        frame = NSMakeRect(0, MAIN_BAR_H, rect.size.width,
                           rect.size.height - MAIN_BAR_H)
        if VLC_READY:
            self.playerView = VLCVideoView.alloc().initWithFrame_(frame)
            self.playerView.setBackColor_(NSColor.blackColor())
            self.playerView.setFillScreen_(False)   # letterbox, never crop
        else:
            self.playerView = NSView.alloc().initWithFrame_(frame)
            self.playerView.setWantsLayer_(True)
            self.playerView.layer().setBackgroundColor_(NSColor.blackColor().CGColor())
        self.playerView.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        click = NSClickGestureRecognizer.alloc().initWithTarget_action_(
            self, "clickedVideo:")
        self.playerView.addGestureRecognizer_(click)
        content.addSubview_(self.playerView)

        # Without the framework there is no player at all. Everything that
        # touches self.vlc checks for it, so the app still opens, still shows
        # your library and still manages tags — it just cannot play.
        self.vlc = None
        if VLC_READY:
            self.vlc = VLCMediaPlayer.alloc().init()
            self.vlc.setDelegate_(self)
            # The drawable is attached later, not here. At this point the view
            # has no window yet — buildWindow has not handed the content view
            # over — and VLC creates its video output against the window the
            # drawable is in. Set it now and the output has nowhere to go.

        # The control bar. All of it is ours now — VLC draws a picture and
        # nothing else, so the scrubber, the clock and the transport are as
        # much this app's job as the Favorite button always was.
        width = rect.size.width
        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, width, MAIN_BAR_H))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        self.buildScrubber(bar, width)

        y = (48 - BUTTON_H) / 2
        x = 14
        self.prevButton = self.xportButton("◀◀", "prevItem:", x, y)
        x += XPORT_W + 6
        self.playButton = self.xportButton("▶", "togglePlayPause:", x, y)
        x += XPORT_W + 6
        self.nextButton = self.xportButton("▶▶", "nextItem:", x, y)
        x += XPORT_W + 6
        self.stopButton = self.xportButton("■", "stopPlayback:", x, y)
        x += XPORT_W + 12
        self.favButton = self.barButton("☆ Favorite", "toggleFavorite:", x, ypos=y)
        x += BUTTON_W + 8
        self.tagButton = self.barButton("Tag ⌃", "toggleTagPanel:", x, ypos=y)
        for b in (self.prevButton, self.playButton, self.nextButton,
                  self.stopButton, self.favButton, self.tagButton):
            bar.addSubview_(b)

        # right-hand group, pinned to the right edge
        self.volumeSlider = NSSlider.alloc().initWithFrame_(
            NSMakeRect(width - 292, y + 3, 70, 20))
        self.volumeSlider.setMinValue_(0.0)
        self.volumeSlider.setMaxValue_(100.0)
        self.volumeSlider.setDoubleValue_(self.volume)
        self.volumeSlider.setTarget_(self)
        self.volumeSlider.setAction_("volumeChanged:")
        self.volumeSlider.setAutoresizingMask_(NSViewMinXMargin)
        self.openButton = self.barButton("Open New…", "openNew:", width - 214, ypos=y)
        self.openButton.setAutoresizingMask_(NSViewMinXMargin)
        self.listButton = self.barButton("Playlist", "togglePlaylist:", width - 110, ypos=y)
        self.listButton.setAutoresizingMask_(NSViewMinXMargin)
        for v in (self.volumeSlider, self.openButton, self.listButton):
            bar.addSubview_(v)
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
        height = rect.size.height - MAIN_BAR_H

        self.sidebar = NSVisualEffectView.alloc().initWithFrame_(
            NSMakeRect(rect.size.width, MAIN_BAR_H, SIDEBAR_W, height))
        self.sidebar.setMaterial_(VIBRANCY_SIDEBAR)
        self.sidebar.setState_(VIBRANCY_ACTIVE)
        self.sidebar.setAutoresizingMask_(NSViewHeightSizable | NSViewMinXMargin)

        # Select mode, above the filter. Selecting a row and playing a row were
        # the same gesture, so a batch could not be built without playback
        # jumping about, and a batch of one was impossible. This separates
        # them: while Select is on, clicking a row ticks it and plays nothing.
        top = height - SELECT_H - 8
        self.selectButton = NSButton.alloc().initWithFrame_(
            NSMakeRect(8, top, 74, SELECT_H))
        self.selectButton.setTitle_("Select")
        self.selectButton.setBezelStyle_(NSBezelStyleRounded)
        self.selectButton.setFont_(NSFont.systemFontOfSize_(11))
        self.selectButton.setTarget_(self)
        self.selectButton.setAction_("toggleSelectMode:")
        self.selectButton.setAutoresizingMask_(NSViewMinYMargin)
        self.batchLabel = self.label(
            NSMakeRect(88, top + 2, SIDEBAR_W - 96 - 96, SELECT_H - 4), 11, 0, dim=True)
        self.batchLabel.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        self.allButton = self.tinyButton("All", "selectAllRows:", SIDEBAR_W - 96, top)
        self.noneButton = self.tinyButton("None", "selectNoRows:", SIDEBAR_W - 52, top)
        for v in (self.selectButton, self.allButton, self.noneButton):
            # None of these may take the keyboard: they sit above the list in
            # the key view loop, and arrow keys belong to the list.
            v.setRefusesFirstResponder_(True)
        for v in (self.selectButton, self.batchLabel, self.allButton, self.noneButton):
            self.sidebar.addSubview_(v)
        self.syncSelectMode()             # All and None start hidden

        # Filter pinned below it. A folder of 300 files is not navigable by
        # scrolling alone.
        self.filterField = NSSearchField.alloc().initWithFrame_(
            NSMakeRect(8, height - SELECT_H - FILTER_H - 12, SIDEBAR_W - 16, FILTER_H))
        self.filterField.setAutoresizingMask_(NSViewWidthSizable | NSViewMinYMargin)
        self.filterField.setPlaceholderString_("Filter")
        self.filterField.setDelegate_(self)
        self.sidebar.addSubview_(self.filterField)

        listHeight = height - FILTER_H - SELECT_H - 20
        self.table = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, SIDEBAR_W, listHeight))
        column = NSTableColumn.alloc().initWithIdentifier_("name")
        column.setWidth_(SIDEBAR_W - 24)
        self.table.addTableColumn_(column)
        self.table.setHeaderView_(None)
        self.table.setTarget_(self)
        self.table.setAction_("rowClicked:")
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
        self.tagCaption.setAutoresizingMask_(NSViewWidthSizable)

        self.chipRow = NSView.alloc().initWithFrame_(
            NSMakeRect(14, TAG_PANEL_H - 98, width - 28, CHIP_H))
        self.chipRow.setAutoresizingMask_(NSViewWidthSizable)

        # Done, not Save: everything is applied the moment you click it, so
        # there is nothing left to commit and nothing to cancel. The button is
        # here only because a panel needs a way out that is not a keystroke.
        done = self.barButton("Done", "closeTagPanel:", width - 14 - BUTTON_W)
        done.setFrameOrigin_((width - 14 - BUTTON_W, 10))
        done.setAutoresizingMask_(NSViewMinXMargin)
        done.setKeyEquivalent_("\033")            # Escape closes it too

        for view in [self.tagSubject, self.tagField, self.tagCaption,
                     self.chipRow, done]:
            self.tagPanel.addSubview_(view)
        content.addSubview_(self.tagPanel)

    @objc.python_method
    def tagPanelFrame(self):
        content = self.window.contentView().frame()
        # Stop short of the playlist drawer rather than sliding underneath it
        width = content.size.width - (SIDEBAR_W if self.sidebarOpen else 0)
        y = MAIN_BAR_H if self.tagPanelOpen else -TAG_PANEL_H
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
        else:
            self.tagSubject.setStringValue_(
                "%d videos — tags are added, nothing is removed" % len(paths))
            self.tagField.setObjectValue_([])
        # Hold the video still while you label it. Anything that was already
        # paused stays paused, so closing never starts something unbidden.
        self.wasPlaying = bool(self.vlc.isPlaying())
        if self.wasPlaying:
            self.userPaused = True
            self.vlc.pause()
        self.fillSuggestions()
        self.slideTagPanel(True)
        self.window.makeFirstResponder_(self.tagField)

    def closeTagPanel_(self, sender):
        # Anything typed and not yet tokenised would otherwise be dropped on
        # the way out, which looks exactly like the app losing your tag.
        if self.tagPanelOpen:
            self.commitTypedTags()
        if self.selectMode:
            # A batch is done with when its panel closes. Leaving Select on
            # with rows still ticked is how the next click ends up somewhere
            # surprising.
            self.selectMode = False
            self.batch = set()
            self.syncSelectMode()
            self.refreshRows()
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
            self.vlc.play()

    def controlTextDidEndEditing_(self, notification):
        """A typed tag lands when you finish typing it.

        On the end of editing rather than on every keystroke: the field would
        otherwise create a tag called "B", then "Bi", then "Big" on the way to
        one called "Big".
        """
        if not self.tagPanelOpen or not notification.object().isEqual_(self.tagField):
            return
        self.commitTypedTags()

    @objc.python_method
    def commitTypedTags(self):
        names = parse_tags(", ".join(str(t) for t in self.tagField.objectValue() or []))
        targets = self.tagTargets or ([self.currentPath()] if self.currentPath() else [])
        if not targets:
            return
        if len(targets) == 1 and names == list(self.tagsFor(targets[0])):
            return                        # nothing actually changed
        self.applyTags(targets, names)
        if len(targets) > 1:
            self.tagField.setObjectValue_([])   # added to all; the field is spent
        self.tagsChanged()
        self.fillSuggestions()

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
        """Chips for tags already in use, most-used first, laid out to fit.

        The ones this video already carries are shown ticked rather than
        hidden, because they are now the way to take a tag off again as well
        as to put one on.
        """
        for old in list(self.chipRow.subviews()):
            old.removeFromSuperview()
        targets = self.tagTargets or ([self.currentPath()] if self.currentPath() else [])
        already = set()
        if len(targets) == 1:
            already = {n.lower() for n in self.tagsFor(targets[0])}
        self.suggestButtons = []
        width = self.chipRow.frame().size.width
        x = 0
        for name in self.popularTags():
            chip = self.suggestionChip(name, name.lower() in already)
            chipWidth = chip.frame().size.width + CHIP_PAD
            if x and x + chipWidth > width:
                break                     # one row; the rest are reachable by typing
            chip.setFrame_(NSMakeRect(x, 0, chipWidth, CHIP_H))
            self.chipRow.addSubview_(chip)
            x += chipWidth + 5
        self.tagCaption.setStringValue_(
            "Click a tag to add or remove it — saved as you go"
            if len(targets) == 1 else
            "Click a tag to add it to all %d — saved as you go" % len(targets))
        self.tagCaption.setHidden_(not self.chipRow.subviews())

    # -- the playlist drawer ---------------------------------------------

    @objc.python_method
    def sidebarFrame(self):
        content = self.window.contentView().frame()
        x = content.size.width - (SIDEBAR_W if self.sidebarOpen else 0)
        return NSMakeRect(x, MAIN_BAR_H, SIDEBAR_W, content.size.height - MAIN_BAR_H)

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
            self.revealCurrentRow(force=True)   # opening it should land on the video
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
        if self.isDupeTable(table):
            return self.previewSelection()
        if self.isFolderTable(table):
            return
        if self.isNameTable(table):
            return self.syncNameButtons()     # the buttons follow the selection
        if self.syncing or self.isTagTable(table):
            return
        if self.selectMode:
            return                        # moving the highlight is not playing
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
    @objc.python_method
    def tinyButton(self, title, action, x, y):
        b = NSButton.alloc().initWithFrame_(NSMakeRect(x, y, 42, SELECT_H))
        b.setTitle_(title)
        b.setBezelStyle_(NSBezelStyleRounded)
        b.setFont_(NSFont.systemFontOfSize_(10))
        b.setTarget_(self)
        b.setAction_(action)
        b.setAutoresizingMask_(NSViewMinXMargin | NSViewMinYMargin)
        return b

    def toggleSelectMode_(self, sender):
        self.selectMode = not self.selectMode
        if self.selectMode:
            # Picking videos out of a list is not watching them. Playing on
            # underneath means the highlight, the sound and the thing you are
            # ticking all disagree about what you are looking at.
            if self.vlc is not None and self.vlc.isPlaying():
                self.userPaused = True
                self.vlc.pause()
                self.syncTransport()
        else:
            self.batch = set()
        self.batchAnchor = None
        self.syncSelectMode()
        self.refreshRows()

    def selectAllRows_(self, sender):
        """Everything the filter is currently showing, not the whole folder."""
        if not self.selectMode:
            return
        self.batch = {i for i, _ in self.rows if i is not None}
        self.syncSelectMode()
        self.refreshRows()

    def selectNoRows_(self, sender):
        self.batch = set()
        self.batchAnchor = None
        self.syncSelectMode()
        self.refreshRows()

    def tableView_shouldTypeSelectForEvent_withCurrentSearchString_(
            self, view, event, search):
        """Space ticks the highlighted row while Select is on.

        Type-select is where a bare keypress in a table ends up, so this is
        the hook that lets the arrow keys and the space bar work together as
        the way to build a batch without touching the mouse.
        """
        if self.selectMode and view is self.table and str(event.characters()) == " ":
            self.tickRow(self.table.selectedRow(), False)
            self.syncSelectMode()
            self.refreshRows()
            return False
        return True

    def rowClicked_(self, sender):
        """A click ticks a row while Select is on, and plays it otherwise."""
        if not self.selectMode:
            return                        # the selection-change path plays it
        row = self.table.clickedRow()
        if not 0 <= row < len(self.rows):
            return
        index = self.rows[row][0]
        if index is None:
            return                        # a heading is not a video

        event = NSApplication.sharedApplication().currentEvent()
        shifted = bool(event and event.modifierFlags() & NSEventModifierFlagShift)
        self.tickRow(row, shifted)
        self.syncSelectMode()
        self.refreshRows()

    @objc.python_method
    def tickRow(self, row, shifted):
        """Tick one row, or the run back to the last one clicked."""
        if not 0 <= row < len(self.rows) or self.rows[row][0] is None:
            return
        if shifted and self.batchAnchor is not None:
            # Shift ticks the run between the last row clicked and this one,
            # and only ticks: a range that untucked whatever it passed over
            # would undo the selection it was meant to extend.
            first, last = sorted((self.batchAnchor, row))
            for r in range(first, last + 1):
                if 0 <= r < len(self.rows) and self.rows[r][0] is not None:
                    self.batch.add(self.rows[r][0])
        else:
            self.batch.symmetric_difference_update({self.rows[row][0]})
            self.batchAnchor = row        # where a later shift-click reaches from

    @objc.python_method
    def syncSelectMode(self):
        """Keep the drawer's header honest about what is ticked."""
        if getattr(self, "selectButton", None) is None:
            return
        self.selectButton.setState_(STATE_ON if self.selectMode else STATE_OFF)
        self.selectButton.setTitle_("Selecting" if self.selectMode else "Select")
        self.batchLabel.setStringValue_(
            "%d selected" % len(self.batch) if self.selectMode else "")
        for b in (self.allButton, self.noneButton):
            b.setHidden_(not self.selectMode)
        if self.selectMode and self.batch:
            self.tagButton.setTitle_("Tag %d ⌃" % len(self.batch))
        else:
            self.tagButton.setTitle_("Tag ⌃")
        # An open panel has to follow the ticks. It used to pin its subject on
        # opening, which is right when the queue is moving underneath it and
        # wrong when you are deliberately choosing what it acts on.
        # getattr, because this now runs while the drawer is being built and
        # the tag panel does not exist yet at that point.
        if getattr(self, "tagPanelOpen", False) and self.selectMode:
            self.retargetTagPanel()

    @objc.python_method
    def retargetTagPanel(self):
        """Point the open tag panel at whatever is ticked now.

        Reads the batch rather than selectedPaths, because that falls back to
        the playing video when nothing is ticked — which is right for Cmd-T
        and wrong here, where an empty batch means empty.
        """
        paths = [self.playlist[i] for i in sorted(self.batch)
                 if isinstance(i, int) and 0 <= i < len(self.playlist)]
        self.tagTargets = paths
        if len(paths) == 1:
            self.tagSubject.setStringValue_(os.path.basename(paths[0]))
            self.tagField.setObjectValue_(list(self.tagsFor(paths[0])))
        elif paths:
            self.tagSubject.setStringValue_(
                "%d videos — tags are added, nothing is removed" % len(paths))
            self.tagField.setObjectValue_([])
        else:
            self.tagSubject.setStringValue_("Nothing selected — tick a row")
            self.tagField.setObjectValue_([])
        self.fillSuggestions()

    @objc.python_method
    def chosenIndexes(self):
        """The playlist indices currently selected, ignoring headings."""
        return [self.rows[r][0] for r in self.table.selectedRowIndexes()
                if 0 <= r < len(self.rows) and self.rows[r][0] is not None]

    @objc.python_method
    def reselect(self, indexes):
        """Select those playlist items again, wherever they are now.

        Returns whether anything was restored, so a rebuild that lost them all
        — a filter that hid them, say — still falls back to showing what is
        playing rather than leaving nothing selected.
        """
        if len(indexes) < 2:
            return False              # one row is the highlight's business
        wanted = set(indexes)
        rows = [r for r, (i, _) in enumerate(self.rows) if i in wanted]
        if not rows:
            return False
        self.syncing = True
        try:
            self.table.deselectAll_(None)
            for r in rows:
                self.table.selectRowIndexes_byExtendingSelection_(
                    NSIndexSet.indexSetWithIndex_(r), True)
            self.revealedIndex = self.index
        finally:
            self.syncing = False
        return True

    @objc.python_method
    def rebuildRows(self):
        chosen = self.chosenIndexes()
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
        # Put a multi-row selection back where it was. Tagging rebuilds these
        # rows on every click now that there is no Save button, and moving the
        # highlight to the playing video each time made tagging a selection
        # impossible: the first tag threw away the selection the rest needed.
        if self.reselect(chosen):
            return
        self.revealCurrentRow(force=True)   # these are different rows now

    def controlTextDidChange_(self, notification):
        if not notification.object().isEqual_(self.filterField):
            return
        self.filterText = str(self.filterField.stringValue())
        self.rebuildRows()

    @objc.python_method
    def revealCurrentRow(self, force=False):
        """Highlight whatever is playing — unless the filter has hidden it.

        Only when the playing video has actually changed. This runs from the
        one-second timer and from every batch of durations and poster frames
        the background scan delivers, and it replaces the whole selection —
        so doing it unconditionally quietly undid multi-row selections a
        second or so after they were made. Which looked like the list
        deselecting itself, and made tagging several videos at once a race
        against a folder scan.

        `force` is for the cases that really are about the selection: opening
        the drawer, or the filter changing what is on screen.
        """
        if not force and self.index == self.revealedIndex:
            return
        row = next((r for r, (i, _) in enumerate(self.rows) if i == self.index), None)
        self.syncing = True
        try:
            if row is None:
                self.table.deselectAll_(None)
            else:
                self.table.selectRowIndexes_byExtendingSelection_(
                    NSIndexSet.indexSetWithIndex_(row), False)
                self.table.scrollRowToVisible_(row)
            self.revealedIndex = self.index
        finally:
            self.syncing = False

    # -- table plumbing, shared with the favorites window ----------------

    def numberOfRowsInTableView_(self, tableView):
        if self.isTagTable(tableView):
            return len(self.tagRows)
        if self.isNameTable(tableView):
            return len(self.nameRows)
        if self.isDupeTable(tableView):
            return len(self.dupeRows)
        if self.isFolderTable(tableView):
            return len(self.scanFolders())
        return len(self.rows)

    def tableView_isGroupRow_(self, tableView, row):
        if self.isDupeTable(tableView):
            # Not a group row, though it reads as one. AppKit paints group
            # rows with its own background, which would punch a hole through
            # the banding that makes a set read as one block. The heading
            # earns its look from bold text instead.
            return False
        return self.isPlainRow(tableView, row) is None

    def tableView_didAddRowView_forRow_(self, tableView, rowView, row):
        """Shade each set differently from the one above it.

        The table's own alternating colours run per row, which is no help
        when what you need to see is where one set of copies ends and the
        next begins. Same two system colours, banded per group instead.
        """
        if not self.isDupeTable(tableView) or not 0 <= row < len(self.dupeRows):
            return
        shades = NSColor.controlAlternatingRowBackgroundColors()
        rowView.setBackgroundColor_(shades[self.dupeRows[row].get("band", 0)])

    def tableView_shouldSelectRow_(self, tableView, row):
        if self.isDupeTable(tableView):
            # Headings stay unselectable so the arrow keys step from one copy
            # to the next, and the preview with them.
            return 0 <= row < len(self.dupeRows) and "head" not in self.dupeRows[row]
        return self.isPlainRow(tableView, row) is not None

    def tableView_heightOfRow_(self, tableView, row):
        index = self.isPlainRow(tableView, row)
        if index is None:
            return GROUP_H
        if self.isTagTable(tableView) or self.isNameTable(tableView):
            return ROW_H
        if self.isDupeTable(tableView) or self.isFolderTable(tableView):
            return DUPE_ROW_H
        if self.showThumbs:
            return THUMB_ROW_H            # a poster frame needs the same room either way
        # Only a video with something to say pays for the second line.
        path = self.playlist[index]
        return TAG_ROW_H if (self.tagsFor(path) or self.dupesFor(path)) else ROW_H

    @objc.python_method
    def isPlainRow(self, tableView, row):
        """The playlist index for a selectable row, or None for a heading."""
        if (self.isTagTable(tableView) or self.isNameTable(tableView)
                or self.isDupeTable(tableView) or self.isFolderTable(tableView)):
            return row                    # the managers are all plain rows
        if not 0 <= row < len(self.rows):
            return None
        return self.rows[row][0]

    def tableView_viewForTableColumn_row_(self, tableView, column, row):
        if self.isTagTable(tableView):
            return self.tagManagerRow(tableView, row)
        if self.isNameTable(tableView):
            return self.nameManagerRow(tableView, row)
        if self.isDupeTable(tableView):
            return self.dupeManagerRow(tableView, row)
        if self.isFolderTable(tableView):
            view = self.reuse(tableView, "folderrow", self.buildManagerRow)
            folder = self.scanFolders()[row]
            view.viewWithTag_(NAME_TAG).setStringValue_(folder)
            view.viewWithTag_(TIME_TAG).setStringValue_("")
            return view
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
        tick = ""
        if self.selectMode:
            tick = "☑  " if index in self.batch else "☐  "
        view.viewWithTag_(NAME_TAG).setStringValue_(
            tick + ("★  " if self.isFavorite(path) else "") + name)
        seconds = self.durations.get(path)
        view.viewWithTag_(TIME_TAG).setStringValue_(clock(seconds) if seconds else "")
        shot = view.viewWithTag_(THUMB_TAG)
        shot.setHidden_(not self.showThumbs)
        shot.setImage_(self.thumbs.get(path) if self.showThumbs else None)
        # A duplicate reads as a note on the row rather than a warning: it is
        # information, and nothing is wrong until you decide it is.
        others = self.dupesFor(path)
        chips = list(self.tagsFor(path))
        if others:
            chips.insert(0, "⧉ %d copies" % (len(others) + 1))
        self.fillChips(view, chips)
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
    def vlcLength(self, path):
        """How long a video AVFoundation cannot open is, in seconds."""
        try:
            media = VLCMedia.alloc().initWithURL_(NSURL.fileURLWithPath_(path))
            length = media.lengthWaitUntilDate_(
                NSDate.dateWithTimeIntervalSinceNow_(8))
            value = length.intValue() if length else 0
            return value / 1000.0 if value > 0 else 0
        except Exception:
            return 0

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
                if os.path.splitext(path)[1].lower() in FAST_EXT:
                    asset = AVURLAsset.URLAssetWithURL_options_(
                        NSURL.fileURLWithPath_(path), None)
                    seconds = CMTimeGetSeconds(asset.duration())
                    seconds = seconds if seconds == seconds and seconds > 0 else 0
                    self.durations[path] = seconds
                    if self.showThumbs and path not in self.thumbs:
                        self.thumbs[path] = self.posterFrame(asset, seconds)
                else:
                    # AVFoundation cannot read these at all, so asking it costs
                    # a round trip over SMB and returns nothing. VLC answers,
                    # more slowly, and only for the length — its thumbnailer
                    # wants a run loop, which this thread does not have.
                    self.durations[path] = self.vlcLength(path)
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

    def showPlayerWindow_(self, sender):
        """Window ▸ FolderVideoPlayer, for when the window has been closed."""
        self.showPlayer()

    @objc.python_method
    def showPlayer(self):
        """Bring the window back if it has been closed.

        Closing the window no longer quits, so every way of starting something
        has to be able to put the picture back on screen — otherwise Open New…
        picks a folder and plays it into a window that is not there.
        """
        if not self.window.isVisible():
            self.window.makeKeyAndOrderFront_(None)
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

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
        self.showPlayer()
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
        self.showPlayer()
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
        """Let go of the outgoing video. VLC replaces media in place."""
        self.item = None

    @objc.python_method
    def playIndex(self, i):
        if not self.playlist or self.vlc is None:
            return
        self.notePosition()             # the outgoing video keeps its place
        self.index = i % len(self.playlist)
        self.detachItem()

        self.itemPath = self.playlist[self.index]
        self.pendingResume = self.progress.get(self.itemPath, 0)
        self.attachDrawable()
        self.item = VLCMedia.alloc().initWithURL_(
            NSURL.fileURLWithPath_(self.itemPath))
        self.userPaused = False
        self.vlc.setMedia_(self.item)
        self.vlc.play()
        self.applySpeed()
        audio = self.vlc.audio()
        if audio:
            audio.setVolume_(self.volume)
        self.syncTransport()
        self.updateUI()
        self.noticeWhilePlaying(self.itemPath)

    @objc.python_method
    def itemFinished(self):
        if self.tagPanelOpen:
            # Hold here rather than moving on under an open tag panel: you are
            # looking at this video because you are labelling it.
            self.heldAdvance = True
            return self.vlc.pause()
        nxt = self.followOn()
        if nxt is None:
            return self.vlc.stop()          # Play Once, and that was the last
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
        # Only when it differs: VLC posts a notification for every rate it is
        # given, including the one it already has.
        if abs(self.vlc.rate() - self.speed) > 0.01:
            self.vlc.setRate_(self.speed)

    @objc.python_method
    def syncPlaybackMenu(self):
        for item in self.orderItems:
            item.setState_(STATE_ON if str(item.representedObject()) == self.repeat
                           else STATE_OFF)
        for item in self.speedItems:
            item.setState_(STATE_ON if float(item.representedObject()) == self.speed
                           else STATE_OFF)

    def stopPlayback_(self, sender):
        """Stop, as opposed to pause: back to the start, and staying there.

        The resume position goes too. Pause means "I am coming back to this
        spot"; stop means "I am done with it", and finding yourself dropped
        two thirds of the way in next time would contradict that.
        """
        if self.item is None:
            return
        # Rewind first, then pause: seeking a paused player does nothing, so
        # pausing first would leave the playhead exactly where it was.
        self.seekTo(0)
        if self.vlc.isPlaying():
            self.performSelector_withObject_afterDelay_("repauseAfterSeek:", None, 0.35)
        if self.itemPath:
            self.progress.pop(self.itemPath, None)
        self.saveState()
        self.updateUI()

    def clickedVideo_(self, sender):
        """A click anywhere on the picture plays or pauses.

        AVKit's own controls swallow clicks that land on them, so this only
        ever fires on the video itself.
        """
        if self.item is None:
            return
        if self.vlc.isPlaying():
            self.userPaused = True
            self.vlc.pause()
        else:
            self.userPaused = False
            self.vlc.play()

    def skipBack_(self, sender):
        self.seekBy(-SKIP_SECONDS)

    def skipForward_(self, sender):
        self.seekBy(SKIP_SECONDS)

    @objc.python_method
    def seekBy(self, seconds):
        now = self.playhead()
        total = self.mediaLength()
        target = max(0.0, now + seconds)
        if total > 0:                       # never seek past the end
            target = min(target, max(0.0, total - 0.25))
        return self.seekTo(target)

    @objc.python_method
    def seekTo(self, seconds):
        """Move the playhead — including when the video is paused.

        VLC ignores a seek on a paused player and says nothing about it, so a
        skip button would simply stop working whenever you had paused, which
        is exactly when you are most likely to want it. Measured: setPosition
        while paused does nothing, and play-seek-pause lands within half a
        second of the target. So it is nudged into playing for the length of
        the seek and put straight back.
        """
        if self.item is None or not self.vlc.isSeekable():
            return
        target = max(0.0, seconds)
        paused = not self.vlc.isPlaying()
        if paused:
            self.vlc.play()
        self.vlc.setTime_(VLCTime.timeWithInt_(int(target * 1000)))
        if paused:
            # Long enough for the seek to be acted on; shorter and it lands
            # back where it started.
            self.performSelector_withObject_afterDelay_("repauseAfterSeek:", None, 0.35)
        return target

    def repauseAfterSeek_(self, _):
        self.userPaused = True
        self.vlc.pause()
        self.syncTransport()
        self.syncScrubber()

    @objc.python_method
    def attachDrawable(self):
        """Give VLC the view to draw into, once it is really on screen.

        Done on the way into playback rather than at build time, because the
        video output is created against the drawable's window and the view has
        no window while the window is still being assembled.
        """
        if self.vlc is None or self.playerView.window() is None:
            return
        if self.vlc.drawable() is not self.playerView:
            self.vlc.setDrawable_(self.playerView)

    # Both take a player rather than reading self.vlc, because the preview
    # window has one of its own and asks the same two questions of it.
    @objc.python_method
    def headOf(self, player):
        t = player.time() if player else None
        return (t.intValue() / 1000.0) if t else 0.0

    @objc.python_method
    def lengthOf(self, player):
        media = player.media() if player else None
        length = media.length() if media else None
        value = length.intValue() if length else 0
        return value / 1000.0 if value > 0 else 0.0

    @objc.python_method
    def playhead(self):
        """Where we are, in seconds. Zero before anything has opened."""
        return self.headOf(getattr(self, "vlc", None))

    @objc.python_method
    def mediaLength(self):
        """How long the current video is, in seconds; 0 until VLC knows."""
        return self.lengthOf(getattr(self, "vlc", None))

    def mediaPlayerStateChanged_(self, notification):
        """VLC's one channel for "something happened to playback"."""
        state = self.vlc.state()
        if state == VLC_PLAYING:
            self.failures = 0
            self.userPaused = False
            self.applyResume()
            self.applySpeed()
        elif state == VLC_ERROR:
            self.skipBroken()
        elif state == VLC_ENDED:
            self.itemFinished()
        elif state in (VLC_PAUSED, VLC_STOPPED) and self.ranOut():
            # VLC does not reliably say "Ended". Measured on a three second
            # clip: it reports Paused on the last frame and Ended never
            # arrives, so waiting for Ended leaves the queue sitting still at
            # the end of every video. A pause at the very end that nobody
            # asked for is the end.
            self.itemFinished()
        self.syncTransport()

    @objc.python_method
    def ranOut(self):
        """Whether playback stopped because the video finished.

        Deliberately not just "near the end": pausing by hand a second before
        the end must not skip you to the next video. Only a stop nobody asked
        for counts.
        """
        if self.userPaused or self.item is None:
            return False
        total = self.mediaLength()
        return total > 0 and self.playhead() >= total - END_SLACK

    def mediaPlayerTimeChanged_(self, notification):
        self.syncScrubber()

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
        if path is None or self.item is None:
            return
        now = self.playhead()
        if now <= 0:
            return                          # nothing has opened yet
        total = self.mediaLength()
        finished = total > 0 and now > total - RESUME_TAIL
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
        if seconds < RESUME_MIN or not self.vlc.isSeekable():
            return
        total = self.mediaLength()
        if total > 0:
            seconds = min(seconds, max(0.0, total - 0.25))
        self.seekTo(seconds)

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
        if self.selectMode and self.batch:
            # The ticked set, in playlist order, and immune to the highlight
            # moving or the rows being rebuilt under it.
            return [self.playlist[i]
                    for i in sorted(i for i in self.batch if isinstance(i, int))
                    if 0 <= i < len(self.playlist)]
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
        self.add(self.tagsMenu, "Publish Tags to Share", "publishTagsNow:")
        self.tagNameItem = self.add(self.tagsMenu, "Tagging As…", "changePerson:")
        self.add(self.tagsMenu, "Names on the Share…", "manageNames:")
        self.syncPersonItem()

    @objc.python_method
    def syncTagsMenu(self):
        """Tick the tags the playing video carries. Cheap enough per track change."""
        playing = self.currentPath()
        for item in self.tagItems:
            item.setState_(
                STATE_ON if playing and self.hasTag(playing, str(item.representedObject()))
                else STATE_OFF)

    @objc.python_method
    def suggestionChip(self, name, applied):
        button = NSButton.alloc().initWithFrame_(NSMakeRect(0, 0, 10, CHIP_H))
        # The name goes on the identifier, not the title: the title carries a
        # tick when the tag is applied, and reading a name back out of it
        # would mean parsing decoration.
        button.setIdentifier_(name)
        button.setTitle_(("✓ " if applied else "") + name)
        button.setBezelStyle_(BEZEL_INLINE)
        button.setFont_(NSFont.systemFontOfSize_(11))
        button.setTarget_(self)
        button.setAction_("toggleSuggestedTag:")
        button.sizeToFit()
        return button

    def toggleSuggestedTag_(self, sender):
        """Click a tag, it is tagged. No save step.

        Applied straight to the videos rather than staged in the field: a
        panel that needs a Save is a panel you can leave without saving, and
        for something as small as one keyword that is all cost and no benefit.
        """
        name = str(sender.identifier())
        targets = self.tagTargets or ([self.currentPath()] if self.currentPath() else [])
        if not targets:
            return
        if len(targets) == 1:
            path = targets[0]
            if self.hasTag(path, name):
                self.setTagsFor(path, [n for n in self.tagsFor(path)
                                       if n.lower() != name.lower()])
            else:
                self.setTagsFor(path, self.tagsFor(path) + [name])
            self.tagField.setObjectValue_(list(self.tagsFor(path)))
        else:
            # Several: still only ever adds. Un-ticking one here would strip
            # it from every selected video at once, which is a lot to do by
            # accident — Manage Tags is where removing in bulk belongs.
            for path in targets:
                if not self.hasTag(path, name):
                    self.setTagsFor(path, self.tagsFor(path) + [name])
        self.tagsChanged()
        self.fillSuggestions()

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
        self.publishTags()                # best effort; failure is not an event
        self.rebuildTagsMenu()
        self.refreshTagManager()
        # A tag is part of what the filter matches, so the rows can change
        self.rebuildRows()
        self.updateUI()

    # -- the tag manager -------------------------------------------------

    @objc.python_method
    def orphanedTags(self):
        """Tagged videos that are no longer where we left them."""
        return [key for key in self.tags if not os.path.isfile(tag_path(key))]

    @objc.python_method
    def syncPersonItem(self):
        self.tagNameItem.setTitle_("Tagging as “%s”…" % self.person)

    def changePerson_(self, sender):
        """Show, and let you change, the name your tags are filed under.

        It defaults to the macOS account name, which is fine until another
        device asks a human for their name — because nobody types their
        account short name when asked who they are, and the two ends then
        never see each other's tags. Showing it is what makes them match.
        """
        typed = self.askText(
            "Tagging as",
            "Your tags are filed under this name on the share, so another "
            "device has to use the same one to see them.\n\n"
            "Right now they go to %s" % self.myTagFile(),
            self.person)
        if typed is None:
            return
        name = " ".join(typed.split())
        if not name or self.slug(name) == self.slug(self.person):
            return
        self.person = name
        self.syncPersonItem()
        self.saveState()
        self.mergeShared()
        claimed = self.claimName()
        written, skipped = self.publishTags()

        if written:
            detail = ("Your tags are published to %s.\n\n"
                      "Use this same name on your other devices."
                      % self.myTagFile())
        elif claimed:
            # Nothing to publish is not the same as nothing working, and
            # saying "no share is mounted" when a share plainly is mounted
            # sends you off checking mounts that were never the problem.
            detail = ("The name is reserved on %s, so your other devices can "
                      "already see it and use it.\n\nNothing is published "
                      "yet: %s. Tag a video that lives on the share and it "
                      "will be." % (
                          ", ".join(claimed),
                          "none of your tagged videos are on a share"
                          if not skipped else
                          "; ".join("%s %s" % (s, why) for s, why in skipped)))
        else:
            detail = ("No share is mounted, so the name is only on this Mac "
                      "for now. Mount the share and your tags will follow.")
        self.say("Now tagging as “%s”" % name, detail)

    def publishTagsNow_(self, sender):
        """Publish, and take in anything waiting from another device.

        The automatic version is deliberately silent, so without this there is
        no way to find out whether any of it is reaching the share.

        Worth having: the automatic one is deliberately silent, so without
        this there is no way to find out whether it is reaching the share.
        """
        adopted = self.mergeShared()
        written, skipped = self.publishTags()
        if adopted:
            self.refreshRows()
            self.rebuildTagsMenu()
        if not written and not skipped:
            return self.say("Nothing to publish",
                            "None of your tagged videos are on a shared volume, "
                            "so there is nothing another device could read.")
        lines = ["%s — %d video%s" % (s, n, "" if n == 1 else "s")
                 for s, n in written]
        if adopted:
            lines.append("took in %d video%s tagged on another device"
                         % (adopted, "" if adopted == 1 else "s"))
        lines += ["%s — %s" % (s, why) for s, why in skipped]
        detail = "\n".join(lines)
        if written:
            detail += ("\n\nEach one now carries %s, which your other devices "
                       "on the same share can read." % self.myTagFile())
        self.say("Tags published" if written else "Could not publish tags", detail)

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

    def manageNames_(self, sender):
        """Every name on the share, and a way to be rid of the ones you retired.

        A name is easy to create and, until now, impossible to remove: a folder
        left behind by a device that has since been renamed sits in the Apple
        TV's list of people forever, looking like a person.
        """
        if self.nameWindow is not None:
            self.refreshNameManager()
            return self.nameWindow.makeKeyAndOrderFront_(None)

        rect = NSMakeRect(0, 0, FAV_W, FAV_H)
        self.nameWindow = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskResizable, NSBackingStoreBuffered, False)
        self.nameWindow.setTitle_("Names on the Share")
        self.nameWindow.setMinSize_(NSMakeSize(420, 240))
        self.nameWindow.center()
        self.nameWindow.setReleasedWhenClosed_(False)
        self.nameWindow.setDelegate_(self)

        content = NSView.alloc().initWithFrame_(rect)
        self.nameTable = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, FAV_W, rect.size.height - BAR_HEIGHT))
        column = NSTableColumn.alloc().initWithIdentifier_("name")
        column.setWidth_(FAV_W - 24)
        self.nameTable.addTableColumn_(column)
        self.nameTable.setHeaderView_(None)
        self.nameTable.setRowHeight_(ROW_H)
        self.nameTable.setUsesAlternatingRowBackgroundColors_(True)
        self.nameTable.setDataSource_(self)
        self.nameTable.setDelegate_(self)

        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, BAR_HEIGHT, FAV_W, rect.size.height - BAR_HEIGHT))
        scroll.setDocumentView_(self.nameTable)
        scroll.setHasVerticalScroller_(True)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        content.addSubview_(scroll)

        bar = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, FAV_W, BAR_HEIGHT))
        bar.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        self.useNameButton = self.barButton("Use This", "useName:", 14)
        bar.addSubview_(self.useNameButton)
        self.deleteNameButton = self.barButton("Delete…", "deleteName:",
                                               14 + BUTTON_W + 8)
        bar.addSubview_(self.deleteNameButton)
        bar.addSubview_(self.barButton("Refresh", "refreshNames:",
                                       14 + 2 * (BUTTON_W + 8)))
        content.addSubview_(bar)

        self.nameWindow.setContentView_(content)
        self.refreshNameManager()
        self.nameWindow.makeKeyAndOrderFront_(None)

    def forgetDiscardFolders_(self, sender):
        """Ask again next time, for volumes that have no Trash."""
        known = [(v, f) for v, f in sorted(self.discardFolder.items()) if f]
        if not known:
            return self.say("Nothing to forget",
                            "No folder has been set for a volume without a Trash.")
        if not self.confirm(
                "Forget where duplicates go?",
                "You will be asked again the next time duplicates are removed "
                "from a volume with no Trash.\n\n%s\n\nNothing already moved "
                "is affected."
                % "\n".join("%s → %s" % (os.path.basename(v.rstrip("/")), f)
                             for v, f in known),
                "Forget"):
            return
        self.discardFolder = {}
        self.saveState()

    def refreshNames_(self, sender):
        self.refreshNameManager()

    @objc.python_method
    def refreshNameManager(self):
        if self.nameTable is None:
            return
        self.nameRows = self.sharePeople()
        self.nameTable.reloadData()
        self.syncNameButtons()

    @objc.python_method
    def syncNameButtons(self):
        entry = self.selectedName()
        self.useNameButton.setEnabled_(
            entry is not None and not self.isMyName(entry["name"]))
        self.deleteNameButton.setEnabled_(entry is not None)

    @objc.python_method
    def selectedName(self):
        row = self.nameTable.selectedRow() if self.nameTable else -1
        return self.nameRows[row] if 0 <= row < len(self.nameRows) else None

    @objc.python_method
    def nameManagerRow(self, tableView, row):
        view = self.reuse(tableView, "namerow", self.buildManagerRow)
        entry = self.nameRows[row]
        mine = self.isMyName(entry["name"])
        view.viewWithTag_(NAME_TAG).setStringValue_(
            "%s%s" % (entry["name"], "  (you)" if mine else ""))
        note = view.viewWithTag_(TIME_TAG)
        if entry["devices"]:
            note.setStringValue_("%d video%s · %d device%s" % (
                len(entry["videos"]), "" if len(entry["videos"]) == 1 else "s",
                entry["devices"], "" if entry["devices"] == 1 else "s"))
            note.setTextColor_(NSColor.secondaryLabelColor())
        else:
            # Claimed but never published to: the name exists so other devices
            # can see it, and that is worth saying rather than showing "0".
            note.setStringValue_("name only, nothing published")
            note.setTextColor_(NSColor.tertiaryLabelColor())
        return view

    def useName_(self, sender):
        entry = self.selectedName()
        if entry is None:
            return self.say("Nothing selected", "Pick a name first.")
        if not self.confirm(
                "Tag as “%s” from now on?" % entry["name"],
                "This Mac files its tags under that name, and reads the tags "
                "every device using it has published.\n\nYour own tags are "
                "not lost — they are republished under the new name.",
                "Use This Name"):
            return
        self.person = entry["name"]
        self.syncPersonItem()
        self.saveState()
        self.mergeShared()
        self.claimName()
        self.publishTags()
        self.refreshRows()
        self.rebuildTagsMenu()
        self.refreshNameManager()

    def deleteName_(self, sender):
        entry = self.selectedName()
        if entry is None:
            return self.say("Nothing selected", "Pick a name to delete first.")
        where = ", ".join(entry["shares"])
        if entry["devices"]:
            detail = ("Removes %d video%s' worth of tags from %s, published by "
                      "%d device%s under that name.\n\nThe videos themselves "
                      "are not touched, and neither are the tags held on those "
                      "devices — any of them still using this name will "
                      "publish it again." % (
                          len(entry["videos"]),
                          "" if len(entry["videos"]) == 1 else "s", where,
                          entry["devices"], "" if entry["devices"] == 1 else "s"))
        else:
            detail = ("Nothing has been published under it, so this only takes "
                      "the name off %s." % where)
        if self.isMyName(entry["name"]):
            detail += ("\n\nThis is the name this Mac is using, so it will "
                       "come straight back. Change it first if you meant to "
                       "retire it.")
        if not self.confirm("Delete the name “%s”?" % entry["name"],
                            detail, "Delete"):
            return
        failed = []
        for share in entry["shares"]:
            folder = os.path.join(VOLUMES, share, SHARE_DIR, entry["name"])
            try:
                shutil.rmtree(folder)
            except OSError as err:
                failed.append("%s — %s" % (share, err.strerror or "could not be removed"))
        self.refreshNameManager()
        if failed:
            self.say("Some of it could not be removed", "\n".join(failed))

    def windowWillClose_(self, notification):
        closing = notification.object()
        if self.tagWindow is not None and closing.isEqual_(self.tagWindow):
            # Drop the table first: every shared table callback keys off it
            self.tagTable = None
            self.tagWindow = None
        elif self.nameWindow is not None and closing.isEqual_(self.nameWindow):
            self.nameTable = None
            self.nameWindow = None
        elif self.previewWindow is not None and closing.isEqual_(self.previewWindow):
            self.closePreview()
        elif self.dupeWindow is not None and closing.isEqual_(self.dupeWindow):
            self.dupeStop = True          # a sweep has nowhere to report to now
            self.dupeTable = None
            self.folderTable = None
            self.dupeStatusLabel = None
            self.dupeWindow = None
            if self.previewWindow is not None:
                self.previewWindow.close()   # nothing left for it to follow
        elif closing.isEqual_(self.window):
            # Nothing is resumed on the way out: the preview only paused
            # playback so it could be heard, and the window is closing anyway.
            self.previewPausedMain = False
            if self.previewWindow is not None:
                self.previewWindow.close()
            # Video playing on into a window that is not on screen is a
            # confusing way to lose track of what the app is doing.
            self.vlc.pause()
            self.notePosition()
            self.saveState()
            if self.tagWindow is not None:
                self.tagWindow.close()
            if self.nameWindow is not None:
                self.nameWindow.close()
            if self.dupeWindow is not None:
                self.dupeWindow.close()

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
    def isNameTable(self, view):
        return self.nameTable is not None and view.isEqual_(self.nameTable)

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
        self.syncTransport()
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
