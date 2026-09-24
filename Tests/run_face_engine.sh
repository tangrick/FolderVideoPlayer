#!/bin/bash
# The face engine's parity gate: the ported YuNet detector, the Umeyama
# alignment and the 18 MB SFace embedder, all measured against the Python-era
# pipeline they replace — cv2.FaceDetectorYN, cv2.alignCrop, and onnxruntime
# SFace, via a fixture that carries real frames and real reference vectors.
#
# Models are optional, the arithmetic is not: the transform, the /32 padding and
# the integer-box NMS are checked with nothing installed, so a bare machine still
# exercises the parts a re-conversion cannot break. The fixture and the compiled
# packages are dev-time artifacts (~/fvp-coreml-models), so when either is absent
# the remaining checks SKIP loudly rather than reddening the gate.
#
# Usage: Tests/run_face_engine.sh
#   FVP_FACE_FIXTURE  the fixture (default <fixtures>/face_engine/face_engine_fixture.json)
#   FVP_FACE_MODELS   the directory holding yunet.mlpackage + sface.mlpackage
#   FVP_FIXTURE_DIR   where the spike's artifacts live (default ~/fvp-coreml-models,
#                     then ~/fvp/fvp-coreml-models — this workspace nests scratch
#                     dirs under a second fvp/, see docs/coreml-spike/sface_torch.py)
#   FVP_BUNDLES       the packed catalogue to check the faces install paths against
#                     (default dist/ai-bundles.json; skipped when it is absent,
#                     because dist/ is build output and a clone has none)
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixtures="${FVP_FIXTURE_DIR:-}"
if [ -z "$fixtures" ]; then
    for d in "$HOME/fvp-coreml-models" "$HOME/fvp/fvp-coreml-models"; do
        if [ -d "$d" ]; then fixtures="$d"; break; fi
    done
fi
fixture="${FVP_FACE_FIXTURE:-$fixtures/face_engine/face_engine_fixture.json}"

# The packed catalogue, when one is on disk. It is what the installer reads, so
# it is the only thing that can prove the bundle's `install` paths are the paths
# `FaceDetector`/`SFaceEmbedder` look in.
if [ -z "${FVP_BUNDLES:-}" ] && [ -f "$here/../dist/ai-bundles.json" ]; then
    FVP_BUNDLES="$here/../dist/ai-bundles.json"
fi
export FVP_BUNDLES

fvp_test "$here/test_face_engine.swift" "$work/face_engine"
"$work/face_engine" "$fixture" "${FVP_FACE_MODELS:-$fixtures}"
