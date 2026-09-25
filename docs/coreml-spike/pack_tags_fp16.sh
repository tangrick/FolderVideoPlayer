#!/bin/bash
# Pack the 16-bit SigLIP 2 image tower as a second, optional "tags" bundle.
#
# The shipped tags bundle is the float32 conversion (343 MB). The float16 one
# is the same weights rounded: half the download (~176 MB) and, measured on 400
# real frames on 2026-09-25, 5.0 ms/frame against 11.5 ms, because only a
# float16 graph runs on the Neural Engine. The cost, same measurement: prompt
# cosines move by up to 0.0146 (p99 0.0033) — outside convert_siglip2_image.py's
# 6e-3 gate, a quarter of the app's 0.06 vocabularyMargin — the top ten prompts
# are identical on 339/400 frames, and the trained heads flipped 1 decision in
# 800.
#
# ## How the app uses it
#
# The app loads whichever build is chosen in Settings ▸ AI ▸ Tags ▸ Pack
# (`ModelSpace.activeTower`), and treats the two precisions as ONE embedding
# space: cached vectors, trained heads and the prompt table carry across a
# switch in either direction (`ModelSpace.write` / `members`).
#
# The entry deliberately carries no `pack` descriptor, like the float32 "tags"
# bundle. A described tower install stamps a space marker, and on a machine
# that has never had one that would move every cached vector out of the
# legacy `frames/siglip2_base` namespace. Undescribed, it joins a marker only
# where one already exists.
#
# ## What it produces
#
#   <out>/assets/siglip2_base_fp16_image.mlpackage.zip
#   <out>/assets/siglip2_base_fp16_prompts.json   (the public table, copied)
#   <out>/assets/siglip2_base_fp16_prompts.f32
#   <out>/tags-fp16-bundle.json
#
# Its own install paths (tags/siglip2_base_fp16*): the catalogue refuses two
# bundles whose install paths overlap. The prompt table is the same public
# table — it holds text-tower vectors, and the float16 tower reads the same
# space — copied under its own names so this bundle installs on its own.
#
# Usage:
#   docs/coreml-spike/pack_tags_fp16.sh <models-dir> <out-dir> <release-tag>
#
# `<models-dir>` must hold:
#   siglip2_base_image_float16.mlpackage/   (convert_siglip2_image.py --precision both
#                                            keeps it beside the float32 build)
#   siglip2_base_prompts.json  .f32         (from precompute_text_siglip2.py)
set -euo pipefail

repo=${FVP_REPO:-tangrick/FolderVideoPlayerSwift-AI}
case $repo in
    tangrick/FolderVideoPlayerSwift | tangrick/FolderVideoPlayerSwift/)
        echo "error: refusing to point the catalogue at the private app repo" >&2
        exit 2 ;;
esac

[ $# -eq 3 ] || { echo "usage: $0 <models-dir> <out-dir> <release-tag>" >&2; exit 2; }
models=$(cd "$1" && pwd)
tag=$3
mkdir -p "$2/assets"
out=$(cd "$2" && pwd)
assets=$out/assets

# The Hugging Face commit the tower was converted from (convert_siglip2_image.py
# loads google/siglip2-base-patch16-224; this is the snapshot in the local cache).
revision=75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2

package=$models/siglip2_base_image_float16.mlpackage
for need in "$package" "$models/siglip2_base_prompts.json" "$models/siglip2_base_prompts.f32"; do
    [ -e "$need" ] || { echo "pack_tags_fp16: missing $need" >&2; exit 1; }
done

# Refuse a package that is not what the name says. A float32 graph under the
# float16 name would ship the big download as the small one, and a different
# output would load and then fail on the first frame.
# Read off the compiled program: a package holds only the binary spec.
compiled=$(mktemp -d)
trap 'rm -rf "$compiled"' EXIT
xcrun coremlcompiler compile "$package" "$compiled" >/dev/null
python3 - "$package" "$compiled"/*.mlmodelc/model.mil <<'PY' || exit 1
import re, sys
package, mil = sys.argv[1], open(sys.argv[2]).read()
fp16, fp32 = len(re.findall(r"tensor<fp16", mil)), len(re.findall(r"tensor<fp32", mil))
if fp16 <= fp32:
    sys.exit(f"pack_tags_fp16: {package} is not a float16 graph ({fp16} fp16 vs {fp32} fp32 tensors)")
if not re.search(r"\bembedding\b", mil):
    sys.exit(f"pack_tags_fp16: {package} has no 'embedding' output (VisionEmbedder reads that name)")
print(f"  float16 graph: {fp16} fp16 / {fp32} fp32 tensors, 'embedding' output")
PY

# The public table only — same guard as pack_bundles.sh: a table that still
# carries the NSFW pool or paired tags would publish the private vocabulary.
python3 - "$models/siglip2_base_prompts.json" <<'PY' || exit 1
import json, sys
meta = json.load(open(sys.argv[1]))
nsfw = meta.get("layout", {}).get("nsfw", [0, 0])
if nsfw[1] > nsfw[0] or meta.get("paired_tags") or meta.get("orientation_tags"):
    sys.exit("pack_tags_fp16: %s carries private rows (NSFW pool or paired tags) -- "
             "rebuild it with precompute_text_siglip2.py, which splits them out" % sys.argv[1])
PY

echo "packing siglip2_base_image_float16.mlpackage…"
rm -f "$assets/siglip2_base_fp16_image.mlpackage.zip"
ditto -c -k --sequesterRsrc --keepParent "$package" "$assets/siglip2_base_fp16_image.mlpackage.zip"
cp "$models/siglip2_base_prompts.json" "$assets/siglip2_base_fp16_prompts.json"
cp "$models/siglip2_base_prompts.f32" "$assets/siglip2_base_fp16_prompts.f32"

python3 - "$assets" "$repo" "$tag" "$revision" "$out/tags-fp16-bundle.json" <<'PY'
import hashlib, json, os, sys
assets, repo, tag, revision, path = sys.argv[1:]  # revision: provenance, printed below

def asset(name, kind, install):
    full = os.path.join(assets, name)
    digest = hashlib.sha256()
    with open(full, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
    return {"url": f"https://github.com/{repo}/releases/download/{tag}/{name}",
            "sha256": digest.hexdigest(), "bytes": os.path.getsize(full),
            "kind": kind, "install": install}

bundle = {
    "id": "tags-fp16",
    "title": "Tag suggestions (faster, 16-bit)",
    "what": "Offers tags for what is on screen, and finds videos that look alike. "
            "Half the download and about twice as fast; suggestions differ slightly.",
    "feature": "tags",
    # No "pack" descriptor — see "How the app uses it" in the header. Source:
    # google/siglip2-base-patch16-224 at `revision`, Apache-2.0.
    "assets": [
        asset("siglip2_base_fp16_image.mlpackage.zip", "coreMLPackage",
              "tags/siglip2_base_fp16.mlmodelc"),
        asset("siglip2_base_fp16_prompts.json", "file", "tags/siglip2_base_fp16_prompts.json"),
        asset("siglip2_base_fp16_prompts.f32", "file", "tags/siglip2_base_fp16_prompts.f32"),
    ],
}
with open(path, "w") as f:
    json.dump(bundle, f, indent=2)
    f.write("\n")
total = sum(a["bytes"] for a in bundle["assets"])
print(f"  tags-fp16 {total / 1e6:.1f} MB -> tags (from google/siglip2-base-patch16-224@{revision[:12]})")
PY

echo
echo "wrote $out/tags-fp16-bundle.json — add it to the published ai-bundles.json after the"
echo "\"tags\" bundle, and upload the assets (the release must exist):"
echo "  gh release upload $tag $assets/siglip2_base_fp16_* -R $repo"
