#!/bin/bash
# The Sep '26 feature batch — bulk tag-a-folder, star ratings, and renaming a
# person in the face registry — against a scratch library.
#
# The three behaviours share one property worth testing together: they are the
# user's judgement about a video or a person, so each must survive a relaunch,
# a repair and a refusal unchanged.
#
# No Xcode, no model, no network. `Paths.support` is redirected before any
# store is built, so nothing here can reach a real library.
#
# Usage: Tests/run_features.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/features" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_features.swift"
"$work/features"
