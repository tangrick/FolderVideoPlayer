#!/bin/bash
# Share and Prepare Video: the plan always; real remux, trim, re-encode, FFmpeg,
# cancellation, collision and ZIP package runs when FFmpeg is here to make the
# fixtures. The original must stay byte-for-byte what it was.
#
# Usage: Tests/run_share_prep.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_share_prep.swift" "$work/share_prep"
"$work/share_prep"
