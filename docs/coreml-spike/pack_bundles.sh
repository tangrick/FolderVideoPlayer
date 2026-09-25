#!/bin/bash
# Pack the three AI bundles as GitHub release assets, and write the catalogue
# the app fetches to find them.
#
# ## Why the catalogue is generated and not committed
#
# Every asset's `sha256` and `bytes` are properties of the *uploaded* artifact.
# A hand-written catalogue is a placeholder that never works, or a hash that
# goes stale the first time an asset is rebuilt — and a stale hash is not a
# cosmetic bug here: `ModelInstaller` refuses any asset that does not match, so
# the feature installs nothing and reports a checksum mismatch, forever. So the
# numbers are measured from the exact bytes that are about to be uploaded.
#
# ## What it produces
#
#   <out>/assets/siglip2_base_image.mlpackage.zip
#   <out>/assets/falconsai.mlpackage.zip
#   <out>/assets/siglip2_base_prompts.json
#   <out>/assets/siglip2_base_prompts.f32
#   <out>/assets/yunet.mlpackage.zip
#   <out>/assets/sface.mlpackage.zip
#   <out>/ai-bundles.json
#
# A Core ML package is a directory, so it travels as a zip and the app unwraps
# it with `ditto -x -k` before compiling (see `ModelArchive`). The prompt table
# is two plain files and travels as itself.
#
# ## The faces bundle is two packages, and 18 MB of the 265 MB
#
# YuNet (300 KB) finds the faces and SFace (18 MB) embeds them; both are Phase
# 6's ports of the ONNX pair the Python engine used, and both install under
# `tags/` like the other models. They are small enough that shipping them in the
# DMG would be tempting — the rule is that AI models are downloads, never
# shipped, so a DMG stays a player with no data in it. See
# `docs/phase6-detector-spike.md`.
#
# Usage:
#   docs/coreml-spike/pack_bundles.sh <models-dir> <out-dir> <release-tag>
#
# `<models-dir>` must hold:
#   siglip2_base_image.mlpackage/   (uncompiled — the app compiles it)
#   falconsai.mlpackage/
#   yunet.mlpackage/  sface.mlpackage/  (from convert_yunet.py / convert_sface_torch.py)
#   siglip2_base_prompts.json  .f32  (from precompute_text_siglip2.py)
#
# Then publish, and the app finds it with no edit to the source:
#   gh release create <release-tag> <out>/assets/* <out>/ai-bundles.json
#
# Only the public assets repo is used at runtime — no Hugging Face dependency,
# no account. `AIBundleManifest.assetsRepo` is `tangrick/FolderVideoPlayerSwift-AI`,
# and the catalogue's asset URLs must point there too: the app downloads with no
# token, so a URL into the private app repo answers 404 to every machine.
set -euo pipefail

# Default to the PUBLIC assets repo (`AIBundleManifest.assetsRepo`), not the
# app's repo. The catalogue's asset URLs are built from this name, and the app
# downloads with no token — URLs into the private app repo answer 404 to every
# machine, which is exactly how v1.2.0's first catalogue shipped broken.
repo=${FVP_REPO:-tangrick/FolderVideoPlayerSwift-AI}

case $repo in
    tangrick/FolderVideoPlayerSwift | tangrick/FolderVideoPlayerSwift/)
        echo "error: refusing to point the catalogue at the private app repo" >&2
        echo "  (the app downloads with no token; those URLs 404 for everyone)." >&2
        echo "  Asset URLs must use the public assets repo (tangrick/FolderVideoPlayerSwift-AI)." >&2
        exit 2 ;;
esac

usage() {
    echo "usage: $0 <models-dir> <out-dir> <release-tag>" >&2
    echo "   eg: $0 ~/fvp-coreml-models ./dist v0.1.0" >&2
    exit 2
}

[ $# -eq 3 ] || usage
models=$(cd "$1" && pwd)
tag=$3
out=$2
mkdir -p "$out/assets"
out=$(cd "$out" && pwd)
assets=$out/assets

# This script's own directory: speech-bundle.json lives beside it, because the
# speech pack is the one bundle with no local assets to assemble.
here=$(cd -- "$(dirname -- "$0")"; pwd)

need() {
    [ -e "$1" ] || { echo "pack_bundles: missing $1" >&2; exit 1; }
}
need "$models/siglip2_base_image.mlpackage"
need "$models/falconsai.mlpackage"
need "$models/yunet.mlpackage"
need "$models/sface.mlpackage"
need "$models/siglip2_base_prompts.json"
need "$models/siglip2_base_prompts.f32"
# Not a local model: the speech pack is 22 files fetched from the Hugging Face
# Hub. Required all the same — a catalogue that silently loses its speech bundle
# is a Settings row that offers nothing, and nobody would see it here.
need "$here/speech-bundle.json"
# The smaller speech packs (build_speech_bundle.py), offered beside the full one
# so the Speech row's pack picker has a real choice.
need "$here/speech-small-bundle.json"
need "$here/speech-base-bundle.json"

# `ditto -c -k --sequesterRsrc --keepParent` is the archive shape macOS itself
# writes, so the reader in `ModelArchive.unwrapPackage` (also `ditto`) cannot
# disagree with it about where the package directory sits in the zip.
# The bundles whose bytes are not ours to host.
#
# Core ML Whisper files (MIT) — the full pack is 22 files, 645.7 MB; the smaller
# two are 21 files each, tokenizer included — fetched from the Hugging Face Hub at
# a pinned commit — neither hosted nor repacked here. Republishing 646 MB to a
# GitHub release to save a redirect is a worse trade than a pinned URL, and the
# catalogue is the trust anchor either way.
#
# Each whole entry, digests included, lives in its speech*-bundle.json: there is
# nothing local to assemble, so `asset` has nothing to do here. It is indented to
# sit in the document exactly like the bundles above it.
speech_bundle() {
    python3 - "$here/speech-bundle.json" "$here/speech-small-bundle.json" \
              "$here/speech-base-bundle.json" <<'PY'
import json, sys
for index, path in enumerate(sys.argv[1:]):
    lines = json.dumps(json.load(open(path)), indent=2).splitlines()
    if index < len(sys.argv) - 2:
        lines[-1] += ","
    for line in lines:
        print("    " + line)
PY
}

zip_package() {
    local package=$1 name=$2
    rm -rf "$assets/$name"
    ditto -c -k --sequesterRsrc --keepParent "$package" "$assets/$name"
    printf '%s' "$assets/$name"
}

echo "packing siglip2_base_image.mlpackage…"
zip_package "$models/siglip2_base_image.mlpackage" "siglip2_base_image.mlpackage.zip" >/dev/null
echo "packing falconsai.mlpackage…"
zip_package "$models/falconsai.mlpackage" "falconsai.mlpackage.zip" >/dev/null
echo "packing yunet.mlpackage…"
zip_package "$models/yunet.mlpackage" "yunet.mlpackage.zip" >/dev/null
echo "packing sface.mlpackage…"
zip_package "$models/sface.mlpackage" "sface.mlpackage.zip" >/dev/null

# The public table only. The NSFW pool and the paired tags belong in the
# private overlay (`siglip2_base_prompts.private.*`), which never ships; a table
# that still carries them is one built before the split, and publishing it would
# publish the private vocabulary.
python3 - "$models/siglip2_base_prompts.json" <<'PY' || exit 1
import json, sys
meta = json.load(open(sys.argv[1]))
nsfw = meta.get("layout", {}).get("nsfw", [0, 0])
if nsfw[1] > nsfw[0] or meta.get("paired_tags") or meta.get("orientation_tags"):
    sys.exit("pack_bundles: %s carries private rows (NSFW pool or paired tags) -- "
             "rebuild it with precompute_text_siglip2.py, which splits them out" % sys.argv[1])
PY
cp "$models/siglip2_base_prompts.json" "$models/siglip2_base_prompts.f32" "$assets/"

# One row of the catalogue: url, digest, size, kind, destination.
#
# `install` is where the app puts it, and it is stated HERE rather than derived
# from the file name, because `MLModel.compileModel` writes the compiled
# directory to a path it chooses — the app renames it to this path on the way
# in, so the compiler's naming never leaks into what the rest of the app reads.
asset() {
    local file=$1 ul=$2 kind=$3 install=$4
    local sha bytes
    sha=$(shasum -a 256 "$file" | awk '{print $1}')
    bytes=$(stat -f %z "$file")
    cat <<EOF
      {
        "url": "https://github.com/$repo/releases/download/$tag/$ul",
        "sha256": "$sha",
        "bytes": $bytes,
        "kind": "$kind",
        "install": "$install"
      }
EOF
}

{
    cat <<EOF
{
  "version": 1,
  "bundles": [
    {
      "id": "tags",
      "title": "Tag suggestions",
      "what": "Offers tags for what is on screen, and finds videos that look alike.",
      "feature": "tags",
      "assets": [
EOF
    # The image tower is SigLIP 2 B/16 (Apache-2.0). It replaced MobileCLIP-S2,
    # whose weights are under Apple's research-only licence — and this repo
    # REPUBLISHES them as public assets, which is the act that licence attaches
    # conditions to. `install` is what `VisionEmbedder.modelURL(root:)` reads, so
    # the two must agree; the app slug is `siglip2_base`.
    asset "$assets/siglip2_base_image.mlpackage.zip" "siglip2_base_image.mlpackage.zip" \
          "coreMLPackage" "tags/siglip2_base.mlmodelc"
    echo "      ,"
    asset "$assets/siglip2_base_prompts.json" "siglip2_base_prompts.json" "file" \
          "tags/siglip2_base_prompts.json"
    echo "      ,"
    asset "$assets/siglip2_base_prompts.f32" "siglip2_base_prompts.f32" "file" \
          "tags/siglip2_base_prompts.f32"
    cat <<EOF
      ]
    },
    {
      "id": "nsfw",
      "title": "Safe / NSFW",
      "what": "Sorts a library into Safe and NSFW, and learns from your corrections.",
      "feature": "classify",
      "assets": [
EOF
    asset "$assets/falconsai.mlpackage.zip" "falconsai.mlpackage.zip" \
          "coreMLPackage" "tags/falconsai.mlmodelc"
    cat <<EOF
      ]
    },
    {
      "id": "faces",
      "title": "Face recognition",
      "what": "Puts a name to a face once, then finds that person everywhere.",
      "feature": "faces",
      "assets": [
EOF
    asset "$assets/yunet.mlpackage.zip" "yunet.mlpackage.zip" \
          "coreMLPackage" "tags/yunet.mlmodelc"
    echo "      ,"
    asset "$assets/sface.mlpackage.zip" "sface.mlpackage.zip" \
          "coreMLPackage" "tags/sface.mlmodelc"
    cat <<EOF
      ]
    },
EOF
    speech_bundle
    cat <<EOF
  ]
}
EOF
} > "$out/ai-bundles.json"

# Read back with the app's own decoder shape, so a catalogue that would fail to
# parse at runtime fails here instead — after the upload, the failure is a
# stranger's Settings row that says nothing at all.
python3 - "$out/ai-bundles.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == 1, d["version"]
total = 0
for b in d["bundles"]:
    size = sum(a["bytes"] for a in b["assets"])
    total += size
    print(f"  {b['id']:<6} {size/1e6:7.1f} MB  -> {b['feature']}")
    assert b["assets"], b["id"]
    for a in b["assets"]:
        assert len(a["sha256"]) == 64, a
        assert a["url"].startswith("https://"), a
        # A bundle whose bytes live elsewhere must PIN them to a commit: a branch
        # would let the bytes change under a digest that never does, and the
        # digest is the only thing the app actually checks.
        # Another repository on the pack's own host is allowed: the smaller
        # speech packs take their tokenizer from openai/whisper-*.
        src = (b.get("pack") or {}).get("sourceURL")
        if not a["url"].startswith("https://github.com/"):
            host = "/".join((src or "").split("/")[:3]) + "/"
            assert src and a["url"].startswith(host) and "/resolve/" in a["url"], \
                (b["id"], a["install"], src)
            commit = a["url"].split("/resolve/", 1)[1].split("/", 1)[0]
            assert len(commit) == 40, commit
            assert all(c in "0123456789abcdef" for c in commit.lower()), commit
print(f"  total {total/1e6:7.1f} MB")
PY

echo
echo "wrote $out/ai-bundles.json"
echo "publish with:"
echo "  gh release create $tag $assets/* $out/ai-bundles.json"
