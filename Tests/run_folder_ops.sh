#!/bin/bash
# Folder operations: create, rename, move, and delete only when empty.
# Folder management, phase 4.
#
# Usage: Tests/run_folder_ops.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_folder_ops.swift" "$work/folder_ops"
"$work/folder_ops"
