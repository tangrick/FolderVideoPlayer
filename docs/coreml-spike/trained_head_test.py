#!/usr/bin/env python3
"""Decisive test: can a TRAINED head on MobileCLIP-S2 embeddings do the job?

Zero-shot margin alone is weak (AUC 0.669). But the shipped verdict is
ViT-L/14 zero-shot PLUS the LAION trained head — and a trained head is exactly
what MobileCLIP is missing, not something it is incapable of.

So: embed videos with MobileCLIP-S2, mean-pool per video, and cross-validate a
logistic head against the shipped verdicts as labels. If this is strong, the
Core ML plan works — we ship a head trained the same way.
"""
import json
import os
import subprocess
import tempfile
import random

import numpy as np
import coremltools as ct
from PIL import Image

SPIKE = "/tmp/mobileclip_spike"
SUPPORT = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
SAMPLE_SHORT_SIDE = 384
N_VIDEOS = int(os.environ.get("N_VIDEOS", "240"))
FRAME_CAP = int(os.environ.get("FRAME_CAP", "8"))


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


def frames_of(path, outdir):
    d = duration(path)
    if d <= 0:
        return []
    interval = 5 if d >= 20 else max(d / 4.0, 0.2)
    subprocess.run(
        [FFMPEG, "-v", "error", "-i", path,
         "-vf", "fps=1/%g,scale='if(gt(iw,ih),-2,%d)':'if(gt(iw,ih),%d,-2)'"
                % (interval, SAMPLE_SHORT_SIDE, SAMPLE_SHORT_SIDE),
         "-frames:v", "250", os.path.join(outdir, "f%04d.jpg")],
        capture_output=True, timeout=300)
    fs = sorted(os.listdir(outdir))
    if len(fs) > FRAME_CAP:
        step = len(fs) / FRAME_CAP
        fs = [fs[int(i * step)] for i in range(FRAME_CAP)]
    return [os.path.join(outdir, f) for f in fs]


def main():
    img_model = ct.models.MLModel(os.path.join(SPIKE, "mobileclip_s2_image.mlpackage"))
    records = json.load(open(os.path.join(SUPPORT, "analysis.json")))
    records = records.get("records", records)
    judged = [(k, v) for k, v in records.items()
              if v.get("prediction") and v["prediction"].get("score") is not None]
    nsfw = [(k, v) for k, v in judged if v["prediction"]["score"] >= 0.5]
    safe = [(k, v) for k, v in judged if v["prediction"]["score"] < 0.5]
    random.seed(7)
    random.shuffle(nsfw); random.shuffle(safe)
    half = N_VIDEOS // 2
    sample = nsfw[:half] + safe[:half]

    X, y, keys = [], [], []
    for i, (key, rec) in enumerate(sample, 1):
        path = abs_path(key)
        if not os.path.exists(path):
            continue
        with tempfile.TemporaryDirectory() as tmp:
            try:
                fs = frames_of(path, tmp)
            except Exception:
                continue
            embs = []
            for f in fs:
                try:
                    im = Image.open(f).convert("RGB").resize((256, 256), Image.BICUBIC)
                except Exception:
                    continue
                e = img_model.predict({"image": im})["final_emb_1"].reshape(-1)
                embs.append(e / np.linalg.norm(e))
            if not embs:
                continue
        v = np.mean(embs, axis=0)
        X.append(v / np.linalg.norm(v))
        y.append(1 if rec["prediction"]["score"] >= 0.5 else 0)
        keys.append(key)
        if i % 20 == 0:
            print(f"  embedded {i}/{len(sample)}", flush=True)

    X = np.stack(X).astype(np.float32)
    y = np.array(y)
    np.savez(os.path.join(SPIKE, "s2_video_embeddings.npz"),
             X=X, y=y, keys=np.array(keys, dtype=object), allow_pickle=True)
    print("\nembedded:", X.shape, "nsfw:", int(y.sum()), "safe:", int((1 - y).sum()))

    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import StratifiedKFold, cross_val_predict
    from sklearn.metrics import roc_auc_score, accuracy_score

    clf = LogisticRegression(max_iter=2000, C=1.0)
    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=0)
    prob = cross_val_predict(clf, X, y, cv=cv, method="predict_proba")[:, 1]

    print("\n=== trained head on MobileCLIP-S2 (5-fold cross-validated) ===")
    print("AUC:      %.4f" % roc_auc_score(y, prob))
    print("accuracy: %.4f at the 0.5 cut" % accuracy_score(y, prob >= 0.5))
    for t in (0.3, 0.5, 0.7):
        pred = prob >= t
        tp = int(((pred == 1) & (y == 1)).sum()); fp = int(((pred == 1) & (y == 0)).sum())
        fn = int(((pred == 0) & (y == 1)).sum()); tn = int(((pred == 0) & (y == 0)).sum())
        print(f"  cut {t}: tp={tp} fp={fp} fn={fn} tn={tn}")


if __name__ == "__main__":
    main()
