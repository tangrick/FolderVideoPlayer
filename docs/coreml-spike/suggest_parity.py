#!/usr/bin/env python3
"""Generate the fixture that proves the Swift suggester matches engine.py.

Same discipline as the other parity fixtures: this does NOT re-implement
`suggest_tags`. It builds a synthetic prompt table and a synthetic frame cache,
patches the few things that need a real model or a real video, and then calls
the REAL `engine.suggest_tags` for every case. Every expected candidate — its
tag, confidence, frame count, provenance and its POSITION in the list — is
therefore the Python path's own answer, merge order and all.

    /opt/anaconda3/bin/python3 docs/coreml-spike/suggest_parity.py [out-dir]

Writes, into that directory, the fixture and the two things the Swift side
actually loads:

    tag_suggester_fixture.json          the cases and their expected answers
    tags/siglip2_base_prompts.{json,f32}  the prompt table  (PromptTable)
    frames/<slug>/<xx>/<hash>.f32       the embedding cache (TagPrototypes)

Patched, and only these:
  - `_ensure_suggest_text` -> the synthetic table's rows, as "text features".
    The real one loads the 121 MB text encoder, which never ships.
  - `sample_frames` / `embed_frames` -> the case's frame vectors, so no video
    and no ffmpeg are involved. Embedding is not what this file measures.
  - `_load_trained_heads` -> heads generated here, so a fitted head can be AIMED
    at an exact probability instead of hoping a real fit lands on a branch.
  - `_face_models_loaded` -> nothing. Faces are Phase E and a separate model.
  - `EMBED_CACHE` / `_model_slug` / `_embed_dim` -> the temp tree. `_cache_path`,
    `_cache_read` and `_library_baseline` stay REAL: they walk this tree with
    engine.py's own path logic, which is the one part of the port that touches
    the filesystem.

The vocabulary, the pools, the constants, the margin and the number of frames
each tag needs all come from engine.py — nothing is restated here, so the
fixture cannot describe a vocabulary that has since changed. The exceptions are
the NSFW pool and the paired tags, which engine.py reads from a private file:
the fixture sets stand-ins for them (see below). (The two pools are
TRIMMED to their first few phrases: their size is not what this measures, their
order is.)

The rows are an ORTHONORMAL basis, one vector per phrase. That is what makes the
fixture aimed rather than lucky: with orthogonal rows a frame's similarity to any
phrase is exactly its coefficient over the frame's norm, so a case can ask for a
margin of 0.0205 and get it, rather than re-rolling a seed until a tag clears the
bar "somehow". A frame's noise is projected into the rows' null space, so it
changes the norm and never the dot products. User tags that CLIP's vocabulary has
never heard of ("Kite", "Bench") get their own direction in the same null space,
which is why the library-prototype pass can be aimed at too.
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
import torch                                           # noqa: E402
import engine                                          # noqa: E402

# The NSFW pool and the paired tags live in a private file the public repo does
# not carry, so the fixture brings its own stand-ins. Only their count and order
# matter here -- every row is an orthonormal basis vector, never a phrase's
# embedding -- so the words are placeholders.
engine.NSFW_POOL = ["nsfw phrase 0", "nsfw phrase 1"]
engine.PAIRED_VOCAB = [("Dawn", ["dawn phrase 0", "dawn phrase 1"]),
                       ("Dusk", ["dusk phrase 0", "dusk phrase 1"])]
engine.PAIRED_TAG_NAMES = {tag for tag, _ in engine.PAIRED_VOCAB}

OUT_DIR = (sys.argv[1] if len(sys.argv) > 1
           else os.path.expanduser("~/fvp-coreml-models/tag_suggester_fixture"))
SLUG = "test_slug"
DIM = 192                       # >= the row count, so the rows can be orthonormal
RNG = np.random.default_rng(20260911)

# --- the vocabulary, straight out of engine.py ------------------------------
VOCAB = engine.SUGGEST_VOCAB + engine.PAIRED_VOCAB
PAIRED = engine.PAIRED_TAG_NAMES
NSFW_POOL = engine.NSFW_POOL[:2]
NEUTRAL_POOL = engine.NEUTRAL_POOL[:2]
BACKGROUND = engine.BACKGROUND_POOL[:3]


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


# --- the rows, in the table's documented order ------------------------------
labels = []
rows = {"nsfw": [], "neutral": [], "background": [], "suggest": [], "paired": []}
labels += ["nsfw/%d" % i for i in range(len(NSFW_POOL))]
rows["nsfw"] = list(range(len(labels) - len(NSFW_POOL), len(labels)))
labels += ["neutral/%d" % i for i in range(len(NEUTRAL_POOL))]
rows["neutral"] = list(range(len(labels) - len(NEUTRAL_POOL), len(labels)))
labels += ["background/%d" % i for i in range(len(BACKGROUND))]
rows["background"] = list(range(len(labels) - len(BACKGROUND), len(labels)))

tag_rows = {}       # suggestion tag -> [lo, hi)
pair_rows = {}
for group, table in (("suggest", engine.SUGGEST_VOCAB), ("paired", engine.PAIRED_VOCAB)):
    bucket = tag_rows if group == "suggest" else pair_rows
    for tag, phrasings in table:
        lo = len(labels)
        labels += ["%s/%s/%d" % (group, tag, i) for i in range(len(phrasings))]
        bucket[tag] = [lo, len(labels)]
        rows[group] += list(range(lo, len(labels)))

R = len(labels)
assert R <= DIM, "the orthonormal basis needs a dimension at least as wide as the rows"

# QR of a random matrix: R orthonormal columns in R^DIM — one unit row per phrase.
Q, _ = np.linalg.qr(RNG.normal(size=(DIM, R)))
Q = np.ascontiguousarray(Q.T)                  # [R, DIM]
TABLE = Q.astype(np.float32)


def null_vector(seed):
    """A unit vector orthogonal to EVERY row — invisible to the prompt table."""
    rng = np.random.default_rng(seed)
    v = rng.normal(size=DIM)
    v = v - Q.T @ (Q @ v)
    return unit(v)


# Names CLIP's phrase vocabulary has never heard of, so no phrasing can ever
# offer them: they can only arrive through a library prototype. Each gets a
# direction in the rows' null space, which is where a real user tag lives too.
USER_TAGS = ["Kite", "Bench", "solo"]
USER_DIRS = {name: null_vector(7000 + i) for i, name in enumerate(USER_TAGS)}


def direction(name):
    if name in tag_rows:
        return Q[tag_rows[name][0]]
    if name in pair_rows:
        return Q[pair_rows[name][0]]
    if name in USER_DIRS:
        return USER_DIRS[name]
    raise KeyError("%s is not a tag engine.py knows and not a user tag" % name)


# --- frames -----------------------------------------------------------------
def aim(coeffs, bg, noise):
    """The coefficients that land every tag exactly on its asked-for margin.

    margin_n = (c_n - bg) / ||f||, and ||f|| = sqrt(bg^2 + sum(c^2) + noise^2)
    because the noise is orthogonal to every row. The norm depends on ALL the
    coefficients, so the whole set is solved together rather than one tag at a
    time — ask for two tags a hair either side of the bar and each lands there,
    which is what makes a threshold test a test of the threshold. The map is a
    contraction (the margin is < 1), so the fixed point converges.
    """
    cs = {name: bg + margin for name, margin in coeffs.items()}
    for _ in range(120):
        norm = np.sqrt(bg * bg + sum(c * c for c in cs.values()) + noise * noise)
        cs = {name: bg + margin * norm for name, margin in coeffs.items()}
    return cs


def frame(coeffs, bg=0.5, noise=0.12, seed=None):
    """One frame vector: `coeffs` maps a tag name to the MARGIN over the
    background it should score. Margins, not raw coefficients — the whole point
    is to aim a tag at a place relative to the bar. A name is a prompt-vocabulary
    tag or a user tag (`USER_TAGS`)."""
    raw = bg * Q[rows["background"][0]]
    for name, c in aim(coeffs, bg, noise).items():
        raw = raw + c * direction(name)
    v = null_vector(9000 + (seed if seed is not None else int(RNG.integers(1 << 30))))
    return unit(raw + noise * v).astype(np.float32)


def frames(n, coeffs, **kw):
    return [frame(coeffs, seed=100 * n + i, **kw) for i in range(n)]


def b64(vec):
    return base64.b64encode(np.asarray(vec, dtype="<f4").tobytes()).decode()


# --- the cache tree ---------------------------------------------------------
work = OUT_DIR
cache_root = os.path.join(work, "frames")
os.makedirs(os.path.join(work, "tags"), exist_ok=True)
engine.EMBED_CACHE = cache_root
engine._model_slug = lambda: SLUG               # noqa: SLF001 — the point
engine._embed_dim = DIM                         # noqa: SLF001 — see docstring


def frame_hash(video, i):
    return hashlib.sha1(("%s/%d" % (video, i)).encode()).hexdigest()


def cache_write(video, i, vec):
    """A real <cache>/<slug>/<xx>/<hash>.f32, at the path engine.py resolves."""
    h = frame_hash(video, i)
    p = engine._cache_path(h)                   # noqa: SLF001 — real path logic
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh:
        fh.write(np.asarray(vec, dtype="<f4").tobytes())
    return h


# Videos the user has already tagged: two or more each, so a prototype exists.
# The frames lean toward the tag by a wide margin, the way a tagged video does.
LIBRARY = {
    "Waterfall": ["v_waterfall1", "v_waterfall2"],
    "Kite": ["v_kite1", "v_kite2", "v_kite3"],
    "Bench": ["v_bench1", "v_bench2"],
    "solo": ["v_solo1"],           # ONE video: too few, must never prototype
}
library_tags = []
seed = 0
for tag, videos in LIBRARY.items():
    entry = {"tag": tag, "videos": []}
    for name in videos:
        keep = []
        for i in range(4):
            seed += 1
            keep.append(cache_write(name, i, frame({tag: 0.50}, seed=seed)))
        entry["videos"].append({"key": name, "hashes": keep})
    library_tags.append(entry)

# The library's ordinary videos: no particular tag, which is what the baseline
# is the mean of.
for i in range(30):
    for j in range(4):
        seed += 1
        cache_write("v_plain%02d" % i, j, frame({}, seed=seed))

# A vector from ANOTHER model: 768 wide, written into the tree. Both sides
# refuse it — engine's `_cache_read` by width, the Swift baseline by the same
# rule — and it is the one thing here that would silently poison the baseline.
poison = frame_hash("v_other_model", 0)
p = os.path.join(cache_root, SLUG, poison[:2])
os.makedirs(p, exist_ok=True)
with open(os.path.join(p, poison + ".f32"), "wb") as fh:
    fh.write(np.zeros(768, dtype="<f4").tobytes())

# --- the prompt table on disk, for PromptTable ------------------------------
meta = {
    "version": 1,
    "model": "suggest-parity",
    "dim": DIM,
    "rows": R,
    "layout": {"nsfw": [rows["nsfw"][0], rows["nsfw"][-1] + 1],
               "neutral": [rows["neutral"][0], rows["neutral"][-1] + 1],
               "background": [rows["background"][0], rows["background"][-1] + 1],
               "suggest": [rows["suggest"][0], rows["suggest"][-1] + 1],
               "paired": [rows["paired"][0], rows["paired"][-1] + 1]},
    "tags": [{"tag": t, "rows": tag_rows[t]} for t, _ in engine.SUGGEST_VOCAB],
    "paired_tags": [{"tag": t, "rows": pair_rows[t]} for t, _ in engine.PAIRED_VOCAB],
    "constants": {k: getattr(engine, k) for k in
                  ["MARGIN_BIAS", "MARGIN_TEMPERATURE", "NSFW_THRESHOLD",
                   "SUGGEST_MARGIN", "SUGGEST_MAX_TAGS", "SAMPLE_INTERVAL_S",
                   "MAX_FRAMES", "SAMPLE_SHORT_SIDE"]},
    "engine_py_sha256": hashlib.sha256(
        open(os.path.join(REPO, "AnalysisEngine/engine.py"), "rb").read()).hexdigest(),
    "prompt_sha256": hashlib.sha256(TABLE.tobytes()).hexdigest(),
    "producer": "docs/coreml-spike/suggest_parity.py",
}
# The fixture's table is named after the app's own `PromptTable.slug`. It is a
# synthetic orthonormal basis, not the shipped table — but it has to live under
# the name the app looks for, or this gate would be exercising a table the app
# never reads.
TABLE.tofile(os.path.join(work, "tags", "siglip2_base_prompts.f32"))
with open(os.path.join(work, "tags", "siglip2_base_prompts.json"), "w") as fh:
    json.dump(meta, fh, indent=1, sort_keys=True)

# --- the engine side: patch it, then call the REAL suggest_tags -------------
def fake_text(req):
    """engine.py's text cache, from the table. The order is engine.py's, NOT the
    table's: the vocabulary's phrases first (paired phrases only for an NSFW
    video), then the background pool."""
    oriented = bool(req.get("paired"))
    vocab = engine.SUGGEST_VOCAB + (engine.PAIRED_VOCAB if oriented else [])
    idx, owner = [], []
    for i, (tag, phrasings) in enumerate(vocab):
        lo = (tag_rows[tag] if tag in tag_rows else pair_rows[tag])[0]
        idx += list(range(lo, lo + len(phrasings)))
        owner += [i] * len(phrasings)
    idx += list(range(rows["background"][0], rows["background"][-1] + 1))
    return {"feats": torch.tensor(TABLE[idx], dtype=torch.float32),
            "owner": owner, "n_vocab": len(owner), "paired": oriented}


engine._ensure_suggest_text = fake_text                       # noqa: SLF001
engine._load_trained_heads = lambda: HEAD_STORE               # noqa: SLF001
engine._face_models_loaded = lambda: (None, None)             # noqa: SLF001

CURRENT = {}


def fake_sample_frames(req, video_path, workdir):
    return list(CURRENT["paths"]), list(range(len(CURRENT["paths"])))


def fake_embed_frames(req, image_paths):
    return torch.tensor(CURRENT["vectors"], dtype=torch.float32), list(CURRENT["hashes"])


engine.sample_frames = fake_sample_frames      # noqa: SLF001
engine.embed_frames = fake_embed_frames        # noqa: SLF001

emitted = []
engine.report = lambda req, kind, **kw: emitted.append(dict(type=kind, **kw))
engine.done = lambda req, ok, **kw: emitted.append(dict(type="done", ok=ok, **kw))
engine.err = lambda req, msg: emitted.append(dict(type="error", message=msg))
engine.emit = lambda ev: emitted.append(dict(type="emit", **ev))

HEAD_STORE = {}


def head(tag, probability, frame_vectors, k=8.0):
    """A logistic head aimed at `probability` on these frames, with w = k*e_row.

    Solving for the bias — rather than guessing weights — is what makes the
    trained branch a test of the MERGE (does stronger evidence replace weaker?)
    instead of a test of whether a random head happened to clear 0.5.
    """
    w = (k * direction(tag)).astype(np.float32)
    cos = [float(np.dot(w, v)) for v in frame_vectors]
    logit = np.log(probability / (1.0 - probability))
    return w, np.float32(float(np.mean([logit - c for c in cos])))


def run_case(name, frame_vectors, paired=False, heads=None, library=False):
    CURRENT["vectors"] = np.stack(frame_vectors).astype(np.float32)
    CURRENT["paths"] = ["frame%02d.jpg" % i for i in range(len(frame_vectors))]
    CURRENT["hashes"] = [frame_hash("case/%s" % name, i) for i in range(len(frame_vectors))]
    HEAD_STORE.clear()
    if heads:
        HEAD_STORE.update(heads(CURRENT["vectors"]))
    emitted.clear()
    engine._library_mean = None                        # noqa: SLF001 — memoised
    req = {"id": 1, "cmd": "suggest_tags", "path": "/tmp/%s.mp4" % name,
           "paired": paired, "faces": False}
    if library:
        req["libraryTags"] = {e["tag"]: {v["key"]: v["hashes"] for v in e["videos"]}
                              for e in library_tags}
    engine.suggest_tags(req, req["path"])
    assert emitted and emitted[0]["type"] == "result", (name, emitted)
    out = emitted[0]
    return {
        "name": name,
        "paired": paired,
        "uses_library": bool(library),
        "frames": [b64(v) for v in CURRENT["vectors"]],
        "frame_hashes": list(CURRENT["hashes"]),
        "heads": [{"tag": t, "w": b64(w), "b": float(b), "n": 1.0}
                  for t, (w, b) in sorted(HEAD_STORE.items())],
        "expected": [{"tag": r["tag"], "confidence": r["confidence"],
                      "frames": r["frames"], "source": r.get("source")}
                     for r in out["suggestions"]],
        "expected_frames_seen": out.get("frames_seen"),
    }


cases = []

# 1. two tags clear the bar, one is aimed below it and must not appear.
cases.append(run_case("clear tags, one below the bar",
                      frames(6, {"Waterfall": 0.35, "Birthday": 0.18, "Beach": -0.15})))

# 2. the bar itself: 0.0205 fires, 0.0195 does not. (`>=` is the rule.)
cases.append(run_case("either side of SUGGEST_MARGIN",
                      frames(6, {"Waterfall": 0.0205, "Beach": 0.0195})))

# 3. a fitted head beats a weak zero-shot entry for the SAME tag: the entry is
#    replaced and its source changes with it.
cases.append(run_case("a stronger head replaces the zero-shot entry",
                      frames(6, {"Bench": 0.05, "Waterfall": 0.30}),
                      heads=lambda fv: {"Bench": head("Bench", 0.90, fv)}))

# 4. ...and a weaker head leaves a strong zero-shot entry alone.
cases.append(run_case("a weaker head leaves the zero-shot entry alone",
                      frames(6, {"Beach": 0.60}),
                      heads=lambda fv: {"Beach": head("Beach", 0.55, fv)}))

# 5. heads exist, but both are PAIRED heads, and this is a Safe video: the
#    non-paired name list is empty — the case that used to raise on
#    `np.stack([])`, and no paired chip may appear for a safe clip.
cases.append(run_case("paired-only heads, on a safe video",
                      frames(6, {"Waterfall": 0.25}),
                      heads=lambda fv: {"Dawn": head("Dawn", 0.80, fv),
                                        "Dusk": head("Dusk", 0.40, fv)}))

# 6. NSFW: Dawn wins more frames than Dusk — exactly ONE chip, Dawn.
cases.append(run_case("paired decided head-to-head",
                      frames(6, {"Dawn": 0.55, "Dusk": 0.20, "Waterfall": 0.25}),
                      paired=True))

# 7. NSFW and genuinely ambiguous — no paired chip at all, rather than both.
cases.append(run_case("ambivalent paired offers nothing",
                      frames(6, {"Dawn": 0.30, "Dusk": 0.30, "Waterfall": 0.25}),
                      paired=True))

# 8. NSFW with BOTH paired heads earned: the heads decide, not the prompts,
#    and their verdict is still one chip.
cases.append(run_case("trained paired heads decide",
                      frames(6, {"Dawn": 0.20, "Dusk": 0.20}),
                      paired=True,
                      heads=lambda fv: {"Dawn": head("Dawn", 0.80, fv),
                                        "Dusk": head("Dusk", 0.40, fv)}))

# 9. the library prototypes: Kite is a name the vocabulary cannot express (a
#    prototype can only APPEND it), Waterfall is one it can (so the prototype
#    has to beat the weak zero-shot entry to REPLACE it).
cases.append(run_case("library prototypes merge into the list",
                      frames(6, {"Kite": 0.30, "Waterfall": 0.05}), library=True))

# 10. more candidates than SUGGEST_MAX_TAGS: the RANKED list is what gets cut.
many = {}
for tag, _phr in engine.SUGGEST_VOCAB[:14]:
    many[tag] = 0.05 + 0.01 * len(many)
cases.append(run_case("more candidates than the cap", frames(6, many)))

# --- verify the fixture aims where it claims, then write it -----------------
by_name = {c["name"]: c for c in cases}
problems = []


def tags(case):
    return [r["tag"] for r in case["expected"]]


def sources(case):
    return {r["source"] for r in case["expected"]}


def find(case, tag):
    return next((r for r in case["expected"] if r["tag"] == tag), None)


if "Waterfall" not in tags(by_name["clear tags, one below the bar"]):
    problems.append("case 1 did not offer the tag aimed over the bar")
if "Beach" in tags(by_name["clear tags, one below the bar"]):
    problems.append("case 1 offered the tag aimed below the bar")
if "Birthday" not in tags(by_name["clear tags, one below the bar"]):
    problems.append("case 1 did not offer the second tag over the bar")
edge = tags(by_name["either side of SUGGEST_MARGIN"])
if "Waterfall" not in edge or "Beach" in edge:
    problems.append("case 2 did not land either side of the margin: %s" % edge)
bench = find(by_name["a stronger head replaces the zero-shot entry"], "Bench")
if not bench or bench["source"] != "trained":
    problems.append("case 3 replaced nothing: Bench = %s" % bench)
beach = find(by_name["a weaker head leaves the zero-shot entry alone"], "Beach")
if not beach or beach["source"] != "zeroshot":
    problems.append("case 4 let the weaker head win: Beach = %s" % beach)
safe = by_name["paired-only heads, on a safe video"]
if {r["tag"] for r in safe["expected"]} & PAIRED:
    problems.append("case 5 offered an paired tag on a safe video")
if sources(safe) - {"zeroshot"}:
    problems.append("case 5 used a source it cannot have: %s" % sources(safe))
ori = [r for r in by_name["paired decided head-to-head"]["expected"]
       if r["tag"] in PAIRED]
if [r["tag"] for r in ori] != ["Dawn"] or ori[0]["source"] != "zeroshot":
    problems.append("case 6 should offer exactly Dawn from the prompts: %s" % ori)
if {r["tag"] for r in by_name["ambivalent paired offers nothing"]["expected"]} & PAIRED:
    problems.append("case 7 offered an paired tag anyway")
tr = [r for r in by_name["trained paired heads decide"]["expected"]
      if r["tag"] in PAIRED]
if [r["tag"] for r in tr] != ["Dawn"] or tr[0]["source"] != "trained":
    problems.append("case 8 did not use the trained paired head: %s" % tr)
lib = by_name["library prototypes merge into the list"]
kite, wf = find(lib, "Kite"), find(lib, "Waterfall")
if not kite or kite["source"] != "library":
    problems.append("case 9 did not append Kite from a prototype: %s" % kite)
if not wf or wf["source"] != "library":
    problems.append("case 9 did not promote Waterfall to a prototype: %s" % wf)
if find(lib, "solo"):
    problems.append("case 9 offered 'solo', which has only one tagged video")
cap = by_name["more candidates than the cap"]["expected"]
if len(cap) != engine.SUGGEST_MAX_TAGS:
    problems.append("case 10 returned %d candidates, not the cap of %d"
                    % (len(cap), engine.SUGGEST_MAX_TAGS))
if any(cap[i]["confidence"] < cap[i + 1]["confidence"] for i in range(len(cap) - 1)):
    problems.append("case 10 is not ranked strongest-first")
for c in cases:
    if len(c["expected"]) > engine.SUGGEST_MAX_TAGS:
        problems.append("%s: more candidates than the cap" % c["name"])
    if c["expected_frames_seen"] != 6:
        problems.append("%s: the engine saw %s frames, not the 6 it was given"
                        % (c["name"], c["expected_frames_seen"]))

if problems:
    raise SystemExit("the fixture does not exercise what it claims:\n  - "
                     + "\n  - ".join(problems))

fixture = {
    "generator": "docs/coreml-spike/suggest_parity.py",
    "support_root": os.path.abspath(work),
    "slug": SLUG,
    "dim": DIM,
    "max_tags": engine.SUGGEST_MAX_TAGS,
    "suggest_margin": engine.SUGGEST_MARGIN,
    "paired_names": sorted(PAIRED),
    "engine_sha256": meta["engine_py_sha256"],
    "library_tags": library_tags,
    "cases": cases,
}
path = os.path.join(work, "tag_suggester_fixture.json")
with open(path, "w") as fh:
    json.dump(fixture, fh, sort_keys=True)

print("wrote %s (%d KB, %d cases, %d prompt rows)"
      % (path, os.path.getsize(path) // 1024, len(cases), R))
for c in cases:
    shown = ", ".join("%s=%.4f/%d/%s" % (r["tag"], r["confidence"], r["frames"], r["source"])
                      for r in c["expected"][:6])
    print("  %-46s %s" % (c["name"], shown or "(nothing)"))
