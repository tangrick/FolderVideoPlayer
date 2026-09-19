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
model="$here/../FolderVideoPlayer/Model"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/tag_provenance" \
    "$model/Formatting.swift" "$model/Paths.swift" \
    "$model/ProfileBundle.swift" \
    "$model/JSONStore.swift" \
    "$model/TagProvenance.swift" \
    "$here/test_tag_provenance.swift"
"$work/tag_provenance"
