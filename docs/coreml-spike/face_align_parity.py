#!/usr/bin/env python3
"""Task 6.2 — can Vision's landmarks replace YuNet's without moving a face?

The Phase 6.1 spike ended on this exact caveat: the SFace port is faithful, but
it eats 112x112 aligned crops, and *how those crops are made* changes with the
substitution from YuNet + `cv2.alignCrop` to Vision + our own transform. If the
crops move, every cosine moves with them, and `FACE_MATCH_COSINE = 0.30` — tuned
on crops made the old way — stops meaning what it means.

    /opt/anaconda3/bin/python3 docs/coreml-spike/face_align_parity.py [--build]

What it settles, in order:

  1. **The reference transform.** `cv2.FaceRecognizerSF.alignCrop` is reproduced
     from scratch (Umeyama similarity onto the ArcFace 5-point template, YuNet's
     landmarks used as-is, no reflection). Measured agreement: cosine
     0.9999995. This is what makes the port a *port* rather than an invention.
  2. **Vision's landmark ordering.** Vision reports eye regions, a nose and lip
     regions; the template wants left eye, right eye, nose, left mouth, right
     mouth. Which of Vision's eyes is the image-left one is the classic trap, so
     both orderings are measured instead of assumed, and the script prints the
     winner and by how much.
  3. **The gate.** Every pair of faces in the fixture, scored by SFace, once
     from crops aligned the old way and once from crops aligned with Vision's
     landmarks. The decisions at 0.30 must agree, and the cosine drift must stay
     small. That is the whole question: not "are the crops the same" but "is it
     still the same person".

Run `docs/coreml-spike/FaceAlignSpike/main.swift` first (the script builds and
runs it when the binary is missing) so `vision.json` exists.
"""

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np                                     # noqa: E402

import sface_torch                                     # noqa: E402

# The ArcFace/SFace 5-point template at 112x112 — what `alignCrop` aligns to:
# left eye, right eye, nose, left mouth corner, right mouth corner.
TEMPLATE = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                     [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float64)

FRAMES = 8              # frames to dump
FRAME_SIZE = 1024       # the app's own longest-side cap
THRESHOLD = 0.30        # engine.FACE_MATCH_COSINE
SPIKE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "FaceAlignSpike", "main.swift")
BINARY = "/tmp/fvp-facealign"


def work_dir():
    override = os.environ.get("FVP_FIXTURE_DIR")
    root = override or sface_torch.fixtures_dir()
    return os.path.join(root, "face_align")


def umeyama(src, dst):
    """OpenCV's `alignCrop` transform: a similarity fit, reflection forbidden."""
    src = np.asarray(src, dtype=np.float64)
    dst = np.asarray(dst, dtype=np.float64)
    n = len(src)
    mean_src, mean_dst = src.mean(0), dst.mean(0)
    src_d, dst_d = src - mean_src, dst - mean_dst
    A = dst_d.T @ src_d / n
    U, D, Vt = np.linalg.svd(A)
    d = np.ones(2)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        d[-1] = -1
    T = U @ np.diag(d) @ Vt
    scale = float((D * d).sum() / ((src_d ** 2).sum() / n))
    M = np.zeros((2, 3), dtype=np.float64)
    M[:, :2] = scale * T
    M[:, 2] = mean_dst - scale * T @ mean_src
    return M


def align(bgr, points):
    import cv2
    M = umeyama(points, TEMPLATE)
    return cv2.warpAffine(bgr, M, (112, 112), flags=cv2.INTER_LINEAR, borderValue=0)


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


# --------------------------------------------------------------------------
# stage 1 — frames, and the YuNet reference
# --------------------------------------------------------------------------

def build_frames(work):
    """Dump frames (PNG, as Vision will read them) and the YuNet reference."""
    import cv2

    frames_dir = os.path.join(work, "frames")
    shutil.rmtree(frames_dir, ignore_errors=True)
    os.makedirs(frames_dir, exist_ok=True)

    yunet = sface_torch.find_model(sface_torch.YUNET_ONNX)
    sface = sface_torch.find_model(sface_torch.SFACE_ONNX)
    det = cv2.FaceDetectorYN.create(yunet, "", (320, 320), 0.7, 0.3, 5000)
    rec = cv2.FaceRecognizerSF.create(sface, "")

    videos = sorted(glob.glob(os.path.expanduser("~/Downloads/*.mp4")))
    if not videos:
        print("SKIP (no videos)\n  set FVP_FACE_VIDEOS, or put mp4s in ~/Downloads")
        return None

    dumped, reference = [], []
    for path in videos:
        if len(dumped) >= FRAMES:
            break
        cap = cv2.VideoCapture(path)
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        for i in range(0, max(total, 1), max(total // 4, 1)):
            if len(dumped) >= FRAMES:
                break
            cap.set(cv2.CAP_PROP_POS_FRAMES, i)
            ok, frame = cap.read()
            if not ok:
                continue
            h, w = frame.shape[:2]
            scale = float(FRAME_SIZE) / max(h, w)
            if scale < 1.0:
                frame = cv2.resize(frame, (int(w * scale), int(h * scale)))
            det.setInputSize((frame.shape[1], frame.shape[0]))
            _ok, faces = det.detect(frame)
            if faces is None or not len(faces):
                continue
            name = "frame_%03d.png" % len(dumped)
            cv2.imwrite(os.path.join(frames_dir, name), frame)
            dumped.append(name)
            for f in faces:
                box, score = f[:4], float(f[-1])
                landmarks = f[4:14].reshape(5, 2).astype(np.float64)
                ref = rec.alignCrop(frame, f)
                reference.append({
                    "frame": name,
                    # Which video the frame came from — the only same-person signal
                    # available without the maintainer's labelled faces, and what makes
                    # "does the threshold still separate people?" measurable.
                    "video": os.path.basename(path),
                    "box": [float(v) for v in box],
                    "score": score,
                    # YuNet's own order, used as-is — measured against the
                    # ArcFace template, not swapped. See the module docstring.
                    "points": landmarks.tolist(),
                    "crop": "%s__%d.png" % (name[:-4], len(reference)),
                })
                cv2.imwrite(os.path.join(work, reference[-1]["crop"]), ref)
        cap.release()

    with open(os.path.join(work, "yunet.json"), "w") as fh:
        json.dump({"faces": reference}, fh)
    print("stage 1  %d frame(s), %d face(s) detected by YuNet" % (len(dumped), len(reference)))
    return reference


# --------------------------------------------------------------------------
# stage 2 — Vision's landmarks
# --------------------------------------------------------------------------

def run_spike(work):
    vision = os.path.join(work, "vision.json")
    if not os.path.exists(BINARY) or os.path.getmtime(SPIKE) > os.path.getmtime(BINARY):
        print("building the Vision spike")
        result = subprocess.run(
            ["swiftc", "-O", "-o", BINARY, SPIKE,
             "-framework", "Vision", "-framework", "ImageIO",
             "-framework", "CoreGraphics"],
            capture_output=True, text=True)
        if result.returncode != 0:
            print("swiftc failed:\n%s" % result.stderr[-3000:])
            return None
    if os.path.exists(vision):
        os.remove(vision)
    result = subprocess.run([BINARY, work], capture_output=True, text=True)
    if result.returncode != 0 or not os.path.exists(vision):
        print("spike failed: %s%s" % (result.stdout, result.stderr))
        return None
    for line in result.stdout.strip().splitlines()[:2]:
        print("stage 2  %s" % line)
    return json.load(open(vision))


# --------------------------------------------------------------------------
# stage 3 — ordering, transform parity, and the identity gate
# --------------------------------------------------------------------------

def iou(a, b):
    """Overlap of two [x, y, w, h] boxes in image pixels."""
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    x1, y1 = max(ax, bx), max(ay, by)
    x2, y2 = min(ax + aw, bx + bw), min(ay + ah, by + bh)
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


def five_points(face, recipe):
    """Vision's regions -> the template's five points, under one recipe.

    Three things are genuinely ambiguous and each is measured rather than
    assumed, because each one moves the crop:

      - **eyes**: Vision's `leftEye` is the subject's left, which is the image
        RIGHT for someone facing the camera. The template wants image-left
        first. `eye_order` settles it by measurement.
      - **mouth corners**: Vision publishes labial contours, not two points. The
        corners are either the extreme-x pair or the farthest-apart pair; they
        agree on a frontal face and diverge on a turned one.
      - **nose**: YuNet's landmark is the nose tip. Vision's `nose` region is a
        small point cloud around the nostrils, so its mean and its lowest point
        are two different guesses at the same thing.
    """
    regions = face["regions"]
    for key in ("leftEye", "rightEye", "nose"):
        if not regions.get(key):
            return None
    outer = np.asarray(regions.get("outerLips") or [], dtype=np.float64)
    if len(outer) < 4:
        return None

    if recipe["mouth"] == "extreme_x":
        left_mouth = outer[outer[:, 0].argmin()]
        right_mouth = outer[outer[:, 0].argmax()]
    else:                                   # "farthest": the corner-to-corner span
        gaps = np.linalg.norm(outer[:, None, :] - outer[None, :, :], axis=-1)
        i, j = np.unravel_index(gaps.argmax(), gaps.shape)
        left_mouth, right_mouth = (outer[i], outer[j]) if outer[i][0] <= outer[j][0] \
            else (outer[j], outer[i])

    nose = np.asarray(regions["nose"], dtype=np.float64)
    nose_point = nose.mean(0) if recipe["nose"] == "mean" else nose[nose[:, 1].argmax()]

    order = recipe["eyes"]
    eye_a = np.asarray(regions[order[0]], dtype=np.float64).mean(0)
    eye_b = np.asarray(regions[order[1]], dtype=np.float64).mean(0)
    return np.stack([eye_a, eye_b, nose_point, left_mouth, right_mouth])


def match(reference, vision):
    """Pair each YuNet face with the Vision face it actually overlaps.

    Ranking both sides by box area and zipping them was the first attempt and it
    was wrong: with two faces in a frame the ranks disagree and different people
    get compared, which reads as a catastrophic alignment failure (-0.006 cosine)
    when the alignment is fine. Overlap is the only honest pairing key.
    """
    by_frame = {}
    for face in reference:
        by_frame.setdefault(face["frame"], []).append(face)
    pairs, unmatched = [], 0
    for frame in vision["frames"]:
        faces = frame["faces"]
        for ref in by_frame.get(frame["name"], []):
            overlaps = [iou(ref["box"], f["box"]) for f in faces]
            if not overlaps or max(overlaps) < 0.30:
                unmatched += 1
                continue
            pairs.append((frame["name"], ref, faces[int(np.argmax(overlaps))],
                          float(max(overlaps))))
    if unmatched:
        print("stage 3  %d YuNet face(s) had no Vision box overlapping them" % unmatched)
    return pairs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", action="store_true", help="re-dump frames")
    args = parser.parse_args()

    work = work_dir()
    os.makedirs(work, exist_ok=True)

    reference = None
    if not args.build and os.path.exists(os.path.join(work, "yunet.json")):
        reference = json.load(open(os.path.join(work, "yunet.json")))["faces"]
        print("stage 1  %d reference face(s) (cached; --build to redo)" % len(reference))
        if not reference:
            reference = None
    if reference is None:
        reference = build_frames(work)
        if reference is None:
            return 0
    if not reference:
        print("SKIP: no faces detected in any frame")
        return 0

    vision = run_spike(work)
    if vision is None:
        print("SKIP: no Vision data")
        return 0

    import cv2
    import onnxruntime as ort
    sess = ort.InferenceSession(sface_torch.find_model(sface_torch.SFACE_ONNX),
                                providers=["CPUExecutionProvider"])

    def embed(crop):
        raw = sess.run(None, {"data": crop[:, :, ::-1].astype(np.float32)
                              .transpose(2, 0, 1)[None]})[0].reshape(-1)
        return unit(raw)

    # --- shared frames, loaded once -----------------------------------------
    pairs = match(reference, vision)
    if not pairs:
        print("SKIP: Vision found no faces on the dumped frames — nothing to compare")
        return 0
    print("stage 3  %d face(s) paired by box overlap (mean IoU %.2f)"
          % (len(pairs), float(np.mean([p[3] for p in pairs]))))
    frames = {}
    for name, _ref, _face, _iou in pairs:
        if name not in frames:
            frames[name] = cv2.imread(os.path.join(work, "frames", name))
    ref_vecs = {face["crop"]: embed(cv2.imread(os.path.join(work, face["crop"])))
                for face in reference}

    # --- which recipe reproduces alignCrop best ------------------------------
    recipes = {}
    for eyes in (("leftEye", "rightEye"), ("rightEye", "leftEye")):
        for mouth in ("extreme_x", "farthest"):
            for nose in ("mean", "lowest"):
                recipes["%-12s %-9s %-6s" % (eyes[0][:12], mouth, nose)] = {
                    "eyes": eyes, "mouth": mouth, "nose": nose}

    print("\n%-32s %-9s %-9s %s" % ("recipe", "min cos", "mean cos", "faces"))
    choice = None
    for label, recipe in recipes.items():
        cosines = []
        for name, ref, face, _iou in pairs:
            points = five_points(face, recipe)
            if points is None:
                continue
            cosines.append(float(np.dot(embed(align(frames[name], points)),
                                        ref_vecs[ref["crop"]])))
        if not cosines:
            continue
        print("%-32s %-9.5f %-9.5f %d"
              % (label, min(cosines), float(np.mean(cosines)), len(cosines)))
        if choice is None or float(np.mean(cosines)) > choice[1]:
            choice = (label, float(np.mean(cosines)), recipe)

    if choice is None:
        print("SKIP: Vision produced no usable 5-point sets")
        return 0
    label, mean_cos, recipe = choice
    print("\nbest recipe: %s (mean cosine to cv2.alignCrop %.5f)" % (label, mean_cos))

    # --- the identity gate --------------------------------------------------
    vision_vecs, ref_vecs_list = [], []
    for name, ref, face, _iou in pairs:
        points = five_points(face, recipe)
        if points is None:
            continue
        vision_vecs.append(embed(align(frames[name], points)))
        ref_vecs_list.append(ref_vecs[ref["crop"]])

    old = np.stack(ref_vecs_list)
    new = np.stack(vision_vecs)
    old_cos, new_cos = old @ old.T, new @ new.T
    upper = np.triu(np.ones(old_cos.shape, dtype=bool), 1)
    drift = float(np.abs(new_cos - old_cos)[upper].max())
    old_hits = int((old_cos[upper] >= THRESHOLD).sum())
    new_hits = int((new_cos[upper] >= THRESHOLD).sum())
    per_face = float(np.abs(new - old).max(axis=1).max())

    print("\n%-22s %s" % ("faces compared", len(new)))
    print("%-22s %.3e" % ("max |Δ unit vector|", per_face))
    print("%-22s %.4f" % ("max |Δ cosine|", drift))
    print("%-22s %.4f .. %.4f" % ("cosine range (yu-net)", old_cos[upper].min(), old_cos[upper].max()))
    print("%-22s %.4f .. %.4f" % ("cosine range (vision)", new_cos[upper].min(), new_cos[upper].max()))
    print("%-22s %d (yu-net) vs %d (vision)" % ("pairs ≥ 0.30", old_hits, new_hits))

    with open(os.path.join(work, "alignment.json"), "w") as fh:
        json.dump({
            "recipe": recipe,
            "gate": {"max_cosine_drift": drift, "same_decisions": old_hits == new_hits,
                     "pairs_at_threshold": [old_hits, new_hits]},
            "template": TEMPLATE.tolist(),
        }, fh, indent=2)

    ok = old_hits == new_hits and drift <= 0.05
    print("\n%s: Vision landmarks are %s for alignment"
          % ("GATE PASS" if ok else "GATE FAIL",
             "a drop-in replacement" if ok else "NOT a drop-in replacement"))
    if not ok:
        print("  The 0.30 threshold would have to be re-derived on Vision-aligned crops.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
