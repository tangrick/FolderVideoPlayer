#!/bin/bash
# S1's gate: a video becomes the one signal a speech model takes — 16 kHz mono
# floats — using only what macOS ships. No ffmpeg, no Python, no network.
#
# Proves what a reviewer would otherwise take on trust: a real AAC track decodes
# to about the right length and rate; sound stays sound and silence stays silent;
# a video with no audio track says so instead of failing; a time window is really
# honoured, which is what lets a long film be transcribed in pieces; malformed
# ranges (backwards, half a range, past the end) are refused as themselves; a
# missing file is refused rather than crashed on; and the WAV written for later
# inspection is read back correctly by the OS decoder, not by our own code.
#
# No model, no network, no Xcode: three committed fixtures totalling 26 KB.
#
# Usage: Tests/run_audio_extraction.sh
#   FVP_AUDIO_FIXTURES  where the fixtures are (default Tests/fixtures/audio)
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixtures="${FVP_AUDIO_FIXTURES:-$here/fixtures/audio}"

fvp_test "$here/test_audio_extraction.swift" "$work/audio_extraction"
"$work/audio_extraction" "$fixtures"
