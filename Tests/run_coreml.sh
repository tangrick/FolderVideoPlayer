#!/bin/bash
# The Core ML classify path through AnalysisEngine itself: one real video, the
# real model, the real prompt table, FVP_ENGINE=coreml, and a scratch support
# dir — no library, no Xcode, no python.
#
# Skips (loudly, exit 0) when the model or a test video is not on this machine:
# both are dev-time artifacts until Phase 5 ships the downloader.
#
# Usage: Tests/run_coreml.sh [video]
#   FVP_TEST_VIDEO   the video to classify (default: $1, then a known sample)
#   FVP_MODELS_DIR   where the models live (default ~/fvp-coreml-models, then
#                     ~/fvp/fvp-coreml-models — this workspace nests the scratch
#                     dirs under a second fvp/)
#   FVP_PHASE2_MODEL the image model (default <models>/siglip2_base_image.mlpackage)
#   FVP_PROMPT_DIR   the prompt table (default <models>)
#   FVP_NSFW_MODEL   the Safe / NSFW package (default <models>/falconsai.mlpackage)
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"

# Two candidate locations, for the same reason as run_prompt_table.sh: looking in
# only one of them turned this whole stage into a silent SKIP, and a stage that
# skipped still let the suite report all-pass — which is how the stale assertions
# in `test_coreml_run.swift` outlived the behaviour they described.
if [ -z "${FVP_MODELS_DIR:-}" ]; then
    for d in "$HOME/fvp-coreml-models" "$HOME/fvp/fvp-coreml-models"; do
        if [ -e "$d/siglip2_base_image.mlpackage" ]; then FVP_MODELS_DIR="$d"; break; fi
    done
fi
modelsDir="${FVP_MODELS_DIR:-$HOME/fvp-coreml-models}"

img="${FVP_PHASE2_MODEL:-$modelsDir/siglip2_base_image.mlpackage}"
prompts="${FVP_PROMPT_DIR:-$modelsDir}"
nsfw="${FVP_NSFW_MODEL:-$modelsDir/falconsai.mlpackage}"
video="${1:-${FVP_TEST_VIDEO:-$HOME/Downloads/X Videos/GjgTjtwGsxRqq0_J.mp4}}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ ! -e "$img" ]; then
    echo "SKIP coreml run — no image model at $img"
    exit 0
fi
if [ ! -f "$prompts/siglip2_base_prompts.json" ]; then
    echo "SKIP coreml run — no prompt table at $prompts (build it with docs/coreml-spike/precompute_text_siglip2.py)"
    exit 0
fi
if [ ! -e "$nsfw" ]; then
    echo "SKIP coreml run — no Safe/NSFW model at $nsfw (build it with docs/coreml-spike/convert_falconsai_ship.py)"
    exit 0
fi
if [ ! -f "$video" ]; then
    # No library sample on this machine. Synthesize one rather than skipping:
    # everything this stage asserts about the in-process path — the ranked,
    # capped list, the frame count, the payload shape, the face pass claiming
    # nothing without an embedder — is structural, and a generated clip has
    # frames like any other. It used to SKIP here, and the skip is why two
    # assertions in `test_coreml_run.swift` outlived the behaviour they
    # described and one of them was failing when finally run (2026-09-13).
    #
    # The clip is deterministic on purpose (fixed source, size, rate, length),
    # so the frame count this stage reports does not wander between runs.
    # ffmpeg is only needed to MAKE it — the Core ML path itself needs neither
    # ffmpeg nor Python, which is the whole point of the phase.
    for f in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
        if [ -x "$f" ]; then generator="$f"; break; fi
    done
    if [ -n "${generator:-}" ]; then
        video="$work/sample.mp4"
        "$generator" -y -f lavfi -i testsrc=size=320x240:rate=10 -t 3 \
            -pix_fmt yuv420p "$video" >/dev/null 2>&1
        if [ -s "$video" ]; then
            echo "· generated a 3 s test clip at $video (no FVP_TEST_VIDEO was usable)"
        else
            echo "SKIP coreml run — no test video, and ffmpeg produced none"
            exit 0
        fi
    else
        echo "SKIP coreml run — no test video at $video (pass one, or set FVP_TEST_VIDEO)"
        exit 0
    fi
fi

# The runner may MOVE what it is handed (a compiled .mlmodelc is used in place,
# not compiled again), so it is given a copy: pointing this at a live install
# must never gut it. Cheap, and it makes the rig safe to use.
#
# The copy keeps the name it arrived with, because the runner decides whether to
# compile by looking at the suffix. Renaming a `.mlpackage` to `image_model` made
# it install the raw package under a `.mlmodelc` name, and every load then failed
# with "Compile the model with Xcode or MLModel.compileModel(at:)" — four FAILs
# that read like a broken Core ML path rather than a renamed argument.
if [ -d "$img" ]; then
    cp -R "$img" "$work/$(basename "$img")"
    img="$work/$(basename "$img")"
fi

swiftc -O -o "$work/coreml_run" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/test_coreml_run.swift"
"$work/coreml_run" "$img" "$prompts" "$video" "$nsfw"
