#!/usr/bin/env python3
"""Positive-control calibration for the FolderVideoPlayer analysis engine.

Scores a folder of VIDEOS (or images) through the exact scoring path the live
engine uses -- same model, same prompt pools, same sampling cadence, same
MARGIN_BIAS / MARGIN_TEMPERATURE / aggregation -- and reports the score spread
against the app's auto-file band.

Read-only. It never touches analysis.json and never writes into the app's
support folder. Videos are sampled into a temp dir that is removed after.

    python3 calibrate_positive.py <folder> [--label NSFW] [--limit N]
"""
import sys, os, glob, importlib.util, statistics, tempfile, shutil

ENGINE = os.path.expanduser(
    "~/Library/Application Support/FolderVideoPlayer/engine/engine.py")

VIDEO_EXTS = ("mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg")
IMAGE_EXTS = ("png", "jpg", "jpeg", "webp")

# The app's confidence band (AnalysisStore.confidentSafeBelow / NsfwAbove).
BAND_SAFE = 0.25
BAND_NSFW = 0.75


def load_engine():
    spec = importlib.util.spec_from_file_location("fvp_engine", ENGINE)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load engine at " + ENGINE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fvp_engine"] = mod
    spec.loader.exec_module(mod)
    return mod


def find(folder, exts):
    out = []
    for e in exts:
        for pat in (e, e.upper()):
            out += glob.glob(os.path.join(folder, "**", "*." + pat), recursive=True)
    return sorted(set(out))


def main():
    argv = sys.argv[1:]
    label = "NSFW"
    limit = None
    if "--label" in argv:
        label = argv[argv.index("--label") + 1]
    if "--limit" in argv:
        limit = int(argv[argv.index("--limit") + 1])
    pos = [a for a in argv if not a.startswith("--")]
    # drop values that belong to flags
    for flag in ("--label", "--limit"):
        if flag in argv:
            v = argv[argv.index(flag) + 1]
            if v in pos:
                pos.remove(v)
    if not pos:
        print(__doc__)
        sys.exit(2)
    folder = os.path.expanduser(pos[0])

    videos = find(folder, VIDEO_EXTS)
    images = find(folder, IMAGE_EXTS)
    if limit:
        videos, images = videos[:limit], images[:limit]
    if not videos and not images:
        print("nothing scoreable under", folder)
        sys.exit(1)

    e = load_engine()
    req = {"id": "calibration", "op": "analyse"}

    print("engine :", ENGINE)
    print("model  :", e.MODEL_ID)
    print("params : bias=%s temp=%s threshold=%s interval=%ss maxframes=%s"
          % (e.MARGIN_BIAS, e.MARGIN_TEMPERATURE, e.NSFW_THRESHOLD,
             e.SAMPLE_INTERVAL_S, e.MAX_FRAMES))
    print("videos : %d   images: %d" % (len(videos), len(images)))
    print("loading model...", flush=True)
    e.ensure_model(req)

    results = []   # (video_score, frames, above, top_label, name)

    for i, v in enumerate(videos, 1):
        name = os.path.basename(v)
        print("[%d/%d] %s" % (i, len(videos), name[:60]), flush=True)
        workdir = tempfile.mkdtemp(prefix="fvp-calib-")
        try:
            paths, indices = e.sample_frames(req, v, workdir)
            if not paths:
                print("      no frames sampled -- skipped")
                continue
            scores, dominant = e.frame_scores(req, paths)
            if scores is None:
                print("      cancelled")
                continue
            vs = max(scores)
            above = sum(1 for s in scores if s >= e.NSFW_THRESHOLD)
            top = None
            if dominant:
                best = max(range(len(scores)), key=lambda k: scores[k])
                top = dominant[best]
            results.append((vs, len(scores), above, top, name))
            print("      score %.3f  (%d frames, %d above %.2f)  %s"
                  % (vs, len(scores), above, e.NSFW_THRESHOLD, str(top or "")[:40]),
                  flush=True)
        except Exception as exc:
            print("      FAILED:", exc)
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    if images:
        scores, dominant = e.frame_scores(req, images)
        if scores:
            for s, d, p in zip(scores, dominant, images):
                results.append((s, 1, 1 if s >= e.NSFW_THRESHOLD else 0,
                                d, os.path.basename(p)))

    if not results:
        print("nothing scored")
        sys.exit(1)

    results.sort()
    scores = [r[0] for r in results]
    n = len(scores)
    thr = e.NSFW_THRESHOLD

    print()
    print("%-8s %-7s %-40s %s" % ("score", "frames", "closest explicit phrase", "file"))
    for vs, nf, above, top, name in results:
        print("%-8.3f %-7s %-40s %s" % (vs, "%d/%d" % (above, nf), str(top or "")[:40], name[:56]))

    hit = [s for s in scores if s >= thr]
    auto_nsfw = [s for s in scores if s >= BAND_NSFW]
    band = [s for s in scores if BAND_SAFE <= s < BAND_NSFW]
    auto_safe = [s for s in scores if s < BAND_SAFE]

    print()
    print("=== %s control, %d videos ===" % (label, n))
    print("min %.3f   median %.3f   mean %.3f   max %.3f"
          % (min(scores), statistics.median(scores), statistics.mean(scores), max(scores)))
    print()
    print("detection rate (>= %.2f)        : %3d / %d (%3.0f%%)" % (thr, len(hit), n, 100.0*len(hit)/n))
    print("auto-file NSFW  (>= %.2f)       : %3d / %d (%3.0f%%)" % (BAND_NSFW, len(auto_nsfw), n, 100.0*len(auto_nsfw)/n))
    print("review band  (%.2f - %.2f)      : %3d / %d (%3.0f%%)" % (BAND_SAFE, BAND_NSFW, len(band), n, 100.0*len(band)/n))
    print("AUTO-FILE SAFE  (< %.2f)        : %3d / %d (%3.0f%%)   <- silently mis-filed"
          % (BAND_SAFE, len(auto_safe), n, 100.0*len(auto_safe)/n))

    if auto_safe:
        print()
        print("MISSED -- would land in Safe with no review:")
        for vs, nf, above, top, name in results:
            if vs < BAND_SAFE:
                print("  %.3f  %s" % (vs, name))


if __name__ == "__main__":
    main()
