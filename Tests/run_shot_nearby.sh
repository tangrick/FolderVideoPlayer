#!/bin/bash
# The videos taken within a few days of one video, nearest day first — what a
# row's "Find Taken Around the Same Time" lists.
#
# Pure arithmetic on a fixed calendar: no model, no cache tree, no Xcode.
#
# Usage: Tests/run_shot_nearby.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_shot_nearby.swift" "$work/shot_nearby"
"$work/shot_nearby"
