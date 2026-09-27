#!/bin/bash
# Audio and subtitle tracks: SRT/VTT parsing, subtitle files beside a video, and
# a saved choice resolved against what this file has.
#
# Usage: Tests/run_media_tracks.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_media_tracks.swift" "$work/media_tracks"
"$work/media_tracks"
