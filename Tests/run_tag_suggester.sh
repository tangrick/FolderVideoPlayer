#!/bin/bash
# The suggester's gate: every candidate a video is offered, its confidence, how
# many frames supported it, which source it came from, and its POSITION in the
# list — compared against engine.py's own `suggest_tags`.
#
# The fixture is REGENERATED on every run by calling the real engine function,
# and it writes both a prompt table and a real cache directory for the engine to
# walk, so it cannot describe behaviour that has since changed.
#
# No model, no video, no Xcode: about two seconds.
#
# Usage: Tests/run_tag_suggester.sh
#   FVP_PARITY_PY   python with numpy+torch (default /opt/anaconda3/bin/python3)
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
py="${FVP_PARITY_PY:-/opt/anaconda3/bin/python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$py" "$here/../docs/coreml-spike/suggest_parity.py" "$work" >/dev/null

fvp_test "$here/test_tag_suggester.swift" "$work/tag_suggester"
"$work/tag_suggester" "$work/tag_suggester_fixture.json"
