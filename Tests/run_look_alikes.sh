#!/bin/bash
# The look-alike search's gate: candidates, scores, refusals and unseen counts,
# compared against engine.py's own `tag_candidates`.
#
# The fixture is REGENERATED on every run, so it cannot describe a command that
# has since changed — edit tag_candidates in engine.py and this fails the same
# day.
#
# No model, no video, no Xcode: about a second.
#
# Usage: Tests/run_look_alikes.sh
#   FVP_PARITY_PY   python with numpy (default /opt/anaconda3/bin/python3)
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
py="${FVP_PARITY_PY:-/opt/anaconda3/bin/python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$py" "$here/../docs/coreml-spike/lookalike_parity.py" "$work/lookalike_fixture.json" >/dev/null

fvp_test "$here/test_look_alikes.swift" "$work/look_alikes"
"$work/look_alikes" "$work/lookalike_fixture.json"
