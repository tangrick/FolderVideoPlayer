#!/bin/bash
# The facts READ off the files — the date, the resolution, the camera, the place
# from GPS — in a store of their own, and the one-time move of them out of the
# tag store.
#
# Pure arithmetic over dictionaries: no FileManager beyond one temp file, no
# models, no Xcode, nothing that touches a real library. `Paths.swift` and
# `JSONStore.swift` come along because the store's file location lives there,
# and `TagKinds`/`AutoTagCore` because the rule for "is this a reading or a
# judgement" is stated there.
#
# Point FVP_REAL_TAGS at a COPY of a real tags.json to have the split reported
# against it — nothing is written.
#
# Usage: Tests/run_metadata_facts.sh [path/to/tags.json]
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
model="$here/../FolderVideoPlayer/Model"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_metadata_facts.swift" "$work/metadata_facts"
if [ -n "${1:-}" ]; then export FVP_REAL_TAGS="$1"; fi
"$work/metadata_facts"
