#!/usr/bin/env python3
"""Generate the fixture for the library-tag prototypes (engine.py, Phase D).

Same discipline as the other parity fixtures: it calls the REAL
`engine._library_prototypes`, `engine._library_baseline` and
`engine._score_library_tags` rather than re-deriving what they do.

    /opt/anaconda3/bin/python3 docs/coreml-spike/prototype_parity.py [out.json]

Unlike `tag_candidates` (which builds its own baseline from the request), the
baseline here walks the WHOLE cache directory — so this script writes a real
`<cache>/<slug>/<xx>/<hash>.f32` tree and lets engine.py read it with its own
path logic. That walk is the one place the Swift port touches the filesystem,
so it is worth measuring rather than assuming.

Two globals are patched, and only two:
  - `EMBED_CACHE` -> a temp tree, and `_model_slug` -> a fixed name. Necessary
    to have a cache at all.
  - `_embed_dim` -> the fixture's width. Real vectors are 768 wide; keeping the
    fixture at 96 keeps it small enough to run on every gate. The width guard
    is not what this file is measuring — but it IS exercised: one file in the
    tree is written at 768 wide and must be ignored by both sides.

Where the numbers come from: the margin a frame earns is affine in its lean
(`margin(base + t·d) = a + t·b`), so rather than guess lean values and hope
they straddle LIBRARY_TAG_MARGIN, this script measures `a` and `b` from the
real functions and SOLVES for the t that lands a frame where it wants it:
0.35 above the line (a hit) or 0.25 below it (not a hit). It then re-measures
against the finished tree and refuses to emit anything that drifted.

What it arranges, so every branch happens:
  - three videos tagged "Kite", two tagged "ALT" -> prototypes;
  - one tagged video -> below LIBRARY_TAG_MIN_VIDEOS, skipped;
  - two tagged videos whose frames were never cached -> skipped, and the count
    is checked BEFORE any frame is read (engine.py tests the map's size first,
    so a tag of ghosts dies on the map, not on the reads);
  - a tag named "Dawn" -> skipped by name, because the paired tags have their own
    head-to-head machinery;
  - sixty ordinary videos in the cache, in NO request, a small lean each:
    only the baseline walk ever sees them, which is the whole point of it;
  - targets with 4 / 3 / 2 / 0 of their frames over the line, and one that
    leans the OTHER tag's way, so the sort across two tags is exercised;
  - the same four targets at min_frames 1, 2 and 3, so the threshold cuts.

The script asserts its own shape: a fixture that quietly collapsed to nothing
must fail here rather than produce a green, vacuous Swift test.
"""

import base64
import hashlib
import json
import os
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "AnalysisEngine"))

import numpy as np                                     # noqa: E402
import torch                                           # noqa: E402
import engine                                          # noqa: E402

OUT = (sys.argv[1] if len(sys.argv) > 1
       else os.path.expanduser("~/fvp-coreml-models/prototype_fixture.json"))
DIM = 96
SLUG = "test_slug"
OVER, UNDER = 0.35, -0.25          # the two margins a target frame aims for

work = tempfile.mkdtemp(prefix="fvp-proto-parity-")
cache_root = os.path.join(work, "frames")               # engine.EMBED_CACHE
engine.EMBED_CACHE = cache_root
engine._model_slug = lambda: SLUG               # noqa: SLF001 — the point
engine._embed_dim = DIM                         # noqa: SLF001 — see docstring
# `_cache_path`, `_cache_read` and `_library_baseline` stay REAL: they resolve
# hashes into this tree exactly as they do on the maintainer's machine.

MARGIN = engine.LIBRARY_TAG_MARGIN
MIN_VIDEOS = engine.LIBRARY_TAG_MIN_VIDEOS
# The paired tags come from a private file the public repo does not carry, so
# the fixture names its own stand-in pair; only the names matter here.
engine.PAIRED_TAG_NAMES = {"Dawn", "Dusk"}
PAIRED = sorted(engine.PAIRED_TAG_NAMES)

rng = np.random.default_rng(20260911)


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


base = unit(rng.normal(size=DIM))
_u = rng.normal(size=DIM)                     # orthogonalise THIS vector...
kite = unit(_u - (_u @ base) * base)            # ...against base, so base·kite = 0
alt = unit(0.45 * kite + 0.9 * unit(rng.normal(size=DIM)))

frames = {}          # hash -> float32 vector, the vectors engine can use


def b64(a, dtype):
    return base64.b64encode(np.asarray(a, dtype=dtype).tobytes()).decode()


def frame_hash(video, i):
    return hashlib.sha1(("%s/%d" % (video, i)).encode()).hexdigest()


def write(video, i, vec):
    h = frame_hash(video, i)
    frames[h] = np.asarray(vec, dtype=np.float32)
    p = engine._cache_path(h)                   # noqa: SLF001 — real path logic
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh:
        fh.write(frames[h].astype("<f4").tobytes())
    return h


def lean(name, direction, ts, noise=0.04):
    """A video's frames: each one `base` plus `t` of `direction`, plus a little
    noise. `noise` is the TOTAL spread, so it does not grow with DIM."""
    sd = noise / np.sqrt(DIM)
    return [write(name, i, base + t * direction + sd * rng.normal(size=DIM))
            for i, t in enumerate(ts)]


# --- what the tags are made of --------------------------------------------
tagged = {
    "Kite": ["v_kite1", "v_kite2", "v_kite3"],
    "ALT": ["v_alt1", "v_alt2"],
    "solo": ["v_solo"],
    "Dawn": ["v_dawn1", "v_dawn2"],
}
leaned = {"Kite": 1.40 * kite, "ALT": 1.30 * alt, "solo": 1.40 * kite, "Dawn": 0.90 * kite}
for tag, names in tagged.items():
    for name in names:
        lean(name, leaned[tag], [1.0, 1.0, 1.0])

ghost = [hashlib.sha1(("ghost/%d" % i).encode()).hexdigest() for i in range(2)]
tagged["ghost"] = ["g1", "g2"]

# --- ordinary videos: in the cache, in no request, barely leaning ----------
plain = {"v_plain%02d" % i: lean("v_plain%02d" % i, 0.15 * kite, [0.6, 0.35, 0.1],
                               noise=0.30)
         for i in range(60)}

# --- a file engine.py must refuse: the wrong width -------------------------
foreign_hash = hashlib.sha1(b"foreign").hexdigest()
foreign_path = engine._cache_path(foreign_hash)          # noqa: SLF001
os.makedirs(os.path.dirname(foreign_path), exist_ok=True)
with open(foreign_path, "wb") as fh:
    fh.write(np.zeros(768, dtype="<f4").tobytes())

# --- size up the two tags, then solve each target frame's lean -------------
req = {"libraryTags": {tag: {n: [frame_hash(n, i) for i in range(3)]
                            for n in names}
                       for tag, names in tagged.items()}}


def compose(aims, passes=12):
    """A frame `base + a·kite + b·alt` that earns each tag's margin target.

    The margin a frame earns is linear in the frame, so each tag's aim can be
    solved for exactly along that tag's direction — but the two directions are
    not orthogonal, so each solve perturbs the other's. Alternating a dozen
    times converges, and the caller re-measures anyway.
    """
    v = base.astype(np.float64).copy()
    for _ in range(passes):
        for tag, d in (("Kite", kite), ("ALT", alt)):
            if tag not in aims:
                continue
            D = prototypes[tag] - baseline
            grip = float(D @ d)
            if abs(grip) < 1e-9:
                print("the %s prototype has no grip on its own direction" % tag)
                sys.exit(1)
            v = v + ((aims[tag] - float(D @ v)) / grip) * d
    return v


# --- targets: how many of their frames are over the line, for which tag ----
wanted = {
    "t_hi":   {"Kite": OVER},
    "t_mid":  {"Kite": OVER},
    "t_low":  {"Kite": OVER},
    "t_none": {"Kite": UNDER},
    "t_alt":  {"ALT": OVER},
    "t_both": {"ALT": OVER, "Kite": 0.20},      # two tags hit the same video
}
counts = {"t_hi": 4, "t_mid": 3, "t_low": 2, "t_none": 4, "t_alt": 3, "t_both": 3}
spread = {"t_hi": 4, "t_mid": 4, "t_low": 4, "t_none": 4, "t_alt": 4, "t_both": 4}

targets = {}


def build_targets():
    """Write every target video: the aimed frames first, then the ones under."""
    for name, aims in wanted.items():
        n, k = spread[name], counts[name]
        below = {tag: UNDER for tag in aims}
        plan = [aims] * k + [below] * (n - k)
        for i, frame_aims in enumerate(plan):
            v = compose(frame_aims) + (0.02 / np.sqrt(DIM)) * rng.normal(size=DIM)
            write(name, i, v)
        targets[name] = {"hashes": [frame_hash(name, i) for i in range(n)],
                         "aims": plan}


def measure():
    """The prototypes and baseline the FINAL tree produces.

    `_library_baseline` memoises into the module global `_library_mean`, so a
    second call returns the first answer whatever the tree now holds — clearing
    it is the only way to ask the function again. (Measured: without this, the
    fixture's baseline was the one from before the target videos existed, and
    every confidence below was quietly 0.01 out.)
    """
    engine._library_mean = None                 # noqa: SLF001
    return engine._library_prototypes(req), engine._library_baseline()


prototypes, baseline = measure()
build_targets()                       # pass 1: targets join the baseline...
prototypes, baseline = measure()      # ...which moves it, so solve again
build_targets()
prototypes, baseline = measure()


def margin(tag, h):
    """The margin one frame earns against one tag, as engine.py computes it."""
    return float((prototypes[tag] - baseline) @ frames[h].astype(np.float64))


cases = []
for name, spec in targets.items():
    mat = np.array([frames[h] for h in spec["hashes"]], dtype=np.float32)
    for min_frames in (1, 2, 3):
        hits = engine._score_library_tags(torch.from_numpy(mat),
                                          engine._library_prototypes(req),
                                          min_frames)
        cases.append({
            "name": "%s min_frames=%d" % (name, min_frames),
            "video": name, "min_frames": min_frames,
            "expected": [{"tag": r["tag"], "confidence": r["confidence"],
                          "frames": r["frames"], "source": r["source"]}
                         for r in hits]})

cached = sorted(os.path.splitext(n)[0]
                for _, _, names in os.walk(os.path.join(cache_root, SLUG))
                for n in names if n.endswith(".f32"))

# --- refuse to emit a vacuous fixture -------------------------------------
fail = []
if set(prototypes) != {"Kite", "ALT"}:
    fail.append("prototypes %s, wanted {Kite, ALT}" % sorted(prototypes))
if not np.isclose(np.linalg.norm(baseline), 1.0):
    fail.append("baseline is not unit-normalised (norm %.6f)"
                % np.linalg.norm(baseline))
if len(baseline) != DIM:
    fail.append("baseline is %d wide, wanted %d" % (len(baseline), DIM))
# every target frame must have landed where it was aimed, for every tag
for name, spec in targets.items():
    for frame_aims, h in zip(spec["aims"], spec["hashes"]):
        for tag, aim in frame_aims.items():
            m = margin(tag, h)
            if abs(m - aim) > 0.05:
                fail.append("%s: a %s frame aimed at %.2f landed at %.3f"
                            % (name, tag, aim, m))
            if (m >= MARGIN) != (aim >= MARGIN):
                fail.append("%s: a %s frame aimed at %.2f crossed the line (%.3f)"
                            % (name, tag, aim, m))
# and the hit counts the port will be judged against
for name, want in (("t_hi", (4, 4, 4)), ("t_mid", (3, 3, 3)),
                   ("t_low", (2, 2, 0)), ("t_none", (0, 0, 0)),
                   ("t_both", (3, 3, 3))):
    for min_frames, n in zip((1, 2, 3), want):
        got = next(c["expected"] for c in cases
                   if c["video"] == name and c["min_frames"] == min_frames)
        hits = next((r["frames"] for r in got if r["tag"] == "Kite"), 0)
        if hits != n:
            fail.append("%s at min_frames=%d: Kite hit %d frames, wanted %d"
                        % (name, min_frames, hits, n))
for name, want in (("t_alt", (3, 3, 3)), ("t_both", (3, 3, 3))):
    for min_frames, n in zip((1, 2, 3), want):
        got = next(c["expected"] for c in cases
                   if c["video"] == name and c["min_frames"] == min_frames)
        hits = next((r["frames"] for r in got if r["tag"] == "ALT"), 0)
        if hits != n:
            fail.append("%s at min_frames=%d: ALT hit %d frames, wanted %d"
                        % (name, min_frames, hits, n))
if not any(len(c["expected"]) == 2 for c in cases):
    fail.append("no case has two tags hitting, so the sort is untested")
if any(c["expected"] == [] for c in cases
       if c["video"] == "t_hi" and c["min_frames"] == 1):
    fail.append("the busiest target hit nothing at all")
if set(cached) != set(frames) | {foreign_hash}:
    fail.append("the hash list is not the usable vectors plus the one refused file")
plain_hashes = sorted(h for v in plain.values() for h in v)
if set(plain_hashes) & {h for spec in targets.values() for h in spec["hashes"]}:
    fail.append("an ordinary video is also a target")
if not set(plain_hashes) <= set(cached):
    fail.append("the ordinary videos are not all in the cache walk")
# Swift rounds with `.rounded()`, Python with round-half-to-even: a confidence
# sitting on a .00005 boundary could round two ways, so refuse to ship one.
for c in cases:
    for r in c["expected"]:
        scaled = r["confidence"] * 10000
        if abs(scaled - int(scaled) - 0.5) < 1e-6:
            fail.append("%s: %s sits on a rounding boundary (%.10f)"
                        % (c["name"], r["tag"], r["confidence"]))
if fail:
    print("FIXTURE IS DEGENERATE:", *fail, sep="\n  ")
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1)

fx = {
    "generator": "docs/coreml-spike/prototype_parity.py",
    "engine_sha256": hashlib.sha256(
        open(os.path.join(REPO, "AnalysisEngine/engine.py"), "rb").read()).hexdigest(),
    "script_sha256": hashlib.sha256(
        open(os.path.abspath(__file__), "rb").read()).hexdigest(),
    "slug": SLUG,
    "dim": DIM,
    "margin": MARGIN,
    "min_videos": MIN_VIDEOS,
    "paired_names": PAIRED,
    "frames": {h: b64(v, "<f4") for h, v in frames.items()},
    "plain_videos": sorted(plain),
    "plain_hashes": sorted(h for v in plain.values() for h in v),
    "targets": {k: {"hashes": v["hashes"],
                    "aims": [{t: float(m) for t, m in a.items()} for a in v["aims"]]}
                for k, v in targets.items()},
    "ghost_hashes": ghost,
    "foreign_hash": foreign_hash,
    "library_tags": [{"tag": t, "videos": [{"key": n,
                                           "hashes": [frame_hash(n, i) for i in range(3)]}
                                          for n in names]}
                     for t, names in tagged.items()],
    "cached_hashes": cached,
    "expected": {
        "prototypes": {t: b64(v, "<f8") for t, v in prototypes.items()},
        "baseline": b64(baseline, "<f8"),
        "cases": cases,
    },
}

shutil.rmtree(work, ignore_errors=True)      # the fixture carries the bytes

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    json.dump(fx, fh, sort_keys=True)
print("wrote %s (%d KB)" % (OUT, os.path.getsize(OUT) // 1024))
print("cache: %d usable hashes (+1 refused at 768 wide)" % len(cached))
print("prototypes: %s,  baseline |m| = %.12f,  skipped names %s"
      % (sorted(prototypes), float(np.linalg.norm(baseline)), PAIRED))
for name, spec in targets.items():
    print("  %-7s margins %s" % (
        name, " ".join("/".join("%s%+.3f" % (t, margin(t, h))
                                for t in sorted(frame_aims))
                       for frame_aims, h in zip(spec["aims"], spec["hashes"]))))
for c in cases:
    print("  %-20s %s" % (c["name"],
                          ", ".join("%s=%.4f(%d)" % (r["tag"], r["confidence"],
                                                     r["frames"])
                                    for r in c["expected"]) or "no hits"))
