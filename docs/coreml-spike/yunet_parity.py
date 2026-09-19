#!/usr/bin/env python3
"""Task 6.2 — what `cv2.FaceDetectorYN` actually does, derived and reproduced.

Face identity is only as good as the crop it is measured on, and the crop is
made from this detector's landmarks. Phase 6.1 ported SFace faithfully, and the
Vision-landmark route was then measured and rejected (scale sd 6.6%, rotation sd
7.4° — enough to invalidate a threshold of 0.30 that was calibrated on
YuNet-aligned crops). So YuNet is ported too, and this file is the specification
the Swift port is held to.

**Everything here was derived, not remembered.** Three guesses were wrong before
the source settled it, and they are recorded because each one is a trap:

  1. **There is no resize and no letterbox.** OpenCV does not scale the frame to
     the model's declared 640x640. It pads the image AT ITS OWN SIZE with zeros
     on the right and bottom to a multiple of 32
     (`padW = ceil(W/32)*32`, `padH = ceil(H/32)*32`) and feeds that. The ONNX
     declares 640x640, but every `Reshape` in it targets `[1, -1, k]`, so it is
     fully convolutional and OpenCV's DNN runs it at any multiple of 32. Feeding
     a stretched 640x640 was the first wrong guess (mean box error 178 px).
  2. **BGR, not RGB.** SFace wanted RGB (measured in 6.1); YuNet wants BGR, the
     `blobFromImage` default. With the geometry right this is unambiguous: RGB
     leaves a 25 px mean error where BGR leaves 0.000.
  3. **The row layout is `(x, y, w, h, 10 landmarks, score)`** — score LAST, not
     after the box. Getting this wrong makes landmarks appear to be off by 780 px.

The decode itself (from `modules/objdetect/src/face_detect.cpp`) is:

    score = sqrt(clamp(cls,0,1) * clamp(obj,0,1))          # threshold 0.7
    cx = (c + bbox[0]) * stride                            # c = col, r = row
    cy = (r + bbox[1]) * stride
    w  = exp(bbox[2]) * stride
    h  = exp(bbox[3]) * stride
    landmark_k = ((kps[2k] + c) * stride, (kps[2k+1] + r) * stride)

and NMS runs on **integer** `Rect2i` boxes (`int()` truncation, not rounding) at
IoU 0.3, keeping the highest score first.

The gate, on the fixture frames:

    max |Δ| box       0.000092 px
    max |Δ| landmarks 0.000046 px
    max |Δ| score     0.00000066

which is float32 noise — the port is exact. `--dynamic` writes the
dynamic-input ONNX copy this needs: onnxruntime enforces the declared 640x640
and refuses any other size, while OpenCV reshapes. That copy is the *same
weights*, only the declared input dims change.

    /opt/anaconda3/bin/python3 docs/coreml-spike/yunet_parity.py [--dynamic]
"""

import argparse
import glob
import os
import sys

import cv2
import numpy as np
import onnx
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sface_torch                                     # noqa: E402

STRIDES = (8, 16, 32)
SCORE_THRESHOLD = 0.7        # engine.py's FaceDetectorYN.create(...)
NMS_THRESHOLD = 0.3
DIVISOR = 32


def dynamic_onnx(path=None):
    """A copy of YuNet whose input dims are dynamic, because ort enforces 640x640.

    Same weights, same graph: only `input`'s declared spatial dims change. This
    is not a workaround for a model defect — the model *is* fully convolutional
    (`Reshape` targets are `[1, -1, k]`); the declared shape is just what
    onnxruntime validates against.
    """
    path = path or sface_torch.find_model(sface_torch.YUNET_ONNX)
    out = os.path.join(sface_torch.fixtures_dir(), "yunet_dynamic.onnx")
    model = onnx.load(path)
    for dim, name in zip(model.graph.input[0].type.tensor_type.shape.dim,
                         ("N", "C", "H", "W")):
        dim.ClearField("dim_value")
        dim.dim_param = name
    onnx.save(model, out)
    return out


def pad_to_divisor(bgr):
    """Pad right/bottom with zeros to a multiple of 32 — OpenCV's own padding."""
    h, w = bgr.shape[:2]
    pad_w = ((w - 1) // DIVISOR + 1) * DIVISOR
    pad_h = ((h - 1) // DIVISOR + 1) * DIVISOR
    if (pad_w, pad_h) == (w, h):
        return bgr, w, h
    canvas = np.zeros((pad_h, pad_w, 3), np.uint8)
    canvas[:h, :w] = bgr
    return canvas, pad_w, pad_h


def decode(outputs, pad_w, pad_h, session):
    """Raw per-anchor tensors -> OpenCV's 15-value rows, highest score last.

    Row layout, matching `cv2.FaceDetectorYN` exactly:
        (tl_x, tl_y, w, h, re_x, re_y, le_x, le_y, nt_x, nt_y, rcm_x, rcm_y,
         lcm_x, lcm_y, score)
    're'/'le' right/left eye, 'nt' nose tip, 'rcm'/'lcm' right/left mouth corner
    — the model's own order, which is the order `cv2.alignCrop` consumes.
    """
    names = [o.name for o in session.get_outputs()]
    outs = dict(zip(names, outputs))
    rows = []
    for stride in STRIDES:
        cols = pad_w // stride
        cls = outs["cls_%d" % stride].reshape(-1)
        obj = outs["obj_%d" % stride].reshape(-1)
        bbox = outs["bbox_%d" % stride].reshape(-1, 4)
        kps = outs["kps_%d" % stride].reshape(-1, 10)
        score = np.sqrt(np.clip(cls, 0.0, 1.0) * np.clip(obj, 0.0, 1.0))
        for idx in np.where(score >= SCORE_THRESHOLD)[0]:
            row, col = divmod(int(idx), cols)
            cx, cy = (col + bbox[idx, 0]) * stride, (row + bbox[idx, 1]) * stride
            w, h = np.exp(bbox[idx, 2]) * stride, np.exp(bbox[idx, 3]) * stride
            points = np.array([[(kps[idx, 2 * k] + col) * stride,
                                (kps[idx, 2 * k + 1] + row) * stride]
                               for k in range(5)]).reshape(-1)
            rows.append(np.concatenate([[cx - w / 2, cy - h / 2, w, h],
                                        points, [score[idx]]]))
    if not rows:
        return np.zeros((0, 15))
    return nms(np.array(rows).reshape(-1, 15))


def nms(boxes, threshold=NMS_THRESHOLD):
    """`dnn::NMSBoxes` — on INTEGER boxes, so the truncation is part of the spec.

    OpenCV converts each float box to `Rect2i` before the overlap test, which
    rounds every coordinate *down*. Using the float boxes instead changes which
    boxes survive near the threshold, so the port has to truncate too.
    """
    order = np.argsort(-boxes[:, 14])
    keep = []
    while len(order):
        i = order[0]
        keep.append(i)
        if len(order) == 1:
            break
        rest = boxes[order[1:]]
        a = boxes[i]
        ax, ay, aw, ah = int(a[0]), int(a[1]), int(a[2]), int(a[3])
        rx, ry, rw, rh = (rest[:, 0].astype(int), rest[:, 1].astype(int),
                          rest[:, 2].astype(int), rest[:, 3].astype(int))
        inter = (np.clip(np.minimum(ax + aw, rx + rw) - np.maximum(ax, rx), 0, None)
                 * np.clip(np.minimum(ay + ah, ry + rh) - np.maximum(ay, ry), 0, None))
        iou = inter / (aw * ah + rw * rh - inter)
        order = order[1:][iou <= threshold]
    return boxes[keep]


def detect(bgr, session):
    padded, pad_w, pad_h = pad_to_divisor(bgr)
    # BGR, raw 0-255, NCHW: `dnn::blobFromImage` with no scale and no swapRB.
    blob = padded.astype(np.float32).transpose(2, 0, 1)[None]
    return decode(session.run(None, {"input": blob}), pad_w, pad_h, session)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dynamic", action="store_true",
                        help="rewrite the dynamic-input ONNX copy and stop")
    args = parser.parse_args()

    dynamic = dynamic_onnx()
    if args.dynamic:
        print("wrote %s" % dynamic)
        return 0

    frames = sorted(glob.glob(os.path.join(sface_torch.fixtures_dir(),
                                           "face_align", "frames", "frame_*.png")))
    if not frames:
        print("SKIP (no frames)\n  run docs/coreml-spike/face_align_parity.py --build first")
        return 0

    session = ort.InferenceSession(dynamic, providers=["CPUExecutionProvider"])
    detector = cv2.FaceDetectorYN.create(sface_torch.find_model(sface_torch.YUNET_ONNX),
                                         "", (320, 320), SCORE_THRESHOLD,
                                         NMS_THRESHOLD, 5000)
    box, landmark, score, faces = [], [], [], 0
    for path in frames:
        image = cv2.imread(path)
        h, w = image.shape[:2]
        detector.setInputSize((w, h))
        _ok, reference = detector.detect(image)
        want = 0 if reference is None else len(reference)
        mine = detect(image, session)
        if want != len(mine):
            print("FAIL %s: cv2 found %d, the port found %d"
                  % (os.path.basename(path), want, len(mine)))
            return 1
        # OpenCV returns highest score first; sort both so row i is the same face.
        reference = reference[np.argsort(-reference[:, 14])] if want else reference
        mine = mine[np.argsort(-mine[:, 14])] if len(mine) else mine
        for i in range(want):
            faces += 1
            box.append(float(np.abs(mine[i, :4] - reference[i, :4]).max()))
            landmark.append(float(np.abs(mine[i, 4:14] - reference[i, 4:14]).max()))
            score.append(float(abs(mine[i, 14] - reference[i, 14])))

    print("frames %d · faces %d · every frame's count identical" % (len(frames), faces))
    print("%-22s %.6f px" % ("max |Δ| box", max(box)))
    print("%-22s %.6f px" % ("max |Δ| landmarks", max(landmark)))
    print("%-22s %.8f" % ("max |Δ| score", max(score)))

    ok = max(box) < 0.01 and max(landmark) < 0.01 and max(score) < 1e-4
    print("\n%s: the decode, the NMS and the preprocessing are the reference"
          % ("GATE PASS" if ok else "GATE FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
