#!/bin/bash
# A renamed or merged tag takes its suggestions, the verdicts on them and its
# fitted head to the new name — and Undo puts them back with the tags.
#
# No model, no video, no Xcode. Scratch root only.
#
# Usage: Tests/run_tag_rename.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_tag_rename.swift" "$work/tag_rename"
"$work/tag_rename"
