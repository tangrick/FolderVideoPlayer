#!/usr/bin/env python3
"""Task 0.2 — convert Falconsai/nsfw_image_detection to Core ML, and judge it.

The gate: it must beat the MobileCLIP-S2 trained head (AUC 0.9659) to justify
shipping 330 MB instead of a 2 KB logistic head.

Judged two ways, because they answer different questions:
  * against the shipped ViT-L/14+LAION verdicts — do we keep behaving the same?
  * against the user's OWN Safe/NSFW marks — which is actually right?

The second matters more. A human mark is the only ground truth in the library.
"""
import json
import os
import subprocess
import tempfile

import numpy as np

SPIKE = "/tmp/mobileclip_spike"
SUPPORT = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
OUT = os.path.join(SPIKE, "falconsai.mlpackage")


def convert():
    """PyTorch -> Core ML. Done once; skipped if the package already exists."""
    if os.path.exists(OUT):
        print("already converted:", OUT)
        return
    import torch
    import coremltools as ct
    from transformers import AutoModelForImageClassification

    model = AutoModelForImageClassification.from_pretrained(
        "Falconsai/nsfw_image_detection").eval()
    print("labels:", model.config.id2label)

    class Wrapped(torch.nn.Module):
        """Softmax folded in so Swift reads a probability, not a logit."""
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return torch.softmax(self.inner(pixel_values=x).logits, dim=-1)

    example = torch.rand(1, 3, 224, 224)
    traced = torch.jit.trace(Wrapped(model), example)

    # ViT normalisation is mean .5 std .5, i.e. (x/255 - .5)/.5 on 0-255 input.
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224),
                             scale=1 / 127.5, bias=[-1, -1, -1],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="probs")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.save(OUT)
    size = subprocess.run(["du", "-sh", OUT], capture_output=True,
                          text=True).stdout.split()[0]
    print("saved:", OUT, size)


def abs_path(key):
    return key if key.startswith("/") else "/Volumes/" + key


def duration(path):
    try:
        return float(subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=30).stdout.strip())
    except Exception:
        return 0.0


def frames_of(path, outdir, cap=8):
    d = duration(path)
    if d <= 0:
        return []
    interval = 5 if d >= 20 else max(d / 4.0, 0.2)
    subprocess.run(
        [FFMPEG, "-v", "error", "-i", path,
         "-vf", "fps=1/%g,scale='if(gt(iw,ih),-2,384)':'if(gt(iw,ih),384,-2)'" % interval,
         "-frames:v", "250", os.path.join(outdir, "f%04d.jpg")],
        capture_output=True, timeout=300)
    fs = sorted(os.listdir(outdir))
    if len(fs) > cap:
        step = len(fs) / cap
        fs = [fs[int(i * step)] for i in range(cap)]
    return [os.path.join(outdir, f) for f in fs]


def score_videos(keys):
    """Max NSFW probability across sampled frames — same aggregation as the app."""
    import coremltools as ct
    from PIL import Image

    model = ct.models.MLModel(OUT)
    # Which output column is NSFW? id2label said {0: normal, 1: nsfw}.
    nsfw_index = 1

    out = {}
    for i, key in enumerate(keys, 1):
        path = abs_path(key)
        if not os.path.exists(path):
            continue
        with tempfile.TemporaryDirectory() as tmp:
            try:
                fs = frames_of(path, tmp)
            except Exception:
                continue
            best = 0.0
            seen = 0
            for f in fs:
                try:
                    im = Image.open(f).convert("RGB").resize((224, 224), Image.BICUBIC)
                except Exception:
                    continue
                p = model.predict({"image": im})["probs"].reshape(-1)
                best = max(best, float(p[nsfw_index]))
                seen += 1
            if seen:
                out[key] = best
        if i % 20 == 0:
            print(f"  scored {i}/{len(keys)}", flush=True)
    return out


def main():
    convert()

    cached = np.load(os.path.join(SPIKE, "s2_video_embeddings.npz"), allow_pickle=True)
    keys = list(cached["keys"])
    y = cached["y"]              # 1 = shipped engine said NSFW

    scores = score_videos(keys)
    keep = [i for i, k in enumerate(keys) if k in scores]
    p = np.array([scores[keys[i]] for i in keep])
    truth = y[keep]

    from sklearn.metrics import roc_auc_score, accuracy_score
    print("\n=== Falconsai vs the SHIPPED verdicts ===")
    print("scored:", len(p))
    print("AUC:      %.4f" % roc_auc_score(truth, p))
    print("accuracy: %.4f at 0.5" % accuracy_score(truth, p >= 0.5))
    print("(MobileCLIP-S2 trained head was AUC 0.9659, acc 0.9000)")

    # --- the honest test: the user's own marks ---
    records = json.load(open(os.path.join(SUPPORT, "analysis.json")))
    records = records.get("records", records)
    marked = {k: v["userLabel"] for k, v in records.items()
              if v.get("userLabel") in ("safe", "nsfw")}
    print("\nhuman-marked videos in the library:", len(marked))

    mk = [k for k in marked if os.path.exists(abs_path(k))]
    if mk:
        mscores = score_videos(mk)
        rows = [(k, marked[k], mscores[k]) for k in mk if k in mscores]
        if rows:
            hy = np.array([1 if lab == "nsfw" else 0 for _, lab, _ in rows])
            hp = np.array([s for _, _, s in rows])
            shipped = np.array([
                1 if records[k].get("prediction", {}).get("score", 0) >= 0.5 else 0
                for k, _, _ in rows])
            print("\n=== against %d HUMAN marks (the real truth) ===" % len(rows))
            print("shipped ViT-L/14+LAION correct: %d/%d"
                  % (int((shipped == hy).sum()), len(rows)))
            print("Falconsai correct:              %d/%d"
                  % (int(((hp >= 0.5) == hy).sum()), len(rows)))
            if len(set(hy)) > 1:
                print("Falconsai AUC on human marks:   %.4f" % roc_auc_score(hy, hp))
            json.dump([{"key": k, "user": lab, "falconsai": float(s)}
                       for k, lab, s in rows],
                      open(os.path.join(SPIKE, "falconsai_human.json"), "w"), indent=1)

    json.dump({k: float(v) for k, v in scores.items()},
              open(os.path.join(SPIKE, "falconsai_scores.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
