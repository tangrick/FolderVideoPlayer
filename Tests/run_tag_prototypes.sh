#!/bin/bash
# The library-tag prototypes' gate: which tags a video is offered, their
# confidences and frame counts, and every refusal — compared against engine.py's
# own `_library_prototypes`, `_library_baseline` and `_score_library_tags`.
#
# The fixture is REGENERATED on every run, and it writes a real cache directory
# for engine.py to walk, so it cannot describe behaviour that has since changed.
#
# No model, no video, no Xcode: about two seconds.
#
# Usage: Tests/run_tag_prototypes.sh
#   FVP_PARITY_PY   python with numpy (default /opt/anaconda3/bin/python3)
set -e
here=$(cd "$(dirname "$0")" && pwd)
py="${FVP_PARITY_PY:-/opt/anaconda3/bin/python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$py" "$here/../docs/coreml-spike/prototype_parity.py" "$work/prototype_fixture.json" >/dev/null

swiftc -O -o "$work/tag_prototypes" \
    "$here/../FolderVideoPlayer/Model/LookAlikes.swift" \
    "$here/../FolderVideoPlayer/Model/TagPrototypes.swift" \
    "$here/test_tag_prototypes.swift"
"$work/tag_prototypes" "$work/prototype_fixture.json"
