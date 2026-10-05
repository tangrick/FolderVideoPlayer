#!/bin/bash
set -e
here=$(cd "$(dirname "$0")" && pwd)
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "SKIP face scan progress — FFmpeg is needed to generate the test video"
    exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=64x64:rate=1:duration=12' -c:v mpeg4 "$work/video.mp4"
swiftc -parse-as-library -module-cache-path "$work/cache" \
    "$here/../FolderVideoPlayer/Model/FrameSampler.swift" \
    "$here/test_face_scan_progress.swift" -o "$work/check"
"$work/check" "$work/video.mp4"
