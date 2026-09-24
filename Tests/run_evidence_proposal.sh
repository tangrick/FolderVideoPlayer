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
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_evidence_proposal.swift" "$work/evidence_proposal"
"$work/evidence_proposal"
