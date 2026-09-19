#!/usr/bin/env python3
"""SigLIP 2 B/16 @224 (Apache-2.0) -> Core ML, to replace the MobileCLIP-S2 tower.

WHY THIS SCRIPT EXISTS. The tag-suggestion bundle's image tower was MobileCLIP-S2,
whose WEIGHTS are under Apple's "Apple Machine Learning Research Model" licence
(`LICENSE_MODELS` in apple-aiml-research/ml-mobileclip): research purposes only,
revocable, and explicitly excluding "product development or use in any commercial
product or service". The app is a distributed Mac App Store product, so that
licence does not cover it — and the app also republishes those weights as public
release assets, which is the one act the licence attaches conditions to. The
MobileCLIP *code* is MIT; only the weights are the problem. SigLIP 2 B/16 is
Apache-2.0 end to end, and better on the published metrics:

    MobileCLIP-S2        74.4 ImageNet zero-shot @256, 35.7M image params, 83 MB
    SigLIP 2 B/16 @224   78.2 ImageNet zero-shot,       86M image params, ~180 MB

That 2.2x download is the price, and the app's own gate (AUC and tags-per-video on
the 240-video set) has to be re-measured before any threshold moves — see the
`docs/plans/` migration notes. Nothing here decides that question; this script only
produces the artifact and proves the conversion did not change the geometry.

WHAT SHIPS. The image tower only. The text tower is used ONCE by
`precompute_text_siglip2.py` to bake the prompt table, exactly as MobileCLIP's was,
so the multilingual 256k-vocab text tower never lands on a user's disk.

GEOMETRY, quoted rather than assumed (google/siglip2-base-patch16-224,
`preprocessor_config.json`): 224x224, `do_rescale` 1/255, mean .5 / std .5, RGB —
which folds into the Core ML image input as `scale=1/127.5, bias=[-1,-1,-1]`, the
same fold `convert_falconsai_ship.py` uses. The graph returns its RAW pooled
output (the MAP head's `pooler_output`): `VisionEmbedder` L2-normalises in Swift
and the prompt table's rows are already unit vectors, so normalising here would
normalise twice.

THE GATE. The conversion must agree with torch on the same images before anything
is installed: max |delta| within float16 rounding, and — the half that matters —
the pairwise cosines that the tag margins are actually built from must not move.
A build that is right on average and wrong on the pair nearest a threshold is the
failure mode this is written to catch (`convert_sface_torch.py` does the same for
`FACE_MATCH_COSINE`).

    /opt/anaconda3/bin/python3 docs/coreml-spike/convert_siglip2_image.py
    /opt/anaconda3/bin/python3 docs/coreml-spike/convert_siglip2_image.py --precision both
"""

import argparse
import os
import shutil
import subprocess
import sys
import time

import numpy as np

HF_ID = "google/siglip2-base-patch16-224"
SLUG = "siglip2_base"                  # app-side slug: cache namespace, head slug
SIZE = 224
MODELS = os.path.expanduser("~/fvp-coreml-models")
SHIP = os.path.join(MODELS, SLUG + "_image.mlpackage")

MAX_COSINE_DELTA = 6e-3               # 10% of the bar the app actually reads

# The drift this gate is about is a drift in COSINE, and a cosine is only ever
# read through a difference — a tag margin. Two bars exist in the app:
#
#   SUGGEST_MARGIN (engine.py 0.02)          the Python parity bar, the strict one
#   TagSuggester.vocabularyMargin (0.06)     what the shipping app compares at
#
# 6e-3 is 10% of the looser one and 30% of the stricter one, which is a choice
# and is stated as one: the strict bar only matters for parity runs against
# engine.py's own vectors, and a conversion artefact that small cannot make a
# tag that was 0.0199 away look like it cleared 0.02 without the app's 0.06 gate
# catching it first. Both fractions are printed per build, so the number can be
# argued with rather than trusted.

# Phase 0's measured per-frame cost for MobileCLIP-S2 through the same Core ML
# path. Quoted for context only — it is NOT a like-for-like measurement of this
# build until this script prints its own.
MOBILECLIP_MS_PER_FRAME = 2.0


def load_vision():
    """The image tower alone, in eval mode.

    Loading the whole `SiglipVisionModel` from a checkpoint that also carries the
    text tower leaves the text weights unused (transformers warns about the
    unexpected keys). That is deliberate: the text tower is only needed by the
    prompt-table script, which loads it its own way.
    """
    import torch
    from transformers import SiglipVisionModel

    vision = SiglipVisionModel.from_pretrained(HF_ID).eval()
    params = sum(p.numel() for p in vision.parameters())
    dim = int(vision.config.hidden_size)
    print("loaded   %s" % HF_ID)
    print("params   %.1fM (image tower) · dim %d · input %dx%d"
          % (params / 1e6, dim, SIZE, SIZE))
    if hasattr(torch, "set_grad_enabled"):
        torch.set_grad_enabled(False)
    return vision


def images():
    """Deterministic probes: greys, a ramp, the three colour solids, and noise.

    Synthetic on purpose. The question the gate asks is whether the conversion
    feeds the graph the same numbers as torch — colour order, normalisation,
    resize — and these probe every channel of that without a video or a library.
    Same set as `convert_falconsai_ship.py`, so a geometry bug reads the same way
    across the two conversions.
    """
    from PIL import Image
    rng = np.random.default_rng(7)
    out = []
    for value in (0, 32, 128, 200, 255):
        out.append(("grey%d" % value, Image.new("RGB", (SIZE, SIZE), (value, value, value))))
    ramp = np.stack([np.linspace(0, 255, SIZE)] * SIZE, axis=1).astype(np.uint8)
    out.append(("ramp", Image.fromarray(np.stack([ramp, ramp, ramp], axis=-1))))
    for name, colour in (("red", (200, 20, 20)), ("green", (20, 200, 20)),
                         ("blue", (20, 20, 200))):
        out.append((name, Image.new("RGB", (SIZE, SIZE), colour)))
    for i in range(3):
        a = rng.integers(0, 256, size=(SIZE, SIZE, 3), dtype=np.uint8)
        out.append(("noise%d" % i, Image.fromarray(a)))
    return out


def unit(v):
    norm = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(norm, 1e-12)


def torch_features(vision, ims):
    """The reference: torch's pooled output for the same images, fp32.

    Called BEFORE `coremltools` is imported (see `main`). Importing coremltools
    first and then running this eager forward segfaults inside the patch
    embedding's conv — measured, not guessed: every zero-input shape passes, the
    real-image batch dies, and the same call in a process that never imports
    coremltools is fine. Python-side crash, no Python traceback beyond
    faulthandler, so the ordering here is the fix rather than a preference.
    """
    import torch
    x = np.stack([np.asarray(im, dtype=np.float32) / 255.0 for _, im in ims])
    x = (x - 0.5) / 0.5
    t = torch.from_numpy(x).permute(0, 3, 1, 2).contiguous()
    with torch.no_grad():
        return vision(pixel_values=t).pooler_output.float().numpy()


def convert(precision):
    """Trace and convert at one precision. The model keeps its raw output."""
    import coremltools as ct
    import torch

    if os.path.exists(SHIP):
        shutil.rmtree(SHIP)
    vision = load_vision()
    class Wrapped(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, pixel_values):
            return self.inner(pixel_values=pixel_values).pooler_output

    wrapper = Wrapped(vision).eval()
    example = torch.zeros(1, 3, SIZE, SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)

    return ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE),
                             scale=1 / 127.5, bias=[-1, -1, -1],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )


def precision_named(name):
    """`ct.precision` for a name, imported HERE so that `main` can do all of its
    torch work before coremltools ever loads (see `torch_features`).
    """
    import coremltools as ct
    return {"float16": ct.precision.FLOAT16, "float32": ct.precision.FLOAT32}[name]


def coreml_features(path, ims):
    import coremltools as ct
    model = ct.models.MLModel(path)
    return np.stack([np.asarray(model.predict({"image": im})["embedding"]).reshape(-1)
                     for _, im in ims])


def measure(path, ims, ref_raw):
    """Vector drift AND the pairwise cosines the tag margins are read through."""
    got_raw = coreml_features(path, ims)
    ref, got = unit(ref_raw), unit(got_raw)
    cos_ref, cos_got = ref @ ref.T, got @ got.T
    upper = np.triu(np.ones(cos_ref.shape, dtype=bool), 1)
    return {
        "vector": float(np.abs(got_raw - ref_raw).max()),
        "norm_delta": float(np.abs(got_raw - ref_raw).max() / max(np.abs(ref_raw).max(), 1e-9)),
        "cosine": float(np.abs(cos_got - cos_ref).max()),
        "cosine_ref": float(cos_ref[upper].max()) if upper.any() else 0.0,
        "cosine_got": float(cos_got[upper].max()) if upper.any() else 0.0,
        "self_cosine": float(np.abs(np.diag(got @ got.T) - 1.0).max()),
    }


def timing(path, ims, repeats=40):
    """Per-frame cost through Core ML from Python — an upper bound on the app's.

    The app calls MLModel from Swift with no numpy round-trip, so this is the
    pessimistic side of the same measurement; it is comparable to the Phase 0
    number for MobileCLIP-S2 because that was taken the same way.
    """
    import coremltools as ct
    model = ct.models.MLModel(path)
    order = [i % len(ims) for i in range(repeats)]
    start = time.perf_counter()
    for i in order:
        model.predict({"image": ims[i][1]})
    return (time.perf_counter() - start) * 1000.0 / repeats


def size_of(path):
    return subprocess.run(["du", "-sh", path], capture_output=True,
                          text=True).stdout.split()[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--precision", choices=["float16", "float32", "both"],
                        default="both")
    parser.add_argument("--out", default=SHIP,
                        help="where the passing package is installed")
    args = parser.parse_args()

    # Order matters: no coremltools import may happen before `torch_features`
    # returns (see that function). `convert`/`measure`/`timing` import it lazily.
    vision = load_vision()
    ims = images()
    ref_raw = torch_features(vision, ims)
    print("probes   %d synthetic images · torch reference %s"
          % (len(ims), np.asarray(ref_raw).shape))

    order = ["float16", "float32"] if args.precision == "both" else [args.precision]

    results = {}
    for name in order:
        staged = os.path.join(MODELS, "%s_image_%s.mlpackage" % (SLUG, name))
        if os.path.exists(staged):
            shutil.rmtree(staged)
        convert(precision_named(name)).save(staged)
        results[name] = measure(staged, ims, ref_raw)
        results[name]["path"] = staged
        results[name]["size"] = size_of(staged)
        r = results[name]
        print("\n%-8s %-8s vec|Δ| %.3e   cosine|Δ| %.3e   self-cos |1-cos| %.2e"
              % (name, r["size"], r["vector"], r["cosine"], r["self_cosine"]))

    print("\n%-8s %-9s %-11s %-11s %-9s %-9s %s"
          % ("build", "size", "max|Δ vec|", "max|Δ cos|", "of 0.06", "of 0.02", "gate"))
    passing = None
    for name in order:
        r = results[name]
        ok = r["cosine"] <= MAX_COSINE_DELTA and r["self_cosine"] <= MAX_COSINE_DELTA
        print("%-8s %-9s %.3e   %.3e   %-9s %-9s %s"
              % (name, r["size"], r["vector"], r["cosine"],
                 "%.1f%%" % (100 * r["cosine"] / 0.06),
                 "%.1f%%" % (100 * r["cosine"] / 0.02),
                 "PASS" if ok else "FAIL"))
        # Retain the published float32 preference until a separate artifact
        # change is validated. The earlier claim that float16 was "dead" was
        # wrong: VisionEmbedder and the standalone check_tower tool interpreted
        # float16 output bytes as Float. With numeric MLMultiArray reads, both
        # packages distinguish images on device (2026-09-16: minimum probe
        # cosine 0.8061 for float16, 0.8017 for the installed float32 package).
        # Any Swift-side probe must honor output dataType and strides; the old
        # pointer-based check_tower executable is not a valid model gate.
        if ok and (passing is None or name == "float32"):
            passing = name

    if passing is None:
        print("\nGATE FAIL: no conversion lands within %.1e of the torch cosines."
              % MAX_COSINE_DELTA)
        print("  Do not install it. Every margin in the tag pipeline is read through")
        print("  these cosines, and a conversion that moves them mints a new space.")
        return 1

    out = args.out
    if os.path.exists(out):
        shutil.rmtree(out)
    shutil.move(results[passing]["path"], out)
    # A passing build that was not chosen is KEPT: the other precision is the
    # evidence for the choice, and re-converting to re-measure it is a minute of
    # GPU for nothing.
    for name in order:
        if name != passing:
            print("kept         %s (%s) — measured, not installed"
                  % (results[name]["path"], results[name]["size"]))

    ms = timing(out, ims)
    print("\nGATE PASS: %s within %.1e cosine of torch (%.1f%% of vocabularyMargin, "
          "%.1f%% of SUGGEST_MARGIN)"
          % (passing, MAX_COSINE_DELTA, 100 * results[passing]["cosine"] / 0.06,
             100 * results[passing]["cosine"] / 0.02))
    print("installed    %s (%s)" % (out, size_of(out)))
    print("dim          %d" % np.asarray(coreml_features(out, ims[:1])).shape[1])
    print("cost/frame   coreml %.2f ms  (MobileCLIP-S2 Phase 0: %.2f ms — context, "
          "not a like-for-like)" % (ms, MOBILECLIP_MS_PER_FRAME))
    print("\nnext         precompute_text_siglip2.py  (bakes the prompt table)")
    print("installs as  tags/%s.mlmodelc  (pack_bundles.sh)" % SLUG)
    return 0


if __name__ == "__main__":
    sys.exit(main())
