#!/bin/bash
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fvp_test "$here/test_tower_precision.swift" "$work/tower-precision"
"$work/tower-precision"
