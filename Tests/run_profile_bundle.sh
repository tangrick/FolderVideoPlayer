#!/bin/bash
# A tag profile as one document — the bundle layout, the manifest, and the
# one-time migration of the legacy files into it.
#
# Real files in a scratch directory, and nothing else: no model, no engine.py,
# no Xcode. `Paths` builds every per-profile path out of `ProfileBundle`, so
# what this suite pins is the layout the rest of the app reads.
#
# Usage: Tests/run_profile_bundle.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/profile_bundle" \
    "$model/Formatting.swift" "$model/JSONStore.swift" \
    "$model/ProfileBundle.swift" "$model/Paths.swift" \
    "$here/test_profile_bundle.swift"
"$work/profile_bundle"
