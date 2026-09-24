#!/bin/bash
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fvp_test "$here/test_model_space_validation.swift" "$work/marker-tests"
"$work/marker-tests"
