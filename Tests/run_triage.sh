#!/bin/bash
# Triage mode, phase 1: the queue, the numbered strip, what each answer records
# (accepted, rejected, ignored, or nothing), the "nothing to tag" mark, and an
# undo that restores tags, verdicts and the mark exactly.
#
# Usage: Tests/run_triage.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_triage.swift" "$work/triage"
"$work/triage"
