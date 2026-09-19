#!/bin/bash
# Kept versions of an installed pack: what an install keeps a copy of, that the
# same catalog entry kept twice is one version, that a copy that never finished
# is invisible, that a tampered kept copy is refused before anything is staged,
# that "is this version the installed one" is the receipt's answer, that the
# store is bounded, and that a catalogue cannot install into it.
#
# No network, no model, no Xcode: fixtures on a scratch root only.
#
# Usage: Tests/run_model_store.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/model_store" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_model_store.swift"
"$work/model_store"
