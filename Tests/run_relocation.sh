#!/bin/bash
# Relocation: a renamed or moved video keeps everything the app knows about it,
# its subtitle files travel with it, and a move a crash cut short is finished at
# the next launch. Folder management, phase 1.
#
# Usage: Tests/run_relocation.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_relocation.swift" "$work/relocation"
"$work/relocation"
