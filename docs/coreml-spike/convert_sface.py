#!/usr/bin/env python3
"""Task 0.3a — convert SFace (face embeddings) to Core ML.

SFace is the model that decides whether two faces are the same person. The
whole face feature is calibrated on its cosine scale: FACE_MATCH_COSINE = 0.30,
tuned against the maintainer's ACTUAL faces (cross-video peak 0.326, well under the
model card's canonical 0.363 — pitfall 28). If the Core ML port shifts that
scale, the threshold stops meaning what it means.

The gate: Core ML and ONNX cosines must agree to +/- 0.01 on identical crops.

SFace is an ONNX model, so the route is ONNX -> Core ML directly.
"""
import os
import subprocess

import numpy as np

SUPPORT = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer")
MODELS = os.path.join(SUPPORT, "models")
SFACE = os.path.join(MODELS, "face_recognition_sface_2021dec.onnx")
OUT = "/tmp/mobileclip_spike/sface.mlpackage"


def main():
    if not os.path.exists(SFACE):
        raise SystemExit("SFace ONNX not found at " + SFACE)

    import cv2
    import coremltools as ct

    # --- what shape does it want? ---
    net = cv2.dnn.readNet(SFACE)
    print("SFace loaded via OpenCV")

    # Gather real face crops from the app's own cache — these are the exact
    # images the live system embeds, so the comparison is on real data.
    faces_dir = os.path.join(SUPPORT, "faces")
    crops = []
    for root, _, files in os.walk(faces_dir):
        for f in files:
            if f.endswith(".jpg"):
                crops.append(os.path.join(root, f))
            if len(crops) >= 40:
                break
        if len(crops) >= 40:
            break
    print("face crops found:", len(crops))
    if not crops:
        raise SystemExit("no cached face crops to compare against")

    # --- ONNX reference embeddings (what the app produces today) ---
    recognizer = cv2.FaceRecognizerSF.create(SFACE, "")
    onnx_vecs = {}
    for path in crops[:20]:
        img = cv2.imread(path)
        if img is None:
            continue
        # Cached crops are already aligned 112x112 by _faces_in_frame.
        if img.shape[0] != 112 or img.shape[1] != 112:
            img = cv2.resize(img, (112, 112))
        vec = recognizer.feature(img).reshape(-1)
        onnx_vecs[path] = vec / np.linalg.norm(vec)
    print("embedded with ONNX:", len(onnx_vecs))

    # --- convert ---
    if not os.path.exists(OUT):
        try:
            mlmodel = ct.converters.onnx.convert(model=SFACE)   # old API
            mlmodel.save(OUT)
        except Exception as e:
            print("coremltools onnx path unavailable (%s)" % type(e).__name__)
            print("Falling back: keep SFace as ONNX and run it through")
            print("onnxruntime? NO — that reintroduces a Python dependency.")
            print()
            print("RECOMMENDATION: convert via PyTorch re-implementation, or")
            print("use Vision's own face landmarks + a Core ML embedder.")
            print("Recording this as a Phase 5 risk rather than a blocker:")
            print("face recognition can ship AFTER the rest.")
            return

    print("converted:", OUT)
    mlmodel = ct.models.MLModel(OUT)
    spec = mlmodel.get_spec()
    for i in spec.description.input:
        print("  IN ", i.name)
    for o in spec.description.output:
        print("  OUT", o.name)

    # --- compare ---
    drifts = []
    for path, ref in list(onnx_vecs.items())[:10]:
        img = cv2.imread(path)
        if img.shape[0] != 112:
            img = cv2.resize(img, (112, 112))
        inp = img.astype(np.float32).transpose(2, 0, 1)[None]
        out = mlmodel.predict({spec.description.input[0].name: inp})
        vec = list(out.values())[0].reshape(-1)
        vec = vec / np.linalg.norm(vec)
        drifts.append(float(np.abs(vec - ref).max()))
    print("max element drift:", max(drifts) if drifts else "n/a")
    print("GATE:", "PASS" if drifts and max(drifts) < 0.01 else "INVESTIGATE")


if __name__ == "__main__":
    main()
