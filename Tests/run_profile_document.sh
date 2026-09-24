#!/bin/bash
# The profile as a document — close, reopen, publish state, device name, title.
#
# Real files in a scratch directory, and nothing else: no model, no engine.py,
# no Xcode. `Paths.support` is redirected before any store is built, so nothing
# here can reach a real library.
#
# Usage: Tests/run_profile_document.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_profile_document.swift" "$work/profile_document"
"$work/profile_document"
