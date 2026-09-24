#!/bin/bash
# T01's evaluation corpus: deterministic group splits, video-level grading and
# the benchmark runner's honesty — pure arithmetic plus one real engine pass
# over a scratch root. No model, no library, no Xcode.
#
# Usage: Tests/run_eval_corpus.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_eval_corpus.swift" "$work/eval_corpus"
"$work/eval_corpus"
