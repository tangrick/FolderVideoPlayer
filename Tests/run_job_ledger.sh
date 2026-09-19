#!/bin/bash
# T05's job ledger and explicit runner: crash-safe idempotent persistence,
# obsolete/foreign job refusal, profile isolation, and a runner that records
# what actually happened. No model, no library, no Xcode; the engine pass runs
# against a scratch root with nothing installed, so its honest failure IS the
# fixture.
#
# Usage: Tests/run_job_ledger.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/job_ledger" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_job_ledger.swift"
"$work/job_ledger"
