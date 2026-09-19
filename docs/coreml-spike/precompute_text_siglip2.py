#!/usr/bin/env python3
"""The SigLIP 2 prompt table — the same rows and the same layout, a different tower.

`precompute_text.py` bakes MobileCLIP-S2's text-encoder answers into
`s2_prompts.{json,f32}`. This does the identical job for the SigLIP 2 image tower
that replaces it (`convert_siglip2_image.py`), so the app scores frames against
the SAME phrases the Python engine scores them against, addressed by row instead
of by string:

    siglip2_base_prompts.f32   rows x 768 little-endian float32, unit-normalised
    siglip2_base_prompts.json  the row layout, the tag -> rows map, the constants

The pools, the vocabulary and the tunables are NOT carried here. They are read out
of `AnalysisEngine/engine.py` by `precompute_text.read_engine`, and the row layout
is built by `precompute_text.build_rows` — imported, not copied, for the same
reason the original script refuses to carry a copy: a copy that must not drift is
a copy that eventually drifts. What differs between the two tables is only how the
text gets encoded, plus the two things that follow from it:

    MobileCLIP-S2   Core ML text package, CLIP BPE, 77 tokens, 512 dim
    SigLIP 2        torch text tower, Gemma tokenizer (256k), 64 tokens, 768 dim

The text length is SigLIP's own (`2.1 Architecture`: "We set the text length to
64"), not CLIP's 77 — tokenizing to the wrong length would pad eleven rows of
nothing into every phrase and move every margin.

The text tower is loaded in torch rather than converted to Core ML, because it is
never asked about anything but this fixed vocabulary and it never ships: converting
a 256k-vocabulary tower to Core ML would be work spent on an artifact no user
downloads. Running it here is the whole reason the table can be half a megabyte.

Usage:
    /opt/anaconda3/bin/python3 docs/coreml-spike/precompute_text_siglip2.py [--out DIR]
"""

import argparse
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                     # so the shared pieces import cleanly

import precompute_text as pt                 # noqa: E402

HF_ID = "google/siglip2-base-patch16-224"
MODEL_ID = "siglip2-base"
TABLE_NAME = "siglip2_base_prompts"
TEXT_LENGTH = 64                             # SigLIP's text length, not CLIP's 77


def encode(rows):
    """Every phrase through the SigLIP 2 text tower, unit-normalised, fp32.

    The MAP head's pooled output, exactly what the image tower's output is
    pooled with — the two halves only share a space if both come from the same
    head, which is why this does not reach for a CLS token instead.
    """
    import torch
    from transformers import AutoTokenizer, SiglipTextModel

    tokenizer = AutoTokenizer.from_pretrained(HF_ID)
    text_tower = SiglipTextModel.from_pretrained(HF_ID).eval()
    print("text tower %s · vocab %d · max %d tokens · dim %d"
          % (HF_ID, tokenizer.vocab_size, TEXT_LENGTH, text_tower.config.hidden_size))

    out = []
    for i, phrase in enumerate(rows, 1):
        ids = tokenizer(phrase, padding="max_length", max_length=TEXT_LENGTH,
                        truncation=True, return_tensors="pt")["input_ids"]
        with torch.no_grad():
            emb = text_tower(input_ids=ids).pooler_output.float().numpy().reshape(-1)
        out.append(emb / np.linalg.norm(emb))
        if i % 25 == 0:
            print("  %d/%d …" % (i, len(rows)), flush=True)
    arr = np.stack(out).astype(np.float32)
    verify_vectors(arr, rows, text_tower, tokenizer)
    return arr


def verify_vectors(arr, rows, text_tower, tokenizer):
    """The checks that need the tower: shape, unit rows, determinism."""
    import torch

    if len(rows) == 0 or arr.shape[1] == 0 or arr.shape[0] != len(rows):
        raise SystemExit("table is %s for %d phrases" % (arr.shape, len(rows)))
    norms = np.linalg.norm(arr, axis=1)
    if np.abs(norms - 1.0).max() > 1e-5:
        raise SystemExit("rows are not unit vectors: |1-|v|| max %.2e"
                         % np.abs(norms - 1.0).max())
    print("rows %d × dim %d, all unit (worst |1-|v|| %.2e)"
          % (arr.shape[0], arr.shape[1], np.abs(norms - 1.0).max()))

    # Determinism: the same phrase, encoded again, must not move. A text tower in
    # train mode would (dropout), which is why .eval() above is load-bearing.
    for index in (0, len(rows) // 2, len(rows) - 1):
        ids = tokenizer(rows[index], padding="max_length", max_length=TEXT_LENGTH,
                        truncation=True, return_tensors="pt")["input_ids"]
        with torch.no_grad():
            again = text_tower(input_ids=ids).pooler_output.float().numpy().reshape(-1)
        again /= np.linalg.norm(again)
        delta = float(np.abs(again - arr[index]).max())
        if delta > 1e-6:
            raise SystemExit("row %d is not reproducible (|Δ| %.2e) — the tower is "
                             "not in eval mode" % (index, delta))
    print("re-encode determinism: 3 rows, worst |Δ| < 1e-6")


def verify_layout(arr, rows, layout, tags, paired_tags):
    """The row ranges Swift addresses by index.

    A range that runs past the table or sits backwards would make the app score
    phrases that are not there, so it is refused here rather than discovered in a
    300 MB download. Swift validates the same ranges on load; this is the half of
    the check that can quote which phrase was wrong.
    """
    for name, pair in layout.items():
        # The private sections may be empty (no private vocabulary); the public
        # ones may not.
        empty_ok = name in ("nsfw", "paired")
        if pair[0] < 0 or pair[1] > len(rows) or pair[0] > pair[1] \
                or (pair[0] == pair[1] and not empty_ok):
            raise SystemExit("layout '%s' = %s is not usable for %d rows"
                             % (name, pair, len(rows)))
    for entry in list(tags) + list(paired_tags):
        if entry["rows"][0] >= entry["rows"][1]:
            raise SystemExit("tag '%s' has no rows" % entry["tag"])
    print("layout ok    %s · %d phrases · %d suggestion tags + %d paired"
          % ({k: tuple(v) for k, v in layout.items()}, len(rows), len(tags),
             len(paired_tags)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=pt.DEFAULT_OUT)
    parser.add_argument("--engine", default=pt.ENGINE_PY)
    args = parser.parse_args()

    engine, engine_sha = pt.read_engine(args.engine)
    rows, layout, tags, paired_tags = pt.build_rows(engine)
    print("engine.py sha256 %s" % engine_sha[:16])
    print("rows: %d  (nsfw %d, neutral %d, background %d, suggest %d, paired %d)"
          % (len(rows), layout["nsfw"][1] - layout["nsfw"][0],
             layout["neutral"][1] - layout["neutral"][0],
             layout["background"][1] - layout["background"][0],
             layout["suggest"][1] - layout["suggest"][0],
             layout["paired"][1] - layout["paired"][0]))

    t0 = time.time()
    arr = encode(rows)
    verify_layout(arr, rows, layout, tags, paired_tags)
    print("encoded %d phrases in %.1f s" % (len(rows), time.time() - t0))

    pt.write_split(arr, rows, layout, tags, paired_tags, engine, engine_sha,
                   args.out, table_name=TABLE_NAME, model_id=MODEL_ID,
                   note=pt.NOTE, producer="docs/coreml-spike/precompute_text_siglip2.py")

    print("\nnext         rename the slug in Swift (VisionEmbedder.modelSlug, "
          "PromptTable.slug)")
    print("installs as  tags/%s.{json,f32}  (pack_bundles.sh)" % TABLE_NAME)


if __name__ == "__main__":
    main()
