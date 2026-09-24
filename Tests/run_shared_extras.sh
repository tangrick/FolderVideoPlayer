#!/bin/bash
# Named people and transcripts following a profile to another Mac through the
# shares: two scratch support roots, one scratch share, no network, no model.
#
# Usage: Tests/run_shared_extras.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_shared_extras.swift" "$work/shared_extras"
"$work/shared_extras"
