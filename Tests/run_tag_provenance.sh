#!/bin/bash
# Where a tag came from: read off the FILE (folder, capture date, camera, GPS)
# or guessed from the picture by a model.
#
# Pure arithmetic over a dictionary: no FileManager, no models, no Xcode.
# `Paths.swift` and `Formatting.swift` come along because the store's file
# location lives there.
#
# Usage: Tests/run_tag_provenance.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
model="$here/../FolderVideoPlayer/Model"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_tag_provenance.swift" "$work/tag_provenance"
"$work/tag_provenance"
