#!/usr/bin/env python3
"""Do the tag thresholds survive a change of embedding space?

`SUGGEST_MARGIN` (engine.py, 0.02) and `TagSuggester.vocabularyMargin` (0.06) were
both derived by hand in MobileCLIP-S2's cosine space, against real videos and the
maintainer's own marks. The SigLIP 2 table carries the SAME 162 phrases out of the
same `engine.py` pools, but the cosines come from a different tower — so the
question this script answers is the one the migration cannot skip:

    does a margin of 0.06 in the new space mean what it meant in the old one?

It cannot answer that fully: text-to-text cosines are not image-to-text cosines,
and only the app's own frames and marks can settle it. What it CAN do is measure
the geometry each space gives the same phrases, which is where a scale difference
shows up first — SigLIP's sigmoid loss is known to push normalized cosines high,
and a bar transplanted between two such spaces is how a tag vocabulary quietly
becomes "everything" or "nothing".

    /opt/anaconda3/bin/python3 docs/coreml-spike/table_margin_compare.py
    /opt/anaconda3/bin/python3 docs/coreml-spike/table_margin_compare.py \
        --mobileclip ~/fvp-coreml-models/s2_prompts.json \
        --siglip2 ~/fvp-coreml-models/siglip2_base_prompts.json
"""

import argparse
import json
import os
import sys

import numpy as np

MODELS = os.path.expanduser("~/fvp-coreml-models")
DEFAULT = {
    "mobileclip-s2": os.path.join(MODELS, "s2_prompts.json"),
    "siglip2-base": os.path.join(MODELS, "siglip2_base_prompts.json"),
}


def load(json_path):
    """The table, as unit rows, plus the meta Swift reads."""
    meta = json.load(open(json_path))
    bin_path = json_path[:-5] + ".f32"
    flat = np.fromfile(bin_path, dtype="<f4")
    expected = meta["rows"] * meta["dim"]
    if flat.size != expected:
        raise SystemExit("%s is %d floats, expected %d (%d rows x %d dim)"
                         % (bin_path, flat.size, expected, meta["rows"], meta["dim"]))
    m = flat.reshape(meta["rows"], meta["dim"]).astype(np.float64)
    m /= np.linalg.norm(m, axis=1, keepdims=True)
    return meta, m


def geometry(meta, m):
    """Two distributions that a phrase-against-background bar is read through.

    A frame is never in the table, so a phrasing cannot stand in for one. What can
    be measured without frames is how far the tag vocabulary sits from the bland
    pool, and how tight each tag's own wording is — the two quantities a
    `best phrasing - best bland phrase` margin is a difference of:

      * `to_background`  max cosine from each suggest phrasing to the bland pool
      * `tightness`      mean pairwise cosine among one tag's own phrasings

    Neither is the app's margin. What each one DOES give is the scale of cosines
    in this space, which is the thing that decides whether a bar of 0.02 or 0.06
    means anything after the tower changes.
    """
    bg = slice(*meta["layout"]["background"])
    suggest = slice(*meta["layout"]["suggest"])

    to_background = (m[suggest] @ m[bg].T).max(axis=1)
    tightness = []
    for tag in meta["tags"]:
        lo, hi = tag["rows"]
        block = m[lo:hi] @ m[lo:hi].T
        if len(block) < 2:
            continue
        upper = block[np.triu_indices(len(block), 1)]
        tightness.append(float(upper.mean()))
    return np.array(tightness), to_background


def pool_separation(meta, m):
    """Are the NSFW and neutral pools actually apart in this space?

    The engine's per-frame score is `max(nsfw) - max(neutral) - MARGIN_BIAS`, and
    MARGIN_BIAS (0.03) is another hand-derived constant. There is no "frame" here
    to score, so what is measured instead is the geometry the score relies on:
    how much closer each pool is to itself than to the other. A separation near
    zero means the pools overlap and the 0.03 bias is describing noise.
    """
    def block(a, b):
        return m[slice(*meta["layout"][a])] @ m[slice(*meta["layout"][b])].T

    def mean_offdiag(x):
        n = len(x)
        if n < 2:
            return float("nan")
        return float(x[np.triu_indices(n, 1)].mean())

    within_nsfw = mean_offdiag(block("nsfw", "nsfw"))
    within_neutral = mean_offdiag(block("neutral", "neutral"))
    cross = float(block("nsfw", "neutral").mean())
    return within_nsfw, within_neutral, cross, (within_nsfw + within_neutral) / 2 - cross


def describe(name, meta, m):
    tightness, to_background = geometry(meta, m)
    print("\n%s  %s  (%d rows x %d dim)"
          % (name, meta["model"], meta["rows"], meta["dim"]))
    print("  phrasing -> bland pool (max)      median %.4f   p10 %.4f   p90 %.4f"
          % (np.median(to_background), np.percentile(to_background, 10),
             np.percentile(to_background, 90)))
    print("  within-tag tightness (mean pair)  median %.4f   p10 %.4f   p90 %.4f"
          % (np.median(tightness), np.percentile(tightness, 10),
             np.percentile(tightness, 90)))
    wn, wn2, cross, sep = pool_separation(meta, m)
    print("  nsfw-vs-neutral pools             within %.4f/%.4f   cross %.4f   "
          "separation %.4f" % (wn, wn2, cross, sep))
    return tightness, to_background


def rank_tags(meta, m):
    """A tag's distance from the bland pool, for ranking the two spaces against
    each other: the tag's centroid against the best bland phrase. Comparable
    across models because both sides are unit vectors in their own space."""
    bg = slice(*meta["layout"]["background"])
    out = {}
    for tag in meta["tags"]:
        lo, hi = tag["rows"]
        centroid = m[lo:hi].mean(axis=0)
        centroid /= np.linalg.norm(centroid)
        out[tag["tag"]] = float((centroid @ m[bg].T).max())
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mobileclip", default=DEFAULT["mobileclip-s2"])
    parser.add_argument("--siglip2", default=DEFAULT["siglip2-base"])
    args = parser.parse_args()

    tables = {}
    for name, path in (("MobileCLIP-S2", args.mobileclip), ("SigLIP 2 B/16", args.siglip2)):
        if not os.path.exists(path):
            raise SystemExit("no table at %s" % path)
        meta, m = load(path)
        tables[name] = (meta, m, describe(name, meta, m), rank_tags(meta, m))

    _, _, (old_tight, old_bg), old_rank_value = tables["MobileCLIP-S2"]
    _, _, (new_tight, new_bg), new_rank_value = tables["SigLIP 2 B/16"]

    print("\nthe same phrases, the same pools, two towers")
    print("  bland-pool cosine scale           old %.4f   new %.4f  (medians)"
          % (np.median(old_bg), np.median(new_bg)))
    print("  within-tag tightness              old %.4f   new %.4f  (medians)"
          % (np.median(old_tight), np.median(new_tight)))
    shared = sorted(set(old_rank_value) & set(new_rank_value))
    old_order = {t: i for i, t in enumerate(sorted(shared, key=lambda t: -old_rank_value[t]))}
    new_order = {t: i for i, t in enumerate(sorted(shared, key=lambda t: -new_rank_value[t]))}
    moved = sorted(shared, key=lambda t: -abs(old_order[t] - new_order[t]))[:6]
    print("  tags furthest from the bland pool, by rank movement (of %d):" % len(shared))
    for tag in moved:
        print("    %-22s old #%-3d %.4f   new #%-3d %.4f"
              % (tag, old_order[tag] + 1, old_rank_value[tag],
                 new_order[tag] + 1, new_rank_value[tag]))

    print("\nWHAT THIS DOES NOT SAY: whether the new space tags real videos better. That")
    print("needs frames and the maintainer's own marks, the same way Phase 0 measured")
    print("AUC 0.669 on the old table. The numbers above only show whether a bar of")
    print("0.02/0.06 divides the same phrases the same way — a bar that does not is a")
    print("threshold to re-derive, not a bug to chase.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
