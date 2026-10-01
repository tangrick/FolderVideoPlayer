#!/bin/bash
# Library folders: the list of every folder the library draws videos from, and
# taking one out of the profile's library — what leaves, what must not, undo.
#
# Usage: Tests/run_library_folders.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_library_folders.swift" "$work/library_folders"
"$work/library_folders"
