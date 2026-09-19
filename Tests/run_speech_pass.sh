#!/bin/bash
# S4's gate: the speech pass — what it writes, what it refuses, and what it must
# never write.
#
# Run against a FAKE transcriber, so this needs no model, no network and no
# 646 MB download: what is under test is the pass's own behaviour (progress, the
# replacement rule, the revision guard, cancellation). The WhisperKit glue is
# not compiled here at all — it is verified by the app build and by
# Tests/check_speech_runtime.sh.
#
# Usage: Tests/run_speech_pass.sh
#   FVP_AUDIO_FIXTURES  where the fixtures are (default Tests/fixtures/audio)
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixtures="${FVP_AUDIO_FIXTURES:-$here/fixtures/audio}"

swiftc -O -o "$work/speech_pass" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_speech_pass.swift"
"$work/speech_pass" "$fixtures"
