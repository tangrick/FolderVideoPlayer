#!/bin/bash
# The fitted heads' storage gate: merge-never-replace, the nsfw collision, a
# bit-exact round trip, and the four ways a bad file is refused.
#
# No model, no video, no Xcode. Scratch root only — nothing here can touch a
# real library (Paths.support is never the default in this test).
#
# Usage: Tests/run_trained_heads.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/trained_heads" \
    "$here/../FolderVideoPlayer/Model/Formatting.swift" \
    "$here/../FolderVideoPlayer/Model/Paths.swift" \
    "$here/../FolderVideoPlayer/Model/ProfileBundle.swift" \
    "$here/../FolderVideoPlayer/Model/JSONStore.swift" \
    "$here/../FolderVideoPlayer/Model/ModelSpace.swift" \
    "$here/../FolderVideoPlayer/Model/LogisticHead.swift" \
    "$here/test_trained_heads.swift" \
    -framework Accelerate
"$work/trained_heads"
