#!/bin/bash
# Every tag profile follows a move: the other profiles on the renaming Mac,
# every person's folder on the share, and the other person's own Mac at its
# next sync. Folder management, phase 2.
#
# Usage: Tests/run_profile_relocation.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_profile_relocation.swift" "$work/profile_relocation"
"$work/profile_relocation"
