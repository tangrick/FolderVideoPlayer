#!/bin/bash
# Opt-in background upkeep, the decisions: scan diffs and moves, the queue
# (never hidden videos), pausing, giving up, and a queue that survives a quit.
#
# Usage: Tests/run_maintenance.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_maintenance.swift" "$work/maintenance"
"$work/maintenance"
