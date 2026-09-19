#!/usr/bin/env python3
"""Precompute MobileCLIP-S2 text embeddings for every fixed prompt pool.

The text encoder is only ever asked about a FIXED vocabulary, so it does not
need to ship: its answers are baked here into two small files the app reads.
That removes 121 MB and the whole BPE-tokenizer-in-Swift problem.

Task 2.1 (extended): the table now covers the suggestion vocabulary and the
background pool as well as the NSFW/neutral pools, and it is emitted in a
form Swift can read with no JSON-parsing of 512-float rows:

    s2_prompts.f32   rows x 512 little-endian float32, unit-normalised, row-major
    s2_prompts.json  the row layout, the tag -> rows map, the constants

The POOLS ARE NOT COPIED HERE. They are read out of AnalysisEngine/engine.py by
parsing the module (ast, no import -- importing it would drag in torch). The old
version of this script carried a verbatim copy with a note saying it must not
drift; a copy that must not drift is a copy that eventually drifts, and the
whole point of the table is that Swift scores with the SAME prompts Python does.
So engine.py is the single source of truth, and this script refuses to run if a
pool or constant it needs is no longer defined there. The two exceptions are the
NSFW pool and the paired tags, which engine.py itself reads from a private JSON
file (see engine.py `_load_private_vocab`); this script reads the same file.

Internally the rows are built in one fixed order,

    [0, n_nsfw)              NSFW_POOL                      (private)
    [.., +n_neutral)         NEUTRAL_POOL
    [.., +n_background)      BACKGROUND_POOL
    [.., +suggest phrasings) one row per phrasing, grouped in SUGGEST_VOCAB order
    [.., +paired rows)       one row per phrasing, grouped in PAIRED_VOCAB order (private)

and written as TWO tables (`write_split`): `<name>.{json,f32}` with the public
rows, which is what ships, and `<name>.private.{json,f32}` with the private
ones, which never ships and which the app appends when a user installs it.

Usage:
    /opt/anaconda3/bin/python3 docs/coreml-spike/precompute_text.py [--out DIR]
"""

import argparse
import ast
import hashlib
import json
import os
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
ENGINE_PY = os.path.join(REPO, "AnalysisEngine", "engine.py")
DEFAULT_OUT = os.path.expanduser("~/fvp-coreml-models")
DEFAULT_TEXT_MODEL = os.path.join(DEFAULT_OUT, "mobileclip_s2_text.mlpackage")

# The spike's leftovers, refreshed best-effort so compare_accuracy.py keeps
# working unchanged. Never the source of truth -- /tmp is purged by macOS.
LEGACY_SPIKE = "/tmp/mobileclip_spike"

# Everything this script needs engine.py to still define.
LIST_NAMES = ["NEUTRAL_POOL", "BACKGROUND_POOL", "SUGGEST_VOCAB"]
NUM_NAMES = ["MARGIN_BIAS", "MARGIN_TEMPERATURE", "NSFW_THRESHOLD",
             "SUGGEST_MARGIN", "SUGGEST_MAX_TAGS", "SAMPLE_INTERVAL_S",
             "MAX_FRAMES", "SAMPLE_SHORT_SIDE"]

VERSION = 1
MODEL_ID = "mobileclip-s2"
TABLE_NAME = "s2_prompts"
NOTE = "zero-shot preview classifier; Falconsai is the shipped verdict"
PRODUCER = "docs/coreml-spike/precompute_text.py"


def read_engine(path):
    """The pools and constants, straight out of engine.py. No import."""
    src = open(path, "r").read()
    tree = ast.parse(src)
    found = {}
    for node in tree.body:          # module level only; nothing nested matters
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id in LIST_NAMES + NUM_NAMES:
                try:
                    found[target.id] = ast.literal_eval(node.value)
                except ValueError:
                    pass
    missing = [n for n in LIST_NAMES + NUM_NAMES if n not in found]
    if missing:
        raise SystemExit("engine.py no longer defines: %s -- the prompt table "
                         "cannot be built from a guess" % ", ".join(missing))
    found["NSFW_POOL"], found["PAIRED_VOCAB"] = read_private_vocab(path)
    if not found["NSFW_POOL"] and not found["PAIRED_VOCAB"]:
        print("note: no private vocabulary -- the table gets no NSFW pool and no "
              "paired tags, and no private overlay is written")
    return found, hashlib.sha256(src.encode()).hexdigest()


def read_private_vocab(engine_path):
    """The NSFW pool and the paired tags, from where engine.py finds them."""
    here = os.path.dirname(os.path.abspath(engine_path))
    for path in (os.environ.get("FVP_PRIVATE_VOCAB", ""),
                 os.path.join(here, "private_vocab.json"),
                 os.path.join(here, "..", "private", "vocab.json")):
        if path and os.path.isfile(path):
            with open(path) as fh:
                data = json.load(fh)
            return (list(data.get("nsfw_pool", [])),
                    [(tag, list(phr)) for tag, phr in data.get("paired_vocab", [])])
    return [], []


def build_rows(engine):
    """Every phrase, in the documented order, with its pool and owner tag."""
    nsfw, neutral = engine["NSFW_POOL"], engine["NEUTRAL_POOL"]
    background = engine["BACKGROUND_POOL"]
    suggest, paired = engine["SUGGEST_VOCAB"], engine["PAIRED_VOCAB"]

    rows = []            # phrase strings, in row order
    tags = []            # [{"tag":..., "rows":[lo,hi]}, ...] for the suggestions

    rows += list(nsfw)
    n_nsfw = len(nsfw)
    rows += list(neutral)
    n_neutral = len(neutral)
    rows += list(background)
    n_background = len(background)

    suggest_lo = len(rows)
    for tag, phrasings in suggest:
        lo = len(rows)
        rows += list(phrasings)
        tags.append({"tag": tag, "rows": [lo, len(rows)]})
    suggest_hi = len(rows)

    paired_lo = len(rows)
    paired_tags = []
    for tag, phrasings in paired:
        lo = len(rows)
        rows += list(phrasings)
        paired_tags.append({"tag": tag, "rows": [lo, len(rows)]})
    paired_hi = len(rows)

    layout = {
        "nsfw": [0, n_nsfw],
        "neutral": [n_nsfw, n_nsfw + n_neutral],
        "background": [n_nsfw + n_neutral, n_nsfw + n_neutral + n_background],
        "suggest": [suggest_lo, suggest_hi],
        "paired": [paired_lo, paired_hi],
    }
    return rows, layout, tags, paired_tags


def encode(rows, text_model):
    import coremltools as ct
    from transformers import CLIPTokenizerFast

    tok = CLIPTokenizerFast.from_pretrained("openai/clip-vit-large-patch14")
    model = ct.models.MLModel(text_model)
    out = []
    for i, phrase in enumerate(rows, 1):
        ids = tok(phrase, padding="max_length", max_length=77, truncation=True,
                  return_tensors="np")["input_ids"].astype(np.int32)
        emb = model.predict({"text": ids})["final_emb_1"].reshape(-1)
        out.append(emb / np.linalg.norm(emb))
        if i % 25 == 0:
            print("  %d/%d …" % (i, len(rows)), flush=True)
    return np.stack(out).astype(np.float32)


def write_table(arr, rows, layout, tags, paired_tags, engine, engine_sha,
                out_dir, table_name=TABLE_NAME, model_id=MODEL_ID,
                note=NOTE, producer=PRODUCER):
    """Write the two files the app reads, from an already-encoded table.

    ONE definition of the JSON shape, because there are now two tables (MobileCLIP-S2
    and SigLIP 2) built from the same engine.py pools, and the shape is read by a
    Swift `Decodable` that cannot be changed by accident. The encoding is what
    differs between the two scripts; the format is not, and a second copy of it
    here would be the kind of copy that drifts.
    """
    os.makedirs(out_dir, exist_ok=True)
    bin_path = os.path.join(out_dir, table_name + ".f32")
    arr.tofile(bin_path)

    constants = {name: engine[name] for name in NUM_NAMES}
    meta = {
        "version": VERSION,
        "model": model_id,
        "dim": int(arr.shape[1]),
        "rows": int(arr.shape[0]),
        "layout": layout,
        "tags": tags,
        "paired_tags": paired_tags,
        # The phrases themselves, aligned to the .f32 rows. Row numbers alone
        # cannot answer "why did it suggest this?" — the app has no engine.py to
        # read them from, and a suggestion you cannot interrogate is one the user
        # has to take on faith. Cheap: ~7 KB of strings.
        "texts": rows,
        "constants": constants,
        "engine_py_sha256": engine_sha,
        "prompt_sha256": hashlib.sha256(arr.tobytes()).hexdigest(),
        "produced_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "producer": producer,
        "note": note,
    }
    json_path = os.path.join(out_dir, table_name + ".json")
    with open(json_path, "w") as fh:
        json.dump(meta, fh, indent=1, sort_keys=False)

    print("wrote %s (%d bytes)" % (bin_path, os.path.getsize(bin_path)))
    print("wrote %s (%d bytes)" % (json_path, os.path.getsize(json_path)))
    print("ships as %.0f KB, not 121 MB" % (os.path.getsize(bin_path) / 1024.0))
    return bin_path, json_path


def write_split(arr, rows, layout, tags, paired_tags, engine, engine_sha,
                out_dir, table_name=TABLE_NAME, **kw):
    """Cut the full `build_rows` table into the public table and the private
    overlay, and write both. The vectors are copied, never re-encoded.

    Public:  neutral, background and the suggestion tags, re-based to row 0.
    Overlay: the NSFW pool, then the paired tags -- `<table_name>.private.*`,
             only when there is anything to put in it. The app appends it after
             the public rows (`PromptTable.init(root:)`).
    """
    n_nsfw = layout["nsfw"][1]
    lo, hi = layout["neutral"][0], layout["suggest"][1]      # the public block
    shift = lambda pair, by: [pair[0] - by, pair[1] - by]
    public = write_table(
        np.ascontiguousarray(arr[lo:hi]), rows[lo:hi],
        {k: shift(layout[k], lo) for k in ("neutral", "background", "suggest")},
        [{"tag": t["tag"], "rows": shift(t["rows"], lo)} for t in tags], [],
        engine, engine_sha, out_dir, table_name=table_name, **kw)

    p_lo, p_hi = layout["paired"]
    if n_nsfw == 0 and p_hi == p_lo:
        return public, None
    ov_arr = np.concatenate([arr[0:n_nsfw], arr[p_lo:p_hi]])
    ov_rows = rows[0:n_nsfw] + rows[p_lo:p_hi]
    ov_layout = {"nsfw": [0, n_nsfw], "paired": [n_nsfw, n_nsfw + (p_hi - p_lo)]}
    ov_paired = [{"tag": t["tag"], "rows": shift(t["rows"], p_lo - n_nsfw)}
                 for t in paired_tags]
    overlay = write_table(np.ascontiguousarray(ov_arr), ov_rows, ov_layout, [], ov_paired,
                          engine, engine_sha, out_dir,
                          table_name=table_name + ".private", **kw)
    print("the .private table is NOT a release asset -- install it by hand")
    return public, overlay


def verify_against_previous(arr, out_dir, n_nsfw, n_neutral):
    """The first 33 rows must still match the verified spike table.

    The spike's 33-prompt npz is what UC 0.669/0.888-style numbers were measured
    with; if this script ever re-encodes them differently, every Phase 0 number
    in the plan is describing a table that no longer exists. Cheap, so it runs
    every time.
    """
    prev_path = os.path.join(out_dir, "s2_text_nsfw.npz")
    if not os.path.exists(prev_path):
        print("note: no previous s2_text_nsfw.npz to compare against")
        return None
    prev = np.load(prev_path, allow_pickle=True)
    old = prev["embeddings"]
    n = min(len(old), n_nsfw + n_neutral)
    new = arr[:n]
    cos = np.sum(old[:n] * new, axis=1)
    worst = float(cos.min())
    print("re-encode vs the verified 33-prompt table: worst cosine %.6f" % worst)
    if worst < 0.999:
        raise SystemExit("re-encoded prompts disagree with the verified table "
                         "(worst cosine %.6f) -- Phase 0 numbers would no longer "
                         "describe this table" % worst)
    return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT, help="where the table is written")
    ap.add_argument("--text-model", default=DEFAULT_TEXT_MODEL)
    ap.add_argument("--engine", default=ENGINE_PY)
    args = ap.parse_args()

    engine, engine_sha = read_engine(args.engine)
    rows, layout, tags, paired_tags = build_rows(engine)
    print("engine.py sha256 %s" % engine_sha[:16])
    print("rows: %d  (nsfw %d, neutral %d, background %d, suggest %d, paired %d)"
          % (len(rows), layout["nsfw"][1] - layout["nsfw"][0],
             layout["neutral"][1] - layout["neutral"][0],
             layout["background"][1] - layout["background"][0],
             layout["suggest"][1] - layout["suggest"][0],
             layout["paired"][1] - layout["paired"][0]))

    if not os.path.exists(args.text_model):
        raise SystemExit("text model not found: %s (the text encoder never ships, "
                         "but it is needed to build the table)" % args.text_model)

    t0 = time.time()
    arr = encode(rows, args.text_model)
    dt = time.time() - t0
    print("encoded %d phrases in %.1f s" % (len(rows), dt))

    n_nsfw = layout["nsfw"][1]
    verify_against_previous(arr, args.out, n_nsfw, layout["neutral"][1] - layout["neutral"][0])

    write_split(arr, rows, layout, tags, paired_tags, engine, engine_sha, args.out)

    # Keep the spike's 33-prompt npz in step for compare_accuracy.py, which
    # reads the NSFW/neutral pools only.
    legacy = np.load(os.path.join(args.out, "s2_text_nsfw.npz"), allow_pickle=True) \
        if os.path.exists(os.path.join(args.out, "s2_text_nsfw.npz")) else None
    n_legacy = n_nsfw + (layout["neutral"][1] - layout["neutral"][0])
    np.savez(os.path.join(args.out, "s2_text_nsfw.npz"),
             embeddings=arr[:n_legacy], n_nsfw=np.int32(n_nsfw),
             prompts=np.array(rows[:n_legacy], dtype=object), allow_pickle=True)
    if os.path.isdir(LEGACY_SPIKE):
        np.savez(os.path.join(LEGACY_SPIKE, "s2_text_nsfw.npz"),
                 embeddings=arr[:n_legacy], n_nsfw=np.int32(n_nsfw),
                 prompts=np.array(rows[:n_legacy], dtype=object), allow_pickle=True)
        print("refreshed the /tmp spike copy too (cache only)")
    if legacy is not None:
        print("previous npz had %d rows" % len(legacy["embeddings"]))


if __name__ == "__main__":
    main()
