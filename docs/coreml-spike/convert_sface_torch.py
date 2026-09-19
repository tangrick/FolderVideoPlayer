#!/usr/bin/env python3
"""Task 6.1 — SFace to Core ML, and the gate that decides whether it ships.

The route is the plan's first choice: ONNX graph -> PyTorch (`sface_torch.py`)
-> traced -> Core ML. `coremltools` dropped its ONNX importer, so this is the
faithful way to keep `FACE_MATCH_COSINE = 0.30` meaning what it means — that
threshold was tuned on the maintainer's real cross-video faces, which peak at 0.326
(pitfall 28). A port that shifts the cosine scale silently breaks it.

    /opt/anaconda3/bin/python3 docs/coreml-spike/sface_parity.py      # fixture
    /opt/anaconda3/bin/python3 docs/coreml-spike/convert_sface_torch.py

**The gate:** Core ML's cosines must land within +/-0.01 of the ONNX reference on
the fixture's real crops, and the number of pairs over the 0.30 line must be
identical. That second half is the one that matters — a uniform drift of 0.01
would pass a naive elementwise check and still flip decisions at the threshold.

Both precisions are converted and measured, because the answer is not obvious:
FLOAT16 is what makes the package shippable (~2x smaller) but it is also the
precision most likely to move a cosine. The script reports both and installs the
smaller one that passes, preferring float16; if neither passes, it writes
neither and says which way the threshold would have to move.

Input geometry, measured rather than assumed (`sface_parity.py`): the graph
carries its own `(x - 127.5) / 128`, so the Core ML image input has scale 1 and
no bias, and RGB — feeding the graph BGR on the same crops lands at 0.099
cosine error, 200x the gate.
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np                                     # noqa: E402

import sface_torch                                     # noqa: E402

SHIP_NAME = "sface.mlpackage"
TOLERANCE = 0.01          # the plan's gate: cosines within +/-0.01 of ONNX
THRESHOLD = 0.30          # engine.FACE_MATCH_COSINE


def load_fixture(fixtures):
    path = os.path.join(fixtures, "sface_fixture.json")
    if not os.path.exists(path):
        print("SKIP (no fixture)\n  run docs/coreml-spike/sface_parity.py first")
        return None, None
    with open(path) as fh:
        fixture = json.load(fh)
    import cv2
    crops = []
    for entry in fixture["crops"]:
        img = cv2.imread(os.path.join(fixtures, entry["file"]))
        if img is None:
            print("SKIP: crop %s is missing (rerun sface_parity.py --rebuild)"
                  % entry["file"])
            return None, None
        crops.append(img)
    ref = np.stack([np.frombuffer(base64.b64decode(e["ref"]), dtype="<f4")
                    .astype(np.float64) for e in fixture["crops"]])
    return crops, sface_torch.unit(ref)


def trace(model):
    import torch
    example = torch.zeros(1, 3, 112, 112)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    return traced.eval()


def convert(traced, precision):
    """Convert at one precision. Image input scale 1, no bias: the graph normalises."""
    import coremltools as ct
    return ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 112, 112),
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )


def measure(mlmodel, crops, ref):
    """Core ML vs the ONNX reference: vector drift, cosine drift, and decisions."""
    from PIL import Image
    vecs = []
    for crop in crops:
        out = mlmodel.predict({"image": Image.fromarray(crop[:, :, ::-1])})
        vecs.append(np.asarray(out["embedding"]).reshape(-1))
    got = sface_torch.unit(np.stack(vecs))

    cos_ref, cos_got = ref @ ref.T, got @ got.T
    upper = np.triu(np.ones(cos_ref.shape, dtype=bool), 1)
    return {
        "vector": float(np.abs(got - ref).max()),
        "cosine": float(np.abs(cos_got - cos_ref).max()),
        "matches": int((cos_ref[upper] >= THRESHOLD).sum()),
        "matches_got": int((cos_got[upper] >= THRESHOLD).sum()),
        "pair": (float(np.abs(cos_got - cos_ref)[upper].max()),
                 float(cos_ref[upper][np.abs(cos_got - cos_ref)[upper].argmax()]),
                 float(cos_got[upper][np.abs(cos_got - cos_ref)[upper].argmax()])),
    }


def size_of(path):
    return subprocess.run(["du", "-sh", path], capture_output=True,
                          text=True).stdout.split()[0]


def timing(crops, mlmodel, repeats=40):
    """Per-face embedding cost, ONNX (today) vs Core ML (the port).

    Phase 6.2/6.3 embed every face a detection pass finds, so the per-face cost
    is the number that decides whether the pipeline is interactive. This is a
    Python-side upper bound for Core ML — the app calls MLModel from Swift, with
    no numpy round-trip; the ONNX side is in the same position it already is in
    the shipped Python engine, which pays for the same bridge.
    """
    import time
    import onnxruntime as ort
    from PIL import Image

    order = [i % len(crops) for i in range(repeats)]
    sess = ort.InferenceSession(sface_torch.find_model(sface_torch.SFACE_ONNX),
                                providers=["CPUExecutionProvider"])

    start = time.perf_counter()
    for i in order:
        crop = crops[i]
        sess.run(None, {"data": crop[:, :, ::-1].astype(np.float32)
                        .transpose(2, 0, 1)[None]})
    onnx_ms = (time.perf_counter() - start) * 1000.0 / repeats

    images = [Image.fromarray(c[:, :, ::-1]) for c in crops]
    start = time.perf_counter()
    for i in order:
        mlmodel.predict({"image": images[i]})
    coreml_ms = (time.perf_counter() - start) * 1000.0 / repeats
    return onnx_ms, coreml_ms


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--precision", choices=["float16", "float32", "both"],
                        default="both")
    args = parser.parse_args()

    fixtures = sface_torch.fixtures_dir()
    crops, ref = load_fixture(fixtures)
    if crops is None:
        return 0
    print("fixture       %d crops · %s" % (len(crops), fixtures))
    print("onnx ref      sha256 %s" % json.load(open(os.path.join(
        fixtures, "sface_fixture.json")))["onnx_sha256"][:16])

    import coremltools as ct
    port = sface_torch.build()
    traced = trace(port)

    precisions = {"float16": ct.precision.FLOAT16,
                  "float32": ct.precision.FLOAT32}
    order = ["float16", "float32"] if args.precision == "both" else [args.precision]

    results = {}
    for name in order:
        staged = os.path.join(fixtures, "sface_%s.mlpackage" % name)
        if os.path.exists(staged):
            shutil.rmtree(staged)
        convert(traced, precisions[name]).save(staged)
        results[name] = measure(ct.models.MLModel(staged), crops, ref)
        results[name]["path"] = staged
        results[name]["size"] = size_of(staged)

    print("\n%-8s %-9s %-11s %-11s %s" % ("build", "size", "max|Δ vec|", "max|Δ cos|",
                                          "pairs ≥ 0.30"))
    for name in order:
        r = results[name]
        ok = r["cosine"] <= TOLERANCE and r["matches"] == r["matches_got"]
        print("%-8s %-9s %.3e   %.3e   %d/%d %s"
              % (name, r["size"], r["vector"], r["cosine"],
                 r["matches_got"], r["matches"], "PASS" if ok else "FAIL"))

    # The drift that decides the gate is the drift on the pair closest to the
    # line, so name it: a build can be inside tolerance on average and still
    # move the one pair the threshold is looking at.
    name = max(order, key=lambda n: results[n]["cosine"])
    onnx_cos, coreml_cos = results[name]["pair"][1], results[name]["pair"][2]
    print("\nworst pair    %s: onnx %.4f -> coreml %.4f (Δ %.4f)"
          % (name, onnx_cos, coreml_cos, abs(coreml_cos - onnx_cos)))

    passing = next((n for n in order
                    if results[n]["cosine"] <= TOLERANCE
                    and results[n]["matches"] == results[n]["matches_got"]), None)
    if passing is None:
        print("\nGATE FAIL: no conversion lands within %.2f of the ONNX cosines." % TOLERANCE)
        print("  The threshold would have to be re-derived against real faces and")
        print("  pitfall 28 rewritten (plan Task 6.1's escape hatch).")
        return 1

    ship = os.path.join(fixtures, SHIP_NAME)
    if os.path.exists(ship):
        shutil.rmtree(ship)
    shutil.move(results[passing]["path"], ship)
    for name in order:
        if name != passing and os.path.exists(results[name]["path"]):
            shutil.rmtree(results[name]["path"])

    print("\nGATE PASS: %s within %.2f cosine of ONNX, decisions identical"
          % (passing, TOLERANCE))
    print("installed     %s (%s)" % (ship, size_of(ship)))
    print("FACE_MATCH_COSINE = %.2f keeps its meaning on this conversion." % THRESHOLD)

    onnx_ms, coreml_ms = timing(crops, ct.models.MLModel(ship))
    print("cost / face   onnx %.1f ms · coreml %.1f ms (%.1fx)"
          % (onnx_ms, coreml_ms, onnx_ms / coreml_ms))
    return 0


if __name__ == "__main__":
    sys.exit(main())
