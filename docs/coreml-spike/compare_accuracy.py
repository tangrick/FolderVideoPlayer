#!/usr/bin/env python3
"""Does MobileCLIP-S2 zero-shot agree with the shipped ViT-L/14 + LAION verdict?

The shipped engine's verdict is the reference (it is what the user has been
living with and correcting). For a balanced sample of already-judged videos we
re-sample frames, embed with MobileCLIP-S2, score the SAME zero-shot margin,
and compare.

Only files named in analysis.json are touched — no folder walking, ever.
"""
import json
import os
import subprocess
import sys
import tempfile
import random

import numpy as np
import coremltools as ct
from PIL import Image

SPIKE = "/tmp/mobileclip_spike"
SUPPORT = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"

# Same constants the shipped engine uses.
MARGIN_BIAS = 0.03
MARGIN_TEMPERATURE = 40.0
NSFW_THRESHOLD = 0.5
SAMPLE_INTERVAL_S = 5
MAX_FRAMES = 250
SAMPLE_SHORT_SIDE = 384

N_VIDEOS = int(os.environ.get("N_VIDEOS", "120"))
FRAME_CAP = int(os.environ.get("FRAME_CAP", "12"))   # per video, for speed


def abs_path(key):
    """analysis.json keys are share-relative for anything under /Volumes."""
    return key if key.startswith("/") else "/Volumes/" + key


def duration(path):
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=30).stdout.strip()
        return float(out)
    except Exception:
        return 0.0


def sample_frames(path, outdir):
    """Uniform frames, the same cadence the engine uses, capped for the spike."""
    d = duration(path)
    if d <= 0:
        return []
    interval = SAMPLE_INTERVAL_S
    if d < SAMPLE_INTERVAL_S * 4:
        interval = max(d / 4.0, 0.2)
    rc = subprocess.run(
        [FFMPEG, "-v", "error", "-i", path,
         "-vf", "fps=1/%g,scale='if(gt(iw,ih),-2,%d)':'if(gt(iw,ih),%d,-2)'"
                % (interval, SAMPLE_SHORT_SIDE, SAMPLE_SHORT_SIDE),
         "-frames:v", str(MAX_FRAMES),
         os.path.join(outdir, "f%04d.jpg")],
        capture_output=True, timeout=300)
    frames = sorted(os.listdir(outdir))
    if len(frames) > FRAME_CAP:                      # even stride across the video
        step = len(frames) / FRAME_CAP
        frames = [frames[int(i * step)] for i in range(FRAME_CAP)]
    return [os.path.join(outdir, f) for f in frames]


def main():
    text = np.load(os.path.join(SPIKE, "s2_text_nsfw.npz"), allow_pickle=True)
    T = text["embeddings"]                 # [33, 512], unit-normalised
    n_nsfw = int(text["n_nsfw"])
    img_model = ct.models.MLModel(os.path.join(SPIKE, "mobileclip_s2_image.mlpackage"))

    records = json.load(open(os.path.join(SUPPORT, "analysis.json")))
    records = records.get("records", records)
    judged = [(k, v) for k, v in records.items()
              if v.get("prediction") and v["prediction"].get("score") is not None]

    nsfw = [(k, v) for k, v in judged if v["prediction"]["score"] >= 0.5]
    safe = [(k, v) for k, v in judged if v["prediction"]["score"] < 0.5]
    random.seed(11)
    random.shuffle(nsfw)
    random.shuffle(safe)
    half = N_VIDEOS // 2
    sample = nsfw[:half] + safe[:half]
    random.shuffle(sample)

    rows, skipped = [], 0
    for i, (key, rec) in enumerate(sample, 1):
        path = abs_path(key)
        if not os.path.exists(path):
            skipped += 1
            continue
        with tempfile.TemporaryDirectory() as tmp:
            try:
                frames = sample_frames(path, tmp)
            except Exception:
                skipped += 1
                continue
            if not frames:
                skipped += 1
                continue
            scores = []
            for f in frames:
                try:
                    im = Image.open(f).convert("RGB").resize((256, 256), Image.BICUBIC)
                except Exception:
                    continue
                emb = img_model.predict({"image": im})["final_emb_1"].reshape(-1)
                emb = emb / np.linalg.norm(emb)
                sims = T @ emb
                margin = sims[:n_nsfw].max() - sims[n_nsfw:].max() - MARGIN_BIAS
                scores.append(1.0 / (1.0 + np.exp(-MARGIN_TEMPERATURE * margin)))
            if not scores:
                skipped += 1
                continue
        new_score = float(max(scores))              # same aggregation: max
        old_score = float(rec["prediction"]["score"])
        user = rec.get("userLabel")
        rows.append({
            "key": key, "old": old_score, "new": new_score,
            "old_nsfw": old_score >= NSFW_THRESHOLD,
            "new_nsfw": new_score >= NSFW_THRESHOLD,
            "user": user, "frames": len(scores),
        })
        if i % 10 == 0:
            print(f"  {i}/{len(sample)} …", flush=True)

    json.dump(rows, open(os.path.join(SPIKE, "compare.json"), "w"), indent=1)

    agree = sum(1 for r in rows if r["old_nsfw"] == r["new_nsfw"])
    print("\n=== MobileCLIP-S2 vs shipped ViT-L/14+LAION ===")
    print(f"compared:  {len(rows)}   (skipped {skipped}: missing/unreadable)")
    print(f"agreement: {agree}/{len(rows)} = {agree/max(len(rows),1)*100:.1f}%")

    fp = [r for r in rows if r["new_nsfw"] and not r["old_nsfw"]]
    fn = [r for r in rows if not r["new_nsfw"] and r["old_nsfw"]]
    print(f"  new says NSFW, old said Safe: {len(fp)}")
    print(f"  new says Safe, old said NSFW: {len(fn)}")

    # Where a human overruled the machine, the human is the truth.
    human = [r for r in rows if r["user"] in ("safe", "nsfw")]
    if human:
        old_ok = sum(1 for r in human if r["old_nsfw"] == (r["user"] == "nsfw"))
        new_ok = sum(1 for r in human if r["new_nsfw"] == (r["user"] == "nsfw"))
        print(f"\nagainst {len(human)} human-marked videos (the real truth):")
        print(f"  shipped ViT-L/14 correct: {old_ok}/{len(human)}")
        print(f"  MobileCLIP-S2   correct: {new_ok}/{len(human)}")


if __name__ == "__main__":
    main()
