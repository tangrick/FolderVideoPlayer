#!/bin/bash
# T01's evaluation corpus: deterministic group splits, video-level grading and
# the benchmark runner's honesty — pure arithmetic plus one real engine pass
# over a scratch root. No model, no library, no Xcode.
#
# Usage: Tests/run_eval_corpus.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/eval_corpus" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_eval_corpus.swift"
"$work/eval_corpus"
