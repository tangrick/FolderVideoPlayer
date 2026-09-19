#!/usr/bin/env python3
"""Emit the fixture `Tests/test_face_engine.swift` measures the Swift port to.

The Swift face engine has three pieces that must agree with the Python-era
engine, because the crop geometry is what `FACE_MATCH_COSINE = 0.30` is
calibrated on:

  1. **the detector** — `cv2.FaceDetectorYN`'s boxes and landmarks, so the
     alignment gets the same five points;
  2. **the alignment** — the 112x112 crop `cv2.alignCrop` produces;
  3. **the embedder** — SFace's unit vectors, so a cosine means the same number.

This writes the frames, the reference detections, the reference crops and the
reference vectors as one JSON, so the Swift test needs no Python at run time and
no OpenCV to disagree with. Regenerate whenever a model is re-converted.

    /opt/anaconda3/bin/python3 docs/coreml-spike/face_engine_fixture.py
"""

import base64
import glob
import hashlib
import json
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "AnalysisEngine"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np                                     # noqa: E402

import face_align_parity as fap                        # noqa: E402
import sface_torch                                     # noqa: E402
import yunet_parity                                    # noqa: E402

NAME = "face_engine_fixture.json"


def b64(vector):
    return base64.b64encode(np.asarray(vector, dtype="<f4").tobytes()).decode("ascii")


def main():
    import cv2
    import onnxruntime as ort

    # The matching threshold is READ from engine.py rather than copied, so the
    # Swift test can assert the app's constant is the one the Python engine
    # ships — the same "comes from engine.py, not a copy" rule the suggester
    # fixture follows for SUGGEST_MARGIN.
    import engine

    root = os.path.join(sface_torch.fixtures_dir(), "face_engine")
    frames_dir = os.path.join(root, "frames")
    crops_dir = os.path.join(root, "crops")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(frames_dir)
    os.makedirs(crops_dir)

    source = sorted(glob.glob(os.path.join(sface_torch.fixtures_dir(),
                                          "face_align", "frames", "frame_*.png")))
    if not source:
        print("SKIP (no frames)\n  run docs/coreml-spike/face_align_parity.py --build first")
        return 0

    detector = cv2.FaceDetectorYN.create(sface_torch.find_model(sface_torch.YUNET_ONNX),
                                         "", (320, 320), yunet_parity.SCORE_THRESHOLD,
                                         yunet_parity.NMS_THRESHOLD, 5000)
    recogniser = cv2.FaceRecognizerSF.create(sface_torch.find_model(sface_torch.SFACE_ONNX), "")
    session = ort.InferenceSession(sface_torch.find_model(sface_torch.SFACE_ONNX),
                                  providers=["CPUExecutionProvider"])

    # --- one crop where the answer is exact, not close ----------------------
    #
    # Everything above is resampled, and the port's warp matches cv2's to ~1.7
    # of 255 per pixel rather than bit-for-bit — good enough for a cosine, not
    # good enough to say two hashes of the same crop are equal. So the cache key
    # gets its own case: landmarks placed so the similarity transform is a pure
    # INTEGER translation, where the fractional weights are all zero and every
    # resampler in existence must produce the same bytes. That is what makes
    # `FaceRegistry.hash` checkable against engine.py's `sha256(crop)[:32]`
    # rather than merely plausible — and a stride bug (hashing the 4-byte-per-
    # pixel buffer instead of the packed 3) shows up here and nowhere else.
    exact_dir = os.path.join(root, "exact")
    os.makedirs(exact_dir, exist_ok=True)
    plain = np.frombuffer(np.random.default_rng(20260913)
                          .integers(0, 256, 200 * 200 * 3, dtype=np.uint8).tobytes(),
                          dtype=np.uint8).reshape(200, 200, 3)
    cv2.imwrite(os.path.join(exact_dir, "source.png"), plain)
    offset = np.array([10.0, 12.0])
    points = fap.TEMPLATE + offset
    face_row = np.concatenate([[0.0, 0.0, 180.0, 180.0], points.ravel(), [0.99]])
    exact_crop = recogniser.alignCrop(plain, face_row.astype(np.float32))
    cv2.imwrite(os.path.join(exact_dir, "crop.png"), exact_crop)

    frames, crops = [], []
    for path in source:
        name = os.path.basename(path)
        image = cv2.imread(path)
        shutil.copyfile(path, os.path.join(frames_dir, name))
        height, width = image.shape[:2]
        detector.setInputSize((width, height))
        _ok, faces = detector.detect(image)
        rows = []
        for face in (faces if faces is not None else []):
            # OpenCV hands back (x, y, w, h, 10 landmarks, score); store it the
            # same way so the Swift side is compared value for value.
            rows.append([float(v) for v in face])
            aligned = recogniser.alignCrop(image, face)
            crop_name = "%s__%d.jpg" % (name[:-4], len(crops))
            cv2.imwrite(os.path.join(crops_dir, crop_name), aligned)
            raw = session.run(None, {"data": aligned[:, :, ::-1].astype(np.float32)
                                     .transpose(2, 0, 1)[None]})[0].reshape(-1)
            crops.append({"file": "crops/" + crop_name,
                          "vector": b64(sface_torch.unit(raw))})
        frames.append({"file": "frames/" + name, "width": width, "height": height,
                       "faces": rows})

    fixture = {
        "generated_by": "docs/coreml-spike/face_engine_fixture.py",
        "reference": "cv2.FaceDetectorYN (score 0.7, nms 0.3) + cv2.alignCrop + "
                     "onnxruntime SFace, unit-normalised",
        "score_threshold": yunet_parity.SCORE_THRESHOLD,
        "nms_threshold": yunet_parity.NMS_THRESHOLD,
        "alignment_side": 112,
        "match_cosine": float(engine.FACE_MATCH_COSINE),
        "exact": {
            "source": "exact/source.png",
            "crop": "exact/crop.png",
            "points": points.tolist(),
            # engine.py's own key formula: sha256 of the packed 112x112x3 BGR
            # crop, first 16 bytes hex. The port must produce this exactly.
            "hash": hashlib.sha256(exact_crop.tobytes()).hexdigest()[:32],
        },
        "frames": frames,
        "crops": crops,
    }
    out = os.path.join(root, NAME)
    with open(out, "w") as handle:
        json.dump(fixture, handle)

    total = sum(len(f["faces"]) for f in frames)
    print("frames %d · faces %d · crops %d" % (len(frames), total, len(crops)))
    print("wrote %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))
    print("points the Swift test at:")
    print("  FVP_FACE_FIXTURE=%s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
