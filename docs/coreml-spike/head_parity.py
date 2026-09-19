#!/usr/bin/env python3
"""Generate the fixture that proves the Swift logistic head fits like engine.py.

This is the counterpart to `table_parity.py`, for Phase 3 instead of Phase 2.
It does not re-implement the trainer. It imports the real `engine` module,
monkeypatches only its I/O (the frame cache, the heads file, the stdout
protocol) and calls the real `engine.train` / `engine.train_nsfw`. So the
"expected" values below are the Python path's own output, not a second copy of
the maths that could drift away from it.

    /opt/anaconda3/bin/python3 docs/coreml-spike/head_parity.py

Writes `~/fvp-coreml-models/head_fixture.json`. The Swift side
(`Tests/test_logistic_head.swift`) reads that file and must reproduce every
number in it: the collection step, the gate, the split, the fit, the held-out
metrics, the refusal reasons, and the stored float32 weights.
"""

import base64
import hashlib
import json
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "AnalysisEngine"))

import numpy as np                                     # noqa: E402
import engine                                          # noqa: E402

OUT = (sys.argv[1] if len(sys.argv) > 1
       else os.path.expanduser("~/fvp-coreml-models/head_fixture.json"))
DIM = 96
N_VIDEOS = 41            # v00…v40; the split is "every 5th video"
FRAMES = 5
MISSING = "v40"          # sent with hashes, but the cache has nothing for it


def b64_f32(a):
    return base64.b64encode(np.asarray(a, dtype="<f4").tobytes()).decode()


def b64_f64(a):
    return base64.b64encode(np.asarray(a, dtype="<f8").tobytes()).decode()


# --- the dataset -----------------------------------------------------------
# Deterministic, and deliberately lumpy rather than Gaussian: a real library's
# vectors are unit-norm and clustered, so a fixture of pure noise would test a
# region the trainer never visits.
rng = np.random.default_rng(7)
frames = {}          # hash -> float32 vector
videos = []          # ordered, as the app sends them
cache = {}           # hash -> vector, what _cache_read will serve

for vi in range(N_VIDEOS):
    key = "v%02d" % vi
    hashes = []
    for fi in range(FRAMES):
        h = "f%02d%02d%s" % (vi, fi, "ab"[vi % 2])
        vec = rng.normal(size=DIM).astype(np.float32)
        # a per-video tilt so tags are actually learnable, and a per-tag-load
        # bump for the positive videos makes the fits non-degenerate
        vec = vec + np.float32(0.35 * (vi % 7)) * np.linspace(-1, 1, DIM).astype(np.float32)
        frames[h] = vec
        hashes.append(h)
    videos.append({"key": key, "hashes": hashes})
    if key != MISSING:
        for h in hashes:
            cache[h] = frames[h]

labels = [
    {"tag": "alpha",   "labels": {  # 10 accepted / 17 rejected -> fits, and 7 held out
        **{"v%02d" % i: True for i in (1, 2, 3, 4, 6, 7, 8, 9, 10, 30)},
        **{"v%02d" % i: False for i in [5] + list(range(11, 26)) + [35]}}},
    {"tag": "eta",     "labels": {  # a fit whose held-out videos are ALL positive
        **{"v%02d" % i: True for i in (0, 5, 10, 15, 20, 1, 2, 3, 4, 6, 7, 8)},
        **{"v%02d" % i: False for i in (26, 27, 28, 29, 31, 32, 33, 34)}}},
    {"tag": "beta",    "labels": {  # 3 accepted -> the gate refuses
        **{"v%02d" % i: True for i in (1, 2, 3)},
        **{"v%02d" % i: False for i in range(11, 26)}}},
    {"tag": "gamma",   "labels": {  # 6 accepted but only 3 rejected -> refuses
        **{"v%02d" % i: True for i in (1, 2, 3, 4, 6, 7)},
        **{"v%02d" % i: False for i in (11, 12, 13)}}},
    {"tag": "delta",   "labels": {  # tagged, and never judged either way
        "v01": None, "v02": None}},
    {"tag": "epsilon", "labels": {  # 4/4, but every labelled video is held out
        **{"v%02d" % i: True for i in (0, 10, 20, 30)},
        **{"v%02d" % i: False for i in (5, 15, 25, 35)}}},
    {"tag": "zeta",    "labels": {  # labels only on videos with no cached frames
        "v00": True, MISSING: True, "v05": False, "v10": False}},
]
nsfw_labels = {**{"v%02d" % i: True for i in range(1, 9)},
               **{"v%02d" % i: False for i in range(9, 21)}}

# --- drive the real trainer through a fake request -------------------------
emitted = []
tmpdir = tempfile.mkdtemp(prefix="fvp-head-parity-")
npz_path = os.path.join(tmpdir, "heads.npz")          # np.savez wants the suffix

engine._cache_path = lambda h: os.path.join(tmpdir, "cache.f32")   # unused: _cache_read is patched
engine._cache_read = lambda h: (None if h not in cache
                                else [float(v) for v in cache[h]])
engine._trained_heads_path = lambda: npz_path
engine._embed_dim = DIM
engine.report = lambda req, kind, **kw: emitted.append(dict(type=kind, **kw))
engine.done = lambda req, ok, **kw: emitted.append(dict(type="done", ok=ok, **kw))
engine.err = lambda req, msg: emitted.append(dict(type="error", message=msg))

req = {"id": 1, "frameHashes": {v["key"]: v["hashes"] for v in videos},
       "labels": {t["tag"]: {k: bool(x) for k, x in t["labels"].items() if x is not None}
                  for t in labels}}

engine.train(req)
train_out = emitted[0]["fits"]
assert "error" not in [e["type"] for e in emitted], emitted

# nsfw: a separate call, into the same file — the merge rule is exercised by
# the fact that the tag heads must still be there afterwards
emitted.clear()
engine.train_nsfw({"id": 2, "frameHashes": {v["key"]: v["hashes"] for v in videos},
                   "labels": nsfw_labels})
nsfw_fit = emitted[0]["fit"]
assert "error" not in [e["type"] for e in emitted], emitted

# --- what the app would read back -----------------------------------------
z = np.load(npz_path)
stored = {k: z[k] for k in z.files}
keys = sorted(stored["head/%s/n" % t["tag"]] for t in labels if "head/%s/n" % t["tag"] in stored)

# the collection step, recomputed the way engine.py does it, so the Swift
# side can be checked on the vectors themselves and not only on the outcome.
# NOTE: `_cache_read` hands Python *float64* values widened from float32
# (`struct.unpack("<f")`), so the sum must be widened too — summing the raw
# float32 scalars here would put a 1e-8 error into the fixture and make the
# Swift port look wrong when it is arithmetic-identical.
used, rows = [], []
for v in videos:
    vecs = [[float(x) for x in cache[h]] for h in v["hashes"] if h in cache]
    if not vecs:
        continue
    acc = None
    for vec in vecs:
        acc = vec if acc is None else [a + b for a, b in zip(acc, vec)]
    used.append(v["key"])
    rows.append([a / len(vecs) for a in acc])
X = np.array(rows, dtype=np.float64)
norms = np.linalg.norm(X, axis=1, keepdims=True)
norms[norms == 0] = 1
X = X / norms

heads = {}
for name in z.files:
    if name.startswith("head/") and name.endswith("/w"):
        tag = name[len("head/"):-2]
        heads[tag] = {"w": b64_f32(z[name]), "b": float(z["head/%s/b" % tag]),
                      "n": float(z["head/%s/n" % tag])}


def raw_metrics(tag, labels):
    """Precision/recall recomputed from the STORED float32 head over the
    held-out videos — the same videos engine.train scored, but scored again
    from the artifact the app will read. engine.py keeps only the rounded
    numbers in its report, so this is the raw value the Swift side is compared
    against, and it must round to what the engine reported."""
    w = np.frombuffer(z["head/%s/w" % tag], dtype="<f4").astype(np.float64)
    b = float(z["head/%s/b" % tag])
    row = {k: i for i, k in enumerate(used)}
    known = [k for k in used if k in labels]
    te = [k for k in known if row[k] % 5 == 0]
    tp = fp = fn = 0.0
    for k in te:
        p = 1 / (1 + np.exp(-(X[row[k]] @ w + b)))
        hit = p >= 0.5
        want = bool(labels[k])
        if hit and want: tp += 1
        if hit and not want: fp += 1
        if not hit and want: fn += 1
    return ((tp / (tp + fp) if tp + fp else 0.0),
            (tp / (tp + fn) if tp + fn else 0.0))


label_maps = {t["tag"]: t["labels"] for t in labels}
for f in train_out:
    if not f["fitted"]:
        continue
    raw = raw_metrics(f["tag"], label_maps[f["tag"]])
    f["precision_raw"], f["recall_raw"] = raw
    assert round(raw[0], 3) == f["precision"] and round(raw[1], 3) == f["recall"], \
        (f["tag"], raw, f["precision"], f["recall"])

if "nsfw/w" in z.files:
    # engine.train_nsfw collects only the LABELLED videos, so its hold-out rule
    # counts positions in that shorter list — not positions in `used`.
    nsfw_used = [k for k in used if k in nsfw_labels]
    w = np.frombuffer(z["nsfw/w"], dtype="<f4").astype(np.float64)
    b = float(z["nsfw/b"])
    tp = fp = fn = 0.0
    for pos, k in enumerate(nsfw_used):
        if pos % 5 != 0:
            continue
        p = 1 / (1 + np.exp(-(X[used.index(k)] @ w + b)))
        hit = p >= 0.5
        want = bool(nsfw_labels[k])
        if hit and want: tp += 1
        if hit and not want: fp += 1
        if not hit and want: fn += 1
    nsfw_raw = ((tp / (tp + fp) if tp + fp else 0.0),
                (tp / (tp + fn) if tp + fn else 0.0))
    nsfw_fit["precision_raw"], nsfw_fit["recall_raw"] = nsfw_raw
    nsfw_fit["held_out"] = len(nsfw_used[::5])    # must equal what the engine reported
    assert round(nsfw_raw[0], 3) == nsfw_fit["precision"], (nsfw_raw, nsfw_fit)
    assert round(nsfw_raw[1], 3) == nsfw_fit["recall"], (nsfw_raw, nsfw_fit)

fx = {
    "generator": "docs/coreml-spike/head_parity.py",
    "engine_sha256": hashlib.sha256(
        open(os.path.join(REPO, "AnalysisEngine/engine.py"), "rb").read()).hexdigest(),
    "script_sha256": hashlib.sha256(open(os.path.abspath(__file__), "rb").read()).hexdigest(),
    "dim": DIM,
    "frames_per_video": FRAMES,
    "videos": videos,
    "frames": {h: b64_f32(v) for h, v in frames.items()},
    "cached": sorted(cache.keys()),
    "tags": [{"tag": t["tag"], "labels": {k: v for k, v in t["labels"].items()
                                          if v is not None}} for t in labels],
    "nsfw_labels": nsfw_labels,
    "expected": {
        "keys": used,
        "X": b64_f64(X),
        "fits": train_out,
        "nsfw_fit": nsfw_fit,
        "heads": heads,
        "nsfw_head": {"w": b64_f32(z["nsfw/w"]), "b": float(z["nsfw/b"]),
                      "n": float(z["nsfw/n"])},
    },
}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    json.dump(fx, fh, sort_keys=True)
print("wrote %s (%d KB)" % (OUT, os.path.getsize(OUT) // 1024))
print("videos used: %d of %d   dim %d" % (len(used), len(videos), DIM))
print("fits: " + ", ".join("%s=%s" % (f["tag"], "fit" if f["fitted"] else "refused(%s)" % f["reason"])
                           for f in train_out))
print("nsfw: %s" % ("fit" if nsfw_fit["fitted"] else "refused(%s)" % nsfw_fit.get("reason")))
for tag, h in sorted(heads.items()):
    print("  head/%s  n=%.0f  |w|=%.4f  b=%+.6f"
          % (tag, h["n"], np.linalg.norm(np.frombuffer(base64.b64decode(h["w"]), dtype="<f4")),
             h["b"]))
print("  nsfw      n=%.0f  b=%+.6f  precision=%s recall=%s"
      % (fx["expected"]["nsfw_head"]["n"], fx["expected"]["nsfw_head"]["b"],
         nsfw_fit["precision"], nsfw_fit["recall"]))
