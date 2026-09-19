#!/usr/bin/env python3
"""Expected values for the Swift prompt-table maths, computed from the same file.

The Swift side must do exactly what numpy did in the spike: same row order, same
max-minus-max margin, same sigmoid, same background subtraction for the
suggestions. A wrong row offset or a transposed read would still produce
plausible-looking scores, so "it runs" is not evidence — this fixture is.

It is generated from the table the Swift test is about to read, and it carries
`prompt_sha256` so the two cannot silently be different tables. When the private
overlay (`<name>.private.{json,f32}`) sits beside the table, its rows are
appended exactly as `PromptTable.init(root:)` appends them, so the NSFW score
and the paired tags are checked too; without it there is no NSFW score to check
(`nsfw_score` is null).

The table's NAME is an argument, because there are now two of them
(`s2_prompts` for MobileCLIP-S2, `siglip2_base_prompts` for SigLIP 2) built from
the same `engine.py` pools, and a rig that silently read the other one would
compare Swift's arithmetic against a table the app does not load.

Usage:
    table_parity.py <table-dir> <out.json> [table-name]
"""

import json
import math
import os
import sys

import numpy as np


def probe_vector(dim):
    """The same deterministic vector the Swift test builds.

    sin(i * 0.7), normalised. Rather than inventing a random generator whose
    two implementations would have to agree (they would not), the vector is a
    closed-form function both languages can evaluate — a 1-ulp difference in
    sin costs ~1e-7 of a margin, four orders below the tolerance the test uses.
    """
    v = np.sin(np.arange(dim, dtype=np.float64) * 0.7)
    return (v / np.linalg.norm(v)).astype(np.float32)


def main():
    if len(sys.argv) < 3:
        print("usage: table_parity.py <table-dir> <out.json> [table-name]")
        return 2
    table_dir, out_path = sys.argv[1], sys.argv[2]
    table_name = sys.argv[3] if len(sys.argv) > 3 else "siglip2_base_prompts"

    def load(name):
        with open(os.path.join(table_dir, name + ".json")) as fh:
            m = json.load(fh)
        t = np.fromfile(os.path.join(table_dir, name + ".f32"),
                        dtype="<f4").reshape(int(m["rows"]), int(m["dim"]))
        return m, t

    meta, T = load(table_name)
    layout = {k: list(v) for k, v in meta["layout"].items()}
    paired = [dict(t) for t in meta.get("paired_tags") or []]
    has_overlay = os.path.exists(os.path.join(table_dir, table_name + ".private.json"))
    if has_overlay:
        extra, E = load(table_name + ".private")
        offset = T.shape[0]
        T = np.concatenate([T, E])
        nsfw = extra["layout"].get("nsfw")
        if nsfw and nsfw[1] > nsfw[0]:
            layout["nsfw"] = [nsfw[0] + offset, nsfw[1] + offset]
        if extra.get("paired_tags"):
            paired = [{"tag": t["tag"], "rows": [t["rows"][0] + offset, t["rows"][1] + offset]}
                      for t in extra["paired_tags"]]
    rows, dim = T.shape
    v = probe_vector(dim)

    norms = np.linalg.norm(T.astype(np.float64), axis=1)
    c = meta["constants"]
    sims = T @ v

    def rng(key):
        lo, hi = layout[key]
        return sims[lo:hi]

    nsfw_rows = layout.get("nsfw", [0, 0])
    if nsfw_rows[1] > nsfw_rows[0]:
        margin = float(rng("nsfw").max() - rng("neutral").max()) - float(c["MARGIN_BIAS"])
        score = 1.0 / (1.0 + math.exp(-float(c["MARGIN_TEMPERATURE"]) * margin))
    else:
        margin, score = None, None

    background = float(rng("background").max())
    margins = {}
    for tag in meta["tags"]:
        lo, hi = tag["rows"]
        margins[tag["tag"]] = float(sims[lo:hi].max() - background)

    fired = sorted((t for t, m in margins.items() if m >= float(c["SUGGEST_MARGIN"])),
                   key=lambda t: -margins[t])
    capped = fired[:int(c["SUGGEST_MAX_TAGS"])]

    fixture = {
        "table": table_name,
        "prompt_sha256": meta["prompt_sha256"],
        "dim": int(dim),
        "rows": int(rows),
        "layout": layout,
        "has_overlay": has_overlay,
        "paired_names": [t["tag"] for t in paired],
        "vector": [float(x) for x in v],
        "nsfw_margin": margin,
        "nsfw_score": score,
        "background_best": background,
        "tag_margins": margins,
        "suggest_1frame_all": fired,
        "suggest_1frame_capped": capped,
        "unit_norm_max_error": float(np.abs(norms - 1.0).max()),
        "row_sums_abs_mean": float(np.abs(T.astype(np.float64).sum(axis=1)).mean()),
    }
    with open(out_path, "w") as fh:
        json.dump(fixture, fh)
    print("parity fixture: score %s, %d tags, %d over the margin, overlay %s "
          "(row-norm error %.2e)" % ("%.6f" % score if score is not None else "n/a",
                                     len(margins), len(fired), has_overlay,
                                     fixture["unit_norm_max_error"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
