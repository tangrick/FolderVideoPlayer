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
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_trained_heads.swift" "$work/trained_heads"
"$work/trained_heads"
