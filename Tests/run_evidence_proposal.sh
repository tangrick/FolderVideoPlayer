#!/bin/bash
# The evidence producer (T07's first half): per-frame prompt-table scores become
# reviewable timed evidence — one row per run of sightings rather than one per
# frame, confidence not averaged, gaps honest about what was not sampled — and a
# re-run replaces its OWN unanswered proposals instead of doubling the review
# list, while everything a human answered and every other revision's or model's
# evidence survives untouched.
#
# No network, no model, no Xcode: readings are hand-made, the store is real SQLite
# in a temporary root.
#
# Usage: Tests/run_evidence_proposal.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/evidence_proposal" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_evidence_proposal.swift"
"$work/evidence_proposal"
