#!/bin/bash
# The transcript editor and its exports: every edit and its undo, validation that
# flags rather than rewrites, the store keeping the machine's lines behind a
# correction, a moved file taking its transcript along, and SRT/VTT/TXT/CSV/JSON
# that agree with each other. Real SQLite in a temporary root; no model.
#
# Usage: Tests/run_transcript_edit.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_transcript_edit.swift" "$work/transcript_edit"
"$work/transcript_edit"
