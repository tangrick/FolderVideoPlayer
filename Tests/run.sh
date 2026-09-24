#!/bin/bash
# Compiles the model layer with the test script and runs it against a
# throwaway folder. No Xcode, no framework, nothing that touches a real
# library. Usage: Tests/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fixtures: two files sharing a size and their bytes, two that do not, one
# text file, and a dot-directory that must not be listed.
mkdir -p "$work/media/clips" "$work/media/.hidden"
head -c 200000 /dev/urandom > "$work/media/clip1.mp4"
cp "$work/media/clip1.mp4" "$work/media/clips/copy-of-clip1.mp4"
head -c 150000 /dev/urandom > "$work/media/clip2.mp4"
head -c 170000 /dev/urandom > "$work/media/clip10.mp4"
echo hello > "$work/media/notes.txt"
head -c 1000 /dev/urandom > "$work/media/.hidden/secret.mp4"

swiftc -O -o "$work/tests" \
    "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$here/main.swift"
"$work/tests" "$work/media"

# Phase D gate: label grouping and the both-classes training gate, standalone.
swiftc -O -o "$work/train_labels" "$here/test_train_labels.swift"
"$work/train_labels"

# The AI capability probe: what the app reports on a machine with nothing
# installed. Standalone, because the point is the bare-Mac case this one is not.
swiftc -O -o "$work/ai_capability" "$here/test_ai_capability.swift"
"$work/ai_capability"

# Check for Updates: version comparison and GitHub's release reply, no network.
# Top-level test code must be main.swift once a second file is compiled with it.
mkdir -p "$work/update_check"
cp "$here/test_update_check.swift" "$work/update_check/main.swift"
swiftc -O -o "$work/update_check/run" "$model/UpdateCheck.swift" "$work/update_check/main.swift"
"$work/update_check/run"

# The FFmpeg fallback: the remux/transcode decision and the cache, plus — when
# FFmpeg is installed — a real remux and transcode checked playable by
# AVFoundation, and a cancelled run that must leave nothing behind.
mkdir -p "$work/playable_copy"
cp "$here/test_playable_copy.swift" "$work/playable_copy/main.swift"
swiftc -O -o "$work/playable_copy/run" "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" \
    "$work/playable_copy/main.swift"
"$work/playable_copy/run"

# The prompt table, against numpy's own arithmetic on the same file.
sh "$here/run_prompt_table.sh"

# The whole classify path through AnalysisEngine itself, in Core ML mode.
sh "$here/run_coreml.sh"

# Phase 3: the logistic heads, against engine.py's own fits.
sh "$here/run_logistic_head.sh"

# Phase 3: the same heads on disk — merge, round trip, refusal.
sh "$here/run_trained_heads.sh"

# Phase 3: the look-alike search, against engine.py's own tag_candidates.
sh "$here/run_look_alikes.sh"

# ...and its person half: the same button on a tag that names someone, ranked
# on face vectors alone. No engine parity — it is the app's own question.
sh "$here/run_face_look_alikes.sh"

# Phase 3: the library-tag prototypes, against engine.py's own prototypes and
# baseline — a fixture that writes a real cache tree for engine.py to walk.
sh "$here/run_tag_prototypes.sh"

# Phase 4: the whole suggester — four sources merged, ranked and capped,
# against engine.py's own `suggest_tags`.
sh "$here/run_tag_suggester.sh"

# The neighbour prior: what the videos shot around one video say about a tag.
# Pure arithmetic on a fixed clock — no model, no cache tree, no engine.py.
sh "$here/run_neighbour_prior.sh"

# Where a tag came from: read off the file, or guessed from the picture.
sh "$here/run_tag_provenance.sh"

# The facts READ off the files — date, resolution, camera, GPS place — in a
# store of their own, apart from the tags, and the one-time move of them out of
# the tag store. Pure, and the invariant it checks is that no name is lost.
sh "$here/run_metadata_facts.sh"

# Phase 5: the download experience — checksums, all-or-nothing installs, no
# half-installed model, and a catalogue that is reported rather than empty.
sh "$here/run_model_downloader.sh"

# T01: the frozen evaluation corpus — deterministic group splits, video-level
# grading against human labels, and the benchmark runner's honesty.
sh "$here/run_eval_corpus.sh"

# T05: the explicit job ledger — crash-safe persistence, obsolete/foreign job
# refusal, profile isolation, and a runner that records what actually happened.
sh "$here/run_job_ledger.sh"

# T06: the shared sampling plan — source-revision binding, the adaptive
# layout's budget guarantee, counters, and the comparison's honesty rules.
sh "$here/run_sampling_plan.sh"

# T05 continued: the versioned evidence store — timed evidence and decisions,
# transcript search (FTS5 where the runtime has it), schema migration with a
# backup first, and a refusal of a file this app did not write or a NEWER one.
sh "$here/run_evidence_store.sh"

# T07's producer half: per-frame prompt-table scores become reviewable timed
# evidence — one row per run of sightings, confidence not averaged, gaps honest
# — and a re-run replaces its own UNANSWERED proposals instead of doubling the
# review list, while what a human answered and other revisions survive.
sh "$here/run_evidence_proposal.sh"
sh "$here/run_evidence_journal.sh"

# T08's first slice: a video becomes the one signal a speech model takes, with
# nothing installed — real AAC decoded, silence left silent, no-audio answered,
# and a time window really honoured, because a long film is read in pieces.
sh "$here/run_audio_extraction.sh"

# T08's fourth slice: the pass that turns a video's audio into searchable lines.
# What it writes, what it replaces, and — the two that matter most — what it
# must NEVER write: a cancelled pass and a file that changed mid-read both
# leave the store untouched. Run against a fake transcriber, so the suite needs
# no model and no 646 MB download.
sh "$here/run_speech_pass.sh"

# T08's runtime half: the speech dependency is PINNED (an exact version at a
# known commit), LINKED into the app target, and nothing may reach the SDK's own
# downloader — the catalogue is the trust anchor, not the SDK.
sh "$here/check_speech_runtime.sh"

# T08's pack half: the catalogue the release publishes, judged by the app's own
# validator — including that the speech bundle's install paths land where the
# Speech row reads, and that its adapter is accepted for speech and refused as
# any other feature's model. Skips when no packed catalogue is present (dist/ is
# build output, not a repository file).
sh "$here/run_catalogue_check.sh"

# Hidden videos: the password is a credential, a broken record locks rather
# than opens, and hiding leaves everything else about a video untouched.
sh "$here/run_hidden.sh"

# Phase 6: the ported face engine (YuNet + alignCrop + SFace) — the transform,
# the /32 padding and the integer-box NMS always, the detections, crops and
# cosines against cv2 when the fixture and the packages are on this machine.
sh "$here/run_face_engine.sh"

# Phase 6: the face registry — the cache key, the per-profile name registry,
# the matcher, the similar-face ranking and the prominence clustering, against
# engine.py's own face commands on a cache tree the fixture writes.
sh "$here/run_face_registry.sh"

# The Sep '26 feature batch: bulk tag-a-folder, star ratings, and renaming a
# person in the face registry — each one the user's judgement, so each has to
# survive a relaunch, a repair and a refusal.
sh "$here/run_features.sh"

# A profile as one document: the bundle layout every per-profile path is built
# from, and the one-time migration's own rules — copies rather than moves, runs
# once, and never resurrects a profile the user deleted.
sh "$here/run_profile_bundle.sh"

# Reject corrupt or incompatible installed visual-space identities before inference.
sh "$here/run_model_space_validation.sh"

# Which model pack each AI capability uses: one recorded choice per capability,
# an incompatible pack refused with its reason, and nothing-chosen behaving as it
# did before choices existed.
sh "$here/run_model_selection.sh"
# The kept versions of an installed pack: an install keeps a copy so an older
# revision can be switched back to without a download.
sh "$here/run_model_store.sh"

# The document's File-menu behaviour: close empties the tagging surfaces and
# nothing else, a reopen reads the bundle back, publish state is stamped only
# by real writes, and the device name is editable.
sh "$here/run_profile_document.sh"

# Named people and transcripts following a profile to another Mac beside its
# tags: a new Mac takes all of it, a rename or a forget carries as one, and a
# newer file on the share is left alone.
sh "$here/run_shared_extras.sh"
