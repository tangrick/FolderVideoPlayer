#!/usr/bin/env python3
"""Local video player: folder playback with a persistent favorites list.

Serves only on 127.0.0.1, and only files under a folder you picked this
session or already in favorites. Every request carries a random token
generated at startup, so other pages in your browser can't reach it.
"""

import http.server
import json
import mimetypes
import os
import re
import secrets
import subprocess
import urllib.parse
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
APP_FILE = os.path.join(HERE, "app.html")

# Shared with Video Player.app, so both launchers see the same favorites.
SUPPORT = os.path.expanduser("~/Library/Application Support/Video Player")
FAV_FILE = os.path.join(SUPPORT, "favorites.json")
VIDEO_EXT = {".mp4", ".m4v", ".webm", ".ogv", ".ogg", ".mov"}
TOKEN = secrets.token_urlsafe(16)

mimetypes.add_type("video/webm", ".webm")
mimetypes.add_type("video/ogg", ".ogv")

roots = set()        # folders picked this session
favorites = []       # absolute paths, in the order they were added


def load_favorites():
    global favorites
    try:
        with open(FAV_FILE) as f:
            favorites = json.load(f)
    except (OSError, ValueError):
        favorites = []


def save_favorites():
    os.makedirs(SUPPORT, exist_ok=True)
    with open(FAV_FILE, "w") as f:
        json.dump(favorites, f, indent=1)


def natural_key(s):
    # digit runs compare numerically, so clip2 sorts before clip10
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", s)]


def list_videos(root):
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


def pick_folder():
    """Native macOS folder chooser. Returns None if cancelled."""
    script = (
        'tell application "Finder"\n'
        "  activate\n"
        '  set f to choose folder with prompt "Select a folder of videos"\n'
        "  POSIX path of f\n"
        "end tell"
    )
    done = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if done.returncode != 0:
        return None
    return os.path.normpath(done.stdout.strip()) or None


def entry(path):
    return {"path": path, "name": os.path.basename(path)}


def allowed(path):
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        return False
    if path in favorites:
        return True
    return any(path.startswith(r + os.sep) for r in roots)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- helpers ---------------------------------------------------------

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def fail(self, code, msg):
        self.send_json({"error": msg}, code)

    def parse(self):
        url = urllib.parse.urlparse(self.path)
        return url.path, urllib.parse.parse_qs(url.query)

    def authed(self, query):
        return query.get("t", [""])[0] == TOKEN

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or "{}")

    # -- routes ----------------------------------------------------------

    def do_GET(self):
        path, query = self.parse()

        if path == "/":
            return self.send_app()
        if not self.authed(query):
            return self.fail(403, "bad token")

        if path == "/api/list":
            root = query.get("dir", [""])[0]
            if not os.path.isdir(root):
                return self.fail(400, "not a folder")
            roots.add(os.path.normpath(root))
            return self.send_json([entry(p) for p in list_videos(root)])

        if path == "/api/favorites":
            live = [p for p in favorites if os.path.isfile(p)]
            return self.send_json([entry(p) for p in live])

        if path == "/media":
            target = query.get("path", [""])[0]
            if not allowed(target):
                return self.fail(403, "not allowed")
            return self.send_media(os.path.abspath(target))

        self.fail(404, "no such route")

    def do_POST(self):
        path, query = self.parse()
        if not self.authed(query):
            return self.fail(403, "bad token")

        if path == "/api/pick":
            chosen = pick_folder()
            if chosen:
                roots.add(chosen)
            return self.send_json({"path": chosen})

        if path == "/api/favorites":
            target = os.path.abspath(self.read_body().get("path", ""))
            if not allowed(target):
                return self.fail(403, "not allowed")
            if target not in favorites:
                favorites.append(target)
                save_favorites()
            return self.send_json({"count": len(favorites)})

        self.fail(404, "no such route")

    def do_DELETE(self):
        path, query = self.parse()
        if not self.authed(query):
            return self.fail(403, "bad token")

        if path == "/api/favorites":
            target = os.path.abspath(query.get("path", [""])[0])
            if target in favorites:
                favorites.remove(target)
                save_favorites()
            return self.send_json({"count": len(favorites)})

        self.fail(404, "no such route")

    # -- responses -------------------------------------------------------

    def send_app(self):
        with open(APP_FILE, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_media(self, path):
        size = os.path.getsize(path)
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        start, end, status = 0, size - 1, 200

        rng = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range") or "")
        if rng:
            lo, hi = rng.group(1), rng.group(2)
            if lo:
                start = int(lo)
                if hi:
                    end = min(int(hi), size - 1)
            elif hi:
                start = max(0, size - int(hi))    # suffix range: last N bytes
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(262144, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass    # the browser aborts these constantly while seeking


def main():
    load_favorites()

    server = None
    for port in range(8765, 8785):
        try:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    if server is None:
        raise SystemExit("No free port in 8765-8784.")

    url = f"http://127.0.0.1:{server.server_port}/?t={TOKEN}"
    print(f"Video player running at {url}")
    print(f"{len(favorites)} favorite(s) loaded from {FAV_FILE}")
    print("Close this window (or press Ctrl+C) to stop.")
    webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
