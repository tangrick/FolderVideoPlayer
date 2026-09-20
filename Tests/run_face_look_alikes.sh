#!/bin/bash
# The face look-alike search's gate: which videos show this person, ranked on
# face vectors alone.
#
# No fixture, no model, no video, no network — the vectors are two-dimensional
# and written by hand, so every expected score in the test is one a reader can
# check with a cosine. The whole model layer is compiled (the same list every
# other gate uses) because SFaceEmbedder, which owns the 0.30 bar, reaches into
# the rest of it.
#
# Usage: Tests/run_face_look_alikes.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/face_look_alikes" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_face_look_alikes.swift"
"$work/face_look_alikes"
