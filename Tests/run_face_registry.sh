#!/bin/bash
# The face registry's gate: the crop-keyed cache, the per-profile name registry,
# the matcher, the similar-face ranking and the prominence clustering — all
# compared against engine.py's own face commands on a cache tree the fixture
# generator writes.
#
# The fixture is REGENERATED on every run, so it cannot describe a command that
# has since changed: edit `name_cluster` or `similar_faces` in engine.py and this
# fails the same day.
#
# No models, no video, no Xcode, no network: about a second.
#
# Usage: Tests/run_face_registry.sh
#   FVP_PARITY_PY       python with numpy (default /opt/anaconda3/bin/python3)
#   FVP_REGISTRY_FIXTURE  where to write the fixture (default a temp file)
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
py="${FVP_PARITY_PY:-/opt/anaconda3/bin/python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixture="${FVP_REGISTRY_FIXTURE:-$work/face_registry_fixture.json}"
"$py" "$here/../docs/coreml-spike/face_registry_parity.py" "$fixture" >/dev/null

swiftc -O -o "$work/face_registry" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_face_registry.swift"
"$work/face_registry" "$fixture"
