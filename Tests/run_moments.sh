#!/bin/bash
# Moments: validation, ordering, disk round trips, moved files, per-profile
# stores, delete and undo.
#
# Usage: Tests/run_moments.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_moments.swift" "$work/moments"
"$work/moments"
