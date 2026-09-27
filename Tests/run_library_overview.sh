#!/bin/bash
# The library overview's sections: continue watching, recently added and
# watched, unwatched, suggestions to review, analysis trouble — hidden excluded.
#
# Usage: Tests/run_library_overview.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_library_overview.swift" "$work/library_overview"
"$work/library_overview"
