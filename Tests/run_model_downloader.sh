#!/bin/bash
# The download/install gate: checksum verification, all-or-nothing installs, no
# `.partial` left behind, removal, and a catalogue that is reported rather than
# silently empty.
#
# No network, no model, no Xcode: the transport is a fixture and the compile step
# is injected. Scratch root only — nothing here can touch a real library.
#
# Usage: Tests/run_model_downloader.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/model_downloader" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_model_downloader.swift"
"$work/model_downloader"
