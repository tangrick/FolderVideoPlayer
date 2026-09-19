#!/usr/bin/env python3
"""Bias/threshold sweep for the FolderVideoPlayer analysis engine.

Scores a NSFW control folder once, keeping every frame score, then re-derives
what each video would have scored under other MARGIN_BIAS values -- no
re-embedding needed, because the bias enters the score analytically:

    score  = sigmoid(T * (margin - bias))
    margin = logit(score)/T + bias            <- invert to recover the raw gap

The safe control comes free: the app's own analysis.json already holds real
frame scores for the user's library, produced at the live bias.

Writes a JSON summary so the sweep can be re-read without re-scoring.
Read-only with respect to the app's records.

    python3 calibrate_sweep.py <nsfw-folder> [--out /tmp/fvp-sweep.json]
"""
import sys, os, json, glob, math, importlib.util, statistics, tempfile, shutil

ENGINE = os.path.expanduser(
    "~/Library/Application Support/FolderVideoPlayer/engine/engine.py")
STORE = os.path.expanduser(
    "~/Library/Application Support/FolderVideoPlayer/analysis.json")
VIDEO_EXTS = ("mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm")


def load_engine():
    spec = importlib.util.spec_from_file_location("fvp_engine", ENGINE)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load engine at " + ENGINE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fvp_engine"] = mod
    spec.loader.exec_module(mod)
    return mod


def logit(p):
    p = min(max(p, 1e-9), 1 - 1e-9)
    return math.log(p / (1 - p))


def margins_from_scores(scores, temp, bias):
    """Recover the raw similarity gaps behind a list of engine scores."""
    return [logit(s) / temp + bias for s in scores]


def score_at(margins, temp, bias):
    """Video score (max aggregation) at a candidate bias."""
    return max(1.0 / (1.0 + math.exp(-temp * (m - bias))) for m in margins)


def main():
    argv = sys.argv[1:]
    out = "/tmp/fvp-sweep.json"
    if "--out" in argv:
        out = argv[argv.index("--out") + 1]
    pos = [a for a in argv if not a.startswith("--") and a != out]
    if not pos:
        print(__doc__); sys.exit(2)
    folder = os.path.expanduser(pos[0])

    e = load_engine()
    T = e.MARGIN_TEMPERATURE
    LIVE_BIAS = e.MARGIN_BIAS
    req = {"id": "sweep", "op": "analyse"}

    # ---- positives: score the control folder, keep every frame -------------
    vids = sorted(set(p for x in VIDEO_EXTS
                      for p in glob.glob(os.path.join(folder, "**", "*." + x), recursive=True)))
    print("model :", e.MODEL_ID, "| live bias:", LIVE_BIAS, "| temp:", T)
    print("positives:", len(vids), "videos")
    e.ensure_model(req)

    pos_margins = {}
    for i, v in enumerate(vids, 1):
        name = os.path.basename(v)
        wd = tempfile.mkdtemp(prefix="fvp-sweep-")
        try:
            paths, _idx = e.sample_frames(req, v, wd)
            if not paths:
                continue
            scores, _dom = e.frame_scores(req, paths)
            if not scores:
                continue
            pos_margins[name] = margins_from_scores(scores, T, LIVE_BIAS)
            print("[%d/%d] %-50s max %.3f" % (i, len(vids), name[:50], max(scores)), flush=True)
        except Exception as exc:
            print("  FAILED", name, exc)
        finally:
            shutil.rmtree(wd, ignore_errors=True)

    # ---- negatives: the user's own library, straight from the app ----------
    neg_margins = {}
    if os.path.exists(STORE):
        d = json.load(open(STORE))
        for key, rec in d.items():
            fs = rec.get("frameScores") or []
            if not fs:
                continue
            # Only rows nobody has contradicted: a machine verdict the user
            # marked safe is still a safe example; a row marked NSFW is not.
            if rec.get("userLabel") == "nsfw":
                continue
            scores = [f["score"] for f in fs if "score" in f]
            if scores:
                neg_margins[os.path.basename(key)] = margins_from_scores(scores, T, LIVE_BIAS)
    print("negatives:", len(neg_margins), "videos from the live library")

    if not pos_margins or not neg_margins:
        print("need both sides to sweep"); sys.exit(1)

    # ---- sweep --------------------------------------------------------------
    print()
    print("%-7s | %-28s | %-28s | %s" % ("bias", "NSFW scores (18)", "SAFE scores", "separation"))
    print("%-7s | %-28s | %-28s | %s" % ("", "min    median   max", "max    median", "gap"))
    print("-" * 96)
    rows = []
    for bias_i in range(-2, 9):
        bias = bias_i / 100.0
        pos_s = sorted(score_at(m, T, bias) for m in pos_margins.values())
        neg_s = sorted(score_at(m, T, bias) for m in neg_margins.values())
        gap = min(pos_s) - max(neg_s)
        rows.append({
            "bias": bias,
            "pos_min": min(pos_s), "pos_med": statistics.median(pos_s), "pos_max": max(pos_s),
            "neg_min": min(neg_s), "neg_med": statistics.median(neg_s), "neg_max": max(neg_s),
            "gap": gap,
            "pos_scores": pos_s, "neg_scores": neg_s,
        })
        mark = "  <-- live" if abs(bias - LIVE_BIAS) < 1e-9 else ""
        print("%-7.2f | %.3f  %.3f  %.3f     | %.3f  %.3f            | %+.3f%s"
              % (bias, min(pos_s), statistics.median(pos_s), max(pos_s),
                 max(neg_s), statistics.median(neg_s), gap, mark))

    best = max(rows, key=lambda r: r["gap"])
    print()
    print("widest separation at bias %.2f  (gap %+.3f: safe tops out at %.3f, "
          "lowest NSFW is %.3f)" % (best["bias"], best["gap"], best["neg_max"], best["pos_min"]))

    # ---- what band would that imply ----------------------------------------
    print()
    print("With bias %.2f, a midpoint cut sits at %.3f."
          % (best["bias"], (best["neg_max"] + best["pos_min"]) / 2))
    for b in rows:
        if abs(b["bias"] - best["bias"]) > 1e-9:
            continue
        for lo, hi in ((0.25, 0.75), (0.35, 0.65), (0.40, 0.60)):
            miss = sum(1 for s in b["pos_scores"] if s < lo)
            fp = sum(1 for s in b["neg_scores"] if s >= hi)
            rev = (sum(1 for s in b["pos_scores"] if lo <= s < hi)
                   + sum(1 for s in b["neg_scores"] if lo <= s < hi))
            print("  band %.2f/%.2f -> %d NSFW mis-filed safe, %d safe mis-filed NSFW, "
                  "%d left to review" % (lo, hi, miss, fp, rev))

    json.dump({"temp": T, "live_bias": LIVE_BIAS, "model": e.MODEL_ID,
               "positives": pos_margins, "negatives": neg_margins, "sweep": rows},
              open(out, "w"), indent=1)
    print()
    print("written:", out)


if __name__ == "__main__":
    main()
