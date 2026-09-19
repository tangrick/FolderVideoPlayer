#!/usr/bin/env python3
"""Task 6.3 — the face registry's gate: Swift's answers against engine.py's own.

`FaceRegistry.swift` ports the half of face recognition that is not a model:
the crop-keyed cache, the per-profile name registry, the matcher, the
similar-face ranking and the prominence clustering. None of those are places
where "looks right" is a standard — this fixture calls the real
`engine.face_people`, `engine._face_matches`, `engine.similar_faces`,
`engine.forget_person`, `engine.set_representative`, `engine.name_cluster` and
`engine.face_clusters` against a cache tree this script writes, and records what
they said.

    /opt/anaconda3/bin/python3 docs/coreml-spike/face_registry_parity.py [out.json]

No models, no video, no network. The tree is built here, so the interesting
cases can be deliberate rather than whatever a real library happened to contain:

  - a person whose first face has no thumbnail (the representative must be the
    first hash *with* one, not simply the first hash);
  - a person whose vectors were all pruned (`similar_faces` returns nothing
    rather than erroring; `_face_matches` skips them);
  - two vectors built to sit at cosine **0.301** and **0.299** from a person's
    anchor — either side of `FACE_MATCH_COSINE = 0.30`, which is the only way to
    pin a threshold rather than hope a random pair lands near it;
  - names that differ only in case, for the lookup rule.

The vectors are seeded, so the fixture is reproducible. Two properties are
ASSERTED rather than assumed, because the gate depends on them:

  1. **no ties** in `similar_faces` scores — Python's sort is stable and glob
     order is the filesystem's, so equal scores would make the expected list
     depend on directory order and the gate would be flaky, not wrong;
  2. **the cluster partition is order-independent** — greedy merging is
     order-sensitive in general, so the partition is recomputed under six
     permutations of `_all_face_hashes()` and all six must agree, or the
     fixture is ill-conditioned and says so.
"""

import base64
import json
import os
import shutil
import struct
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "AnalysisEngine"))

import numpy as np                                     # noqa: E402
import engine                                          # noqa: E402

NAME = "face_registry_fixture.json"
DIM = engine.FACE_DIM


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


def b64(vec):
    return base64.b64encode(np.asarray(vec, dtype="<f4").tobytes()).decode("ascii")


# ---------------------------------------------------------------------------
# the tree
# ---------------------------------------------------------------------------

def build(root, vectors, thumbs, registry):
    """Write the cache + registry an engine (and Swift) can be pointed at."""
    faces = os.path.join(root, "faces")
    profile = os.path.join(root, "profiles", "quincy")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(profile)

    for h, v in vectors.items():
        sub = os.path.join(faces, h[:2])
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, h + ".f32"), "wb") as fh:
            fh.write(struct.pack("<%df" % len(v), *v))

    # A thumbnail is only ever tested for EXISTENCE by both sides, so the bytes
    # do not matter — a real JPEG here would just be a slower way to say "yes".
    for h in thumbs:
        sub = os.path.join(faces, h[:2])
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, h + ".jpg"), "wb") as fh:
            fh.write(b"\xff\xd8\xff\xd9")

    with open(os.path.join(profile, "faces.json"), "w") as fh:
        json.dump(registry, fh)

    engine.SUPPORT_DIR = root
    engine.FACE_DIR = faces
    engine.PROFILE_DIR = profile
    engine.FACE_REGISTRY = os.path.join(profile, "faces.json")
    return faces, profile


# The commands this fixture drives, by the engine's own names. Listed rather
# than reached through the engine's dispatch chain (which is an if-ladder of
# `cmd == ...` in `main`, not a table) so the fixture can be called twice in a
# row without a stdin loop in the way.
COMMANDS = {
    "face_people": engine.face_people,
    "face_clusters": engine.face_clusters,
    "name_cluster": engine.name_cluster,
    "forget_person": engine.forget_person,
    "set_representative": engine.set_representative,
    "similar_faces": engine.similar_faces,
}


def call(req):
    """Run one engine command and hand back the messages it emitted.

    `report`/`done`/`err` all go through `engine.emit`, so capturing that gives
    the same lines the app's child process would have received.
    """
    captured = []
    original = engine.emit

    def capture(obj):
        captured.append(obj)

    engine.emit = capture
    try:
        COMMANDS[req["cmd"]](req)
    finally:
        engine.emit = original
    return captured


def result_of(req):
    for line in call(req):
        if line.get("type") == "result":
            return line
    return {}


def error_of(req):
    for line in call(req):
        if line.get("type") == "error":
            return line.get("message")
    return None


def partition(clusters):
    """Clusters as an order-free set of member sets — what the gate compares."""
    return sorted(sorted(c["hashes"]) for c in clusters)


# ---------------------------------------------------------------------------

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.expanduser("~/fvp-coreml-models"), NAME)

    rng = np.random.default_rng(20260913)

    # The person's anchor, and vectors built at chosen cosines from it. `at()`
    # puts the remainder in an orthogonal direction, so the achieved cosine is
    # the requested one and not "about that".
    anchor = unit(rng.normal(size=DIM))

    def at(cosine, base=None):
        base = anchor if base is None else np.asarray(base, dtype=np.float64)
        orth = rng.normal(size=DIM)
        orth = orth - orth.dot(base) * base
        return unit(cosine * base + np.sqrt(1 - cosine ** 2) * unit(orth))

    hashes = ["%02x%030x" % (i, i * 7919) for i in range(12)]
    h0, h1, h2, h3, h4 = hashes[:5]
    random = hashes[5:]

    vectors = {
        h0: anchor,
        h1: at(0.95),             # the same person, another angle
        h2: at(0.50),
        h3: at(0.301),            # just above FACE_MATCH_COSINE
        h4: at(0.299),            # ...and just below it
    }
    for h in random:
        vectors[h] = unit(rng.normal(size=DIM))

    # Deliberately absent from the cache: a person whose vectors were pruned.
    pruned = "%02x%030x" % (99, 12345)

    thumbs = {h3, h4, random[2], random[3]}
    base_registry = {
        "Quincy": [h0, random[2]],        # first has no thumb -> rep is the second
        "Mia Ong": [h2, random[3]],
        "Bob Meyer": [h3],
        "Zero": [pruned],                  # nothing cached behind it
    }

    work = tempfile.mkdtemp(prefix="fvp-face-registry-")
    try:
        faces, _profile = build(work, vectors, thumbs, base_registry)

        # --- cosine 0.301 / 0.299, asserted, not hoped for --------------------
        achieved = {
            h3: float(np.dot(vectors[h3], anchor)),
            h4: float(np.dot(vectors[h4], anchor)),
        }
        assert achieved[h3] >= engine.FACE_MATCH_COSINE, achieved
        assert achieved[h4] < engine.FACE_MATCH_COSINE, achieved

        # --- people -----------------------------------------------------------
        people = result_of({"id": 1, "cmd": "face_people"})["people"]

        # --- the matcher ------------------------------------------------------
        # A detected face is just a vector; the engine only ever sees vectors.
        detected_cases = [
            ("one face, exactly at the threshold", [vectors[h3]]),
            ("one face, just under it", [vectors[h4]]),
            ("a face built off a random ref", [at(0.6, vectors[random[3]])]),
            ("a miss plus a hit", [vectors[random[0]], at(0.6, vectors[random[3]])]),
            ("nothing to match", []),
        ]
        matches = []
        for label, detected in detected_cases:
            hits = engine._face_matches(detected, base_registry)
            matches.append({
                "label": label,
                "detected": [b64(v) for v in detected],
                "hits": {k: float(v) for k, v in hits.items()},
            })

        # --- similar faces ----------------------------------------------------
        similar = []
        for name in ["Quincy", "quincy", "Mia Ong", "Zero", "Nobody"]:
            payload = result_of({"id": 2, "cmd": "similar_faces", "name": name})
            similar.append({"name": name,
                            "faces": payload.get("faces", []),
                            "total": payload.get("total", -1)})

        # Scores must be distinct or the expected ORDER depends on glob order.
        # The person's own faces are the exception: each scores exactly 1.0
        # against itself, and they are excluded from the result anyway, so a tie
        # between two of them cannot move anything the gate compares.
        quincy = next(s for s in similar if s["name"] == "Quincy")
        if quincy["faces"]:
            own = set(base_registry["Quincy"])
            refs = [vectors[h] for h in base_registry["Quincy"] if h in vectors]
            scored = sorted(
                ((max(float(np.dot(vectors[h], r)) for r in refs), h)
                 for h in vectors if h not in own), reverse=True)
            values = [s for s, _h in scored]
            assert len(set(values)) == len(values), \
                "similar_faces scores tie — the fixture would be order-dependent"

        # --- forget -----------------------------------------------------------
        forget = []
        for name in ["quincy", "Bob Meyer", "Nobody"]:
            build(work, vectors, thumbs, base_registry)
            payload = result_of({"id": 3, "cmd": "forget_person", "name": name})
            forget.append({
                "name": name,
                "removed": payload.get("removed"),
                "found": payload.get("found"),
                "registry_after": engine._load_face_registry(),
            })
        build(work, vectors, thumbs, base_registry)

        # --- representative ---------------------------------------------------
        representative = []
        for label, name, h in [
            ("a face with a thumbnail", "Mia Ong", random[2]),
            ("another person's face", "Bob Meyer", random[2]),
            ("a face with no thumbnail", "Bob Meyer", random[0]),
            ("a name that is not there yet", "Nobody", random[2]),
        ]:
            build(work, vectors, thumbs, base_registry)
            payload = result_of({"id": 4, "cmd": "set_representative",
                                 "name": name, "hash": h})
            representative.append({
                "label": label,
                "name": name,
                "hash": h,
                "photo": payload.get("photo"),
                "error": error_of({"id": 4, "cmd": "set_representative",
                                   "name": name, "hash": h}),
                "registry_after": engine._load_face_registry(),
            })
        build(work, vectors, thumbs, base_registry)

        # --- name_cluster -----------------------------------------------------
        # Two cases, and both are places the engine and the Swift port differ on
        # purpose: it keys the name VERBATIM (every other face command in the
        # engine case-folds) and it does not collapse a hash repeated inside one
        # request. The fixture records what the engine did so the Swift test can
        # pin the difference instead of hiding it.
        bind = []
        for label, name, incoming in [
            ("a new name", "Ann", [random[0], random[1]]),
            ("an existing name, merge", "Bob Meyer", [h3, random[0], random[0], random[1]]),
            ("the same person, other case", "quincy", [random[4]]),
        ]:
            build(work, vectors, thumbs, base_registry)
            payload = result_of({"id": 5, "cmd": "name_cluster",
                                 "name": name, "hashes": incoming})
            registry_after = engine._load_face_registry()
            victims = [k for k in registry_after
                       if k.casefold() == name.casefold()]
            bind.append({
                "label": label,
                "name": name,
                "hashes": incoming,
                "engine_bound": payload.get("bound"),
                "engine_keys": victims,
                "engine_registry_after": registry_after,
                "swift_expected_key": victims[0] if victims else name,
            })
        build(work, vectors, thumbs, base_registry)

        # --- clustering -------------------------------------------------------
        # `face_clusters` is the engine's own greedy running-mean merge, the same
        # rule `detect_faces` uses, and it needs nothing but the cache — so it
        # can be the oracle for the partition.
        #
        # A SEPARATE tree, and deliberately not the one above. Greedy clustering
        # is order-sensitive wherever a pair sits near the threshold, and the
        # chain built for the matcher (h3 at 0.301 from the anchor, h4 at 0.299)
        # sits exactly there: reordering it genuinely moves h3 in and out of the
        # main cluster, which is a fact about greedy merging rather than a bug in
        # either implementation. So the partition is measured on three tight,
        # well-separated groups, and the margins are asserted — within-group
        # cosine well above the threshold, between-group well below.
        cluster_hashes = ["%02x%030x" % (i, 104729 * (i + 1)) for i in range(9)]
        centroids = [unit(rng.normal(size=DIM)) for _ in range(3)]
        cluster_vectors = {}
        groups = []
        sizes = [4, 3, 2]
        cursor = 0
        for centroid, size in zip(centroids, sizes):
            group = []
            for _ in range(size):
                noise = rng.normal(size=DIM)
                noise = noise - noise.dot(centroid) * centroid
                cluster_vectors[cluster_hashes[cursor]] = unit(
                    0.9 * centroid + 0.43589 * unit(noise))
                group.append(cluster_hashes[cursor])
                cursor += 1
            groups.append(group)

        # Own group: cosine to the group's own centroid. Other group: the
        # worst case, over every centroid that is NOT its own.
        within = [float(np.dot(cluster_vectors[h], centroids[i]))
                  for i, group in enumerate(groups) for h in group]
        between = [float(np.dot(cluster_vectors[h], centroids[j]))
                   for i, group in enumerate(groups) for h in group
                   for j in range(len(centroids)) if j != i]
        assert min(within) >= engine.FACE_CLUSTER_COSINE + 0.3, min(within)
        assert max(between) < engine.FACE_CLUSTER_COSINE - 0.05, max(between)

        build(work, cluster_vectors, set(), {})
        orders = [
            cluster_hashes,
            list(reversed(cluster_hashes)),
            cluster_hashes[4:] + cluster_hashes[:4],
            cluster_hashes[::2] + cluster_hashes[1::2],
            cluster_hashes[1::2] + cluster_hashes[::2],
            [cluster_hashes[i] for i in (5, 0, 8, 3, 1, 7, 4, 6, 2)],
            [cluster_hashes[i] for i in (8, 2, 6, 4, 7, 1, 3, 0, 5)],
        ]
        partitions = []
        for order in orders:
            engine._all_face_hashes = lambda order=order: list(order)
            payload = result_of({"id": 6, "cmd": "face_clusters"})
            partitions.append(partition(payload.get("clusters", [])))
        del engine._all_face_hashes
        assert all(p == partitions[0] for p in partitions), \
            ("face_clusters partitions differ under permutation — the fixture is "
             "order-dependent and cannot be a gate:\n  %s" % (partitions,))
        assert sorted(len(c) for c in partitions[0]) == sorted(sizes), partitions[0]

        fixture = {
            "generated_by": "docs/coreml-spike/face_registry_parity.py",
            "reference": "engine.py's own face commands, against a tree written here",
            "dim": DIM,
            "match_cosine": engine.FACE_MATCH_COSINE,
            "cluster_cosine": engine.FACE_CLUSTER_COSINE,
            "choice_limit": engine.FACE_CHOICE_LIMIT,
            "max_choices": engine.FACE_MAX_CHOICES,
            "cache": {h: b64(v) for h, v in vectors.items()},
            "thumbs": sorted(thumbs),
            "pruned": pruned,
            "base_registry": base_registry,
            "anchor_cosines": {"above": achieved[h3], "below": achieved[h4]},
            "people": people,
            "matches": matches,
            "similar": similar,
            "forget": forget,
            "representative": representative,
            "bind": bind,
            "clusters": {
                "hashes": cluster_hashes,
                "vectors": {h: b64(v) for h, v in cluster_vectors.items()},
                "partition": partitions[0],
                "orders_agreed": len(partitions),
            },
        }
    finally:
        shutil.rmtree(work, ignore_errors=True)

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as fh:
        json.dump(fixture, fh)

    print("cache %d faces (%d with thumbnails) · %d names"
          % (len(vectors), len(thumbs), len(base_registry)))
    print("anchor cosines: above %.6f · below %.6f (threshold %.2f)"
          % (achieved[h3], achieved[h4], engine.FACE_MATCH_COSINE))
    print("clusters: %s — stable across %d orders"
          % ([len(c) for c in partitions[0]], len(partitions)))
    print("wrote %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
