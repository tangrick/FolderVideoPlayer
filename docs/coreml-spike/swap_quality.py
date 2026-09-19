#!/usr/bin/env python3
"""Does the replacement tower tag real footage as well as the one it replaces?

`convert_siglip2_image.py` proves the CONVERSION is faithful; `table_margin_compare.py`
proves the two tables divide the same phrases differently. Neither answers the only
question that decides the swap: on the maintainer's own videos, does SigLIP 2 +
its prompt table nominate tags as well as MobileCLIP-S2 + the old table?

There is no baseline to inherit. The frame cache on this machine holds ONLY
`frames/openai_clip-vit-large-patch14/` (the Python engine's space), so the Core ML
tag path has never embedded this library here — which means MobileCLIP has to be
run alongside SigLIP 2 rather than quoted from a note. That is what this script
does: the SAME sampled frames through both towers, each scored with its OWN table,
so the only difference left is the model.

Frames are sampled exactly as `engine.py` samples them (`sample_frames`): one every
`SAMPLE_INTERVAL_S`, short side capped at `SAMPLE_SHORT_SIDE`, jpg q3 — so this is
the sampling the app itself uses, not a convenient different one.

What it reports per tower, per video:
  * how many tags clear a bar (at SUGGEST_MARGIN 0.02 and vocabularyMargin 0.06)
  * whether the video's OWN user tags fire, over the part of them the fixed
    vocabulary can express at all (a tag like "AI Cat" is not in SUGGEST_VOCAB and
    never could fire; counting those would flatter neither tower)
  * the zero-shot NSFW score, where the video has a human Safe/NSFW mark

and between towers: list overlap, and how often one fires and the other does not.

This is a probe, not a benchmark: a handful of videos proves the harness works and
shows the direction of travel. Anything with a threshold in it still needs the full
run over the analysed library.

    /opt/anaconda3/bin/python3 docs/coreml-spike/swap_quality.py --from-tags 8
    /opt/anaconda3/bin/python3 docs/coreml-spike/swap_quality.py --videos a.mp4 b.mp4
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import precompute_text as pt                 # noqa: E402  (engine.py constants)
import table_margin_compare as tmc           # noqa: E402  (table loading + geometry)

SUPPORT = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer")
MODELS = os.path.expanduser("~/fvp-coreml-models")
FFMPEG = "/opt/homebrew/bin/ffmpeg"

# slug -> (Core ML package, prompt table, what the app compares margins at)
TOWERS = {
    "mobileclip-s2": (os.path.join(MODELS, "mobileclip_s2_image.mlpackage"),
                      os.path.join(MODELS, "s2_prompts.json"), 0.06),
    "siglip2-base": (os.path.join(MODELS, "siglip2_base_image.mlpackage"),
                     os.path.join(MODELS, "siglip2_base_prompts.json"), 0.06),
}
BARS = (0.02, 0.06)                          # SUGGEST_MARGIN, vocabularyMargin
# Every bar the sweep reports, so the replacement can be chosen by matching the
# old tower's chips-per-video rather than by taste.
SWEEP = (0.005, 0.01, 0.015, 0.02, 0.03, 0.04, 0.06)


def probe_duration(path):
    try:
        out = subprocess.run([FFMPEG.replace("ffmpeg", "ffprobe"), "-v", "error",
                              "-show_entries", "format=duration", "-of",
                              "csv=p=0", path], capture_output=True, text=True)
        return float(out.stdout.strip())
    except (ValueError, AttributeError):
        return None


def sample_frames(path, workdir, interval_s, short_side, max_frames, target_short=4):
    """engine.py's `sample_frames`, same filter and same cap."""
    duration = probe_duration(path)
    if duration is None or duration <= 0:
        interval = interval_s
    else:
        interval = min(interval_s, max(duration / target_short, 0.2))
    pattern = os.path.join(workdir, "f_%06d.jpg")
    vf = "fps=1/%s,scale='min(%d,iw)':-2" % (interval, short_side)
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-an", "-i", path,
                    "-vf", vf, "-q:v", "3", pattern], check=False)
    frames = sorted(f for f in os.listdir(workdir) if f.endswith(".jpg"))
    return [os.path.join(workdir, f) for f in frames[:max_frames]]


class Tower:
    """One image tower, its table, and the numbers its table is read at."""

    def __init__(self, name, package, table_json, bar):
        import coremltools as ct
        self.name = name
        self.meta, self.matrix = tmc.load(table_json)
        self.model = ct.models.MLModel(package)
        spec = self.model.get_spec()
        self.input_name = spec.description.input[0].name
        image_type = spec.description.input[0].type.imageType
        self.size = (image_type.width, image_type.height)
        self.bar = bar
        self.background = slice(*self.meta["layout"]["background"])
        self.nsfw = slice(*self.meta["layout"]["nsfw"])
        self.neutral = slice(*self.meta["layout"]["neutral"])
        self.out = spec.description.output[0].name

    def embed(self, paths):
        """Per-frame unit vectors, in order. The package normalises its own input
        (VisionEmbedder draws the CGImage straight in), so the image goes in raw."""
        from PIL import Image
        out = []
        for p in paths:
            img = Image.open(p).convert("RGB").resize(self.size)
            vec = np.asarray(self.model.predict({self.input_name: img})[self.out],
                             dtype=np.float64).reshape(-1)
            out.append(vec / max(np.linalg.norm(vec), 1e-12))
        return np.stack(out)

    def tag_margins(self, vectors):
        """`PromptTable.tagMargins` for each frame: tag best minus bland best."""
        bg_best = (vectors @ self.matrix[self.background].T).max(axis=1)
        per_frame = {}
        for tag in self.meta["tags"]:
            lo, hi = tag["rows"]
            best = (vectors @ self.matrix[lo:hi].T).max(axis=1)
            per_frame[tag["tag"]] = best - bg_best
        return per_frame

    def suggestions(self, vectors, bar):
        """The engine's bar plus its min-frames rule, uncapped and unsorted."""
        per_frame = self.tag_margins(vectors)
        needed = 1 if len(vectors) <= 3 else (2 if len(vectors) <= 10 else 3)
        fired = []
        for tag, margins in per_frame.items():
            if int((margins >= bar).sum()) >= needed:
                fired.append((tag, float(margins.max())))
        return sorted(fired, key=lambda t: -t[1])

    def gist(self, vectors, top=10):
        """The best-matching PHRASES for this video, in this space.

        The one check that does not depend on any threshold: a tower whose top
        phrases for a wedding video are wedding-shaped is calibrated differently;
        a tower whose top phrases are nonsense is broken, and no bar will reveal
        that. The phrases are in the table because the original script decided a
        suggestion nobody can interrogate is one the user has to take on faith.
        """
        mean = vectors.mean(axis=0)
        mean = mean / max(np.linalg.norm(mean), 1e-12)
        sims = self.matrix @ mean
        order = np.argsort(-sims)[:top]
        texts = self.meta.get("texts") or []
        return [(texts[i] if i < len(texts) else "row %d" % i, float(sims[i]))
                for i in order]

    def nsfw_zero_shot(self, vectors):
        """The preview classifier's own score — `PromptTable.nsfwScore`, max over frames."""
        bias = self.meta["constants"]["MARGIN_BIAS"]
        temp = self.meta["constants"]["MARGIN_TEMPERATURE"]
        scores = []
        for v in vectors:
            margin = ((v @ self.matrix[self.nsfw].T).max()
                      - (v @ self.matrix[self.neutral].T).max())
            scores.append(1.0 / (1.0 + np.exp(-temp * (margin - bias))))
        return float(np.max(scores))


def load_tags():
    path = os.path.join(SUPPORT, "tags.json")
    return json.load(open(path)) if os.path.exists(path) else {}


def load_marks():
    """Human Safe/NSFW verdicts, wherever this build keeps them.

    Per `Paths`: a profile owns its marks, and the older shape kept corrections in
    `analysis.json`'s per-record history. Both are read; whichever exists is used.
    """
    marks = {}
    profiles = os.path.join(SUPPORT, "profiles")
    for root, _dirs, files in os.walk(profiles):
        for name in files:
            if name != "marks.json":
                continue
            try:
                for key, value in json.load(open(os.path.join(root, name))).items():
                    label = value if isinstance(value, str) else value.get("label")
                    if label:
                        marks[key] = str(label).lower()
            except (ValueError, OSError):
                continue
    return marks


def pick_videos(count, tags):
    """Videos with user tags whose files are on this Mac — no folder scan.

    The library spans a network share (`private/…` keys) that may not be mounted;
    a path that does not exist is skipped rather than reported as a failure of
    either tower.
    """
    picked = []
    for key, names in tags.items():
        if not names:
            continue
        path = key if os.path.isabs(key) else None
        if path and os.path.exists(path):
            picked.append(path)
        if len(picked) >= count:
            break
    return picked


def fmt_tags(fired):
    return ", ".join("%s %.3f" % (t, m) for t, m in fired) if fired else "—"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--videos", nargs="*", default=None)
    parser.add_argument("--from-tags", type=int, default=6,
                        help="how many tagged videos to probe when --videos is absent")
    parser.add_argument("--towers", nargs="*", default=list(TOWERS))
    args = parser.parse_args()

    engine, _ = pt.read_engine(pt.ENGINE_PY)
    interval_s = engine["SAMPLE_INTERVAL_S"]
    short_side = engine["SAMPLE_SHORT_SIDE"]
    max_frames = engine["MAX_FRAMES"]
    print("sampling  fps=1/%s · short side %d · cap %d  (engine.py's own numbers)"
          % (interval_s, short_side, max_frames))

    tags = load_tags()
    marks = load_marks()
    videos = args.videos or pick_videos(args.from_tags, tags)
    if not videos:
        raise SystemExit("no videos to probe: pass --videos, or tag something first")
    print("videos    %d%s" % (len(videos), "" if args.videos else " (from tags.json)"))
    for v in videos:
        print("   %s" % v.replace(os.path.expanduser("~"), "~"))

    towers = {}
    for name in args.towers:
        if name not in TOWERS:
            raise SystemExit("unknown tower %s" % name)
        package, table, bar = TOWERS[name]
        if not os.path.exists(package) or not os.path.exists(table):
            raise SystemExit("%s: missing %s or %s" % (name, package, table))
        towers[name] = Tower(name, package, table, bar)
        t = towers[name]
        print("\ntower     %s  input %dx%d · table dim %d · %d tags"
              % (name, t.size[0], t.size[1], t.matrix.shape[1], len(t.meta["tags"])))
        if t.matrix.shape[1] not in (512, 768):
            raise SystemExit("%s: unexpected table dim %d" % (name, t.matrix.shape[1]))

    overlap, only = [], {name: 0 for name in towers}
    covered_hits = {name: [0, 0] for name in towers}      # [fired, vocabulary-covered]
    fired_at = {name: {bar: [] for bar in SWEEP} for name in towers}
    nsfw = []

    for video in videos:
        with tempfile.TemporaryDirectory(prefix="fvp-swap-") as work:
            frames = sample_frames(video, work, interval_s, short_side, max_frames)
            if not frames:
                print("\n%s\n  no frames (corrupt or unsupported) — skipped"
                      % os.path.basename(video))
                continue
            print("\n%s\n  %d frames" % (os.path.basename(video), len(frames)))
            mine = set(tags.get(video) or [])
            vocab = {t["tag"].lower() for name in towers for t in towers[name].meta["tags"]}
            own = {t.lower() for t in mine if t.lower() in vocab}

            lists = {}
            for name, tower in towers.items():
                started = time.time()
                vectors = tower.embed(frames)
                ms = (time.time() - started) * 1000.0 / len(frames)
                for bar in SWEEP:
                    fired = tower.suggestions(vectors, bar)
                    lists.setdefault(bar, {})[name] = {t for t, _ in fired}
                    fired_at[name][bar].append(len(fired))
                top = tower.suggestions(vectors, tower.bar)
                print("  %-14s %5.1f ms/frame · %d tags at %.2f · %s"
                      % (name, ms, len(top), tower.bar, fmt_tags(top[:6])))
                print("      gist: %s"
                      % "; ".join("%s %.3f" % (p, s) for p, s in tower.gist(vectors, 6)))
                if own:
                    hits = sum(1 for t, _ in top if t.lower() in own)
                    covered_hits[name][0] += hits
                    covered_hits[name][1] += len(own)
                nsfw.append((name, video, tower.nsfw_zero_shot(vectors)))

            if len(towers) == 2:
                first, second = args.towers[0], args.towers[1]
                for bar in BARS:
                    a, b = lists[bar][first], lists[bar][second]
                    union = a | b
                    overlap.append(len(a & b) / len(union) if union else 1.0)
                    if bar == BARS[-1]:            # the app compares margins here
                        only[first] += len(a - b)
                        only[second] += len(b - a)

    # The sweep, which is the number a replacement bar comes from: a margin is
    # only meaningful against the chips-per-video it produces on real footage.
    print("\n%-16s %s" % ("tower", "tags/video at bar:"))
    print("%-16s %s" % ("", "  ".join("%6.3f" % b for b in SWEEP)))
    for name in towers:
        values = []
        for bar in SWEEP:
            seen = fired_at[name][bar]
            values.append(float(np.mean(seen)) if seen else float("nan"))
        print("%-16s %s" % (name, "  ".join("%6.2f" % v for v in values)))

    if len(towers) == 2:
        print("\nagreement between towers: mean Jaccard %.2f over %d (video, bar) pairs"
              % (float(np.mean(overlap)) if overlap else float("nan"), len(overlap)))
        print("tags one tower fired and the other did not (at 0.06): %s"
              % ", ".join("%s %d" % (n, c) for n, c in only.items()))

    print("\nuser tags the vocabulary can express, and whether they fired:")
    for name in towers:
        fired, covered = covered_hits[name]
        print("  %-14s %d/%d%s" % (name, fired, covered,
                                   "  (no probed video had a covered tag)" if not covered else ""))

    if marks:
        print("\nzero-shot NSFW (preview only — Falconsai is the shipped verdict):")
        for name, video, score in nsfw:
            mark = marks.get(video)
            print("  %-14s %-40s %.4f   human: %s"
                  % (name, os.path.basename(video)[:40], score, mark or "—"))
    else:
        print("\nzero-shot NSFW: no human marks found, so nothing to compare against")

    print("\nREAD THIS AS A PROBE. %d videos cannot move a threshold; the full run over"
          % len(videos))
    print("the analysed library is what re-derives SUGGEST_MARGIN and vocabularyMargin")
    print("in the new space. If the two towers disagree on which tags fire at all, that")
    print("is the finding, not the overlap number.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
