#!/bin/bash
# The logistic head's gate: the fit, the gate, the split, the held-out metrics
# and the stored weights, all compared against the real engine.py.
#
# The fixture is REGENERATED on every run rather than checked in, so it can
# never describe a trainer that has since changed — if engine.py's train() is
# edited, this test starts failing on the same day.
#
# No model, no video, no Xcode: a second or two.
#
# Usage: Tests/run_logistic_head.sh
#   FVP_PARITY_PY   python with numpy (default /opt/anaconda3/bin/python3)
set -e
here=$(cd "$(dirname "$0")" && pwd)
py="${FVP_PARITY_PY:-/opt/anaconda3/bin/python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$py" "$here/../docs/coreml-spike/head_parity.py" "$work/head_fixture.json" >/dev/null

swiftc -O -o "$work/logistic_head" \
    "$here/../FolderVideoPlayer/Model/Formatting.swift" \
    "$here/../FolderVideoPlayer/Model/Paths.swift" \
    "$here/../FolderVideoPlayer/Model/ProfileBundle.swift" \
    "$here/../FolderVideoPlayer/Model/JSONStore.swift" \
    "$here/../FolderVideoPlayer/Model/ModelSpace.swift" \
    "$here/../FolderVideoPlayer/Model/LogisticHead.swift" \
    "$here/test_logistic_head.swift" \
    -framework Accelerate
"$work/logistic_head" "$work/head_fixture.json"
