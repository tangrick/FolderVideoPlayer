#!/bin/bash
# T02's gate: the pack registry and the persisted choice of which model pack a
# capability uses — one choice per capability, incompatible packs refused with
# their reason, a catalogue that cannot write the choice, removal that forgets,
# and nothing-chosen behaving exactly as before selections existed.
#
# No network, no model, no Xcode: the transport is a fixture and the compile step
# is injected. Scratch root only — nothing here can touch a real library.
#
# Usage: Tests/run_model_selection.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/model_selection" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_model_selection.swift"
"$work/model_selection"
