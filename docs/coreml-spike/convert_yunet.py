#!/usr/bin/env python3
"""Task 6.2 — YuNet to Core ML, gated at the detection level against OpenCV.

The point of porting the detector as well as the embedder is that the crops must
not move: `FACE_MATCH_COSINE = 0.30` was calibrated on YuNet-aligned crops, and
Vision's landmarks were measured and rejected for exactly this reason. So this
script does not settle for "the tensors are close" — it decodes the Core ML
output with the ported decode and NMS and compares the *detections* to
`cv2.FaceDetectorYN`, because a detection is what the app actually consumes.

**The input is dynamic.** YuNet is fully convolutional (every `Reshape` targets
`[1, -1, k]`), and OpenCV runs it at the frame's own size padded to a multiple of
32 — so the Core ML model is asked for the same freedom rather than being pinned
to one resolution. A fixed 640x640 was the first wrong guess in this task.

Input geometry, from `yunet_parity.py`: BGR, raw 0-255, zero-padded right/bottom
to a multiple of 32, `scale=1` and no bias.

    /opt/anaconda3/bin/python3 docs/coreml-spike/convert_yunet.py
"""

import glob
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np                                     # noqa: E402

import sface_torch                                     # noqa: E402
import yunet_parity                                    # noqa: E402
import yunet_torch                                     # noqa: E402

SHIP_NAME = "yunet.mlpackage"
MIN_SIDE, MAX_SIDE = 32, 1600      # RangeDim bounds; the app caps frames at 1024


def trace(model, example):
    import torch
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)
    return traced.eval()


def convert(traced):
    """Dynamic height/width, a multiple of 32, BGR, raw pixels."""
    import coremltools as ct
    return ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            # RangeDim has no step: the model accepts any size, and the caller
            # always feeds a multiple of 32 because the decode divides by it.
            shape=ct.Shape(shape=(
                1, 3,
                ct.RangeDim(MIN_SIDE, MAX_SIDE, default=288),
                ct.RangeDim(MIN_SIDE, MAX_SIDE, default=512))),
            color_layout=ct.colorlayout.BGR)],
        outputs=[ct.TensorType(name=n) for n in yunet_torch.OUTPUT_NAMES],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )


def size_of(path):
    return subprocess.run(["du", "-sh", path], capture_output=True,
                          text=True).stdout.split()[0]


def main():
    fixtures = sface_torch.fixtures_dir()
    frames = sorted(glob.glob(os.path.join(fixtures, "face_align", "frames", "frame_*.png")))
    if not frames:
        print("SKIP (no frames)\n  run docs/coreml-spike/face_align_parity.py --build first")
        return 0

    import cv2
    import coremltools as ct
    import onnxruntime as ort
    from PIL import Image

    model = yunet_torch.build()
    example = torch_example()
    traced = trace(model, example)
    staged = os.path.join(fixtures, "yunet_staged.mlpackage")
    if os.path.exists(staged):
        shutil.rmtree(staged)
    convert(traced).save(staged)
    print("converted %s (%s)" % (staged, size_of(staged)))

    mlmodel = ct.models.MLModel(staged)
    session = ort.InferenceSession(yunet_parity.dynamic_onnx(),
                                   providers=["CPUExecutionProvider"])
    detector = cv2.FaceDetectorYN.create(sface_torch.find_model(sface_torch.YUNET_ONNX),
                                         "", (320, 320),
                                         yunet_parity.SCORE_THRESHOLD,
                                         yunet_parity.NMS_THRESHOLD, 5000)

    tensor_drift, box_drift, lm_drift, score_drift, faces = [], [], [], [], 0
    for path in frames:
        image = cv2.imread(path)
        h, w = image.shape[:2]
        padded, pad_w, pad_h = yunet_parity.pad_to_divisor(image)

        # --- tensor level: Core ML vs the same graph in onnxruntime -----------
        blob = padded.astype(np.float32).transpose(2, 0, 1)[None]
        reference = session.run(None, {"input": blob})
        # The package declares BGR, so hand it the frame in its natural order and
        # let the declared layout do the swap. (coremltools' Python `predict`
        # insists on a PIL image; the app hands it a CVPixelBuffer instead.)
        got = mlmodel.predict({"image": Image.fromarray(padded[:, :, ::-1])})
        for name, want in zip(yunet_torch.OUTPUT_NAMES, reference):
            mine = np.asarray(got[name]).reshape(want.shape)
            tensor_drift.append(float(np.abs(mine - want).max()))

        # --- detection level: decode Core ML's OWN tensors, compare to OpenCV -
        # This is the gate that matters: not that the tensors are close, but
        # that the detections the app consumes are the same ones.
        detector.setInputSize((w, h))
        _ok, faces_cv = detector.detect(image)
        want_faces = 0 if faces_cv is None else len(faces_cv)
        mine_faces = yunet_parity.decode(
            [np.asarray(got[n]) for n in yunet_torch.OUTPUT_NAMES], pad_w, pad_h, session)
        if want_faces != len(mine_faces):
            print("FAIL %s: cv2 found %d, Core ML found %d"
                  % (os.path.basename(path), want_faces, len(mine_faces)))
            return 1
        faces_cv = faces_cv[np.argsort(-faces_cv[:, 14])] if want_faces else faces_cv
        mine_faces = mine_faces[np.argsort(-mine_faces[:, 14])] if len(mine_faces) else mine_faces
        for i in range(want_faces):
            faces += 1
            box_drift.append(float(np.abs(mine_faces[i, :4] - faces_cv[i, :4]).max()))
            lm_drift.append(float(np.abs(mine_faces[i, 4:14] - faces_cv[i, 4:14]).max()))
            score_drift.append(float(abs(mine_faces[i, 14] - faces_cv[i, 14])))

    print("\n%-28s %.6f" % ("max |Δ| raw tensor", max(tensor_drift)))
    print("%-28s %.6f px  (%d faces, every count identical)"
          % ("max |Δ| box vs cv2", max(box_drift), faces))
    print("%-28s %.6f px" % ("max |Δ| landmarks vs cv2", max(lm_drift)))
    print("%-28s %.8f" % ("max |Δ| score vs cv2", max(score_drift)))

    ok = max(box_drift) < 0.01 and max(lm_drift) < 0.01 and max(score_drift) < 1e-4
    if not ok:
        print("\nGATE FAIL: Core ML does not reproduce the detector — not installing")
        return 1

    ship = os.path.join(fixtures, SHIP_NAME)
    if os.path.exists(ship):
        shutil.rmtree(ship)
    shutil.move(staged, ship)
    print("\nGATE PASS: Core ML detections match cv2.FaceDetectorYN")
    print("installed     %s (%s)" % (ship, size_of(ship)))
    return 0


def torch_example():
    import torch
    return torch.zeros(1, 3, 288, 512)


if __name__ == "__main__":
    sys.exit(main())
