#!/usr/bin/env python3
"""Re-convert Falconsai/nsfw_image_detection to Core ML — from a wrapper in EVAL mode.

Phase 0 converted a wrapper that had NOT been put in eval mode (the tracer log
said so). ViT-base has no dropout or batchnorm live at inference, so the measured
numbers stand — but the shipped artifact must come from a wrapper with `.eval()`
called on it, and there is no reason to ship a doubt.

This script is the shipped conversion. It differs from `convert_falconsai.py` in
exactly one thing (the `.eval()`), and it *proves* that is the only difference:

  1. convert the eval-mode wrapper to `falconsai_ship.mlpackage`;
  2. score the same images with torch, with the old package and with the new one;
  3. require new-vs-torch to match to float16 rounding, and report old-vs-new so
     the "nothing changed" claim is measured rather than asserted;
  4. only then install it as `falconsai.mlpackage`, keeping the Phase 0
     conversion beside it as `falconsai_pre_eval.mlpackage`.

    /opt/anaconda3/bin/python3 docs/coreml-spike/convert_falconsai_ship.py

The input geometry is the load-bearing part: ViT normalisation is mean .5 / std
.5, i.e. `scale = 1/127.5` with `bias = [-1, -1, -1]` on 0-255 RGB. Softmax is
folded into the model so Swift reads a probability, not a logit, and column 1 is
NSFW (id2label is {0: normal, 1: nsfw}).

Written before any app code reads it: `Model/NSFWClassifier.swift` looks for the
result at `<support>/tags/falconsai.mlmodelc` and reads `probs[1]`.
"""

import os
import shutil
import subprocess
import sys

import numpy as np

MODELS = os.path.expanduser("~/fvp-coreml-models")
SHIP = os.path.join(MODELS, "falconsai_ship.mlpackage")
LIVE = os.path.join(MODELS, "falconsai.mlpackage")
OLD = os.path.join(MODELS, "falconsai_pre_eval.mlpackage")
HF_ID = "Falconsai/nsfw_image_detection"
SIZE = 224
NSFW_INDEX = 1


def load_wrapper():
    """The PyTorch model, wrapped with softmax and IN EVAL MODE at every level."""
    import torch
    from transformers import AutoModelForImageClassification

    inner = AutoModelForImageClassification.from_pretrained(HF_ID).eval()
    print("labels:", inner.config.id2label)
    assert inner.config.id2label[NSFW_INDEX].lower().startswith("nsfw"), \
        "column %d is not the NSFW class" % NSFW_INDEX

    class Wrapped(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return torch.softmax(self.inner(pixel_values=x).logits, dim=-1)

    # .eval() on the WRAPPER too — this line is the whole point of the script.
    return Wrapped(inner).eval()


def convert():
    import coremltools as ct
    import torch

    if os.path.exists(SHIP):
        shutil.rmtree(SHIP)
    wrapper = load_wrapper()
    example = torch.rand(1, 3, SIZE, SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE),
                             scale=1 / 127.5, bias=[-1, -1, -1],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="probs")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.save(SHIP)
    size = subprocess.run(["du", "-sh", SHIP], capture_output=True, text=True).stdout.split()[0]
    print("converted:", SHIP, size)


def images():
    """Deterministic test images: uniform greys, a gradient, and two noise fields.

    Synthetic on purpose — the parity question is whether the *conversion* feeds
    the graph the same numbers (colour order, normalisation, size), and these
    probe that in every channel without needing a video or a library.
    """
    from PIL import Image
    rng = np.random.default_rng(7)
    out = []
    for value in (0, 32, 128, 200, 255):
        out.append(("grey%d" % value, Image.new("RGB", (SIZE, SIZE), (value, value, value))))
    ramp = np.stack([np.linspace(0, 255, SIZE)] * SIZE, axis=1).astype(np.uint8)
    out.append(("ramp", Image.fromarray(np.stack([ramp, ramp, ramp], axis=-1))))
    # channel probes: red / green / blue solids catch a swapped colour layout
    for name, colour in (("red", (200, 20, 20)), ("green", (20, 200, 20)), ("blue", (20, 20, 200))):
        out.append((name, Image.new("RGB", (SIZE, SIZE), colour)))
    for i in range(3):
        a = rng.integers(0, 256, size=(SIZE, SIZE, 3), dtype=np.uint8)
        out.append(("noise%d" % i, Image.fromarray(a)))
    return out


def torch_probs(wrapper, ims):
    import torch
    x = np.stack([np.asarray(im, dtype=np.float32) / 255.0 for _, im in ims])
    x = (x - 0.5) / 0.5                                       # ViT mean/std .5
    t = torch.from_numpy(x).permute(0, 3, 1, 2)
    with torch.no_grad():
        return wrapper(t).numpy()


def coreml_probs(path, ims):
    import coremltools as ct
    model = ct.models.MLModel(path)
    return np.stack([np.asarray(model.predict({"image": im})["probs"]).reshape(-1)
                     for _, im in ims])


def main():
    convert()

    wrapper = load_wrapper()
    ims = images()
    truth = torch_probs(wrapper, ims)
    new = coreml_probs(SHIP, ims)

    print("\n%-8s %-22s %-22s" % ("image", "torch (normal/nsfw)", "new package"))
    worst = 0.0
    for i, (name, _) in enumerate(ims):
        d = float(np.max(np.abs(new[i] - truth[i])))
        worst = max(worst, d)
        print("%-8s %.6f / %.6f       %.6f / %.6f   |Δ|=%.6f"
              % (name, truth[i][0], truth[i][1], new[i][0], new[i][1], d))

    old_worst = None
    if os.path.exists(LIVE) and not os.path.exists(OLD):
        old = coreml_probs(LIVE, ims)
        old_worst = float(np.max(np.abs(old - truth)))
        print("\nPhase 0 package vs torch: max |Δ| = %.6f" % old_worst)
        print("eval package    vs torch: max |Δ| = %.6f" % worst)

    ok = worst <= 5e-3      # float16 rounding, nothing else
    print("\n%-24s %s" % ("new package matches torch", "YES" if ok else "NO"))
    if not ok:
        print("not installing %s" % LIVE)
        return 1

    if os.path.exists(LIVE):
        if os.path.exists(OLD):
            shutil.rmtree(OLD)
        shutil.move(LIVE, OLD)
        print("kept the Phase 0 conversion at:" , OLD)
    shutil.move(SHIP, LIVE)
    size = subprocess.run(["du", "-sh", LIVE], capture_output=True, text=True).stdout.split()[0]
    print("installed:", LIVE, size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
