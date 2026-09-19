# Custom Video Classification & NSFW Library — Design for FolderVideoPlayer (macOS)

Scope: implement the attached technical specification (Custom Video Classification
& NSFW Library) as a native feature of FolderVideoPlayerSwift. Everything local,
model-agnostic, Apple-Silicon-first. This doc maps the spec onto the code that
exists, states the decisions, and lays out the build order. It is the
source-of-truth design note; the code and the test suite follow it.

## 0. What the spec really asks for

A pipeline: scan library → sample frames → embed them with a local vision model →
classify (NSFW first, custom categories later) → store everything with provenance
(which model, which sampling, which aggregation) → let the user correct results →
retrain small classifiers from corrections → browse/search. Two hard requirements
shape every choice:

1. **Model-agnostic**: the app must not depend on one model. CLIP ViT-L/14 is a
   baseline, not the architecture. Swapping the embedder or classifier must not
   touch the app, the database, or the UI.
2. **Local & private**: nothing leaves the Mac. NAS-hosted files are analysed
   over the OS SMB mount without copying the library.

## 1. What already exists (reuse, don't rebuild)

| Need | Already in the app |
|---|---|
| Folder scan incl. mounted NAS | `Scanner`, `MovedScan` (button-only, scoped to a folder/view), `NameIndex` per-share cache |
| A video's identity that survives across devices | path keys (`Paths.tagKey`) — share-relative on `/Volumes` |
| User categories vocabulary | tags + tag profiles + `.FolderVideoPlayer` share sync (tags ARE the user's categories; spec §12 CRUD = existing tag editing) |
| Poster/thumb extraction | `MediaCache` (AVAsset, but only mp4/m4v/mov/avi) |
| Non-modal background progress UI pattern | MovedScan panel + AutoTag sheet phases, `Task.detached` + bounded pools (6 in flight), never freeze the window |
| Safe JSON persistence with SMB-robust writes | `JSONStore` |
| Undoable destructive edits | `rememberForUndo` pattern |
| Secondary utility windows | `DuplicatesWindow`, `TagProfilesWindow` scenes in the App struct |
| Testable pure model layer | `Tests/run.sh` swiftc harness (add new Model files by hand) |

Gap: the app has no embedding/classification store and no ML runtime. That is
the new work.

## 2. Machine probe (this Mac, Sep 2026)

Apple M4 Pro, 64 GB RAM, macOS 26.6. `/opt/homebrew/bin/ffmpeg` 9.0.1 present.
Python 3.10 base env at `/opt/anaconda3` has torch 2.2.1 (MPS available),
transformers, scikit-learn 1.6.1, onnxruntime — **no mlx**. The bonsai-image-demo
venv has **mlx 0.31.1** (proof MLX runs fine here). No CLIP/SigLIP weights
cached anywhere yet.

## 3. Architecture decision — the Analysis Engine boundary

**The app (Swift) never links a model. Inference lives in a separate local
"Analysis Engine" process (Python + PyTorch/MPS) that the app spawns and talks
to over a versioned JSON-lines protocol on stdio.**

> **Shipped as PyTorch, not MLX.** This section originally specified MLX. When
> the engine was built there was no MLX port of CLIP ViT-L/14, and torch 2.2.1
> with the MPS backend was already present in the base env. Measured on the
> M4 Pro: **36.9 ms/frame** (fp16, batch 32) — fast enough that the runtime
> choice is not the bottleneck. MLX stays a candidate; the process boundary is
> what makes it swappable, which is the point of this section.

```
FolderVideoPlayer.app (SwiftUI)
   │  spawns / manages        JSON-lines over stdio
   ▼                         ┌─────────────────────────────┐
ClassificationStore ───────► │ Analysis Engine (Python+MLX) │
(Model/ JSON files)          │  registry  embed  classify   │
   ▲                         │  sample    aggregate  train  │
   │                         └─────────────────────────────┘
   └── Review window, row badges, sidebar (UI)
```

Why this and not in-app Swift inference:
- The spec *is* written as Python interfaces with a model registry, benchmarks,
  sklearn-style classifiers and per-model profiles. A Python engine implements
  the whole spec (new models, dedicated NSFW classifiers, SigLIP 2, video
  models) with zero app rebuilds — model swap = registry entry + weights.
- MLX is the right Apple-Silicon runtime and is Python-first.
- The engine's RAM/CPU budget (2–5 GB, GPU frames) stays out of the app process,
  so classification never degrades playback.
- MAS-sandbox caveat: a bundled engine complicates a future sandboxed build.
  The Mac app is currently DMG/adhoc-distributed; revisit if MAS becomes the
  distribution channel (same caveat as the homebrew ffmpeg dependency — record
  it, don't block on it).
- The engine is optional at runtime: absent/broken engine → app degrades to
  today's behaviour plus a clear "Analysis engine not installed" state. The
  player never waits on the engine.

Engine placement: dedicated env at `~/.foldervideoplayer-engine` (uv-managed,
Python 3.10, mlx + numpy), weights under `~/Library/Application Support/
FolderVideoPlayer/models/`. First run downloads public weights (~0.3–1.7 GB);
all analysis is local. Engine version handshake + capability listing = the app's
"model registry" view.

## 4. Protocol (the spec's interfaces, made concrete)

One request → one JSON object per line, one reply per line. Every request names
a `request_id`. Methods v1:

| Method | Purpose | Spec section |
|---|---|---|
| `hello` | engine + model registry: `{embedding_model, dim, version, runtime, device}`, classifier list, sampling/aggregation strategies available | §3, §22 |
| `sample_frames {video, strategy}` | ffmpeg sampling → frame image files (temp), returns timestamps + hashes | §7 |
| `embed {video, frames}` | frame embeddings; cache hits skipped; returns per-frame vectors (binary side-channel) | §6, §30 |
| `classify_nsfw {video_id, frames, embeddings}` | per-frame scores + video-level aggregation, raw frame scores retained | §8–§10 |
| `suggest_tags {frames}` | (V2) per-tag logistic predictions from trained embeddings | §14 |
| `train {classifier_id, dataset}` | retrain the small custom classifier from labeled examples | §17–§21 |
| `similar {embedding, k}` | (later) similarity search over the embedding index | §26 |

Reply includes `{model_id, classifier_version, sampling, aggregation}` so every
stored result is reproducible (spec §10, §22). A `ping`/`cancel` pair lets the UI
pause/resume and the app kill work on window close.

## 5. Storage — follow the app's JSON conventions, not SQLite (yet)

The spec proposes SQLite; this app has none and its data model is
path-keyed JSON with atomic SMB-safe writes. Honest call: single-file JSON with
debounced writes holds comfortably to tens of thousands of videos; the
performance-critical part — embeddings — is binary regardless of store choice.
Introduce SQLite only if measured search/filter cost demands it (same bar the
spec's own "don't over-engineer" section sets).

Files under `Paths.support` (all keyed on `Paths.tagKey(path)`, model-versioned):

- `analysis.json` — per-video record:
  ```json
  { "videos/<path-key>": {
      "state": "queued|sampled|embedded|classified|reviewed",
      "nsfw": { "score": 0.94, "max": 0.97, "mean": 0.11,
                "frames": 143, "above": 119, "threshold": 0.6,
                "aggregation": "weighted_max_frac", 
                "model_id": "clip-vit-l14", "sampling": "uniform_5s_cap250",
                "classifier": "zeroshot-nsfw-v1", "classified_at": 0.0 },
      "user": { "label": null, "corrected_at": null },   // user > automatic
      "reviewed": false, "suggested": [] } }
  ```
- ~~`analysis.progress.json`~~ — **not built, and not needed.** The queue lives
  in `analysis.json` as each record's `phase`, so an interrupted scan resumes
  from the store itself (`rescueStaleAnalyses` returns rows abandoned mid-run
  to the queue). One file, one write path, same guarantee.
- `frames/<model_slug>/<hh>/<hash>.f32` — raw frame embeddings. **Built and
  verified Sep 2026** (see §5a below). The model slug in the path keeps
  embedding spaces from ever mixing (§24) and leaves an old model's vectors in
  place rather than deleting them (§23). Each record's `frameScores` array
  holds `at` + `score` + `hash`, so re-aggregation needs no re-embedding (§8).
- JSON files follow the app's 4-step persisted-field pattern (optional var +
  CodingKey + load + save) and the store ships in `Tests/run.sh`.

### 5a. The embedding cache — why it is the centre of the design

Embedding is ~all of the cost of a pass; every question asked of an embedding
is a dot product costing microseconds. So the vectors, not the verdicts, are
the asset worth keeping.

Measured on this Mac (21 frames, CLIP ViT-L/14):

| Pass | Time |
|---|---|
| Cold (embeds, writes cache) | 0.89 s |
| Warm (reads cache) | 0.00 s — **376×** |
| A *different* question over the same cached vectors | 0.002 s |

That last row is the design decision. A new category, a retuned prompt pool, a
retrained head, "which of these has Dad in it" — each is a fresh dot product
over vectors already paid for. Without the cache every one of them is a full
re-scan of the library; with it, seconds. At 3 KB per frame a 3,000-video
library costs roughly 70–270 MB, which is nothing against ~1.2 h of recompute.

Implementation notes that matter:

- **Keyed on frame content, not path.** The hash is SHA-256 of the sampled
  JPEG's bytes. Renaming or moving a video on the NAS keeps every vector it
  has already earned; two videos sharing a frame share the vector.
- **Two-level fan-out** (`<hash[:2]>/<hash>.f32`) — a flat directory of a
  million files is slow on any filesystem and hopeless over SMB.
- **Temp-then-rename writes.** A crash mid-write can never leave a truncated
  vector that a later run would read back as real data. Short or wrong-dimension
  files are treated as a miss and re-embedded.
- **Best-effort.** A full disk degrades to today's behaviour (recompute); it
  never fails an analysis.

**Early exit.** Video aggregation is `max`, so once `EARLY_EXIT_HITS` (3)
frames clear the confident-NSFW line the verdict cannot change and the
remaining frames are embedded for nothing. Measured over 68 videos: saves ~26%
of embeddings, changes **0** verdicts. It rarely fires on short home clips —
it exists for long recordings, where the waste would otherwise be worst.

Swift model additions (all pure logic, unit-tested):
`AnalysisModels.swift` (structs + thresholds), `AnalysisStore.swift` (queue,
records, corrections, resume), later `AnalysisEngineClient.swift` (protocol +
stdio client — protocol-first so a future in-app Core ML engine can conform).

## 6. Model selection (spec §3–§5) — recommendation, not assumption

Baseline to actually ship v1: **CLIP ViT-L/14 (open_clip LAION-2B, MLX bf16,
768-d) for embeddings + zero-shot NSFW scoring with a prompt ensemble**, because
it needs zero training data and works the day weights land. Candidates in the
registry from day one, benchmarked against each other with the user's own
calibration set (§5 of spec, below):

| Candidate | Role | Notes |
|---|---|---|
| CLIP ViT-L/14 (LAION-2B) | embedder baseline | spec's pick; good NSFW zero-shot, ~1.7 GB |
| CLIP ViT-B/32 | fast embedder | ~4× faster, for the bulk pass + retrains |
| SigLIP 2 (when MLX port) | embedder candidate | needs evaluation, don't assume better |
| MobileCLIP-family NSFW-tuned or Falconsai-style ViT classifier | dedicated NSFW | swap-in entry; beats zero-shot on precision once labeled data exists |
| Logistic regression (sklearn) on stored embeddings | custom classifier | the "learn from your tags" head (V2) |

Zero-shot NSFW scoring: per-frame CLIP similarity against a fixed prompt set
(a NSFW pool and a neutral pool), frame score = `sigmoid(T · (best_nsfw −
best_neutral − bias))`, video score = max over frames. Frame scores stay raw so
the aggregation policy can be tuned without re-embedding.

**Calibration status (Sep 2026) — done, on both classes.** v1's bias was set
from safe frames only, because no positives existed yet. It has since been
swept against 18 known-explicit and 24 known-safe videos from this library,
re-deriving each frame's raw margin analytically so every candidate bias saw
identical embeddings:

| bias | lowest NSFW | highest safe | gap |
|---|---|---|---|
| 0.02 | 0.651 | 0.556 | +0.095 |
| **0.03** | **0.556** | **0.456** | **+0.099** ← shipped |
| 0.04 | 0.456 | 0.360 | +0.096 (v1 guess) |
| 0.06 | 0.274 | 0.202 | +0.072 |

The two classes are **disjoint at every bias tested** — the model separates
this library cleanly; only the placement was in question. At the shipped bias:
detection 18/18, nothing explicit mis-filed as safe, and the app's auto-file
band (0.35 / 0.65) sits inside the empty gap between the classes.

**Honest limits of that calibration:** 42 videos, and all 18 positives come
from one source. The ~0.1 gap should not be read as a guarantee for content
neither class covered — film, art, medical, beach footage. That is exactly why
the band is kept wider than the measured gap requires: unfamiliar content lands
in review rather than being filed wrongly. The user's manual marks outrank all
of it, and every verdict records the bias that produced it.

Throughput, **measured** (M4 Pro, torch MPS fp16, batch 32, Sep 2026):
**36.9 ms/frame**. Frame counts from 68 real videos in this library: median 6,
mean 7.8, max 45 — the 250-frame cap never bound, because home clips are
short. A 3,000-video first pass is therefore ≈ **15 min of GPU + ~1 h of
ffmpeg ≈ 1.2 h**, not the multi-hour figure a cap-bound estimate suggests.
Re-runs cost seconds once embeddings are cached (§5a). Everything is
pause/resume-able; the size+mtime gate for changed files is still to build.

## 7. Sampling (spec §7) — pluggable, default uniform + dedupe

Default strategy `uniform-fps-1/5s-cap250`: one ffmpeg pass with `fps=1/5`
at 384 px wide, JPEG q3, capped at 250 frames by keeping an evenly spaced
subset.

> **Sequential decode beats per-frame seeking — measured.** This section
> originally specified seeking to N timestamps. On a 30-minute test video:
> one decode pass **7.0 s** vs 250 individual `-ss` seeks **12.8 s**. Seeking
> pays a container-open and keyframe-hunt per frame; one pass streams. The
> code does the faster thing; this doc was wrong.
>
> Near-duplicate frame dedupe is specified here but **not implemented**. With
> a median of 6 frames per video it would save little; revisit if long
> recordings become common. Scene-detection and
keyframe strategies are registry entries the engine advertises; swap without
app changes. Per-frame results carry `timestamp` + `hash` for provenance.

## 8. UI — where classification lives in this app

Design follows the house rules: nothing auto-runs, non-modal, panels in
context, review = reversible, unknown surfaces ask before guessing.

**1. "Review & Classify" window** (new Window scene, like Find Duplicates —
⌥⌘C under a new "Library" menu):
- Scope strip at top: re-aim the analysis at what the player is showing (⎇
  toolbar button, same contract as MovedScan) or pick a folder. **Scan is
  button-only** — no auto-scan on open.
- Engine status footer: model id, dim, version, "engine not installed" state
  with the install path shown.
- Main view = the queue + results. Queue row: name, phase (queued/sampling/
  embedding/classifying), progress bar; pause/resume; Scan / Resume buttons.
- Results are grouped tabs the review workflow needs: **Needs Review**
  (score in the uncertain band — the active-learning queue, spec §17), **NSFW**,
  **Safe**, plus **Unclassified**. Each row: poster thumb, name, score meter,
  frames-above-threshold, model tag, per-row actions: **Mark Safe / Mark NSFW**
  (writes `user.label`, source `user_correction`, timestamped, higher trust than
  the model — §18) and a **Review** toggle that empties the Needs Review queue
  as the user works it.
- Multi-select + batch mark. Every correction is undoable via the existing
  undo pattern.

**2. Playlist row badges** — beside the existing missing/corrupted badges: a
small marker on classified rows (NSFW badge / safe check) that opens the review
window when clicked. Grey = queued but not done yet.

**3. Library sidebar section (phase 2)** — a "Review & Classify" group under
the tag list offering *NSFW · Safe · Needs Review · [your categories]* as
one-click playlists, reusing the playlist mode machinery the way `.tag` does.

**4. TagPanel "Suggested" chips (phase 2, spec §12–§16)** — after the first
custom classifier trains on the user's existing tags, the tag panel offers a
suggested-tag row ("from the look of it") on untagged videos; applying a
suggestion is a user act → training data. Single- and multi-label both fall out
of per-tag logistic heads.

Window/menu wiring follows `FolderVideoPlayerApp.swift` scenes + `Menus.swift`
exactly (fourth Window scene, `openWindow(id: "analysis")`).

## 9. Review/correction → retrain loop (spec §17–§21)

Every correction appends to a labeled-example log (video, frame hashes,
label, source, timestamp) — never overwrites. When the labeled set grows by ≥ 20
new examples since the last fit (or on demand), the engine refits the small
classifier over *stored embeddings only* (no re-embedding, §30), reports
per-class precision/recall on the held-out videos (frames grouped by video —
no leakage, §20), and the window shows "classifier v3 trained — F1 0.92 on 14
held-out videos". Versioned classifiers let the user compare and revert.

## 10. Build order (each step ends green: build + tests + your QA, split commits)

1. **Phase A — Foundation (pure Swift, no engine yet):** `AnalysisModels.swift`
   + `AnalysisStore.swift` (queue/resume, records, corrections) + tests;
   `analysis.json` wiring; Review window shell showing the queue over real
   scanned files with manual Mark Safe/NSFW working end-to-end (this is also
   the calibration-labeling tool). Commit split: store+models, then window.
2. **Phase B — Engine v1:** engine env + `hello`/`sample_frames`/`embed`/
   `classify_nsfw` (CLIP ViT-L/14 zero-shot); `AnalysisEngineClient` in Swift;
   engine-status footer; wire window buttons to a real background scan with
   pause/resume over SMB-mounted folders. Threshold calibrated on the labels
   collected in Phase A.
3. **Phase C — Review polish:** grouped result tabs, row badges, uncertainty
   band tuning, incremental "scan new/changed only".
   *Status Sep 2026:* grouped sections, Failed group + Retry, Finder-standard
   multi-select, and the auto-file confidence band are **done**; the band is
   calibrated (§6). Row badges and the mtime/size "changed files only" gate are
   still open.
4. **Phase D — Learn from your tags:** `train`/`suggest_tags`, TagPanel
   Suggested chips, correction-driven retrain with honest held-out metrics.
   **This is the next build.** The user's decision (Sep 2026): tags *are* the
   categories — no fixed taxonomy is imposed. Tag a few dozen videos and a
   per-tag logistic head fits over the cached embeddings in seconds, then
   suggests that tag across the library; applying or rejecting a suggestion is
   more training data.

   Feasibility probed and recorded, one embedding pass answering many
   questions:
   - **An NSFW-only tag pair** (the paired tags, from the private vocabulary)
     — 9 of 10 known-NSFW videos called correctly from prompts alone. Viable
     as prompts, better once trained.
   - **Event categories** (birthday, dancing, cruise…) — mixed. Confident and
     right where the scene is distinctive (cruise 92–100%), unreliable
     elsewhere ("wedding" fired on ordinary indoor gatherings). Softmax over a
     fixed list always names a winner, so events need **per-category
     thresholds and a "none of these" outcome**, not winner-take-all. This is
     the argument for training on the user's own tags rather than shipping a
     prompt taxonomy.

5. **Phase E — Faces (new).** `Vision.framework` does face *detection*
   natively in Swift (`VNDetectFaceRectanglesRequest`, confirmed available);
   face *identity* needs its own small embedding model and a "name this person
   once" UI that propagates. Separate pipeline from CLIP, separate vector
   store, biggest build of the remaining work — do it last.
6. **Phase F — Benchmark harness** (spec §5): pick a representative subset,
   compare registry entries, produce the precision/recall/speed table. The
   calibration and frame-count scripts in `AnalysisEngine/` are the start of
   this: `calibrate_positive.py`, `calibrate_sweep.py`, `test_embed_cache.py`,
   `test_frame_count.py`, `probe_multicategory.py` — all read-only against the
   live store.

## 11. Open decisions for the user

- Feature/UI naming (window title, menu wording).
- Which embedder to start the bulk pass with (L/14 accuracy vs B/32 speed) —
  Phase B ships both in the registry; the benchmark settles it.
- Accepting the first-run weight download (~0.3–1.7 GB) and a dedicated engine
  env on this Mac.
