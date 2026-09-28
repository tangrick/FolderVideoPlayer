#!/bin/bash
# What a profile carries to another Mac — tags, people, file facts, pinned
# folders — end to end through the library, as File ▸ Open adopts it.
#
# Two scratch support roots, one scratch share; no model, no network, no Xcode.
#
# Usage: Tests/run_profile_travels.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_profile_travels.swift" "$work/profile_travels"
"$work/profile_travels"
