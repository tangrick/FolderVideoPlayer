#!/bin/bash
# Hidden videos — the password, the filter, and the invariant that hiding
# changes nothing else about a video.
#
# No Xcode, no model, no network. `Paths.support` is redirected to a scratch
# directory before any store is built, so nothing here can reach a real library
# — and a temporary media file of known size proves the file itself is never
# renamed, moved, flagged or resized by hiding.
#
# Usage: Tests/run_hidden.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/hidden" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_hidden.swift"
"$work/hidden"
