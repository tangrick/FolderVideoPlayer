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
    NSEventModifierFlagCommand,
    NSEventModifierFlagControl,
    NSEventModifierFlagShift,
    NSColor,
    NSFileManager,
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
    NSClickGestureRecognizer,
    NSScrollView,
    NSSearchField,
    NSSlider,
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
DUPE_W, DUPE_H = 720, 560
DUPE_ROW_H = 22
KEEP_TAG = 5
RADIO_BUTTON = 4              # NSButtonTypeRadio
SWITCH_BUTTON = 3             # NSButtonTypeSwitch
FAV_NOTE_W = 130

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

    Grouped on the full hash where there is one and the fingerprint otherwise,
    so verifying a group tightens it rather than splitting it in two.
    """
    groups = {}
    for key, entry in index.items():
        mark = entry.get("full") or entry.get("fp")
        if not mark:
            continue
        if verified_only and not entry.get("full"):
            continue
        groups.setdefault(("full" if entry.get("full") else "fp", mark), []).append(key)
    return [sorted(keys) for keys in groups.values() if len(keys) > 1]


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
        self.printGen = 0
        self.dupeWindow = None
        self.dupeTable = None
        self.dupeRows = []
        self.dupeFolders = []
        self.dupeScanning = False
        self.dupeStop = False
        self.dupeStatus = ""
        self.dupeKeep = {}            # group id -> the key to keep
        self.verifyDupes = True
        self.dupeStatusLabel = None
        self.folderTable = None
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
                for key in group:
                    out[key] = [k for k in group if k != key]
            self.dupeCache = out
        return self.dupeCache

    @objc.python_method
    def dupesChanged(self):
        self.dupeCache = None

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
        """One item, carrying the count when there is one to carry."""
        groups = len(duplicate_groups(self.prints))
        self.dupeCountItem.setTitle_(
            "Find Duplicates… (%d found)" % groups if groups else "Find Duplicates…")
        self.watchItem.setState_(STATE_ON if self.watchDupes else STATE_OFF)

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
        self.dupeWindow.setMinSize_(NSMakeSize(560, 420))
        self.dupeWindow.center()
        self.dupeWindow.setReleasedWhenClosed_(False)
        self.dupeWindow.setDelegate_(self)

        content = NSView.alloc().initWithFrame_(rect)
        top = DUPE_H

        # folders to search
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

        # results
        self.dupeTable = NSTableView.alloc().initWithFrame_(
            NSMakeRect(0, 0, DUPE_W, top - BAR_HEIGHT))
        column = NSTableColumn.alloc().initWithIdentifier_("dupe")
        column.setWidth_(DUPE_W - 24)
        self.dupeTable.addTableColumn_(column)
        self.dupeTable.setHeaderView_(None)
        self.dupeTable.setRowHeight_(DUPE_ROW_H)
        self.dupeTable.setDataSource_(self)
        self.dupeTable.setDelegate_(self)
        scroll = NSScrollView.alloc().initWithFrame_(
            NSMakeRect(0, BAR_HEIGHT, DUPE_W, top - BAR_HEIGHT))
        scroll.setDocumentView_(self.dupeTable)
        scroll.setHasVerticalScroller_(True)
        scroll.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        content.addSubview_(scroll)

        # what to keep, and the one destructive button
        foot = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, BAR_HEIGHT))
        foot.setAutoresizingMask_(NSViewWidthSizable | NSViewMaxYMargin)
        foot.addSubview_(self.barButton("Keep Tagged", "keepTagged:", 14))
        foot.addSubview_(self.barButton("Keep Oldest", "keepOldest:", 14 + BUTTON_W + 8))
        foot.addSubview_(self.barButton("Shortest Path", "keepShortest:",
                                        14 + 2 * (BUTTON_W + 8)))
        self.reclaimLabel = self.label(
            NSMakeRect(DUPE_W - 340, (BAR_HEIGHT - 18) / 2, 160, 18),
            11, 0, align=ALIGN_RIGHT, dim=True)
        self.reclaimLabel.setAutoresizingMask_(NSViewMinXMargin)
        foot.addSubview_(self.reclaimLabel)
        self.removeButton = self.barButton("Move to Trash…", "removeDuplicates:",
                                           DUPE_W - BUTTON_W - 60)
        self.removeButton.setFrame_(NSMakeRect(DUPE_W - 170, (BAR_HEIGHT - BUTTON_H) / 2,
                                               156, BUTTON_H))
        self.removeButton.setAutoresizingMask_(NSViewMinXMargin)
        foot.addSubview_(self.removeButton)
        content.addSubview_(foot)

        self.dupeWindow.setContentView_(content)
        self.dupeWindow.makeKeyAndOrderFront_(None)

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
        self.dupeRows = []
        groups = self.dupeGroupsForDisplay()
        reclaim = 0
        for group in groups:
            self.dupeRows.append({"head": group})
            for key in group["keys"]:
                self.dupeRows.append({"group": group, "key": key})
            reclaim += group["reclaim"]

        self.folderTable.reloadData()
        self.dupeTable.reloadData()
        self.updateDupeStatus()
        self.reclaimLabel.setStringValue_(
            "%s in %d group%s" % (human_bytes(reclaim), len(groups),
                                  "" if len(groups) == 1 else "s")
            if groups else "")
        self.removeButton.setEnabled_(bool(groups) and not self.dupeScanning)

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
            group = item["head"]
            view = self.reuse(tableView, "dupehead", self.buildManagerRow)
            view.viewWithTag_(NAME_TAG).setStringValue_(
                "%d copies · %s each%s" % (len(group["keys"]),
                                           human_bytes(group["size"]),
                                           "" if group["verified"] else " · not verified"))
            note = view.viewWithTag_(TIME_TAG)
            note.setStringValue_("frees %s" % human_bytes(group["reclaim"]))
            note.setTextColor_(NSColor.secondaryLabelColor())
            return view

        group, key = item["group"], item["key"]
        keeping = key == group["keeper"]
        view = self.reuse(tableView, "dupefile", self.buildDupeRow)
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
    def buildDupeRow(self):
        view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, DUPE_W, DUPE_ROW_H))
        keep = NSButton.alloc().initWithFrame_(NSMakeRect(10, 2, 72, DUPE_ROW_H - 4))
        keep.setButtonType_(RADIO_BUTTON)
        keep.setTag_(KEEP_TAG)
        view.addSubview_(keep)
        name = self.label(NSMakeRect(92, 2, DUPE_W - 92 - 92, DUPE_ROW_H - 4),
                          11, NAME_TAG)
        name.setAutoresizingMask_(NSViewWidthSizable)
        view.addSubview_(name)
        note = self.label(NSMakeRect(DUPE_W - 88, 2, 78, DUPE_ROW_H - 4),
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
        """Groups, biggest reclaim first, each with its keeper decided."""
        rows = []
        for group in duplicate_groups(self.prints):
            alive = [k for k in group if os.path.isfile(tag_path(k))]
            if len(alive) < 2:
                continue              # one or none left; nothing to choose between
            gid = alive[0]
            keeper = self.dupeKeep.get(gid)
            if keeper not in alive:
                keeper, why = self.suggestKeeper(alive)
            else:
                why = "your choice"
            size = self.prints.get(alive[0], {}).get("size", 0)
            rows.append({"id": gid, "keys": alive, "keeper": keeper,
                         "why": why, "size": size,
                         "reclaim": size * (len(alive) - 1),
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
            self.dupeKeep[group["id"]] = pick
        self.refreshDupeManager()

    def chooseKeeper_(self, sender):
        """A radio button in a row: keep this one, discard the rest of its group.

        The row is found from the key on the button rather than from its tag.
        Cells are reused as the table scrolls, so a tag holding a row number
        goes stale the moment anything moves — and the key does not.
        """
        key = str(sender.toolTip() or "")
        for item in self.dupeRows:
            if item.get("key") == key:
                self.dupeKeep[item["group"]["id"]] = key
                return self.refreshDupeManager()

    def removeDuplicates_(self, sender):
        groups = self.dupeGroupsForDisplay()
        doomed = [(g, k) for g in groups for k in g["keys"] if k != g["keeper"]]
        if not doomed:
            return self.say("Nothing to remove", "Every group already has one copy.")
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
        moved, failed, kept_out = 0, [], 0
        for group, key in doomed:
            path = tag_path(key)
            if path == playing:
                kept_out += 1         # never pull the file out from under playback
                continue
            # Tags first: a file in the Trash can be dragged back, but labelling
            # thrown away with it cannot.
            self.mergeTagsInto(group["keeper"], key)
            ok, why = self.discard(path)
            if ok:
                self.prints.pop(key, None)
                moved += 1
            else:
                failed.append("%s — %s" % (os.path.basename(path), why))

        self.dupesChanged()
        self.savePrints()
        self.saveTags()
        self.dupeKeep = {}
        self.refreshDupeManager()
        self.refreshRows()
        self.rebuildTagsMenu()
        self.syncDupeMenu()

        where = set(f for f in self.discardFolder.values() if f)
        note = "%d moved to the Trash." % moved if not where else (
            "%d moved — to the Trash, and to %s."
            % (moved, ", ".join(sorted(where))))
        if kept_out:
            note += "\n\n%d skipped: still playing." % kept_out
        if failed:
            note += "\n\nCould not move:\n" + "\n".join(failed[:8])
        self.say("Duplicates removed" if moved else "Nothing was moved", note)

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

    # -- the deliberate sweep ---------------------------------------------

    def findDuplicates_(self, sender):
        self.openDupeWindow()
        if not self.dupeFolders and self.folder:
            self.dupeFolders = [self.folder]
        self.refreshDupeManager()

    def addDupeFolder_(self, sender):
        panel = NSOpenPanel.openPanel()
        panel.setCanChooseFiles_(False)
        panel.setCanChooseDirectories_(True)
        panel.setAllowsMultipleSelection_(True)
        if panel.runModal() != 1:
            return
        for url in panel.URLs():
            folder = str(url.path())
            if folder not in self.dupeFolders:
                self.dupeFolders.append(folder)
        self.refreshDupeManager()

    def removeDupeFolder_(self, sender):
        row = self.folderTable.selectedRow()
        if 0 <= row < len(self.dupeFolders):
            del self.dupeFolders[row]
            self.refreshDupeManager()

    def startDupeScan_(self, sender):
        if self.dupeScanning:
            self.dupeStop = True
            return
        if not self.dupeFolders:
            return self.say("Nothing to search",
                            "Add at least one folder to look through.")
        self.dupeScanning = True
        self.dupeStop = False
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
                "sweepDone:", None, False)
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
        for folder in list(self.dupeFolders):
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

    def sweepDone_(self, _):
        self.dupeScanning = False
        self.dupesChanged()
        self.savePrints()
        self.dupeStatus = ("Stopped — what was found is kept."
                           if self.dupeStop else "Done.")
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
        if self.isDupeTable(table) or self.isFolderTable(table):
            return
        if self.isNameTable(table):
            return self.syncNameButtons()     # the buttons follow the selection
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
        if self.tagPanelOpen and self.selectMode:
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
            return len(self.dupeFolders)
        return len(self.rows)

    def tableView_isGroupRow_(self, tableView, row):
        if self.isDupeTable(tableView):
            return 0 <= row < len(self.dupeRows) and "head" in self.dupeRows[row]
        return self.isPlainRow(tableView, row) is None

    def tableView_shouldSelectRow_(self, tableView, row):
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
            folder = self.dupeFolders[row]
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
        # Setting a rate on a paused player would start it playing, so the
        # choice is only pushed through while something is actually running.
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

    @objc.python_method
    def playhead(self):
        """Where we are, in seconds. Zero before anything has opened."""
        t = self.vlc.time() if getattr(self, "vlc", None) else None
        return (t.intValue() / 1000.0) if t else 0.0

    @objc.python_method
    def mediaLength(self):
        """How long the current video is, in seconds; 0 until VLC knows."""
        media = self.vlc.media() if getattr(self, "vlc", None) else None
        length = media.length() if media else None
        value = length.intValue() if length else 0
        return value / 1000.0 if value > 0 else 0.0

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
        elif self.dupeWindow is not None and closing.isEqual_(self.dupeWindow):
            self.dupeStop = True          # a sweep has nowhere to report to now
            self.dupeTable = None
            self.folderTable = None
            self.dupeStatusLabel = None
            self.dupeWindow = None
        elif closing.isEqual_(self.window):
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
