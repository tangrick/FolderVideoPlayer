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
. "$here/harness.sh"
model="$here/../FolderVideoPlayer/Model"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_profile_bundle.swift" "$work/profile_bundle"
"$work/profile_bundle"
