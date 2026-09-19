#!/usr/bin/env python3
"""FolderVideoPlayer analysis engine — v0.1.

Runs the video-classification half of the Review & Classify feature. The app
speaks JSON-lines over stdio; the engine never touches the library store and
the app never links a model, so models and scoring can be replaced without an
app rebuild (the spec's one hard rule).

Requests (one line, {"id": N, "cmd": ...}):
  hello          -> capability + environment report
  ensure_model   -> download/load the vision model (first run only really)
  analyse        -> sample frames from one video, embed, score NSFW, aggregate

Responses: any number of {"type": ...} event lines, then exactly one terminal
line {"type": "done", "ok": true/false, ...}. "error" and "cancelled" events
carry the reason. One analysis runs at a time; further "analyse" requests while
busy are answered with an immediate error.

Model baseline: openai/clip-vit-large-patch14 (ViT-L/14) via transformers on
torch MPS. Classifier: zero-shot margin between an NSFW prompt pool and a
neutral pool — a deliberately crude v1 that needs no training data; the user's
manual Safe/NSFW marks in the app calibrate and replace it in later phases.
"""

import json
import os
import sys
import io
import time
import math
import subprocess
import tempfile
import shutil
import threading
import traceback
import hashlib
import struct

# --------------------------------------------------------------------------
# Tunables. Everything that shapes a verdict is here so the record in the app
# can name the exact parameters that produced it (reproducibility, spec 22).
# --------------------------------------------------------------------------

MODEL_ID = "openai/clip-vit-large-patch14"      # baseline; registry-swappable
EMBED_DIM = 768                                  # CLIP projection width (what get_*_features returns)
DEVICE = "mps"                                   # torch MPS on Apple Silicon
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
SAMPLE_INTERVAL_S = 5                            # one frame every N seconds
SAMPLE_TARGET_SHORT = 4                          # frames to aim for on short clips
SAMPLE_SHORT_SIDE = 384                          # keep thumbnails small
MAX_FRAMES = 250                                 # hard cap per video
BATCH = 32                                       # images per embed call

# Where frame embeddings are kept. The model id is part of the path so two
# embedding spaces can never be mistaken for one another (spec 24), and an old
# model's vectors are simply left behind rather than deleted (spec 23).
#
# These vectors are the expensive asset: embedding dominates the cost of a
# pass, while every question asked of a vector (NSFW, who is in it, what kind
# of event) is a dot product costing microseconds. Cached, a new category or a
# retuned prompt set re-scores a whole library in seconds instead of re-running
# the GPU over it for hours.
SUPPORT_DIR = os.path.expanduser(
    "~/Library/Application Support/FolderVideoPlayer")

# Which tag profile is in force, as the app launched us (`FVP_PROFILE`).
#
# A profile is one person's judgement: the heads fitted from their accept and
# reject clicks, and the faces they have named. Those are filed under the
# profile's own folder, so training one person never changes what another is
# offered, and a profile nobody has used yet starts genuinely blank.
#
# What is NOT here is the machine's own work. The frame vector cache below, and
# the downloaded model files, are a reading of the videos and carry nobody's
# opinion; sharing them is what makes a second profile cheap instead of a second
# full encode.
PROFILE = os.environ.get("FVP_PROFILE", "").strip()
PROFILE_DIR = (os.path.join(SUPPORT_DIR, "profiles", PROFILE)
               if PROFILE else SUPPORT_DIR)
EMBED_CACHE = os.path.join(SUPPORT_DIR, "frames")
EMBED_CACHE_ENABLED = True
MARGIN_TEMPERATURE = 40.0                        # sigmoid steepness on sim gap
# Zero-shot CLIP noise floor: pooled maxima drift positive even on innocuous
# content, so a flat bias is subtracted before the sigmoid.
#
# v2, calibrated 2026-09-08 against BOTH classes on real footage — 18 known
# NSFW videos and 24 known-safe ones from a real library (42 videos,
# ~400 sampled frames). The bias was swept from -0.02 to 0.08 by re-deriving
# each frame's raw margin analytically, so every value saw identical
# embeddings:
#
#     bias   lowest NSFW   highest safe   gap
#     0.02      0.651          0.556     +0.095
#     0.03      0.556          0.456     +0.099   <- widest, chosen
#     0.04      0.456          0.360     +0.096   (v1, safe-only guess)
#     0.06      0.274          0.202     +0.072
#
# The classes never overlap at any bias tested; 0.03 maximises the margin
# between them. v1's 0.04 was set from safe frames alone (no positives
# existed yet) and landed close, but it compressed NSFW scores far enough
# down that most of them fell into the app's review band for no reason.
#
# Caveat kept deliberately: 42 videos is a small sample and the positives come
# from one source, so the ~0.1 gap should not be treated as a hard guarantee
# for content unlike either set. The app's manual Safe/NSFW marks supersede
# this (Phase C), and every verdict records the bias that produced it.
MARGIN_BIAS = 0.03
NSFW_THRESHOLD = 0.5                             # frame & video classification cut

# Early exit: once this many frames have cleared the confident-NSFW line, the
# video's verdict cannot change (aggregation is max), so the remaining frames
# are embedded for nothing. Measured 2026-09-08 over 68 real videos: this cuts
# ~26% of frame embeddings and changes 0 verdicts.
#
# It only helps long videos -- on this library's short clips most videos have
# fewer frames than the trigger -- but a single long recording is exactly where
# the waste would otherwise be worst, and the rule costs nothing when it does
# not fire.
EARLY_EXIT_HITS = 3
EARLY_EXIT_SCORE = 0.65                          # the app's confident-NSFW line

def _load_private_vocab():
    """The NSFW prompt pool and the paired tags, from a file kept out of source.

    Neither list is in this file: both are explicit by nature, and the source is
    public. They live in a private JSON file (`nsfw_pool`, `paired_vocab`),
    looked for at $FVP_PRIVATE_VOCAB, then beside this file as
    `private_vocab.json` (the deployed engine), then at `../private/vocab.json`
    (a checkout that carries it). Without it both lists are empty: tag
    suggestions still work, the paired tags are never offered, and the
    zero-shot NSFW verdict refuses to run (see `ensure_model`) rather than
    scoring against nothing. The app's shipped verdict is Falconsai and does
    not need this file.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    for path in (os.environ.get("FVP_PRIVATE_VOCAB", ""),
                 os.path.join(here, "private_vocab.json"),
                 os.path.join(here, "..", "private", "vocab.json")):
        if path and os.path.isfile(path):
            with open(path, "r") as f:
                data = json.load(f)
            return (list(data.get("nsfw_pool", [])),
                    [(tag, list(phr)) for tag, phr in data.get("paired_vocab", [])])
    return [], []


NSFW_POOL, PAIRED_VOCAB = _load_private_vocab()

NEUTRAL_POOL = [
    "a person fully clothed in everyday clothes",
    "a group of people fully dressed in normal clothes",
    "an everyday indoor scene", "a landscape without people", "a nature scene",
    "a city street scene", "food on a table", "a pet animal at home",
    "people eating a meal together", "people playing sports",
    "a child's birthday party", "a person exercising at the gym",
    "a beach scene with people wearing swimsuits",
    "people dancing at a party", "a family gathering at home",
    "a person sitting at a desk with a computer",
]

CLASSIFIER = "zeroshot-margin-v1"                # provenance tag for verdicts

# --------------------------------------------------------------------------
# LAION NSFW head (clip_autokeras_binary_nsfw, ported weights-only to torch)
#
# A second opinion over the SAME cached embeddings: a small dense stack
# (768 -> 64 -> 512 -> 256 -> 1) trained by LAION on ~225k labelled images.
# The original ships as a Keras SavedModel; its weights were extracted and the
# architecture recovered by numerical matching against the TF runtime
# (max |err| 1.5e-4 on random inputs, i.e. float32 rounding). Running it is a
# few matmuls per frame -- effectively free next to embedding.
#
# Provenance: laion_nsfw_head/1.0, weights at
#   ~/Library/Application Support/FolderVideoPlayer/models/laion_nsfw_l14.npz
# Source: LAION-AI/CLIP-based-NSFW-Detector (MIT), ViT-L/14 variant.
# --------------------------------------------------------------------------
LAION_HEAD_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "models", "laion_nsfw_l14.npz")

_laion_head = {"tensors": None}                  # lazy; survives per-process


def laion_scores(emb):
    """Score [B, 768] CLIP embeddings with the ported LAION head.

    Returns a float32 torch tensor of NSFW probabilities in [0, 1], or None
    when the weights file is missing or malformed -- the head is a second
    opinion, so it degrades to absent rather than failing the run.
    """
    import numpy as np
    import torch
    if _laion_head["tensors"] is None:
        if not os.path.exists(LAION_HEAD_PATH):
            return None
        try:
            z = np.load(LAION_HEAD_PATH)
            need = {"norm_mean", "norm_var", "d0_w", "d0_b", "d1_w", "d1_b",
                    "d2_w", "d2_b", "d3_w", "d3_b"}
            if not need.issubset(set(z.files)):
                return None
            _laion_head["tensors"] = {k: torch.from_numpy(np.ascontiguousarray(z[k])) for k in need}
        except Exception:
            return None
    t = _laion_head["tensors"]
    x = (emb - t["norm_mean"]) / torch.sqrt(t["norm_var"] + 1e-7)
    x = torch.relu(x @ t["d0_w"] + t["d0_b"])
    x = torch.relu(x @ t["d1_w"] + t["d1_b"])
    x = torch.relu(x @ t["d2_w"] + t["d2_b"])
    return torch.sigmoid(x @ t["d3_w"] + t["d3_b"]).squeeze(-1)


SAMPLING = "uniform-fps-1/%ds-cap%d" % (SAMPLE_INTERVAL_S, MAX_FRAMES)
AGGREGATION = "max-margin-v1"

# --------------------------------------------------------------------------
# JSON-lines plumbing
# --------------------------------------------------------------------------

_busy = threading.Event()          # one analysis at a time
_busy_job = ""                     # what the busy slot is doing: analysing/training/suggesting
_cancel = threading.Event()        # set by a "cancel" request
_ffmpeg_proc = None                # child being cancelled, if any


# ---------------------------------------------------------------- suggestion vocabulary
#
# Candidate tags offered while a video plays. Each entry is (tag, [phrasings]).
# Several phrasings per tag because CLIP is sensitive to wording -- the best
# match across them is used, which is far steadier than any single sentence.
#
# The measured lesson from the Sep 2026 probe: a softmax over a fixed list ALWAYS
# names a winner, so "wedding" fired confidently on ordinary indoor gatherings.
# Nothing here is scored that way. Each tag competes against the BACKGROUND_POOL
# below and must clear a margin on its own, so the honest answer "none of these"
# is reachable -- which is the common case for home video.
SUGGEST_VOCAB = [
    # --- occasions / events -------------------------------------------------
    ("Birthday",        ["a birthday party", "a birthday cake with candles",
                         "people singing happy birthday"]),
    ("Wedding",         ["a wedding ceremony", "a bride and groom",
                         "a wedding reception"]),
    ("Party",           ["a party with people celebrating", "a festive gathering"]),
    ("Concert",         ["a live music concert", "a band performing on stage"]),
    ("Parade",          ["a street parade", "a procession with performers"]),
    ("Fireworks",       ["a fireworks display at night", "fireworks in the sky"]),
    ("Graduation",      ["a graduation ceremony", "people in graduation gowns"]),

    # --- activities ---------------------------------------------------------
    ("Dancing",         ["people dancing", "a person dancing"]),
    ("Dining",          ["people eating a meal at a table", "a restaurant meal"]),
    ("Swimming",        ["people swimming in a pool", "someone swimming"]),
    ("Hiking",          ["people hiking on a trail", "walking in the mountains"]),
    ("Sightseeing",     ["tourists sightseeing at a landmark",
                         "people taking photos of a monument"]),
    ("Shopping",        ["people shopping in a store", "a shopping mall interior"]),
    ("Sports",          ["people playing a sport", "a sports match"]),
    ("Driving",         ["a view from inside a moving car", "driving on a road"]),
    ("Performance",     ["a stage performance", "a theatre show"]),

    # --- places / settings --------------------------------------------------
    ("Beach",           ["a sandy beach by the sea", "people at the beach"]),
    ("Cruise Ship",     ["a large cruise ship", "the deck of a cruise ship"]),
    ("Airport",         ["an airport terminal", "an aeroplane at a gate"]),
    ("Hotel",           ["a hotel room", "a hotel lobby"]),
    ("Restaurant",      ["the inside of a restaurant", "a cafe interior"]),
    ("City",            ["a city street with buildings", "an urban skyline"]),
    ("Mountains",       ["a mountain landscape", "snow covered mountains"]),
    ("Forest",          ["a forest with trees", "a woodland trail"]),
    ("Garden",          ["a garden with plants and flowers", "a botanical garden"]),
    ("Waterfall",       ["a waterfall", "water falling over rocks"]),
    ("Lake",            ["a lake", "a calm body of water with shore"]),
    ("Snow",            ["a snowy landscape", "snow on the ground"]),
    ("Museum",          ["a museum exhibit", "an art gallery interior"]),
    ("Temple",          ["a temple", "a religious shrine"]),
    ("Church",          ["a church interior", "a cathedral"]),
    ("Market",          ["an outdoor market with stalls", "a street market"]),
    ("Aquarium",        ["an aquarium tank with fish", "people watching fish in an aquarium"]),
    ("Theme Park",      ["an amusement park ride", "a theme park"]),
    ("Indoors",         ["the inside of a room", "an indoor space"]),
    ("Outdoors",        ["an outdoor natural scene", "being outside in the open air"]),
    ("Night",           ["a scene at night", "city lights in the dark"]),

    # --- subjects -----------------------------------------------------------
    ("Group of People", ["a group of people together", "several people in a room"]),
    ("Children",        ["young children playing", "a child"]),
    ("Baby",            ["a baby", "an infant being held"]),
    ("Pets",            ["a pet dog or cat", "someone with their pet"]),
    ("Dog",             ["a dog", "a dog outdoors"]),
    ("Cat",             ["a cat", "a cat indoors"]),
    ("Birds",           ["birds", "a bird in the wild"]),
    ("Wildlife",        ["a wild animal in nature", "wildlife"]),
    ("Flowers",         ["flowers in bloom", "a close up of a flower"]),
    ("Food",            ["a plate of food", "a close up of a dish"]),
    ("Boat",            ["a boat on the water", "a small boat"]),
    ("Aircraft",        ["an aeroplane", "a plane in flight"]),
    ("Vehicle",         ["a car or vehicle", "cars on a road"]),
    ("Sunset",          ["a sunset", "the sun setting over the horizon"]),
    ("Text on Screen",  ["a slide with text", "a document or presentation"]),
]

# PAIRED_VOCAB (loaded above, from the private vocabulary) is a mutually
# exclusive pair of tags offered ONLY for videos already filed NSFW (the
# caller passes paired: true). Safe videos are never asked about them.
#
# A video can carry at most one of the two, so they are decided head to head
# (`_paired_winner`) rather than each against the background pool. The phrases
# are a rough prompt-only start; every accept/reject of these chips is a
# labelled example for the Phase D heads (engine.py "train"), which replace the
# guess once a tag has 4+ accepted and 4+ rejected videos.
#
# Tags that only ever fire on NSFW videos -- used to gate BOTH the prompt
# pass and any Phase D head the user happens to train with the same names.
PAIRED_TAG_NAMES = {tag for tag, _ in PAIRED_VOCAB}

# What every candidate must beat. These are deliberately bland: if a frame is
# just "a photo" or "an indoor scene", no specific tag should win.
BACKGROUND_POOL = [
    "a photo", "a video frame", "a scene", "an ordinary moment",
    "a blurry image", "a dark image", "an indoor scene", "an outdoor scene",
    "a person", "an object", "a wall", "the ground", "the sky",
]

# A tag is suggested when its best phrasing beats the best background phrase by
# this margin, on at least `_min_frames_for()` frames.
#
# Measured Sep 2026 over 342 (video, tag) pairs from the user's own library: the
# correct tag ranked FIRST for every video inspected, at margin +0.03..+0.06,
# while wrong-but-plausible tags sat below +0.01. So the bar is about right at
# 0.02 -- that is roughly the top 2-5% of pairs.
#
# The frame requirement has to scale, though. A flat "2 frames" silently dropped
# correct tags on short clips (a 3-frame screen recording scored +0.061 on one
# frame and was thrown away). Videos here have a median of 6 frames, so:
SUGGEST_MARGIN = 0.02
SUGGEST_MAX_TAGS = 8          # never bury the user in chips

# --------------------------------------------------------------------------
# Trained per-tag heads (Phase D: learn from your tags)
#
# One logistic head per tag, fit over the CACHED frame embeddings by the
# "train" command from the labels the user has already given (tag accepted /
# rejected via suggestions, or the video carries the tag). The weights live in
# one npz in the PROFILE's own folder — profiles/<profile>/<slug>_trained_heads.npz
# — so a head fitted for one person is never read as another's — entries
#   head/<tag>/w  [768]   head/<tag>/b  scalar   head/<tag>/n  example count
# A tag with a stored head is scored by w.x + b per frame; frames above the
# logistic cut vote, and the fraction must clear _min_frames_for() like the
# zero-shot path. Nothing here re-embeds: vectors are read straight from the
# cache, so a fit takes seconds for hundreds of videos.
#
# The per-tag "none of these" outcome survives by construction: a frame that
# clears no head clears no tag, and a tag needs positive frames to fire -- the
# same discipline the zero-shot suggester learned the hard way.
# --------------------------------------------------------------------------
TRAINED_HEADS_MIN_POS = 4       # fewer accepted videos than this: refuse to fit
TRAINED_HEADS_MIN_REJ = 4       # negatives matter; refuse to fit without them
TRAINED_HEADS_CUT = 0.5         # logistic cut for a frame to count as a hit
_trained_heads = {"npz": None, "heads": None}   # tag -> (w [1,768] torch, b)


def _trained_heads_path():
    # The profile's own folder, not the shared models dir: a head is fitted from
    # one person's decisions and must not be read as another's.
    return os.path.join(PROFILE_DIR, "%s_trained_heads.npz" % _model_slug())


def _load_trained_heads():
    """Read the stored heads once per process. Returns {tag: (w, b)} or {}."""
    import numpy as np
    if _trained_heads["heads"] is not None:
        return _trained_heads["heads"]
    out = {}
    path = _trained_heads_path()
    if os.path.exists(path):
        try:
            z = np.load(path)
            for name in z.files:
                if not name.startswith("head/") or not name.endswith("/w"):
                    continue
                tag = name[len("head/"):-2]
                w = z[name]
                b = float(z["head/%s/b" % tag])
                out[tag] = (w, b)
        except Exception:
            out = {}
    _trained_heads["heads"] = out
    return out


def _invalidate_trained_heads():
    _trained_heads["heads"] = None


# --------------------------------------------------------------------------
# Safe/NSFW correction head (Sep'26)
#
# The Safe/NSFW decision is a forced binary that the rest of the pipeline
# gates on (paired tags, auto-file, suggestion vocab), so it is NOT a tag --
# but the user's mark corrections were being recorded and never used. This
# head closes that loop: a SINGLE logistic head fit over the cached
# embeddings from the user's mark history (nsfw=positive, safe=negative),
# applied at scoring time as a NUDGE toward its opinion rather than a
# replacement of the calibrated zero-shot score. It lives in the same
# trained-heads npz under nsfw/* (never clobbering, never clobbered by, the
# per-tag head/<tag>/* entries).
# --------------------------------------------------------------------------
NSFW_CORRECTION_WEIGHT = 0.25    # how far the zero-shot score moves toward the head
_nsfw_correction = {"loaded": False, "head": None}   # (w [768] ndarray, b float)


def _load_nsfw_correction():
    """The Safe/NSFW correction head as (w, b), or None until fitted."""
    import numpy as np
    if _nsfw_correction["loaded"]:
        return _nsfw_correction["head"]
    head = None
    path = _trained_heads_path()
    if os.path.exists(path):
        try:
            z = np.load(path)
            if "nsfw/w" in z.files and "nsfw/b" in z.files:
                head = (z["nsfw/w"], float(z["nsfw/b"]))
        except Exception:
            head = None
    _nsfw_correction["loaded"] = True
    _nsfw_correction["head"] = head
    return head


def _invalidate_nsfw_correction():
    _nsfw_correction["loaded"] = False
    _nsfw_correction["head"] = None


def _nsfw_correction_scores(emb):
    """Per-frame correction-head probabilities for [B, 768] embeddings, or
    None until a head exists. Cheap: one dot product on already-computed
    vectors, no GPU trip beyond what scoring already paid for."""
    import numpy as np
    import torch
    head = _load_nsfw_correction()
    if head is None:
        return None
    w, b = head
    w_t = torch.from_numpy(np.ascontiguousarray(w)).to(emb.device)
    return torch.sigmoid(emb @ w_t + b)


def train_nsfw(req):
    """Fit ONE Safe/NSFW correction head from the user's mark corrections.

    Labels: {key: bool} (True = marked NSFW, False = marked Safe), frame
    hashes {key: [hash]} read from the cache exactly like train(). The head
    only fits once both classes clear the same 4/4 gate the tag heads use;
    below that the honest refusal is reported. Merged into the trained-heads
    npz under nsfw/* so it never erases (or is erased by) per-tag heads.
    """
    import numpy as np
    labels = req.get("labels") or {}
    videos = {}
    for key, hashes in (req.get("frameHashes") or {}).items():
        if key not in labels:
            continue
        acc, n = None, 0
        for h in hashes:
            vec = _cache_read(h)
            if vec is None:
                continue
            acc = vec if acc is None else [a + b for a, b in zip(acc, vec)]
            n += 1
        if acc is not None and n:
            videos[key] = [a / n for a in acc]

    if not videos:
        err(req, "no cached embeddings for the marked videos -- analyse them first")
        done(req, False)
        return

    keys = list(videos.keys())
    X = np.array([videos[k] for k in keys], dtype=np.float64)
    norms = np.linalg.norm(X, axis=1, keepdims=True)
    norms[norms == 0] = 1
    X = X / norms
    y = np.array([1.0 if labels[k] else 0.0 for k in keys], dtype=np.float64)
    pos = int((y == 1).sum()); neg = int((y == 0).sum())
    if pos < TRAINED_HEADS_MIN_POS or neg < TRAINED_HEADS_MIN_REJ:
        report(req, "result", fit={"fitted": False,
            "reason": "need %d+ NSFW and %d+ Safe marks (have %d/%d)"
                      % (TRAINED_HEADS_MIN_POS, TRAINED_HEADS_MIN_REJ, pos, neg)})
        done(req, True)
        return

    # deterministic per-video hold-out, same split rule as train()
    test_mask = np.zeros(len(keys), dtype=bool)
    for i in range(0, len(keys), 5):
        test_mask[i] = True
    train_mask = ~test_mask
    if train_mask.sum() < 4 or test_mask.sum() < 1:
        report(req, "result", fit={"fitted": False, "reason": "not enough held-out videos"})
        done(req, True)
        return

    w = np.zeros(X.shape[1]); b = 0.0
    lr, epochs, lam = 0.5, 300, 1e-3
    Xt, yt = X[train_mask], y[train_mask]
    for _ in range(epochs):
        p = 1 / (1 + np.exp(-(Xt @ w + b)))
        g = (Xt.T @ (p - yt)) / len(yt) + lam * w
        w -= lr * g
        b -= lr * float((p - yt).mean())
    yt_te = y[test_mask]
    p_te = 1 / (1 + np.exp(-(X[test_mask] @ w + b)))
    pred = (p_te >= TRAINED_HEADS_CUT).astype(np.float64)
    tp = float(((pred == 1) & (yt_te == 1)).sum()); fp = float(((pred == 1) & (yt_te == 0)).sum())
    fn = float(((pred == 0) & (yt_te == 1)).sum())
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0

    path = _trained_heads_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    merged = {}
    if os.path.exists(path):
        try:
            old = np.load(path)
            merged = {k: old[k] for k in old.files}
        except Exception:
            merged = {}
    merged["nsfw/w"] = w.astype(np.float32)
    merged["nsfw/b"] = np.float32(b)
    merged["nsfw/n"] = np.float32(len(keys))
    np.savez(path, **merged)
    _invalidate_nsfw_correction()
    report(req, "result", fit={"fitted": True, "videos": len(keys),
                               "held_out": int(test_mask.sum()),
                               "precision": round(prec, 3), "recall": round(rec, 3)})
    done(req, True)


def train(req):
    """Fit one logistic head per tag over the cached embeddings.

    Labels arrive as {tag: {path_or_key: bool}}; positives are videos the user
    accepted the tag for (or tagged outright), negatives the ones rejected.
    Every video's frames are read from the embedding cache by the hashes the
    analyse pass stored in analysis.json -- the app sends no pixels.

    A tag needs both classes (TRAINED_HEADS_MIN_*) to fit; the honest refusal
    is reported per tag rather than fitting a head on one example. Held-out
    metrics come from a per-video split: frames of one video never straddle
    the split, so no leakage.
    """
    import numpy as np
    labels = req.get("labels") or {}

    # collect: one mean-vector per video, read straight from the cache
    videos = {}        # key -> [768]
    for key, hashes in (req.get("frameHashes") or {}).items():
        acc, n = None, 0
        for h in hashes:
            vec = _cache_read(h)
            if vec is None:
                continue
            acc = vec if acc is None else [a + b for a, b in zip(acc, vec)]
            n += 1
        if acc is not None and n:
            videos[key] = [a / n for a in acc]

    if not videos:
        err(req, "no cached embeddings for the labelled videos -- analyse them first")
        done(req, False)
        return

    keys = list(videos.keys())
    X = np.array([videos[k] for k in keys], dtype=np.float64)
    norms = np.linalg.norm(X, axis=1, keepdims=True)
    norms[norms == 0] = 1
    X = X / norms

    # deterministic split: every 5th video held out (grouped by video, so no
    # frame leakage; stable order so refits are comparable)
    test_mask = np.zeros(len(keys), dtype=bool)
    for i in range(0, len(keys), 5):
        test_mask[i] = True
    train_mask = ~test_mask

    z = {}
    fit_out = []
    import torch
    for tag, per_video in labels.items():
        y = [per_video.get(k) for k in keys]
        idx = [i for i, v in enumerate(y) if v is not None]
        pos = [i for i in idx if y[i]]
        neg = [i for i in idx if not y[i]]
        if len(pos) < TRAINED_HEADS_MIN_POS or len(neg) < TRAINED_HEADS_MIN_REJ:
            fit_out.append({"tag": tag, "fitted": False,
                            "reason": "need %d+ accepted and %d+ rejected videos (have %d/%d)"
                                      % (TRAINED_HEADS_MIN_POS, TRAINED_HEADS_MIN_REJ, len(pos), len(neg))})
            continue
        tr = train_mask & np.isin(np.arange(len(keys)), idx)
        te = test_mask & np.isin(np.arange(len(keys)), idx)
        if tr.sum() < 4 or te.sum() < 1:
            fit_out.append({"tag": tag, "fitted": False, "reason": "not enough held-out videos"})
            continue
        w = np.zeros(X.shape[1]); b = 0.0
        lr, epochs, lam = 0.5, 300, 1e-3
        Xt, yt = X[tr], (np.array([y[i] for i in range(len(keys)) if tr[i]], dtype=np.float64))
        for _ in range(epochs):
            p = 1 / (1 + np.exp(-(Xt @ w + b)))
            g = (Xt.T @ (p - yt)) / len(yt) + lam * w
            w -= lr * g
            b -= lr * float((p - yt).mean())
        # held-out honesty: precision/recall on videos the fit never saw
        yt_te = np.array([y[i] for i in range(len(keys)) if te[i]], dtype=np.float64)
        p_te = 1 / (1 + np.exp(-(X[te] @ w + b)))
        pred = (p_te >= TRAINED_HEADS_CUT).astype(np.float64)
        tp = float(((pred == 1) & (yt_te == 1)).sum()); fp = float(((pred == 1) & (yt_te == 0)).sum())
        fn = float(((pred == 0) & (yt_te == 1)).sum())
        prec = tp / (tp + fp) if tp + fp else 0.0
        rec = tp / (tp + fn) if tp + fn else 0.0
        z["head/%s/w" % tag] = w.astype(np.float32)
        z["head/%s/b" % tag] = np.float32(b)
        z["head/%s/n" % tag] = np.float32(len(idx))
        fit_out.append({"tag": tag, "fitted": True, "videos": len(idx),
                        "held_out": int(te.sum()),
                        "precision": round(prec, 3), "recall": round(rec, 3)})
    if z:
        path = _trained_heads_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # MERGE, never replace: two training scopes exist (a playlist's Train
        # button and Tag Profiles' whole-library pass) and one must not erase
        # the other's heads. A tag fitted here updates its own w/b/n entries
        # and leaves every other tag's entries untouched.
        merged = {}
        if os.path.exists(path):
            try:
                old = np.load(path)
                merged = {k: old[k] for k in old.files}
            except Exception:
                merged = {}
        merged.update(z)
        np.savez(path, **merged)
        _invalidate_trained_heads()
    report(req, "result", fits=fit_out)
    done(req, True)


def _min_frames_for(n_frames):
    """How many supporting frames a tag needs, given how many exist.

    Short clips get one frame's worth of benefit of the doubt; longer ones must
    show the subject persisting, which is what kills chance alignments.
    """
    if n_frames <= 3:
        return 1
    if n_frames <= 10:
        return 2
    return 3

_suggest_cache = {"text": None}   # tag -> encoding block, keyed by the paired flag

# Library-tag prototypes (Phase D, "suggest from YOUR tags").
#
# A user tag like "Kite" or "Bench" is not in the CLIP phrase vocabulary, so the
# zero-shot pass can never offer it — which also meant it could never be
# rejected, and a head needs rejections. The fix: prototype each user tag by
# the AVERAGE embedding of the videos already carrying it (the app sends the
# frame hashes; the vectors come from the same cache as everything else, no
# GPU). A candidate video is then scored against the prototype, but against
# a BASELINE too — the library's own average video — because in a library of
# similar videos everything is close to everything (measured: untagged videos
# average +0.60 cosine to a Kite prototype). What discriminates is the MARGIN:
# videos the user tagged Kite sit +0.10..+0.22 ABOVE the library mean; videos
# they did not tag Kite sit BELOW it. So a tag fires only when it clears the
# library baseline by LIBRARY_TAG_MARGIN on enough frames.
LIBRARY_TAG_MARGIN = 0.10
LIBRARY_TAG_MIN_VIDEOS = 2      # fewer tagged videos: prototype is one video's noise
_library_mean = None            # lazy: mean cached embedding of the whole library


def _library_baseline():
    """Mean of every cached embedding, so user-tag margins are measured
    against \"the typical video in this library\" rather than against zero
    (where everything scores ~0.6+ and nothing separates)."""
    global _library_mean
    if _library_mean is not None:
        return _library_mean
    import numpy as np
    root = os.path.join(EMBED_CACHE, _model_slug())
    acc, n = None, 0
    if os.path.isdir(root):
        for sub in os.listdir(root):
            d = os.path.join(root, sub)
            if not os.path.isdir(d):
                continue
            for name in os.listdir(d):
                if not name.endswith(".f32"):
                    continue
                vec = _cache_read(name[:-4])
                if vec is None:
                    continue
                if acc is None:
                    acc = np.asarray(vec, dtype=np.float64)
                else:
                    acc += vec
                n += 1
    if acc is None or n == 0:
        _library_mean = np.zeros(1)   # degenerate; margins against it stay ~0
    else:
        m = acc / n
        norm = np.linalg.norm(m)
        _library_mean = m / norm if norm else m
    return _library_mean


def _library_prototypes(req):
    """Mean embedding per user tag, from the frame hashes the app sent.

    The app sends {tag: [videoKey: [frameHash...]]} for the videos already
    tagged with that name; each video is averaged to one vector first (the
    same per-video normalisation train() uses), then the tag is the mean of
    its videos' vectors. Returns {tag: unit vector} for tags with enough
    distinct tagged videos, or {} when the request carried none."""
    import numpy as np
    library = req.get("libraryTags") or {}
    if not library:
        return {}
    out = {}
    for tag, videos in library.items():
        if not isinstance(videos, dict):
            continue
        if tag in PAIRED_TAG_NAMES:
            continue   # the paired tags have their own head-to-head machinery below
        if len(videos) < LIBRARY_TAG_MIN_VIDEOS:
            continue
        per_video = []
        for key, hashes in videos.items():
            if not hashes:
                continue
            acc, n = None, 0
            for h in hashes:
                vec = _cache_read(h)
                if vec is None:
                    continue
                acc = vec if acc is None else [a + b for a, b in zip(acc, vec)]
                n += 1
            if acc is not None and n:
                per_video.append(np.asarray(acc, dtype=np.float64) / n)
        if len(per_video) < LIBRARY_TAG_MIN_VIDEOS:
            continue
        prot = np.mean(per_video, axis=0)
        norm = np.linalg.norm(prot)
        if norm:
            out[tag] = prot / norm
    return out


def _score_library_tags(emb, prototypes, min_frames):
    """Suggest user tags whose prototype the frames beat the library baseline
    by LIBRARY_TAG_MARGIN on at least min_frames frames.

    Returns list of {tag, confidence, frames, source:\"library\"} — same shape
    as the zero-shot and trained candidates, so the caller merges them all.
    """
    import numpy as np
    if not prototypes:
        return []
    base = _library_baseline()
    if base.ndim != 1 or base.shape[0] != emb.shape[1]:
        return []
    E = emb.detach().cpu().numpy().astype(np.float64)          # [F, 768]
    out = []
    for tag, prot in prototypes.items():
        # margin = (prot - baseline) · frame  == prot·f - baseline·f
        margin = E @ (prot - base)
        n_hits = int((margin >= LIBRARY_TAG_MARGIN).sum())
        if n_hits < min_frames:
            continue
        out.append({"tag": tag,
                    "confidence": round(float(margin.max()), 4),
                    "frames": n_hits,
                    "source": "library"})
    out.sort(key=lambda r: r["confidence"], reverse=True)
    return out


def tag_candidates(req):
    """Rank the WHOLE analysed library against one user tag's prototype.

    The tag-review playlist asks this once per tag: \"which videos, anywhere,
    look like the ones I tagged Kite?\" The app sends the tagged videos' frame
    hashes (they ARE the prototype) and every analysed video it does NOT
    already carry the tag with (the candidate pool). Pure cache reads — no
    ffmpeg, no model, no GPU — so it is cheap enough to run on every toggle.

    Returns the pool's videos ranked by how far their mean embedding clears
    the library baseline relative to the tag prototype; entries below
    LIBRARY_TAG_MARGIN are dropped (they are the \"everything looks like
    everything\" noise).
    """
    import numpy as np
    tagged = req.get("tagged") or {}        # {key: [frame hashes]} — the prototype
    pool = req.get("pool") or {}            # {key: [frame hashes]} — the candidates
    limit = int(req.get("limit") or 25)

    def video_means(mapping):
        """One mean vector per video (unit), skipping videos with no vectors."""
        out = []
        for key, hashes in mapping.items():
            if not hashes:
                continue
            acc, n = None, 0
            for h in hashes:
                vec = _cache_read(h)
                if vec is None:
                    continue
                acc = vec if acc is None else [a + b for a, b in zip(acc, vec)]
                n += 1
            if acc is not None and n:
                v = np.asarray(acc, dtype=np.float64) / n
                norm = np.linalg.norm(v)
                if norm:
                    out.append(v / norm)
        return out

    proto_vecs = video_means(tagged)
    if len(proto_vecs) < LIBRARY_TAG_MIN_VIDEOS:
        report(req, "result", tag=req.get("tag"), candidates=[],
               reason="need %d+ tagged videos to form a prototype (have %d)"
                      % (LIBRARY_TAG_MIN_VIDEOS, len(proto_vecs)))
        done(req, True)
        return
    prot = np.mean(proto_vecs, axis=0)
    norm = np.linalg.norm(prot)
    if not norm:
        report(req, "result", tag=req.get("tag"), candidates=[], reason="empty prototype")
        done(req, True)
        return
    prot = prot / norm
    # Library baseline from THIS request: the tagged videos plus the pool ARE
    # every analysed video, so the mean of their per-video means is the
    # "typical video here" — the same per-video baseline the +0.10 margin was
    # calibrated against. (A raw frame-mean would let long videos dominate.)
    lib_vecs = video_means({**tagged, **pool})
    if len(lib_vecs) < 3:
        report(req, "result", tag=req.get("tag"), candidates=[], reason="no library baseline")
        done(req, True)
        return
    lib = np.mean(lib_vecs, axis=0)
    lnorm = np.linalg.norm(lib)
    if not lnorm:
        report(req, "result", tag=req.get("tag"), candidates=[], reason="no library baseline")
        done(req, True)
        return
    lib = lib / lnorm
    delta = prot - lib
    scored = []
    unseen = 0
    for key, hashes in pool.items():
        if not hashes:
            unseen += 1
            continue
        acc, n = None, 0
        for h in hashes:
            vec = _cache_read(h)
            if vec is None:
                continue
            acc = vec if acc is None else [a + b for a, b in zip(acc, vec)]
            n += 1
        if acc is None or n == 0:
            unseen += 1
            continue
        v = np.asarray(acc, dtype=np.float64) / n
        vn = np.linalg.norm(v)
        if not vn:
            unseen += 1
            continue
        margin = float(delta @ (v / vn))
        if margin >= LIBRARY_TAG_MARGIN:
            scored.append({"key": key, "score": round(margin, 4)})
    scored.sort(key=lambda r: r["score"], reverse=True)
    report(req, "result", tag=req.get("tag"),
           candidates=scored[:limit], unseen_pool=unseen)
    done(req, True)


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def report(req, kind, **kw):
    line = {"id": req.get("id"), "type": kind}
    line.update(kw)
    emit(line)


def done(req, ok, **kw):
    line = {"id": req.get("id"), "type": "done", "ok": ok}
    line.update(kw)
    emit(line)


def err(req, message):
    emit({"id": req.get("id"), "type": "error", "message": message})


# --------------------------------------------------------------------------
# Model state (loaded lazily, once per process)
# --------------------------------------------------------------------------

_model = None
_processor = None
_text_cache = {}      # frozen prompt text -> tensor kept on CPU in fp32
_device = None
_embed_dim = EMBED_DIM   # registry fallback; set from the real tensor at load
_active_workdir = None   # the current video's temp dir, for EOF cleanup


def ensure_model(req, download_hint=None):
    """Load the CLIP model and precompute the frozen text features.

    First call downloads ~1.7 GB of public weights into the Hugging Face
    cache; transformers prints its progress bar to stderr, which the app
    relays into the footer status line.
    """
    global _model, _processor, _device, _embed_dim
    if _model is not None:
        return
    report(req, "status", stage="model", detail="loading %s" % MODEL_ID)
    import torch
    from transformers import CLIPModel, CLIPProcessor
    _device = torch.device(DEVICE if torch.backends.mps.is_available() else "cpu")
    _model = CLIPModel.from_pretrained(MODEL_ID).half().to(_device).eval()
    _processor = CLIPProcessor.from_pretrained(MODEL_ID)
    with torch.no_grad():
        all_prompts = NSFW_POOL + NEUTRAL_POOL
        text = _processor.tokenizer(all_prompts, padding=True, return_tensors="pt")
        feats = _model.get_text_features(**text.to(_device)).float().cpu()
    _embed_dim = int(feats.shape[1])   # the truth, whatever model is loaded
    feats = feats / feats.norm(dim=-1, keepdim=True)
    _text_cache["all"] = feats
    _text_cache["nsfw_n"] = len(NSFW_POOL)
    report(req, "status", stage="model",
           detail="ready: %s · %s · embed %d" % (_device.type, MODEL_ID, _embed_dim))


# --------------------------------------------------------------------------
# Frame sampling
# --------------------------------------------------------------------------

def _sample_interval(duration):
    """Frames-per-second interval, clamped so short clips still yield frames.

    ``fps=1/N`` emits a frame only when a frame time crosses each N-second
    boundary. A clip shorter than N seconds can therefore produce ZERO frames
    — the failure behind the mystery "analyse failed" rows for ~2 s videos.
    Clamping the interval to a fraction of the clip's own length keeps the
    uniform cadence for normal videos (5 s) while guaranteeing roughly
    SAMPLE_TARGET_SHORT frames even for a 2 s clip.
    """
    if duration is None or duration <= 0:
        return SAMPLE_INTERVAL_S
    return min(SAMPLE_INTERVAL_S, max(duration / SAMPLE_TARGET_SHORT, 0.2))


def _probe_duration(video_path):
    """Seconds of video, or None when ffprobe cannot say. Best-effort: the
    sampling clamp treats an unknown duration as a normal-length video."""
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", video_path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        return float(out.stdout.strip())
    except Exception:
        return None


def sample_frames(req, video_path, workdir):
    """Uniformly sample up to MAX_FRAMES frames with ffmpeg into workdir.

    Returns the sorted list of jpg paths. The fps filter yields one frame per
    interval; when that exceeds the cap we keep an evenly spaced subset, so a
    two-hour video and a ten-minute one cost the same.
    """
    global _ffmpeg_proc
    report(req, "status", stage="sampling", detail=os.path.basename(video_path))
    pattern = os.path.join(workdir, "f_%06d.jpg")
    interval = _sample_interval(_probe_duration(video_path))
    vf = "fps=1/%s,scale='min(%d,iw)':-2" % (interval, SAMPLE_SHORT_SIDE)
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-an", "-i", video_path,
           "-vf", vf, "-q:v", "3", pattern]
    _ffmpeg_proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE)
    _ffmpeg_proc.wait()
    _ffmpeg_proc = None
    if _cancel.is_set():
        return [], []   # same shape as the happy return, so callers unpack
    frames = sorted(f for f in os.listdir(workdir) if f.startswith("f_"))
    if not frames:
        raise RuntimeError("ffmpeg produced no frames (corrupt or unsupported file?)")
    frames = [os.path.join(workdir, f) for f in frames]
    indices = list(range(len(frames)))
    if len(indices) > MAX_FRAMES:
        step = math.ceil(len(indices) / MAX_FRAMES)
        indices = indices[::step][:MAX_FRAMES]
    return [frames[i] for i in indices], indices


# --------------------------------------------------------------------------
# Scoring
# --------------------------------------------------------------------------

def _model_slug():
    """A filesystem-safe name for the current embedding space."""
    return MODEL_ID.replace("/", "_")


def _frame_hash(path):
    """Content hash of one sampled frame.

    Keyed on the frame's own bytes, not on the video path or the frame index:
    the same picture embeds to the same vector no matter which video it came
    from or where that video now lives, so a moved or renamed library keeps
    every vector it has already paid for.
    """
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:32]


def _cache_path(frame_hash):
    # Two-level fan-out: a flat directory of a million files is slow to list
    # on any filesystem, and hopeless over SMB.
    sub = os.path.join(EMBED_CACHE, _model_slug(), frame_hash[:2])
    return os.path.join(sub, frame_hash + ".f32")


def _cache_read(frame_hash):
    """The stored vector for this frame, or None. Never raises: a corrupt or
    truncated file is treated as a miss and simply re-embedded."""
    if not EMBED_CACHE_ENABLED:
        return None
    path = _cache_path(frame_hash)
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    if len(raw) % 4 or not raw:
        return None
    vec = list(struct.unpack("<%df" % (len(raw) // 4), raw))
    if _embed_dim and len(vec) != _embed_dim:
        return None          # a different model wrote this; ignore it
    return vec


def _cache_write(frame_hash, vec):
    """Store one vector. Best-effort: a full disk must not fail an analysis.

    Written to a temp name and renamed, so a crash mid-write can never leave a
    half-vector that a later run would read back as real data.
    """
    if not EMBED_CACHE_ENABLED:
        return
    path = _cache_path(frame_hash)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(struct.pack("<%df" % len(vec), *vec))
        os.replace(tmp, path)
    except OSError:
        pass


# --------------------------------------------------------------------------
# Face recognition (Phase E)
#
# A separate pipeline from CLIP, because CLIP embeddings cannot tell two
# people apart — face *identity* needs a face model. Detection (YuNet) and
# embedding (SFace) are both ONNX models run through cv2 + onnxruntime, on
# CPU: cheap enough to run over the same sampled frames suggest_tags already
# produces, so nothing here re-samples or re-embeds.
#
# Storage is its own store, never mixed with CLIP frame vectors:
#   faces/<hash>.f32      — one 128-dim SFace vector per detected face crop,
#                           keyed by the crop's content hash (same content-
#                           addressed idea as the frame cache).
#   faces.json            — the person registry: {name: [face_hash, ...]}.
#                           The profile's own, under profiles/<profile>/, because
#                           which name is bound to a face is a judgement.
# A person NAME is a tag the user has bound to face vectors. Until a name is
# bound it cannot be suggested by the face path — face identity is never a
# CLIP guess. Person names are excluded from the CLIP library-prototype path
# (see _library_prototypes) so the two models never compete for one tag.
# --------------------------------------------------------------------------
FACE_DIR = os.path.join(SUPPORT_DIR, "faces")
# The crops are content-addressed — the same face in the same video — so they
# stay shared. Which NAME is bound to a face is a judgement, so the registry is
# the profile's own.
FACE_REGISTRY = os.path.join(PROFILE_DIR, "faces.json")
FACE_DETECT_MODEL = os.path.join(
    SUPPORT_DIR, "models", "face_detection_yunet_2023mar.onnx")
FACE_RECOG_MODEL = os.path.join(
    SUPPORT_DIR, "models", "face_recognition_sface_2021dec.onnx")
FACE_DIM = 128
# Matching threshold for "is this face one of my named people?" This is a
# SUGGESTION context, not security: recall beats precision. A false positive
# costs one ⌥click-reject; a false negative makes the user re-type the name on
# every video (the exact "not friendly" complaint). SFace's canonical same-id
# threshold is 0.363, but the user's own cross-video faces measured 0.326 peak,
# so we sit at 0.30 — still well above the different-person floor (~0.1–0.2).
FACE_MATCH_COSINE = 0.30
FACE_CLUSTER_COSINE = 0.30   # merge faces into one person at this cosine
FACE_MAX_FRAMES = 40         # frames scanned per suggest (strided across the video)
FACE_MAX_FACES = 48          # hard cap on distinct faces embedded (safety net only)
FACE_MAX_CHOICES = 5         # biggest faces shown when the user adds a person
FACE_CHOICE_LIMIT = 48       # similar faces offered in the pick-a-picture chooser

_face_models = {"det": None, "rec": None}


def _face_models_loaded():
    """Lazy-load YuNet + SFace once per process. Returns (detector, recogniser)
    or (None, None) when the ONNX weights are missing (face suggestion then
    degrades to absent, never failing the suggest call)."""
    global _face_models
    if _face_models["det"] is not None:
        return _face_models["det"], _face_models["rec"]
    if not (os.path.exists(FACE_DETECT_MODEL) and os.path.exists(FACE_RECOG_MODEL)):
        return None, None
    try:
        import cv2
        det = cv2.FaceDetectorYN.create(FACE_DETECT_MODEL, "", (320, 320),
                                        0.7, 0.3, 5000)
        rec = cv2.FaceRecognizerSF.create(FACE_RECOG_MODEL, "")
    except Exception:
        return None, None
    _face_models["det"], _face_models["rec"] = det, rec
    return det, rec


def _face_cache_path(face_hash):
    sub = os.path.join(FACE_DIR, face_hash[:2])
    return os.path.join(sub, face_hash + ".f32")


def _face_cache_read(face_hash):
    try:
        with open(_face_cache_path(face_hash), "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    if len(raw) % 4 or not raw:
        return None
    vec = list(struct.unpack("<%df" % (len(raw) // 4), raw))
    if len(vec) != FACE_DIM:
        return None
    return vec


def _face_cache_write(face_hash, vec):
    try:
        os.makedirs(os.path.dirname(_face_cache_path(face_hash)), exist_ok=True)
        tmp = _face_cache_path(face_hash) + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(struct.pack("<%df" % len(vec), *vec))
        os.replace(tmp, _face_cache_path(face_hash))
    except OSError:
        pass


def _face_thumb_path(face_hash):
    sub = os.path.join(FACE_DIR, face_hash[:2])
    return os.path.join(sub, face_hash + ".jpg")


def _face_thumb_write(face_hash, bgr):
    """Persist a small JPEG of the aligned crop, so a People view can show the
    face without re-decoding the source video. Best-effort, like the vector."""
    try:
        import cv2
        os.makedirs(os.path.dirname(_face_thumb_path(face_hash)), exist_ok=True)
        ok, buf = cv2.imencode(".jpg", bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
        if ok:
            tmp = _face_thumb_path(face_hash) + ".tmp"
            with open(tmp, "wb") as fh:
                fh.write(buf.tobytes())
            os.replace(tmp, _face_thumb_path(face_hash))
    except Exception:
        pass


def _face_thumb_exists(face_hash):
    return os.path.exists(_face_thumb_path(face_hash))


def _faces_in_frame(img_bgr):
    """Detect faces in one BGR frame, return [(hash, unit_vector), ...].

    Every face is PERSISTED here — vector and thumbnail — so a later cluster
    pass can group the whole library's faces without re-decoding video. The
    hash is the content hash of the aligned 112x112 crop; the vector is the
    SFace embedding unit-normalised so cosine similarity is a plain dot
    product. Empty list when no faces (or models unavailable)."""
    det, rec = _face_models_loaded()
    if det is None or rec is None:
        return []
    import cv2
    det.setInputSize((img_bgr.shape[1], img_bgr.shape[0]))
    _ok, faces = det.detect(img_bgr)
    if faces is None:
        return []
    out = []
    for f in faces:
        try:
            aligned = rec.alignCrop(img_bgr, f)
        except Exception:
            continue
        if aligned is None or aligned.size == 0:
            continue
        vec = rec.feature(aligned)[0].astype("float32")
        n = float(__import__("numpy").linalg.norm(vec))
        if not n:
            continue
        vec = (vec / n).tolist()
        h = hashlib.sha256(aligned.tobytes()).hexdigest()[:32]
        # Persist the identity evidence (idempotent: same crop -> same hash).
        _face_cache_write(h, vec)
        _face_thumb_write(h, aligned)
        # Pixel area of the detection box — lets the add-person chooser rank
        # faces by prominence (the person on camera, not background extras).
        area = float(f[2]) * float(f[3])
        out.append((h, vec, area))
    return out


def _load_face_registry():
    """{name: [face_hash, ...]} from faces.json, or {} when absent/corrupt."""
    try:
        with open(FACE_REGISTRY, "r") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return {}
        return {k: v for k, v in data.items() if isinstance(v, list)}
    except (OSError, ValueError):
        return {}


def _save_face_registry(registry):
    try:
        os.makedirs(os.path.dirname(FACE_REGISTRY), exist_ok=True)
        tmp = FACE_REGISTRY + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(registry, fh)
        os.replace(tmp, FACE_REGISTRY)
    except OSError:
        pass


def _person_names():
    """Every name bound to face vectors."""
    return set(_load_face_registry().keys())


def _face_matches(face_vectors, registry):
    """Best person match per detected face, above the cosine threshold.

    Returns a dict {name: (best_cosine, n_faces_hit)} for names whose ANY
    stored vector matches ANY detected face. Cosines are computed against the
    cached vectors behind each stored hash (names whose vectors have since
    been pruned simply stop matching until re-bound)."""
    import numpy as np
    if not face_vectors or not registry:
        return {}
    hits = {}
    for name, hashes in registry.items():
        best = -1.0
        for h in hashes:
            stored = _face_cache_read(h)
            if stored is None:
                continue
            sv = np.asarray(stored, dtype=np.float64)
            for fv in face_vectors:
                c = float(np.dot(sv, np.asarray(fv, dtype=np.float64)))
                if c > best:
                    best = c
        if best >= FACE_MATCH_COSINE:
            hits[name] = best
    return hits


def name_face(req):
    """Bind a video's faces to a person name (the "name this person once" step).

    Samples the video, detects + embeds its faces, stores the vectors in the
    face cache, and appends their hashes to the registry under `name`. From
    then on, any video whose faces match those vectors suggests that name.
    The name is stored verbatim (a tag string), so an existing name-tag like
    "Quincy Hale" binds directly to faces.
    """
    name = (req.get("name") or "").strip()
    path = req.get("path")
    if not name or not path or not os.path.exists(path):
        err(req, "name_face needs a non-empty name and an existing video path")
        done(req, False)
        return
    import cv2
    det, rec = _face_models_loaded()
    if det is None or rec is None:
        err(req, "face models unavailable (YuNet/SFace weights missing)")
        done(req, False)
        return
    workdir = tempfile.mkdtemp(prefix="fvp-face-")
    try:
        frames, _indices = sample_frames(req, path, workdir)
        if not frames:
            err(req, "could not read frames from this video")
            done(req, False)
            return
        hashes = []
        scanned = 0
        for fp in frames:
            img = cv2.imread(fp)
            if img is None:
                continue
            scanned += 1
            for h, vec, _area in _faces_in_frame(img):
                _face_cache_write(h, vec)
                if h not in hashes:
                    hashes.append(h)
            if len(hashes) >= FACE_MAX_FACES or scanned >= FACE_MAX_FRAMES:
                break
        if not hashes:
            report(req, "result", name=name, bound=0,
                   detail="no faces detected in this video")
            done(req, True)
            return
        registry = _load_face_registry()
        existing = set(registry.get(name, []))
        added = [h for h in hashes if h not in existing]
        registry.setdefault(name, [])
        registry[name].extend(added)
        _save_face_registry(registry)
        report(req, "result", name=name, bound=len(added),
               total_faces=len(hashes))
        done(req, True)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _all_face_hashes():
    """Every face vector hash on disk, by walking the faces/ cache. Small
    directory (content-addressed, deduped), so a plain walk is fine."""
    out = []
    try:
        for root, _dirs, files in os.walk(FACE_DIR):
            for name in files:
                if name.endswith(".f32"):
                    out.append(name[:-4])
    except OSError:
        pass
    return out


def face_clusters(req):
    """Group every UNNAMED face into identity clusters by cosine similarity.

    The standalone heart of face recognition: reads the persisted face
    vectors, greedily merges faces above FACE_CLUSTER_COSINE into person
    clusters, and returns each cluster's size and a representative thumbnail
    hash. Faces already bound to a name (in the registry) are excluded — the
    user has already identified those people. Nothing here needs a video, a
    tag, or CLIP; it is pure face identity.
    """
    import numpy as np
    registry = _load_face_registry()
    named = set()
    for hs in registry.values():
        named.update(hs)
    unnamed = [h for h in _all_face_hashes() if h not in named]
    if not unnamed:
        report(req, "result", clusters=[])
        done(req, True)
        return

    clusters = []   # [{centroid: np[128], members: [hash]}]
    for h in unnamed:
        v = _face_cache_read(h)
        if v is None:
            continue
        v = np.asarray(v, dtype=np.float64)
        best = None
        for c in clusters:
            sim = float(np.dot(v, c["centroid"]))
            if sim >= FACE_CLUSTER_COSINE and (best is None or sim > best[0]):
                best = (sim, c)
        if best is None:
            clusters.append({"centroid": v, "members": [h]})
        else:
            c = best[1]
            n = len(c["members"])
            c["centroid"] = (c["centroid"] * n + v) / (n + 1)
            c["members"].append(h)

    out = []
    for c in clusters:
        rep = None
        for h in c["members"]:
            if _face_thumb_exists(h):
                rep = h
                break
        if rep is None:
            rep = c["members"][0]
        out.append({"representative": rep, "faces": len(c["members"]),
                    "hashes": c["members"]})
    out.sort(key=lambda c: -c["faces"])
    report(req, "result", clusters=out)
    done(req, True)


def face_people(req):
    """Named people and their face counts, for the People view's 'named' side."""
    registry = _load_face_registry()
    out = []
    for name, hashes in registry.items():
        rep = None
        for h in hashes:
            if _face_thumb_exists(h):
                rep = h
                break
        if rep is None and hashes:
            rep = hashes[0]
        out.append({"name": name, "faces": len(hashes), "representative": rep})
    out.sort(key=lambda p: p["name"].casefold())
    report(req, "result", people=out)
    done(req, True)


def name_cluster(req):
    """Bind a whole identity cluster to a name.

    The app resolves which videos a cluster covers (it owns the face→video
    mapping), then calls this to record name → face hashes so future suggest
    calls recognise the person. Merge, never replace: naming one cluster must
    not detach faces the user already bound under the same name.
    """
    name = (req.get("name") or "").strip()
    hashes = req.get("hashes") or []
    if not name or not hashes:
        err(req, "name_cluster needs a name and face hashes")
        done(req, False)
        return
    registry = _load_face_registry()
    existing = set(registry.get(name, []))
    added = [h for h in hashes if h not in existing]
    registry.setdefault(name, [])
    registry[name].extend(added)
    _save_face_registry(registry)
    report(req, "result", name=name, bound=len(added))
    done(req, True)


def set_photo(req):
    """Give a named person a portrait photo as their thumbnail.

    The user picks a clear picture of the person; the biggest face in it is
    detected, embedded and persisted (idempotent), then PREPENDED to the
    person's face list. The registry order picks the thumbnail, so the photo
    face becomes the representative shown in the People rows and chips — and
    because it is also a real SFace vector of the same identity, it joins the
    matcher and can only help recognition. Best-effort: no face detected
    reports faces=0 and leaves the registry untouched.
    """
    name = (req.get("name") or "").strip()
    path = req.get("path")
    if not name or not path or not os.path.exists(path):
        err(req, "set_photo needs a person name and an existing image path")
        done(req, False)
        return
    ext = str(path).lower()
    if not ext.endswith((".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tiff")):
        err(req, "set_photo needs an image file")
        done(req, False)
        return
    import cv2
    img = cv2.imread(path)
    if img is None:
        err(req, "could not read image %r" % path)
        done(req, False)
        return
    # Biggest face by pixel area = the person in the portrait. A photo is a
    # single frame, so no stride/dedupe machinery is needed.
    best = None
    for h, vec, area in _faces_in_frame(img):
        if best is None or area > best[2]:
            best = (h, vec, area)
    if best is None:
        report(req, "result", name=name, faces=0, photo=None)
        done(req, True)
        return
    h, _vec, _area = best
    registry = _load_face_registry()
    victims = [k for k in registry if k.casefold() == name.casefold()]
    key = victims[0] if victims else name
    existing = set(registry.get(key, []))
    if h not in existing:
        # Front of the list -> first candidate for the representative.
        registry[key] = [h] + registry.get(key, [])
        _save_face_registry(registry)
    report(req, "result", name=key, faces=1, photo=h)
    done(req, True)


def similar_faces(req):
    """Rank every face the system has cached by similarity to a person.

    For the "choose a picture" flow: the user already has a person, and the
    app can show the faces the system has SEEN across the library that look
    most like that person — at every angle and lighting, straight out of the
    face cache (vector + thumbnail), no re-decoding. Score = best cosine over
    the person's stored vectors; the person's own faces naturally lead the
    list. Returns up to FACE_CHOICE_LIMIT hashes, best first.
    """
    name = (req.get("name") or "").strip()
    if not name:
        err(req, "similar_faces needs a name")
        done(req, False)
        return
    import numpy as np
    registry = _load_face_registry()
    victims = [k for k in registry if k.casefold() == name.casefold()]
    key = victims[0] if victims else name
    own = set(registry.get(key, []))
    refs = []
    for h in own:
        v = _face_cache_read(h)
        if v is not None:
            refs.append(np.asarray(v, dtype=np.float32))
    if not refs:
        report(req, "result", name=name, faces=[], total=0)
        done(req, True)
        return
    # Enumerate the whole cache: faces/<xx>/<hash>.f32
    import glob
    scored = []
    for fp in glob.glob(os.path.join(FACE_DIR, "*", "*.f32")):
        h = os.path.splitext(os.path.basename(fp))[0]
        v = _face_cache_read(h)
        if v is None:
            continue
        v = np.asarray(v, dtype=np.float32)
        sim = max(float(np.dot(v, r)) for r in refs)
        scored.append((sim, h))
    scored.sort(key=lambda t: -t[0])
    chosen = [h for _s, h in scored[:FACE_CHOICE_LIMIT] if h not in own]
    report(req, "result", name=name, faces=chosen, total=len(scored))
    done(req, True)


def set_representative(req):
    """Make an existing cached face this person's representative thumbnail.

    The registry order decides the thumbnail, so PREPENDING the chosen hash
    makes it what the People rows and chips show — and since it is a real
    SFace vector of the person, it joins the matcher too. Unlike set_photo no
    image decoding happens: the face already lives in the cache (must still
    have its thumbnail, or the pick would show a blank circle).
    """
    name = (req.get("name") or "").strip()
    h = (req.get("hash") or "").strip()
    if not name or not h:
        err(req, "set_representative needs a name and a face hash")
        done(req, False)
        return
    if not _face_thumb_exists(h):
        err(req, "that face has no thumbnail on disk")
        done(req, False)
        return
    registry = _load_face_registry()
    victims = [k for k in registry if k.casefold() == name.casefold()]
    key = victims[0] if victims else name
    existing = set(registry.get(key, []))
    if h not in existing:
        registry[key] = [h] + registry.get(key, [])
        _save_face_registry(registry)
    report(req, "result", name=key, photo=h)
    done(req, True)


def forget_person(req):
    """Remove a person from the face registry entirely.

    The user's escape hatch for a wrong or junk identity (a mis-named face, a
    placeholder like "unknown" left over from testing). Only the name→face
    binding is dropped — the cached face vectors/thumbnails stay, so the face
    can be bound to the right person later. Tag removal is the app's job; the
    engine owns the registry only.
    """
    name = (req.get("name") or "").strip()
    if not name:
        err(req, "forget_person needs a name")
        done(req, False)
        return
    registry = _load_face_registry()
    # Case-insensitive so the app never has to match the stored spelling.
    victims = [k for k in registry if k.casefold() == name.casefold()]
    removed = 0
    for k in victims:
        removed += len(registry.pop(k, []))
    if victims:
        _save_face_registry(registry)
    report(req, "result", name=name, removed=removed, found=bool(victims))
    done(req, True)


def face_index(req):
    """Detect + persist faces across a batch of videos.

    Button-triggered only (the app's People view). For each existing path,
    sample frames with ffmpeg, detect + embed faces (YuNet/SFace, no CLIP —
    the standalone face module), and record which faces came from which video.
    Returns {path: [face_hash...]} so the app can build its face→video index,
    which is what turns "name this cluster" into "tag these videos".
    """
    global _busy_job
    import cv2
    det, rec = _face_models_loaded()
    if det is None or rec is None:
        err(req, "face models unavailable (YuNet/SFace weights missing)")
        done(req, False)
        return
    paths = [p for p in (req.get("paths") or []) if p and os.path.exists(p)]
    if not paths:
        err(req, "face_index needs at least one existing video path")
        done(req, False)
        _cancel.clear()
        _busy.clear()
        return
    result = {}
    try:
        for i, path in enumerate(paths):
            if _cancel.is_set():
                break
            report(req, "status", stage="faces",
                   detail="%d/%d %s" % (i + 1, len(paths), os.path.basename(path)))
            workdir = tempfile.mkdtemp(prefix="fvp-faceidx-")
            try:
                frames, _indices = sample_frames(req, path, workdir)
                hashes = []
                seen = set()
                step = max(1, math.ceil(len(frames) / FACE_MAX_FRAMES))
                for fp in frames[::step]:
                    img = cv2.imread(fp)
                    if img is None:
                        continue
                    for h, _vec, _area in _faces_in_frame(img):
                        if h not in seen:
                            seen.add(h)
                            hashes.append(h)
                    if len(hashes) >= FACE_MAX_FACES:
                        break
                result[path] = hashes
            except Exception:
                result[path] = []
            finally:
                shutil.rmtree(workdir, ignore_errors=True)
        report(req, "result", videos=result)
        done(req, True)
    except Exception:
        emit({"id": req.get("id"), "type": "error",
              "message": traceback.format_exc(limit=2)})
        done(req, False)
    finally:
        # Runs in a thread now (like analyse): the thread owns the busy slot
        # and must release it, or every later request is refused as busy.
        _cancel.clear()
        _busy.clear()
        _busy_job = ""


def detect_faces(req):
    """Return the most prominent DISTINCT people in one video or image.

    'Add a person' step 1. Rather than dump every detection (a crowd scene is
    hundreds, and one person is detected many times at different angles and
    scales), this groups faces by cosine similarity — the same
    FACE_CLUSTER_COSINE used for clustering — so one person is ONE choice,
    then returns the FACE_MAX_CHOICES most prominent by pixel area. Every
    face's vector + thumbnail is persisted here so the chooser can show real
    crops. Single bounded source, so it runs inline (a few seconds of ffmpeg
    at most).
    """
    path = req.get("path")
    if not path or not os.path.exists(path):
        err(req, "detect_faces needs an existing path")
        done(req, False)
        return
    det, rec = _face_models_loaded()
    if det is None or rec is None:
        err(req, "face models unavailable (YuNet/SFace weights missing)")
        done(req, False)
        return
    import cv2
    import numpy as np

    # Largest sighting per unique face crop: someone seen small in the distance
    # and large in close-up is one crop, counted at their biggest. The vector is
    # kept so the dedupe step can cluster by identity.
    seen = {}   # hash -> (area, vec)

    def _ingest(img):
        for h, vec, area in _faces_in_frame(img):
            if h not in seen or area > seen[h][0]:
                seen[h] = (area, vec)

    ext = path.lower()
    if ext.endswith((".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tiff")):
        img = cv2.imread(path)
        if img is None:
            err(req, "could not read image %r" % path)
            done(req, False)
            return
        _ingest(img)
    else:
        workdir = tempfile.mkdtemp(prefix="fvp-detect-")
        try:
            frames, _indices = sample_frames(req, path, workdir)
            step = max(1, math.ceil(len(frames) / FACE_MAX_FRAMES))
            for fp in frames[::step]:
                img = cv2.imread(fp)
                if img is None:
                    continue
                _ingest(img)
                if len(seen) >= FACE_MAX_FACES:
                    break
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    # Cluster by cosine similarity so the SAME person — detected many times at
    # different angles and scales — is one choice, not several. Greedy merge
    # with a running centroid, exactly like face_clusters. Prominence is the
    # cluster's biggest sighting (the clearest crop wins as the thumbnail).
    clusters = []   # [{centroid, n, rep, area}]
    for h, (area, vec) in sorted(seen.items(), key=lambda kv: -kv[1][0]):
        v = np.asarray(vec, dtype=np.float64)
        best_c = None
        for c in clusters:
            sim = float(np.dot(v, c["centroid"]))
            if sim >= FACE_CLUSTER_COSINE and (best_c is None or sim > best_c[0]):
                best_c = (sim, c)
        if best_c is None:
            clusters.append({"centroid": v, "n": 1, "rep": h, "area": area})
        else:
            c = best_c[1]
            n = c["n"]
            c["centroid"] = (c["centroid"] * n + v) / (n + 1)
            c["n"] = n + 1
            if area > c["area"]:
                c["area"] = area
                c["rep"] = h
    clusters.sort(key=lambda c: -c["area"])
    chosen = clusters[:FACE_MAX_CHOICES]
    report(req, "result", faces=[c["rep"] for c in chosen], total=len(clusters))
    done(req, True)


def scan_person(req):
    """Scan the analysed library for a named person, returning matching videos.

    'Add a person' step 2. After the app has bound a name to face hashes (via
    name_cluster), this walks the analysed set, detects faces per video, and
    flags any video whose faces match the name's registry vectors above
    FACE_MATCH_COSINE. Runs in a THREAD (ffmpeg per video) with live progress
    and cancellation, exactly like face_index — the thread owns the busy slot.
    """
    global _busy_job
    name = (req.get("name") or "").strip()
    paths = [p for p in (req.get("paths") or []) if p and os.path.exists(p)]
    registry = _load_face_registry()
    hashes = registry.get(name)
    if not name:
        err(req, "scan_person needs a name")
        done(req, False)
        _cancel.clear()
        _busy.clear()
        _busy_job = ""
        return
    if not hashes:
        err(req, "no face registered for %r — bind a face first" % name)
        done(req, False)
        _cancel.clear()
        _busy.clear()
        _busy_job = ""
        return
    det, rec = _face_models_loaded()
    if det is None or rec is None:
        err(req, "face models unavailable")
        done(req, False)
        _cancel.clear()
        _busy.clear()
        _busy_job = ""
        return
    import cv2
    matched = []
    try:
        for i, path in enumerate(paths):
            if _cancel.is_set():
                break
            report(req, "status", stage="faces",
                   detail="%d/%d %s" % (i + 1, len(paths), os.path.basename(path)))
            workdir = tempfile.mkdtemp(prefix="fvp-facescan-")
            try:
                frames, _indices = sample_frames(req, path, workdir)
                if not frames:
                    continue
                step = max(1, math.ceil(len(frames) / FACE_MAX_FRAMES))
                hit = False
                for fp in frames[::step]:
                    img = cv2.imread(fp)
                    if img is None:
                        continue
                    vecs = [vec for _h, vec, _area in _faces_in_frame(img)]
                    if _face_matches(vecs, {name: hashes}):
                        hit = True
                        break
                if hit:
                    matched.append(path)
            except Exception:
                pass
            finally:
                shutil.rmtree(workdir, ignore_errors=True)
        report(req, "result", name=name, matched=matched)
        done(req, True)
    except Exception:
        emit({"id": req.get("id"), "type": "error",
              "message": traceback.format_exc(limit=2)})
        done(req, False)
    finally:
        _cancel.clear()
        _busy.clear()
        _busy_job = ""


def embed_frames(req, image_paths):
    """Embed frames, reusing any vector already on disk.

    Returns (embeddings, hashes) where embeddings is a normalised tensor of
    shape [len(image_paths), dim] in the same order as the input.
    """
    import torch
    hashes = [_frame_hash(p) for p in image_paths]
    cached = [_cache_read(h) for h in hashes]
    todo = [i for i, c in enumerate(cached) if c is None]
    hits = len(image_paths) - len(todo)
    if hits:
        report(req, "status", stage="embedding",
               detail="%d of %d frames already embedded" % (hits, len(image_paths)))

    with torch.no_grad():
        for start in range(0, len(todo), BATCH):
            if _cancel.is_set():
                return None, None
            idxs = todo[start:start + BATCH]
            imgs = [_processor(images=_open_or_black(image_paths[i]),
                               return_tensors="pt").pixel_values for i in idxs]
            px = torch.cat(imgs, dim=0).to(_device)
            emb = _model.get_image_features(pixel_values=px).float()
            emb = emb / emb.norm(dim=-1, keepdim=True)
            rows = emb.cpu().tolist()
            for i, row in zip(idxs, rows):
                cached[i] = row
                _cache_write(hashes[i], row)

    return torch.tensor(cached), hashes


def frame_scores(req, image_paths):
    """Score every frame for NSFW. Returns (scores, dominant_label).

    Embedding is delegated to `embed_frames`, so a second pass over a video --
    a retuned prompt pool, a new category, a threshold change -- costs a dot
    product per frame instead of a trip through the GPU.
    """
    global _text_cache
    import torch
    scores, dominant, _hashes, _laion = frame_scores_cached(req, image_paths)
    return scores, dominant


def frame_scores_cached(req, image_paths):
    """As `frame_scores`, but also returns each frame's cache hash so the
    caller can record which vector produced which score.

    Frames are embedded and scored in batches so the run can stop as soon as
    the verdict is settled (see EARLY_EXIT_HITS). Cached frames are free, so
    the early exit only ever saves GPU work, never cache reads.

    Returns (scores, dominant, hashes, laion) -- `laion` is the parallel list
    of LAION-head probabilities, or None when the head is unavailable. Both
    opinions are read off the SAME embedding, so this costs microseconds.
    """
    global _text_cache
    import torch
    n_nsfw = _text_cache["nsfw_n"]
    if not n_nsfw:
        raise RuntimeError("the zero-shot NSFW prompt pool is not installed "
                           "(private_vocab.json) -- use the Core ML engine, "
                           "whose verdict is Falconsai")
    text_feats = _text_cache["all"]

    scores, dominant, hashes, laion = [], [], [], []
    hits = 0
    for start in range(0, len(image_paths), BATCH):
        if _cancel.is_set():
            return None, None, None, None
        chunk = image_paths[start:start + BATCH]
        emb, chunk_hashes = embed_frames(req, chunk)
        if emb is None:
            return None, None, None, None
        with torch.no_grad():
            sims = emb @ text_feats.T                  # [B, T]
            nsfw_max = sims[:, :n_nsfw].max(dim=-1).values
            neutral_max = sims[:, n_nsfw:].max(dim=-1).values
            margin = (nsfw_max - neutral_max) - MARGIN_BIAS
            batch_score = 1.0 / (1.0 + torch.exp(-MARGIN_TEMPERATURE * margin))
            top_nsfw = sims[:, :n_nsfw].argmax(dim=-1)
            batch_laion = laion_scores(emb)
            # Correction head nudges the calibrated zero-shot score toward its
            # opinion (never replaces it): absent until ~4+4 marks exist.
            corr = _nsfw_correction_scores(emb)
            if corr is not None:
                batch_score = ((1.0 - NSFW_CORRECTION_WEIGHT) * batch_score
                               + NSFW_CORRECTION_WEIGHT * corr)
        batch_list = batch_score.tolist()
        scores.extend(batch_list)
        hashes.extend(chunk_hashes)
        dominant.extend(NSFW_POOL[t] for t in top_nsfw.tolist())
        if batch_laion is not None:
            laion.extend(batch_laion.tolist())
        else:
            laion.extend([None] * len(batch_list))

        hits += sum(1 for s in batch_list if s >= EARLY_EXIT_SCORE)
        if hits >= EARLY_EXIT_HITS and start + BATCH < len(image_paths):
            # Settled: aggregation is max, and enough frames are already above
            # the confident line that no later frame can change the verdict.
            report(req, "status", stage="classifying",
                   detail="verdict settled after %d of %d frames"
                          % (len(scores), len(image_paths)))
            break

    if not any(s is not None for s in laion):
        laion = None
    return scores, dominant, hashes, laion


def _open_or_black(path):
    from PIL import Image
    try:
        return Image.open(path).convert("RGB")
    except Exception:
        return Image.new("RGB", (64, 64), (8, 8, 8))


def analyse_video(req, video_path):
    """Sample -> embed -> score -> aggregate for one video."""
    global _busy, _cancel, _active_workdir
    _cancel.clear()
    workdir = tempfile.mkdtemp(prefix="fvp-analyse-")
    _active_workdir = workdir
    try:
        paths, indices = sample_frames(req, video_path, workdir)
        if _cancel.is_set():
            done(req, False, reason="cancelled")
            return
        scores, dominant, hashes, laion = frame_scores_cached(req, paths)
        if scores is None:
            done(req, False, reason="cancelled")
            return
        frames_above = sum(1 for s in scores if s >= NSFW_THRESHOLD)
        video_score = max(scores) if scores else 0.0
        # "at" is the video second a kept frame came from: the sampled frame's
        # original index times the cadence, so capped runs report honest times.
        # "hash" names the frame's cached embedding under frames/<model>/, so a
        # later pass -- a new category, a retrained head -- can reuse the
        # vector instead of paying for the GPU again.
        frames = [{"at": idx * SAMPLE_INTERVAL_S, "score": round(s, 4), "hash": h}
                  for idx, s, h in zip(indices, scores, hashes)]
        if laion is not None:
            for f, l in zip(frames, laion):
                if l is not None:
                    f["laion"] = round(l, 4)
        laion_max = max((l for l in (laion or []) if l is not None), default=None)
        top_label = None
        if video_score >= NSFW_THRESHOLD and dominant:
            best = max(range(len(scores)), key=lambda i: scores[i])
            top_label = dominant[best]
        payload = {
            "video_path": video_path,
            "nsfw_score": round(video_score, 4),
            "classification": "NSFW" if video_score >= NSFW_THRESHOLD else "NON_NSFW",
            "frames_analyzed": len(scores),
            "frames_above_threshold": frames_above,
            "dominant_label": top_label,
            "laion_score": round(laion_max, 4) if laion_max is not None else None,
            "frames": frames,
            "provenance": {
                "embedding_model": MODEL_ID,
                "classifier_model": CLASSIFIER,
                "classifier_version": "1.0",
                "sampling_strategy": SAMPLING,
                "aggregation_strategy": AGGREGATION,
                "sample_interval_s": SAMPLE_INTERVAL_S,
                "embedding_dim": _embed_dim,
                "threshold": NSFW_THRESHOLD,
                "margin_bias": MARGIN_BIAS,
                "temperature": MARGIN_TEMPERATURE,
                "laion_head": "laion_nsfw_head/1.0" if laion is not None else None,
            },
        }
        report(req, "result", **payload)
        done(req, True)
    except Exception:
        emit({"id": req.get("id"), "type": "error",
              "message": traceback.format_exc(limit=2)})
        done(req, False)
    finally:
        _cancel.clear()
        _busy.clear()
        shutil.rmtree(workdir, ignore_errors=True)


def _ensure_suggest_text(req):
    """Encode the suggestion vocabulary once per process.

    Text features are tiny and never change, so this is done on first use and
    then reused for every video the user plays. Two caches exist -- the plain
    vocabulary and the extended one that also carries the paired tags --
    because the paired phrases are only added for NSFW videos (see
    PAIRED_VOCAB); swapping the phrase set mid-session must not reuse the
    wrong encoding.
    """
    global _suggest_cache
    paired = bool(req.get("paired"))
    cached = _suggest_cache["text"]
    if cached is not None and cached.get("paired") == paired:
        return cached
    import torch

    vocab = SUGGEST_VOCAB + (PAIRED_VOCAB if paired else [])
    flat, owner = [], []
    for i, (_tag, phrasings) in enumerate(vocab):
        for phrase in phrasings:
            flat.append(phrase)
            owner.append(i)
    n_vocab = len(flat)
    flat = flat + BACKGROUND_POOL

    # Same convention as ensure_model's NSFW pool: encode, bring back to float
    # on the CPU, then unit-normalise, so a dot product with a frame embedding
    # is a cosine similarity directly comparable to the NSFW path's numbers.
    with torch.no_grad():
        text = _processor.tokenizer(flat, padding=True, return_tensors="pt")
        feats = _model.get_text_features(**text.to(_device)).float().cpu()
    feats = feats / feats.norm(dim=-1, keepdim=True)

    _suggest_cache["text"] = {"feats": feats, "owner": owner, "n_vocab": n_vocab,
                              "paired": paired}
    return _suggest_cache["text"]


def _paired_winner(per_tag, vocab, heads, emb, n_frames):
    """Decide between the two PAIRED_VOCAB tags for one NSFW video — ONE
    winner, or none.

    The pair is a forced choice: a video cannot be both, so the two candidates
    are scored against EACH OTHER on every frame rather than each against the
    bland background pool (which is why both chips used to appear — a frame
    that suits either phrasing out-scores \"a photo\" for both).

    The side that wins more frames — and at least `_min_frames_for()` of them
    — is the only one offered. When the clip is genuinely ambiguous (no side
    wins clearly) no chip appears: the user can tag by hand, and that mark is
    what the next Phase D head learns from.

    Trained heads (Phase D) decide when the user has earned a head for both
    tags; otherwise the zero-shot phrase columns do. The returned dict matches
    the suggestion entries: tag / confidence / frames / source.
    """
    import torch
    if len(PAIRED_VOCAB) != 2:
        return None
    first, second = PAIRED_VOCAB[0][0], PAIRED_VOCAB[1][0]
    idx = {tag: i for i, (tag, _phr) in enumerate(vocab)}
    a, b = idx.get(first), idx.get(second)
    if a is None or b is None:
        return None
    tmin = _min_frames_for(n_frames)

    # Trained heads first: user-earned evidence outranks the rough prompt guess.
    trained = {}
    if heads:
        for tag in (first, second):
            head = heads.get(tag)
            if head is None:
                continue
            w = torch.tensor(head[0], dtype=emb.dtype, device=emb.device)
            trained[tag] = torch.sigmoid(emb @ w + float(head[1]))
    if first in trained and second in trained:
        pa, pb = trained[first], trained[second]
        a_wins = int(((pa >= pb) & (pa >= TRAINED_HEADS_CUT)).sum())
        b_wins = int(((pb > pa) & (pb >= TRAINED_HEADS_CUT)).sum())
        if a_wins == b_wins or max(a_wins, b_wins) < tmin:
            return None
        tag = first if a_wins > b_wins else second
        p = trained[tag]
        return {"tag": tag, "confidence": round(float(p.max()), 4),
                "frames": max(a_wins, b_wins), "source": "trained"}
    # One trained head (the other not yet earned): let it speak alone — its
    # rejections already taught it the other side.
    if trained:
        tag = next(iter(trained))
        p = trained[tag]
        n = int((p >= TRAINED_HEADS_CUT).sum())
        if n < tmin:
            return None
        return {"tag": tag, "confidence": round(float(p.max()), 4),
                "frames": n, "source": "trained"}

    # Zero-shot: compare the two candidates on each frame, not the background.
    diff = per_tag[:, a] - per_tag[:, b]                   # >0 leans first
    a_wins = int((diff >= SUGGEST_MARGIN).sum())
    b_wins = int((diff <= -SUGGEST_MARGIN).sum())
    if a_wins == b_wins or max(a_wins, b_wins) < tmin:
        return None
    tag = first if a_wins > b_wins else second
    side = diff if tag == first else -diff
    conf = float(side.max()) if a_wins + b_wins else SUGGEST_MARGIN
    return {"tag": tag, "confidence": round(conf, 4),
            "frames": max(a_wins, b_wins), "source": "zeroshot"}


def suggest_tags(req, video_path):
    """Offer candidate tags for one video.

    Runs over the SAME cached frame embeddings the NSFW pass uses, so a video
    that has already been analysed costs no GPU at all -- just one matrix
    multiply against the vocabulary.

    Every tag is scored independently against the background pool rather than in
    a softmax across tags, so "none of these" is a normal and frequent outcome.
    That is deliberate: the Sep 2026 probe showed a forced choice will always
    name a winner, which is how "wedding" ended up on ordinary living rooms.
    """
    import numpy as np
    import torch
    _cancel.clear()
    workdir = tempfile.mkdtemp(prefix="fvp-suggest-")
    try:
        tc = _ensure_suggest_text(req)
        vocab = SUGGEST_VOCAB + (PAIRED_VOCAB if tc["paired"] else [])
        frames, _indices = sample_frames(req, video_path, workdir)
        if not frames:
            err(req, "could not read frames from this video")
            done(req, False)
            return
        emb, _hashes = embed_frames(req, frames)
        if emb is None:
            err(req, "could not embed frames")
            done(req, False)
            return

        with torch.no_grad():
            sims = emb @ tc["feats"].T                          # [frames, phrases]
            n_vocab = tc["n_vocab"]
            background = sims[:, n_vocab:].max(dim=-1).values   # [frames]

            # Best phrasing per tag, per frame.
            per_tag = torch.full((sims.shape[0], len(vocab)), -1e4,
                                 device=sims.device, dtype=sims.dtype)
            for col, tag_idx in enumerate(tc["owner"]):
                per_tag[:, tag_idx] = torch.maximum(per_tag[:, tag_idx], sims[:, col])

            margin = per_tag - background.unsqueeze(1)          # [frames, tags]
            hits = (margin >= SUGGEST_MARGIN).sum(dim=0)
            strength = margin.max(dim=0).values

        min_frames = _min_frames_for(len(frames))
        out = []
        for i, (tag, _phr) in enumerate(vocab):
            if tag in PAIRED_TAG_NAMES:
                continue   # the pair is decided head-to-head below, one winner only
            n_hits = int(hits[i].item())
            if n_hits >= min_frames:
                out.append({"tag": tag,
                            "confidence": round(float(strength[i].item()), 4),
                            "frames": n_hits,
                            "source": "zeroshot"})

        # Trained per-tag heads (Phase D): score the SAME frames with the
        # heads fit from your own accept/reject decisions. A tag with a head
        # competes on equal footing with the zero-shot candidates; the
        # stronger evidence wins and the entry records which way it decided.
        # Paired-tag heads are excluded here and handled pairwise below.
        heads = _load_trained_heads()
        if heads:
            names = [t for t in sorted(heads.keys()) if t not in PAIRED_TAG_NAMES]
            # All heads may be paired-tag heads, which are
            # handled pairwise below — an empty non-paired list must not
            # reach np.stack([]), which raises "need at least one array".
            if names:
                W = np.stack([heads[t][0] for t in names]).astype(np.float32)   # [T,768]
                bias = np.array([heads[t][1] for t in names], dtype=np.float32)
                E = emb.detach().cpu().numpy().astype(np.float32)               # [F,768]
                p = 1 / (1 + np.exp(-(E @ W.T + bias)))                         # [F,T]
                thits = p >= TRAINED_HEADS_CUT
                tmin = _min_frames_for(len(frames))
                by_tag = {r["tag"]: r for r in out}
                for j, tag in enumerate(names):
                    n_hits = int(thits[:, j].sum())
                    if n_hits < tmin:
                        continue
                    conf = round(float(p[:, j].max()), 4)
                    cur = by_tag.get(tag)
                    if cur is None:
                        by_tag[tag] = {"tag": tag, "confidence": conf,
                                       "frames": n_hits, "source": "trained"}
                        out.append(by_tag[tag])
                    elif conf > cur["confidence"]:
                        cur.update(confidence=conf, frames=n_hits, source="trained")

        # The pair is decided HEAD-TO-HEAD, one winner only. The two tags
        # are scored against each other on every frame (the same
        # per-frame best-phrase similarities the zero-shot pass used, plus any
        # trained heads the user has earned for the pair) — the tag
        # with more winning frames is the one offered, and the loser is never
        # shown, because a video cannot be both. When neither wins enough
        # frames (an ambiguous clip), no chip appears at all.
        if tc["paired"]:
            pair_hit = _paired_winner(per_tag, vocab, heads, emb, len(frames))
            if pair_hit is not None:
                out.append(pair_hit)

        # Library-tag prototypes (Phase D): offer the user's OWN tags — the
        # ones CLIP's phrase vocabulary has never heard of (Kite, Bench, Confetti…)
        # — when the frames sit clearly above the library's average for that
        # tag. This is what gives such tags their first rejections, which is
        # the class they have been starving for. A trained head for the same
        # tag (stronger evidence) still outranks the prototype below.
        library_hits = _score_library_tags(emb, _library_prototypes(req),
                                           min_frames)
        by_tag = {r["tag"]: r for r in out}
        for cand in library_hits:
            cur = by_tag.get(cand["tag"])
            if cur is None:
                by_tag[cand["tag"]] = cand
                out.append(cand)
            elif cand["confidence"] > cur["confidence"]:
                cur.update(confidence=cand["confidence"], frames=cand["frames"],
                           source="library")

        # Face recognition (Phase E): detect + embed faces over the SAME
        # sampled frames, match against the person registry, and offer each
        # matched name as a "face" candidate. This is a separate model from
        # CLIP (YuNet/SFace on CPU) — cheap because the frames already exist,
        # and it degrades to nothing when the weights are absent or no face is
        # bound to a name yet.
        #
        # The app can switch this whole path off (Tags > Face Recognition).
        # When it is off no face is detected, embedded, hashed or stored for
        # this video at all -- the request simply carries no face work, rather
        # than doing it and hiding the result.
        faces_detected = 0
        faces_hashes = []
        try:
            import cv2
            det, _rec = _face_models_loaded()
            if det is not None and req.get("faces", True):
                face_vectors = []
                seen_faces = set()
                # Spread the face scan across the WHOLE video, not just the
                # first N frames: frames[] is already uniform (fps=1/N), so
                # stride it so a long video still samples faces near the end.
                # The naive "first 40 frames" cap missed people who appear
                # mid-video — the exact "keep asking me who this is" bug.
                step = max(1, math.ceil(len(frames) / FACE_MAX_FRAMES))
                for fp in frames[::step]:
                    img = cv2.imread(fp)
                    if img is None:
                        continue
                    for h, vec, _area in _faces_in_frame(img):
                        if h in seen_faces:
                            continue
                        seen_faces.add(h)
                        face_vectors.append(vec)
                        faces_hashes.append(h)
                    if len(face_vectors) >= FACE_MAX_FACES:
                        break
                faces_detected = len(face_vectors)
                for name, best in _face_matches(face_vectors,
                                                _load_face_registry()).items():
                    cur = by_tag.get(name)
                    # A face match is the strongest evidence for a person tag:
                    # it wins over a CLIP prototype of the same name (which
                    # should have been excluded anyway) and is never re-offered
                    # under a weaker source.
                    if cur is None or cur.get("source") != "face":
                        by_tag[name] = {"tag": name,
                                        "confidence": round(best, 4),
                                        "frames": 1,
                                        "source": "face"}
                        out.append(by_tag[name])
                    elif best > cur["confidence"]:
                        cur.update(confidence=round(best, 4))
        except Exception:
            pass   # faces are an optional extra, never a reason to fail a suggest

        out.sort(key=lambda r: r["confidence"], reverse=True)
        out = out[:SUGGEST_MAX_TAGS]

        # Reuse the "result" event kind rather than inventing one: the app's
        # reader drops any type it does not know, and the mailbox only stores
        # payloads for hello/result/error. A new kind would be silently lost.
        report(req, "result", path=video_path, suggestions=out,
               frames_seen=len(frames), model=MODEL_ID,
               faces_detected=faces_detected, faces=faces_hashes)
        done(req, True)
    except Exception:
        emit({"id": req.get("id"), "type": "error",
              "message": traceback.format_exc(limit=2)})
        done(req, False)
    finally:
        _cancel.clear()
        _busy.clear()
        shutil.rmtree(workdir, ignore_errors=True)


# --------------------------------------------------------------------------
# Request dispatch
# --------------------------------------------------------------------------

def handle(req):
    global _busy_job
    cmd = req.get("cmd")
    if cmd == "cancel":
        _cancel.set()
        if _ffmpeg_proc is not None:
            try:
                _ffmpeg_proc.kill()
            except Exception:
                pass
        done(req, True)
        return

    if cmd == "hello":
        report(req, "hello", engine="fvp-analysis", version="0.1",
               device=DEVICE,
               model={"id": MODEL_ID, "dim": _embed_dim},
               classifier=CLASSIFIER,
               sampling=SAMPLING, aggregation=AGGREGATION,
               ffmpeg=FFMPEG, max_frames=MAX_FRAMES, threshold=NSFW_THRESHOLD)
        done(req, True)
        return

    if cmd == "ensure_model":
        try:
            ensure_model(req)
            done(req, True)
        except Exception as e:
            err(req, "model load failed: %s" % e)
            done(req, False)
        return

    if cmd == "analyse":
        path = req.get("path")
        if not path or not os.path.exists(path):
            err(req, "no such file: %r" % (path or ""))
            done(req, False)
            return
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        try:
            ensure_model(req)
        except Exception as e:
            err(req, "model load failed: %s" % e)
            done(req, False)
            return
        # Claim the slot before the thread can start, so a pipelined second
        # analyse in the gap is refused instead of running two workers.
        _busy_job = "analysing"
        _busy.set()
        t = threading.Thread(target=analyse_video, args=(req, path), daemon=True)
        t.start()
        return

    if cmd == "train":
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        try:
            _busy_job = "training"
            _busy.set()
            report(req, "status", stage="training",
                   detail="fitting per-tag heads")
            train(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        finally:
            _busy.clear()
            _busy_job = ""
        return

    if cmd == "face_clusters":
        # Pure cache reads (walk faces/, cluster vectors) — no ffmpeg, no
        # model, so it runs inline like tag_candidates.
        try:
            face_clusters(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "face_people":
        try:
            face_people(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "name_cluster":
        # A registry write (no ffmpeg) — inline, no busy gate.
        try:
            name_cluster(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "forget_person":
        # A registry delete (no ffmpeg) — inline, no busy gate.
        try:
            forget_person(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "set_photo":
        # A registry write + one image detection (no ffmpeg) — inline.
        try:
            set_photo(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "similar_faces":
        # A cache + registry read (no ffmpeg) — inline.
        try:
            similar_faces(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "set_representative":
        # A registry write (no ffmpeg) — inline.
        try:
            set_representative(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "face_index":
        # Batch face detection across videos: sample frames, detect + embed +
        # persist faces, return {path: [face_hash...]}. Button-triggered only
        # (never auto-scans). Claims the busy slot, but runs in a THREAD like
        # analyse — running ffmpeg per video inline would block the handle loop
        # from reading any further request (including "cancel"), which is
        # exactly the "stuck, can't get out, interface sluggish" bug.
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        _busy_job = "indexing faces"
        _busy.set()
        t = threading.Thread(target=face_index, args=(req,), daemon=True)
        t.start()
        return

    if cmd == "name_face":
        # Bind a video's faces to a person name. Needs ffmpeg sampling (a new
        # video), so it claims the busy slot like analyse/train do.
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        try:
            _busy_job = "naming faces"
            _busy.set()
            report(req, "status", stage="faces",
                   detail="detecting faces for %s" % (req.get("name") or ""))
            name_face(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        finally:
            _busy.clear()
            _busy_job = ""
        return

    if cmd == "detect_faces":
        # 'Add a person' step 1: return the biggest faces in one video/image
        # so the user can pick which face to add. Single bounded source, so it
        # claims the busy slot inline like name_face (a few seconds at most).
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        try:
            _busy_job = "detecting faces"
            _busy.set()
            report(req, "status", stage="faces", detail="detecting faces")
            detect_faces(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        finally:
            _busy.clear()
            _busy_job = ""
        return

    if cmd == "scan_person":
        # 'Add a person' step 2: scan the analysed library for one named person.
        # ffmpeg per video, so it runs in a THREAD and owns the busy slot —
        # cancellable with live progress, exactly like face_index.
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        _busy_job = "scanning for person"
        _busy.set()
        t = threading.Thread(target=scan_person, args=(req,), daemon=True)
        t.start()
        return

    if cmd == "train_nsfw":
        # Single-worker gate as train(): inline in handle, claims the busy slot
        # so a pipelined analyse cannot start mid-fit.
        if _busy.is_set():
            err(req, "engine busy (%s)" % _busy_job)
            done(req, False)
            return
        try:
            _busy_job = "training"
            _busy.set()
            report(req, "status", stage="training",
                   detail="fitting the Safe/NSFW correction head")
            train_nsfw(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        finally:
            _busy.clear()
            _busy_job = ""
        return

    if cmd == "tag_candidates":
        # Pure cache reads (no ffmpeg, no model): score every analysed video
        # in the pool against the tag's prototype. Runs inline — it never
        # contends for the GPU, so it does not need the single-worker gate.
        try:
            tag_candidates(req)
        except Exception:
            emit({"id": req.get("id"), "type": "error",
                  "message": traceback.format_exc(limit=2)})
            done(req, False)
        return

    if cmd == "suggest_tags":
        path = req.get("path")
        if not path or not os.path.exists(path):
            err(req, "no such file: %r" % (path or ""))
            done(req, False)
            return
        if _busy.is_set():
            err(req, "engine busy")
            done(req, False)
            return
        try:
            ensure_model(req)
        except Exception as e:
            err(req, "model load failed: %s" % e)
            done(req, False)
            return
        # Same busy contract as analyse: one worker at a time, claimed before
        # the thread starts so a pipelined request is refused, never run twice.
        _busy.set()
        t = threading.Thread(target=suggest_tags, args=(req, path), daemon=True)
        t.start()
        return

    err(req, "unknown command %r" % cmd)
    done(req, False)


def main():
    # Keep the model warm across a whole queue: the process runs for the life
    # of the review session and is told goodbye by EOF on stdin.
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            emit({"type": "error", "message": "bad request line"})
            continue
        try:
            handle(req)
        except Exception:
            emit({"type": "error", "message": traceback.format_exc(limit=2)})
            done(req, False)
    # stdin closed -> the app is gone. Finish whatever is in flight rather
    # than killing the worker mid-analysis (a daemon thread would die with
    # the interpreter), then exit. The cap keeps a wedged engine from
    # lingering forever on a dead app.
    deadline = time.time() + 300
    while _busy.is_set() and time.time() < deadline:
        time.sleep(0.2)
    if _ffmpeg_proc is not None:
        try:
            _ffmpeg_proc.kill()
        except Exception:
            pass
    if _active_workdir is not None:
        shutil.rmtree(_active_workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
