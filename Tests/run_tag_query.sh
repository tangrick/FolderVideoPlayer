#!/bin/bash
# The library panel's ⌘-click query: several names combined into one playlist,
# Any or All, across tags, stars, people and readings — hidden videos never in it.
#
# Usage: Tests/run_tag_query.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_tag_query.swift" "$work/tag_query"
"$work/tag_query"
