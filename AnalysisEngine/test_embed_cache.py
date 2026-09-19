#!/usr/bin/env python3
"""Prove the embedding cache: same video twice, second pass must skip the GPU.

Also proves the vectors on disk are reusable for a DIFFERENT question than the
one that created them -- the whole point of caching. Scores cached vectors
against an event-category prompt set without re-embedding anything.
"""
import os, sys, time, glob, json, importlib.util, tempfile, shutil

ENG = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer/engine/engine.py")


def load():
    spec = importlib.util.spec_from_file_location("e", ENG)
    m = importlib.util.module_from_spec(spec)
    sys.modules["e"] = m
    spec.loader.exec_module(m)
    return m


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else "/Volumes/media/videos"
    vids = sorted(glob.glob(os.path.join(folder, "*.mp4")))[:3]
    if not vids:
        print("no videos"); sys.exit(1)

    e = load()
    import torch
    req = {"id": "cachetest", "op": "analyse"}
    print("cache dir :", e.EMBED_CACHE)
    print("model     :", e.MODEL_ID)
    e.ensure_model(req)

    # sample once, reuse the same jpgs for both passes so we time embedding only
    wd = tempfile.mkdtemp(prefix="fvp-cachetest-")
    frames = []
    try:
        for v in vids:
            sub = tempfile.mkdtemp(dir=wd)
            fs, _ = e.sample_frames(req, v, sub)
            frames += fs[:12]
        print("frames    :", len(frames))

        # wipe just these hashes so pass 1 is honestly cold
        hashes = [e._frame_hash(f) for f in frames]
        for h in hashes:
            try:
                os.remove(e._cache_path(h))
            except OSError:
                pass

        t0 = time.time(); s1, d1, h1 = e.frame_scores_cached(req, frames); t1 = time.time() - t0
        t0 = time.time(); s2, d2, h2 = e.frame_scores_cached(req, frames); t2 = time.time() - t0

        print()
        print("pass 1 (cold, embeds) : %6.2f s" % t1)
        print("pass 2 (warm, cached) : %6.2f s   speedup %.0fx" % (t2, t1 / max(t2, 1e-6)))
        print("scores identical      :", all(abs(a - b) < 1e-6 for a, b in zip(s1, s2)))
        print("hashes stable         :", h1 == h2)

        on_disk = sum(1 for h in hashes if os.path.exists(e._cache_path(h)))
        size = sum(os.path.getsize(e._cache_path(h)) for h in hashes
                   if os.path.exists(e._cache_path(h)))
        print("vectors on disk       : %d/%d  (%.1f KB, %.0f bytes each)"
              % (on_disk, len(hashes), size / 1024, size / max(on_disk, 1)))

        # --- the real payoff: a different question, no re-embedding ----------
        events = {
            "cruise ship": "a cruise ship at sea",
            "beach": "a beach with sand and ocean",
            "dancing": "people dancing at a party",
            "bedroom": "a bedroom interior",
        }
        keys = list(events)
        with torch.no_grad():
            tok = e._processor.tokenizer([events[k] for k in keys],
                                         padding=True, return_tensors="pt")
            tf = e._model.get_text_features(**tok.to(e._device)).float().cpu()
            tf = tf / tf.norm(dim=-1, keepdim=True)

        t0 = time.time()
        vecs = torch.tensor([e._cache_read(h) for h in hashes])
        sims = (vecs @ tf.T).mean(dim=0)
        t3 = time.time() - t0
        print()
        print("NEW QUESTION over the same cached vectors: %.3f s (no GPU embed)" % t3)
        for i, k in enumerate(keys):
            print("   %-12s %.3f" % (k, sims[i]))
        print()
        print("=> a new category costs %.3f s instead of %.2f s per %d frames"
              % (t3, t1, len(frames)))
    finally:
        shutil.rmtree(wd, ignore_errors=True)


if __name__ == "__main__":
    main()
