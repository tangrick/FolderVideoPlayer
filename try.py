#!/usr/bin/env python3
"""Run the player against a throwaway copy of your data.

The real app keeps favorites, tags and resume positions in
~/Library/Application Support/FolderVideoPlayer. Testing an unfinished build
straight against those risks mangling them, so this points the app at a copy
under /tmp instead: everything you do here is real enough to judge, and
nothing you do here can touch the originals.

    ./venv/bin/python try.py

Delete the sandbox and start over at any time:

    rm -rf /tmp/fvp-sandbox
"""

import os
import shutil

import player

REAL = player.SUPPORT
SANDBOX = "/tmp/fvp-sandbox"

os.makedirs(SANDBOX, exist_ok=True)
for name in ["favorites.json", "tags.json", "state.json"]:
    source, copy = os.path.join(REAL, name), os.path.join(SANDBOX, name)
    if os.path.exists(source) and not os.path.exists(copy):
        shutil.copy(source, copy)       # start from what you actually have

player.SUPPORT = SANDBOX
player.FAV_FILE = os.path.join(SANDBOX, "favorites.json")
player.TAGS_FILE = os.path.join(SANDBOX, "tags.json")
player.STATE_FILE = os.path.join(SANDBOX, "state.json")

print("data sandbox: %s   (your real data is untouched)" % SANDBOX)
player.main()
