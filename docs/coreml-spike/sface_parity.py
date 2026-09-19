#!/usr/bin/env python3
"""Task 6.1 — the SFace parity fixture: real crops, the ONNX reference vectors.

The Core ML port has to answer one question before any app code is written:
does it produce the *same numbers* as the model the app runs today? Everything
here exists to make that measurable on real faces rather than on noise.

    /opt/anaconda3/bin/python3 docs/coreml-spike/sface_parity.py [--rebuild]

What it does, in order:

  1. **Harvests crops with the app's own pipeline.** Not a re-implementation:
     `engine._faces_in_frame` is called with YuNet + SFace, so the crops are the
     aligned 112x112 BGR images the app already stores under `faces/`, keyed by
     the same content hash. Frames are read with cv2 at a uniform stride across
     the WHOLE video (pitfall 29 — a cap that stops early never sees anyone who
     appears later).
  2. **Builds the reference** with onnxruntime, feeding raw 0-255 RGB, and
     cross-checks it against `cv2.FaceRecognizerSF.feature` — the call the app
     makes today. If the two disagree, the fixture is measuring the wrong thing
     and the script refuses to emit it.
  3. **Measures the port** (`sface_torch.py`) against that reference: per-element
     vector drift and the pairwise cosines, which is the quantity the 0.30
     threshold actually reads.
  4. Writes `sface_fixture.json` — crop files, reference unit vectors, and the
     cosines derived from them — beside the crops in `~/fvp-coreml-models/`.

Two deliberate substitutions, because the original data is gone:

  - **The crops are not the maintainer's `faces/` cache.** `/Volumes/media` is not
    mounted on this machine and that cache no longer exists, so the crops are
    regenerated from videos that are on this disk, through the same code path.
    The reference cosines are therefore of THIS crop set; the claim they support
    is that the Core ML port reproduces the ONNX model, which is exactly what
    the gate needs and is independent of whose faces are in the set.
  - **The model came from the scratch area, not the app's support dir.**
    `~/fvp-coreml-test/models/` holds the same two OpenCV-Zoo ONNX files; the
    app's own `models/` is empty on this machine.

Skips loudly (exit 0 with a reason, so a machine without the weights is not a
red gate) when there are no crops and no videos to make them from.
"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "AnalysisEngine"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np                                     # noqa: E402

import sface_torch                                     # noqa: E402

CROP_COUNT = 24            # what the gate asks for, with margin over 20
CROPS_PER_VIDEO = 6        # so one video cannot carry the whole fixture
SCAN_FRAMES = 14           # uniform stride across each video
MAX_SIZE = 1024            # the app's own longest-side cap
OUT_DIR = None             # resolved in main()
FIXTURE_NAME = "sface_fixture.json"
CROPS_NAME = "sface_crops"


def videos():
    """The videos to harvest from: `FVP_FACE_VIDEOS` or the Downloads folder.

    Deterministic order, so rebuilding the fixture from the same disk produces
    the same crops in the same order.
    """
    override = os.environ.get("FVP_FACE_VIDEOS")
    if override and os.path.isdir(override):
        found = [os.path.join(override, f) for f in sorted(os.listdir(override))]
    elif override:
        import glob
        found = sorted(glob.glob(os.path.expanduser(override)))
    else:
        import glob
        found = sorted(glob.glob(os.path.expanduser("~/Downloads/*.mp4")))
    return [f for f in found if f.lower().endswith((".mp4", ".mov", ".m4v", ".avi", ".mkv"))]


def harvest():
    """Crops via engine.py's real detector+recogniser, or [] when unavailable."""
    import cv2
    import engine

    try:
        det_path = sface_torch.find_model(sface_torch.YUNET_ONNX)
        rec_path = sface_torch.find_model(sface_torch.SFACE_ONNX)
    except SystemExit as e:
        print("SKIP (no face weights)\n%s" % e)
        return []

    # Point engine.py at the real weights but a throwaway face store, and reset
    # the lazily-loaded models so it builds them against these paths.
    engine.FACE_DETECT_MODEL = det_path
    engine.FACE_RECOG_MODEL = rec_path
    engine.FACE_DIR = os.path.join(OUT_DIR, CROPS_NAME)
    engine._face_models = {"det": None, "rec": None}          # noqa: SLF001
    shutil.rmtree(engine.FACE_DIR, ignore_errors=True)
    os.makedirs(engine.FACE_DIR, exist_ok=True)

    vids = videos()
    if not vids:
        print("SKIP (no videos)\n  set FVP_FACE_VIDEOS to a folder or glob of videos")
        return []

    crops, seen = [], set()
    for path in vids:
        if len(crops) >= CROP_COUNT:
            break
        cap = cv2.VideoCapture(path)
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        taken = 0
        for i in range(0, max(total, 1), max(total // SCAN_FRAMES, 1)):
            if taken >= CROPS_PER_VIDEO or len(crops) >= CROP_COUNT:
                break
            cap.set(cv2.CAP_PROP_POS_FRAMES, i)
            ok, frame = cap.read()
            if not ok:
                continue
            h, w = frame.shape[:2]
            scale = float(MAX_SIZE) / max(h, w)
            if scale < 1.0:
                frame = cv2.resize(frame, (int(w * scale), int(h * scale)))
            for face_hash, _vec, _area in engine._faces_in_frame(frame):   # noqa: SLF001
                if face_hash in seen:
                    continue
                seen.add(face_hash)
                crops.append(face_hash)
                taken += 1
                if taken >= CROPS_PER_VIDEO or len(crops) >= CROP_COUNT:
                    break
        cap.release()

    # engine.py writes into the app's two-level fan-out (`faces/<xx>/<hash>.jpg`,
    # the same shape `_face_cache_path` uses). The fixture is a flat directory:
    # one list, one `os.listdir`, no path arithmetic for the next reader.
    flat = []
    for h in crops:
        src = os.path.join(engine.FACE_DIR, h[:2], h + ".jpg")
        if not os.path.exists(src):
            continue
        shutil.copyfile(src, os.path.join(engine.FACE_DIR, h + ".jpg"))
        flat.append(h)
    for name in sorted(os.listdir(engine.FACE_DIR)):
        sub = os.path.join(engine.FACE_DIR, name)
        if os.path.isdir(sub):
            shutil.rmtree(sub)

    print("harvested %d distinct crops from %d video(s)" % (len(flat), len(vids)))
    return flat


def load_crops(hashes):
    import cv2
    out = {}
    for h in hashes:
        path = os.path.join(OUT_DIR, CROPS_NAME, h + ".jpg")
        img = cv2.imread(path)
        if img is not None:
            out[h] = img
    return out


def b64(vec):
    return base64.b64encode(np.asarray(vec, dtype="<f4").tobytes()).decode("ascii")


def main():
    global OUT_DIR
    parser = argparse.ArgumentParser()
    parser.add_argument("--rebuild", action="store_true",
                        help="re-harvest the crops instead of using the saved ones")
    args = parser.parse_args()

    OUT_DIR = sface_torch.fixtures_dir()
    os.makedirs(OUT_DIR, exist_ok=True)

    onnx_path = sface_torch.find_model(sface_torch.SFACE_ONNX)
    print("onnx          %s" % onnx_path)

    crops_dir = os.path.join(OUT_DIR, CROPS_NAME)
    have = sorted(f[:-4] for f in os.listdir(crops_dir)) if os.path.isdir(crops_dir) else []
    if args.rebuild or len(have) < CROP_COUNT:
        harvested = harvest()
        if harvested:
            have = harvested
        elif not have:
            print("\nSKIP: no crops and nothing to harvest from — fixture not written")
            return 0
    if len(have) < CROP_COUNT:
        print("SKIP: only %d crops, the gate wants %d (rerun with --rebuild)"
              % (len(have), CROP_COUNT))
        return 0

    images = load_crops(have)
    if len(images) != len(have):
        print("SKIP: %d of %d crops could not be read" % (len(have) - len(images), len(have)))
        return 0
    hashes = list(images)
    bgr = [images[h] for h in hashes]

    # --- reference 1: onnxruntime, raw 0-255 RGB -----------------------------
    import onnxruntime as ort
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    # One crop per call: the graph is exported at batch 1, exactly as the app runs it.
    raw = [sess.run(None, {"data": c[:, :, ::-1].astype(np.float32)
                           .transpose(2, 0, 1)[None]})[0].reshape(-1)
           for c in bgr]
    ref = sface_torch.unit(np.stack(raw))

    # --- reference 2: cv2, the call the app makes today ----------------------
    import cv2
    rec = cv2.FaceRecognizerSF.create(onnx_path, "")
    cv2_vecs = sface_torch.unit(np.stack([rec.feature(c).reshape(-1) for c in bgr]))
    cv2_delta = float(np.abs(cv2_vecs - ref).max())
    print("cv2 vs ort    max|Δ unit vector| = %.3e" % cv2_delta)
    if cv2_delta > 1e-5:
        print("\nFAIL: the two references disagree — colour order or normalisation is wrong.")
        print("      Feeding BGR instead of RGB is the known way to get here (~0.099).")
        return 1

    # --- the port ------------------------------------------------------------
    port = sface_torch.build(onnx_path)
    out = sface_torch.unit(sface_torch.embed(port, bgr))
    port_delta = float(np.abs(out - ref).max())
    deltas = np.abs(out - ref).max(axis=1)

    cosines = ref @ ref.T
    off = cosines[~np.eye(len(ref), dtype=bool)]
    port_cosines = out @ out.T
    cos_drift = float(np.abs(port_cosines - cosines).max())
    matches = int((np.triu(cosines, 1) >= 0.30).sum())
    port_matches = int((np.triu(port_cosines, 1) >= 0.30).sum())

    print("torch vs ort  max|Δ unit vector| = %.3e  (worst crop %.3e)"
          % (port_delta, float(deltas.max())))
    print("              max|Δ cosine|      = %.3e" % cos_drift)
    print("cosines       min %.4f · median %.4f · max %.4f"
          % (float(off.min()), float(np.median(off)), float(off.max())))
    print("at 0.30       %d pair(s) match (onnx) vs %d (torch)" % (matches, port_matches))

    if port_delta > 1e-4 or cos_drift > 1e-4 or matches != port_matches:
        print("\nFAIL: the port does not reproduce the ONNX model — not writing a fixture")
        return 1

    fixture = {
        "generated_by": "docs/coreml-spike/sface_parity.py",
        "reference": "onnxruntime %s, raw 0-255 RGB, unit-normalised"
                     % ort.__version__,
        "onnx_sha256": hashlib.sha256(open(onnx_path, "rb").read()).hexdigest(),
        "crop_source": os.environ.get("FVP_FACE_VIDEOS", "~/Downloads/*.mp4"),
        "cv2_max_abs_delta": cv2_delta,
        "torch_max_abs_delta": port_delta,
        "dim": int(ref.shape[1]),
        "crops": [{"hash": h,
                   "file": "%s/%s.jpg" % (CROPS_NAME, h),
                   "ref": b64(v)} for h, v in zip(hashes, ref)],
    }
    out_path = os.path.join(OUT_DIR, FIXTURE_NAME)
    with open(out_path, "w") as fh:
        json.dump(fixture, fh)
    print("\nwrote %s (%d crops, %.1f KB)"
          % (out_path, len(hashes), os.path.getsize(out_path) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
