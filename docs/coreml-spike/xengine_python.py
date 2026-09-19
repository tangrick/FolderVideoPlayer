#!/usr/bin/env python3
"""Cross-engine check, part 1 (Python side).

Embed four fixed PNGs through coremltools exactly as the spike did
(PIL image in, final_emb_1 out, L2-normalised) and save the vectors.
The Swift side embeds the same PNGs through VisionEmbedder; cosines
must be ~1.0 or the two engines are not the same space.
"""
import numpy as np, coremltools as ct
from PIL import Image
import os

SPIKE = "/tmp/mobileclip_spike"
OUT = os.path.join(SPIKE, "xengine")
os.makedirs(OUT, exist_ok=True)

model = ct.models.MLModel(os.path.join(SPIKE, "mobileclip_s2_image.mlpackage"))

# Four images with very different channel signatures: if the Swift path
# swapped R and B, red and blue would swap their vectors too, and the
# gradient/noise images would drift.
imgs = {
    "red":     np.full((256, 256, 3), [255, 0, 0], np.uint8),
    "blue":    np.full((256, 256, 3), [0, 0, 255], np.uint8),
    "gray":    np.full((256, 256, 3), 128, np.uint8),
    "checker": (np.add.outer(np.arange(256), np.arange(256)) // 32 % 2 * 255)
        .astype(np.uint8)[..., None].repeat(3, axis=2),
}

vecs = {}
for name, arr in imgs.items():
    im = Image.fromarray(arr, "RGB")
    im.save(os.path.join(OUT, f"{name}.png"))
    emb = model.predict({"image": im})["final_emb_1"].reshape(-1)
    emb = emb / np.linalg.norm(emb)
    vecs[name] = emb
    print(f"{name}: dim={emb.shape[0]} norm={np.linalg.norm(emb):.4f}")

np.stack(list(vecs.values())).astype("<f8").tofile(os.path.join(OUT, "python_vecs.f64"))
with open(os.path.join(OUT, "names.txt"), "w") as fh:
    fh.write("\n".join(vecs.keys()))
print("saved", os.path.join(OUT, "python_vecs.f64"))
