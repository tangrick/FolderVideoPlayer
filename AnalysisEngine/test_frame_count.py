#!/usr/bin/env python3
"""How many frames does a verdict actually need?

Samples each control video at the full cadence ONCE (embeddings land in the
cache), then re-derives the video verdict from the first N frames, from N
evenly-spaced frames, and with an early-exit rule. Because everything is
scored from cached vectors, every strategy sees identical embeddings and the
comparison is exact rather than a re-run.

Reports, per strategy: how many videos change bucket versus the full-cadence
answer -- the only number that matters, since the bucket is what the app files.
"""
import os, sys, glob, json, importlib.util, tempfile, shutil, time

ENG = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer/engine/engine.py")
STORE = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer/analysis.json")
BAND_SAFE, BAND_NSFW = 0.35, 0.65


def load():
    spec = importlib.util.spec_from_file_location("e", ENG)
    m = importlib.util.module_from_spec(spec)
    sys.modules["e"] = m
    spec.loader.exec_module(m)
    return m


def bucket(score):
    if score < BAND_SAFE:
        return "Safe"
    if score >= BAND_NSFW:
        return "NSFW"
    return "Review"


def main():
    nsfw_dir = sys.argv[1] if len(sys.argv) > 1 else "/Volumes/media/videos"
    e = load()
    req = {"id": "framecount", "op": "analyse"}
    e.ensure_model(req)

    vids = [(p, "nsfw") for p in sorted(glob.glob(os.path.join(nsfw_dir, "*.mp4")))]
    # safe side: whatever of the user's library is reachable right now
    if os.path.exists(STORE):
        d = json.load(open(STORE))
        for k in d:
            p = "/Volumes/" + k
            if os.path.exists(p):
                vids.append((p, "safe"))
    print("videos:", len(vids), "(%d nsfw, %d safe)"
          % (sum(1 for _, c in vids if c == "nsfw"), sum(1 for _, c in vids if c == "safe")))

    per_video = []      # (name, cls, [frame scores in time order])
    for i, (p, cls) in enumerate(vids, 1):
        wd = tempfile.mkdtemp(prefix="fvp-fc-")
        try:
            frames, _ = e.sample_frames(req, p, wd)
            if not frames:
                continue
            scores, _dom, _h = e.frame_scores_cached(req, frames)
            if not scores:
                continue
            per_video.append((os.path.basename(p), cls, scores))
            print("[%d/%d] %-44s %2d frames  max %.3f"
                  % (i, len(vids), os.path.basename(p)[:44], len(scores), max(scores)), flush=True)
        except Exception as exc:
            print("  FAILED", os.path.basename(p), exc)
        finally:
            shutil.rmtree(wd, ignore_errors=True)

    if not per_video:
        print("nothing scored"); sys.exit(1)

    def evenly(scores, n):
        if len(scores) <= n:
            return scores
        step = len(scores) / n
        return [scores[int(i * step)] for i in range(n)]

    def early_exit(scores, need=3, thr=0.65):
        """Stop as soon as `need` frames clear `thr` -- the verdict is settled."""
        hits = 0
        for i, s in enumerate(scores, 1):
            if s >= thr:
                hits += 1
                if hits >= need:
                    return max(scores[:i]), i
        return max(scores), len(scores)

    truth = {n: max(s) for n, _c, s in per_video}
    total_frames = sum(len(s) for _n, _c, s in per_video)

    print()
    print("%-22s %8s %10s %10s %s" % ("strategy", "frames", "vs full", "bucket chg", "detail"))
    print("-" * 78)
    print("%-22s %8d %10s %10s" % ("full cadence (now)", total_frames, "-", "-"))

    for n in (4, 6, 8, 10, 12, 16):
        used = 0
        changed = []
        for name, cls, scores in per_video:
            sub = evenly(scores, n)
            used += len(sub)
            if bucket(max(sub)) != bucket(truth[name]):
                changed.append((name, cls, truth[name], max(sub)))
        print("%-22s %8d %9.0f%% %10d %s"
              % ("evenly %d frames" % n, used, 100.0 * used / total_frames, len(changed),
                 ", ".join("%s %.2f->%.2f" % (c[0][:16], c[2], c[3]) for c in changed[:2])))

    used = 0
    changed = []
    for name, cls, scores in per_video:
        sc, n_used = early_exit(scores)
        used += n_used
        if bucket(sc) != bucket(truth[name]):
            changed.append(name)
    print("%-22s %8d %9.0f%% %10d" % ("early exit (3 hits)", used,
                                      100.0 * used / total_frames, len(changed)))

    # combined: cap at 12 evenly spaced, with early exit inside that
    used = 0
    changed = []
    for name, cls, scores in per_video:
        sub = evenly(scores, 12)
        sc, n_used = early_exit(sub)
        used += n_used
        if bucket(sc) != bucket(truth[name]):
            changed.append((name, cls, truth[name], sc))
    print("%-22s %8d %9.0f%% %10d %s"
          % ("12 frames + early exit", used, 100.0 * used / total_frames, len(changed),
             ", ".join("%s %.2f->%.2f" % (c[0][:16], c[2], c[3]) for c in changed[:3])))

    print()
    print("Bucket changes are the number that matters: a different max score is")
    print("harmless as long as the video still files the same way.")


if __name__ == "__main__":
    main()
