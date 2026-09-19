#!/bin/bash
# The versioned evidence store (T05's other half): timed evidence round-trips,
# unreviewable rows are refused and a batch is all-or-nothing, confidence stays
# beside its capability, only a human's yes or no is training data, transcript
# search works for both languages this library holds, profiles stay disjoint, an
# older schema is backed up before it is migrated, and a file this app did not
# write — or a NEWER one — is refused and left untouched.
#
# No network, no model, no Xcode: scratch roots and hand-made SQLite files.
#
# Usage: Tests/run_evidence_store.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O -o "$work/evidence_store" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_evidence_store.swift"
"$work/evidence_store"
