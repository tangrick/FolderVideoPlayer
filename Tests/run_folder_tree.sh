#!/bin/bash
# The Organize window's model: the folder tree, listings, progress and Stop.
# Folder management, phase 5.
#
# Usage: Tests/run_folder_tree.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_folder_tree.swift" "$work/folder_tree"
"$work/folder_tree"
