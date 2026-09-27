#!/bin/bash
# Watch state and smart collections: thresholds, replay, manual marks, moves and
# profiles; every rule kind, All/Any, missing values, hidden videos, and a file
# from a newer build that still loads.
#
# Usage: Tests/run_smart_collections.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_smart_collections.swift" "$work/smart_collections"
"$work/smart_collections"
