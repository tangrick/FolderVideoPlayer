#!/usr/bin/env python3
"""Generate the fixture that proves the Swift look-alike search matches engine.py.

Same discipline as `head_parity.py`: this does not re-implement `tag_candidates`.
It monkeypatches the frame cache and the stdout protocol and calls the REAL
`engine.tag_candidates`, so the expected candidates, reasons and unseen counts
are the Python path's own answers.

    /opt/anaconda3/bin/python3 docs/coreml-spike/lookalike_parity.py [out.json]

Writes `~/fvp-coreml-models/lookalike_fixture.json`. The Swift side
(`Tests/test_look_alikes.swift`) must reproduce every case in it.

The library is built so that the interesting branches actually happen:
  - three videos tagged "Kite" (the prototype) and one untagged video that really
    does look like them -> a candidate that must be found;
  - a video that is only a little rotated -> below the 0.10 margin, so it must
    NOT be offered (this is the "everything looks like everything" case);
  - a video whose frames sum to exactly zero -> a zero norm, counted unseen;
  - a video with no cached frames, and one with no hashes at all -> unseen;
  - a request with one tagged video, and one with no pool -> the two refusals.
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
       else os.path.expanduser("~/fvp-coreml-models/lookalike_fixture.json"))
DIM = 96
FRAMES = 4

rng = np.random.default_rng(11)
base = rng.normal(size=DIM)
base = (base / np.linalg.norm(base)).astype(np.float64)
kite = rng.normal(size=DIM)
kite = kite - (kite @ base) * base
kite = (kite / np.linalg.norm(kite)).astype(np.float64)


def b64(a, dtype):
    return base64.b64encode(np.asarray(a, dtype=dtype).tobytes()).decode()


def frames_for(centre, n=FRAMES, noise=0.25):
    """n frame vectors whose mean lands near `centre`."""
    return [(centre + noise * rng.normal(size=DIM)).astype(np.float32) for _ in range(n)]


def f32(v):
    return np.asarray(v, dtype=np.float32)


cache = {}          # hash -> float32 vector, what _cache_read serves


def add_video(key, kind):
    """Register a video's frames. `kind` sets how far it leans toward Kite."""
    if kind == "tagged":
        centre = base + 1.4 * kite
    elif kind == "look":
        centre = base + 1.4 * kite
    elif kind == "strong":
        centre = base + 1.9 * kite          # the clearest look-alike
    elif kind == "solid":
        centre = base + 1.7 * kite          # a clear one too
    elif kind == "weak":
        centre = base + 1.15 * kite         # just over the margin
    elif kind == "close":
        centre = base + 0.35 * kite         # under the margin: must NOT be offered
    elif kind == "zero":
        # exact cancellation: mean is 0 and the norm is 0, not merely small
        w = rng.normal(size=DIM).astype(np.float32)
        hashes = store(key, [f32(w), f32(-w), f32(w), f32(-w)])
        return hashes
    else:
        centre = base
    return store(key, frames_for(centre))


def store(key, vecs):
    hashes = []
    for i, vec in enumerate(vecs):
        h = "%s_%02d" % (key, i)
        hashes.append(h)
        cache[h] = vec
    return hashes


videos = {}
videos["v_kite1"] = add_video("v_kite1", "tagged")
videos["v_kite2"] = add_video("v_kite2", "tagged")
videos["v_kite3"] = add_video("v_kite3", "tagged")
videos["v_look"] = add_video("v_look", "look")
videos["v_strong"] = add_video("v_strong", "strong")
videos["v_solid"] = add_video("v_solid", "solid")
videos["v_weak"] = add_video("v_weak", "weak")
videos["v_close"] = add_video("v_close", "close")
# 30 ordinary videos: the library has to be big enough that its own mean stays
# near "the typical video" — with a handful of videos, one look-alike drags the
# baseline toward itself and every margin collapses.
for i in range(30):
    videos["v_plain%02d" % i] = add_video("v_plain%02d" % i, "plain")
videos["v_zero"] = add_video("v_zero", "zero")
videos["v_empty"] = []                       # analysed, no hashes at all
videos["v_nocache"] = ["v_nocache_00", "v_nocache_01"]   # never written to the cache

tagged_keys = ["v_kite1", "v_kite2", "v_kite3"]
pool_keys = [k for k in videos if k not in tagged_keys]

engine._cache_read = lambda h: (None if h not in cache else [float(v) for v in cache[h]])
emitted = []
engine.report = lambda req, kind, **kw: emitted.append(dict(type=kind, **kw))
engine.done = lambda req, ok, **kw: emitted.append(dict(type="done", ok=ok, **kw))
engine.err = lambda req, msg: emitted.append(dict(type="error", message=msg))


def run_case(name, tag, tagged, pool, limit=25):
    emitted.clear()
    engine.tag_candidates({"id": 1, "tag": tag,
                           "tagged": {k: videos[k] for k in tagged},
                           "pool": {k: videos[k] for k in pool},
                           "limit": limit})
    assert emitted and emitted[0]["type"] == "result", (name, emitted)
    out = emitted[0]
    expected = {"tag": out.get("tag"), "candidates": out.get("candidates", []),
                "unseen_pool": out.get("unseen_pool", 0), "reason": out.get("reason")}
    return {"name": name, "tag": tag, "tagged": tagged, "pool": pool, "limit": limit,
            "expected": expected}


cases = [
    run_case("the whole library against Kite", "Kite", tagged_keys, pool_keys),
    # the limit truncates the RANKED list, not the search
    run_case("limit 2 keeps the two best", "Kite", tagged_keys, pool_keys, limit=2),
    # a request carrying one tagged video cannot form a prototype
    run_case("one tagged video refuses", "Kite", ["v_kite1"], pool_keys),
    # two tagged videos and nothing to search: no "typical video" to measure against
    run_case("no pool means no baseline", "Kite", ["v_kite1", "v_kite2"], []),
]

# a per-video mean vector per video, so the Swift collection step is checked on
# its own and not only through the candidate list
means = {}
for key, hashes in videos.items():
    vecs = [cache[h] for h in hashes if h in cache]
    if not vecs:
        continue
    acc = None
    for v in vecs:
        acc = np.asarray(v, dtype=np.float64) if acc is None else acc + v
    if acc is None:
        continue
    m = acc / len(vecs)
    n = np.linalg.norm(m)
    if n:
        means[key] = b64(m / n, "<f8")

fx = {
    "generator": "docs/coreml-spike/lookalike_parity.py",
    "engine_sha256": hashlib.sha256(
        open(os.path.join(REPO, "AnalysisEngine/engine.py"), "rb").read()).hexdigest(),
    "script_sha256": hashlib.sha256(open(os.path.abspath(__file__), "rb").read()).hexdigest(),
    "dim": DIM,
    "margin": 0.10,
    "min_videos": 2,
    "frames": {h: b64(v, "<f4") for h, v in cache.items()},
    "videos": [{"key": k, "hashes": videos[k]} for k in videos],
    "means": means,
    "cases": cases,
}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    json.dump(fx, fh, sort_keys=True)
print("wrote %s (%d KB)" % (OUT, os.path.getsize(OUT) // 1024))
for c in cases:
    e = c["expected"]
    head = ", ".join("%s=%.4f" % (r["key"], r["score"]) for r in e["candidates"][:4])
    print("  %-34s candidates=%d unseen=%d reason=%s%s"
          % (c["name"], len(e["candidates"]), e["unseen_pool"], e["reason"],
             ("  [" + head + "]") if e["candidates"] else ""))
