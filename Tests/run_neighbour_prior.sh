#!/bin/bash
# The neighbour prior — the ranking term that asks what the videos shot AROUND
# this one say about a tag.
#
# Pure arithmetic: no model, no cache tree, no engine.py, no Xcode, and a fixed
# clock so "same calendar day" is not a function of when the suite runs. It
# compiles against `Paths.swift` (for `DevOverride`, which the on/off ladder is
# read from) and `Formatting.swift`, which `Paths` needs for `slug`.
#
# Usage: Tests/run_neighbour_prior.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
model="$here/../FolderVideoPlayer/Model"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_neighbour_prior.swift" "$work/neighbour_prior"
"$work/neighbour_prior"
