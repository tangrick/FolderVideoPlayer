#!/bin/bash
# The packed catalogue, checked by the code that would refuse it.
#
# test_face_engine decodes a packed catalogue to look at the faces bundle. This
# gate runs the WHOLE document through `ModelCatalogPolicy.validate` — the
# function that stands between a catalogue and the user's disk — and then asks
# the questions that decide whether the new Speech bundle works at all:
#
#   * does the validator accept it? (a path outside tags/ or models/ makes the
#     app refuse EVERY bundle, not just the new one)
#   * is every asset URL credential-free https, pinned to a 40-character commit
#     and not pointing at a branch?
#   * do the catalogue's install paths land where the Speech row looks for what
#     is installed — otherwise a successful install reads as "nothing installed"
#   * is the pack's adapter one this build supports for speech, and *not*
#     accepted as a different feature's model?
#   * does the descriptor name its licence and revision (what the release notes
#     and the installer need)?
#
# Skips in one piece when no catalogue is handed over: dist/ is build output,
# not a repository file, so a clone with no packed release is normal.
#
# Usage: FVP_BUNDLES=/path/to/dist/ai-bundles.json Tests/run_catalogue_check.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_catalogue.swift" "$work/catalogue"

# Default to the local packed release when one exists: on a machine that has
# packed a release this gate really checks it, and on a bare clone the test
# skips itself with a reason rather than passing for the wrong reason.
FVP_BUNDLES="${FVP_BUNDLES:-$here/../dist/ai-bundles.json}" "$work/catalogue"
