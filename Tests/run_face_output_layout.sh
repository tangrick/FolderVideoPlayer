#!/bin/bash
# The face models' output reader: padded, packed and float16 arrays all read
# their real values. No model, no fixture — hand-made MLMultiArrays.
#
# Usage: Tests/run_face_output_layout.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_face_output_layout.swift" "$work/face_output_layout"
"$work/face_output_layout"
