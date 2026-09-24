#!/bin/bash
# Phase 2 gate: the Swift embedding path AND the Core ML classify path,
# standalone, against a real video, the real vision model (SigLIP 2) and the
# real prompt table. No Xcode build needed.
#
# Usage: Tests/run_phase2.sh <video>
#   FVP_PHASE2_MODEL  the image model (default: ~/fvp-coreml-models/…)
#   FVP_PROMPT_DIR    the prompt table (default: ~/fvp-coreml-models)
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
# The SHARED list, not one kept here. This script hand-kept its own set of
# source files and stopped compiling the moment Phase 3 and 4 landed — a
# `swiftc` error that reads as a broken test rather than as a stale list, which
# is the trap `model_sources.sh` exists to close.
. "$here/harness.sh"

img="${FVP_PHASE2_MODEL:-$HOME/fvp-coreml-models/siglip2_base_image.mlpackage}"
prompts="${FVP_PROMPT_DIR:-$HOME/fvp-coreml-models}"
nsfw="${FVP_NSFW_MODEL:-$HOME/fvp-coreml-models/falconsai.mlpackage}"
video="${1:-}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -z "$video" ]; then
    echo "usage: run_phase2.sh <video>   (FVP_PHASE2_MODEL overrides the model)"
    exit 2
fi

# Skips loudly (exit 0), like run_coreml.sh: the model and the prompt table are
# dev-time artifacts, and a rig that silently halves itself is worse than one
# that says what it is missing.
if [ ! -e "$img" ]; then
    echo "SKIP phase2 — no image model at $img"
    exit 0
fi
if [ ! -f "$prompts/siglip2_base_prompts.json" ]; then
    echo "SKIP phase2 — no prompt table at $prompts (build it with docs/coreml-spike/precompute_text_siglip2.py)"
    exit 0
fi
# The verdict is Falconsai's since Phase 4, so classify needs that model too.
if [ ! -e "$nsfw" ]; then
    echo "SKIP phase2 — no Safe/NSFW model at $nsfw (build it with docs/coreml-spike/convert_falconsai_ship.py)"
    exit 0
fi

fvp_test "$here/test_phase2.swift" "$work/phase2"
"$work/phase2" "$img" "$video" "$work/support" "$prompts" "$nsfw"
