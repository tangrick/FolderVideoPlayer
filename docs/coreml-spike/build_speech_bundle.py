#!/usr/bin/env python3
"""Write the catalogue entry for one of the smaller WhisperKit speech packs.

    python3 docs/coreml-spike/build_speech_bundle.py small   # -> speech-small-bundle.json
    python3 docs/coreml-spike/build_speech_bundle.py base    # -> speech-base-bundle.json

The Core ML files come from argmaxinc/whisperkit-coreml and the tokenizer from
the matching openai/whisper-* repo, every URL pinned to a commit. A file whose
LFS sha256 the Hub publishes uses that digest; any other file is fetched once
and hashed here (`_digest` records which). Nothing is hosted by us.

The tokenizer is IN the pack on purpose: without a tokenizer.json in the model
folder WhisperKit fetches one from the Hub by itself on first use, which is the
hidden download the speech design forbids.

pack_bundles.sh splices every speech*-bundle.json beside this script into the
released catalogue. Validate with Tests/run_catalogue_check.sh.
"""
import hashlib
import json
import os
import sys
import urllib.request

WHISPERKIT_REPO = "argmaxinc/whisperkit-coreml"
WHISPERKIT_COMMIT = "0f63a7800b00dd0226abd051b906c246e1907482"
TOKENIZER_FILES = ["tokenizer.json", "tokenizer_config.json"]

PACKS = {
    "small": {
        "id": "speech-small",
        "title": "Speech transcription (smaller)",
        "folder": "openai_whisper-small_216MB",
        "adapter": "whisperkit-small-216mb-v1",
        "install": "models/speech-small",
        "tokenizer_repo": "openai/whisper-small",
        "tokenizer_commit": "973afd24965f72e36ca33b3055d56a652f456b4d",
    },
    "base": {
        "id": "speech-base",
        "title": "Speech transcription (smallest)",
        "folder": "openai_whisper-base",
        "adapter": "whisperkit-base-v1",
        "install": "models/speech-base",
        "tokenizer_repo": "openai/whisper-base",
        "tokenizer_commit": "e37978b90ca9030d5170a5c07aadb050351a65bb",
    },
}


def get_json(url):
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def sha256_of(url):
    digest = hashlib.sha256()
    with urllib.request.urlopen(url) as response:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def tree(repo, commit, folder=""):
    url = f"https://huggingface.co/api/models/{repo}/tree/{commit}/{folder}?recursive=true"
    return [item for item in get_json(url) if item["type"] == "file"]


def asset(repo, commit, path, relative, install_root, item):
    url = f"https://huggingface.co/{repo}/resolve/{commit}/{path}"
    if item.get("lfs"):
        sha, how = item["lfs"]["oid"], "published"
    else:
        sha, how = sha256_of(url), "computed here"
    return {
        "url": url,
        "sha256": sha,
        "bytes": item.get("lfs", {}).get("size", item["size"]),
        "kind": "file",
        "install": f"{install_root}/{relative}",
        "_digest": how,
    }


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in PACKS:
        sys.exit(f"usage: {sys.argv[0]} {'|'.join(PACKS)}")
    pack = PACKS[sys.argv[1]]

    assets = []
    for item in sorted(tree(WHISPERKIT_REPO, WHISPERKIT_COMMIT, pack["folder"]),
                       key=lambda i: i["path"]):
        # The Hub's path already starts with the pack folder: split it off
        # once, or every URL doubles it and 404s (pitfall 77).
        relative = item["path"].split("/", 1)[1]
        assets.append(asset(WHISPERKIT_REPO, WHISPERKIT_COMMIT, item["path"],
                            relative, pack["install"], item))
    tokenizer = {i["path"]: i for i in tree(pack["tokenizer_repo"], pack["tokenizer_commit"])}
    for name in TOKENIZER_FILES:
        assets.append(asset(pack["tokenizer_repo"], pack["tokenizer_commit"], name,
                            name, pack["install"], tokenizer[name]))

    bundle = {
        "id": pack["id"],
        "title": pack["title"],
        "what": "Writes down what is said, so you can find a video by its words. "
                "A smaller download that is less accurate than the full pack.",
        "feature": "speech",
        "pack": {
            "version": 1,
            "modelID": pack["folder"],
            "revision": WHISPERKIT_COMMIT,
            "adapter": pack["adapter"],
            "minimumMacOS": "14.0",
            "architectures": ["arm64"],
            "license": "MIT (tokenizer Apache-2.0)",
            "sourceURL": f"https://huggingface.co/{WHISPERKIT_REPO}",
        },
        "assets": assets,
    }
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"{pack['id']}-bundle.json")
    with open(out, "w") as f:
        json.dump(bundle, f, indent=2)
        f.write("\n")
    total = sum(a["bytes"] for a in assets)
    print(f"{out}: {len(assets)} files, {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
