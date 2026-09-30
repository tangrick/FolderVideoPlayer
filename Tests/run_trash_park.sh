#!/bin/bash
# The Trash keeps tags, out of sight, for every profile and person; Put Back
# returns them; discard folders are not scanned. Folder management, phase 3.
#
# Usage: Tests/run_trash_park.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_trash_park.swift" "$work/trash_park"
"$work/trash_park"
