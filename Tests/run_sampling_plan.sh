#!/bin/bash
# T06's shared sampling plan: source-revision binding, the adaptive layout's
# budget guarantee and fallback, the counters' honest arithmetic, and the
# comparison harness's rules — plus, when a real clip is available, one real
# adaptive-vs-uniform measurement. No model, no library, no Xcode.
#
# Usage: Tests/run_sampling_plan.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fvp_test "$here/test_sampling_plan.swift" "$work/sampling_plan"
"$work/sampling_plan"
