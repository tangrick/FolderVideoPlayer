#!/bin/bash
# Task 5.4, the half a machine can do: prove the thing that ships carries no
# data from this library.
#
# The manual half — install the DMG on a fresh macOS account with no Anaconda
# and no Homebrew on PATH, then walk the journey — is in
# `docs/clean-start-checklist.md`. This script is what makes the second run of
# that walk cheap: it fails if a trained head, a suggestion history, a named
# person, a tag, or a baked-in absolute path has crept into the app bundle or
# into a packed release.
#
# Usage:
#   Tests/check_clean_start.sh                       # newest built .app
#   Tests/check_clean_start.sh /path/to/App.app      # a specific build or DMG's app
#   Tests/check_clean_start.sh /path/to/App.app /path/to/dist
#
# The second argument is what `docs/coreml-spike/pack_bundles.sh` wrote
# (`assets/` + `ai-bundles.json`), so the release can be checked the same way.
set -uo pipefail

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; fails=$((fails + 1)); }
skip() { printf 'skip %s\n' "$1"; }

# The names this app writes when a *person* uses it. Any of them inside the
# shipped bundle is data that came from somewhere it should not have.
forbidden_names=(
    "tags.json" "analysis.json" "suggestions.json" "faces.json" "marks.json"
    "face_index.json" "name-index.json" "fingerprints.json" "durations.json"
    "state.json" "tag-groups.json" "favorites.json"
    "siglip2_base_prompts.json" "siglip2_base_prompts.f32"
)
# Patterns, because these are named after the embedding slug and can appear
# under any of them.
forbidden_globs=("*_trained_heads.json" "*_trained_heads.npz" "*_tag_priors.json")

app=${1:-}
if [ -z "$app" ]; then
    app=$(ls -dt ~/Library/Developer/Xcode/DerivedData/FolderVideoPlayer-*/Build/Products/*/FolderVideoPlayer.app \
          2>/dev/null | head -1)
fi
if [ -z "$app" ] || [ ! -d "$app" ]; then
    skip "no built FolderVideoPlayer.app found — build it first, or pass a path"
    echo
    echo "0 checks failed (nothing was checked)"
    exit 0
fi
echo "app: $app"
echo

# --- 1. no library data in the bundle --------------------------------------
# Command substitution rather than process substitution: this runs under `sh`,
# which on macOS is bash in POSIX mode, where `<(...)` is a syntax error.
found=0
for name in "${forbidden_names[@]}"; do
    hits=$(find "$app" -name "$name" -type f 2>/dev/null)
    if [ -n "$hits" ]; then
        bad "the bundle carries $name" "$(echo "$hits" | head -2 | tr '\n' ' ')"
        found=1
    fi
done
for glob in "${forbidden_globs[@]}"; do
    hits=$(find "$app" -name "$glob" -type f 2>/dev/null)
    if [ -n "$hits" ]; then
        bad "the bundle carries a trained artifact ($glob)" "$(echo "$hits" | head -2 | tr '\n' ' ')"
        found=1
    fi
done
if [ $found -eq 0 ]; then
    ok "no tags, heads, suggestions, marks, people or prompt table in the bundle"
fi

# --- 2. no model ships ------------------------------------------------
# The whole point of Phase 5 is an app that is small and empty; an .mlmodelc
# inside it would mean the download step is a lie.
models=$(find "$app" \( -name '*.mlmodelc' -o -name '*.mlpackage' \) -print 2>/dev/null)
if [ -z "$models" ]; then
    ok "no model ships in the bundle — every feature is downloaded"
else
    bad "a model is inside the bundle" "$(echo "$models" | head -3)"
fi

# --- 3. no path from this machine -------------------------------------------
# A baked-in absolute path is how a stranger's app reads a directory that only
# exists on the machine it was built on.
binary="$app/Contents/MacOS/$(basename "$app" .app)"
if [ -f "$binary" ]; then
    hits=$(strings -a "$binary" 2>/dev/null | grep -n "/Users/" | head -5)
    if [ -z "$hits" ]; then
        ok "the app binary names no /Users path"
    else
        bad "the app binary has an absolute /Users path baked in" "$hits"
    fi
else
    skip "no Mach-O at $binary to scan"
fi

resource_hits=$(find "$app/Contents/Resources" -type f 2>/dev/null \
    | grep -Ev '\.(icns|car|png|jpg|jpeg|gif|pdf)$' \
    | xargs -I{} sh -c 'grep -lI "/Users/" "$1" 2>/dev/null' _ {})
if [ -z "$resource_hits" ]; then
    ok "no resource file names a /Users path"
else
    bad "a bundled resource has an absolute /Users path" "$resource_hits"
fi

# --- 4. the packed release, when one was handed over ------------------------
dist=${2:-}
if [ -n "$dist" ]; then
    echo
    echo "release: $dist"
    if [ ! -f "$dist/ai-bundles.json" ]; then
        bad "no ai-bundles.json under $dist"
    else
        assets=$(ls -1 "$dist/assets" 2>/dev/null)
        # Exactly what the three bundles are allowed to contain: four model
        # packages, two prompt-table files, and nothing else.
        allowed='^(siglip2_base_image\.mlpackage\.zip|falconsai\.mlpackage\.zip|yunet\.mlpackage\.zip|sface\.mlpackage\.zip|siglip2_base_prompts\.json|siglip2_base_prompts\.f32)$'
        extras=$(printf '%s\n' "$assets" | grep -Ev "$allowed" | grep -v '^$')
        if [ -z "$extras" ]; then
            ok "the release holds only the four models and the prompt table"
        else
            bad "the release holds files no bundle names" "$(echo "$extras" | tr '\n' ' ')"
        fi
        # What must never appear: a filename that holds a *library's* own data.
        #
        # Note what is deliberately NOT a hit — the word `tags`. The models
        # install under `<support>/tags/` and the bundle's feature id is `tags`
        # by design; that is a model directory, not the user's tag data. Naming
        # the data files (rather than the string "tags") is what keeps this check
        # meaningful once a real catalogue exists — matching the bare word made
        # the gate fail on the first packed release, on the bundle's own install
        # paths. The prompt-table files are missing here on purpose too: the table
        # is a released artifact, and only its presence *in the app bundle* is a
        # leak (checked in section 1).
        library_files='analysis\.json|suggestions\.json|faces\.json|marks\.json'
        library_files+='|face_index\.json|name-index\.json|fingerprints\.json'
        library_files+='|durations\.json|state\.json|tags\.json|tag-groups\.json'
        library_files+='|favorites\.json|trained_heads|tag_priors'
        if grep -qE "($library_files)" "$dist/ai-bundles.json"; then
            bad "the catalogue mentions this library's data files"
        else
            ok "the catalogue names no library data"
        fi

        # The catalogue must point at the repo the APP reads.
        #
        # Two ways to get this wrong, and both are silent 404s at runtime rather
        # than a build failure — which is how they survived until 2026-09-12:
        # a catalogue published to a PRIVATE repo (the app fetches with no token,
        # so every user gets nothing and no Install button), and a catalogue
        # repacked against one repo while the constant names another. The
        # constant is the source of truth, so it is read from the source.
        source_dir=$(cd "$(dirname "$0")/.." && pwd)
        declared=$(grep -o 'assetsRepo = "[^"]*"' \
            "$source_dir/FolderVideoPlayer/Model/ModelDownloader.swift" \
            | head -1 | sed 's/.*= "//; s/"$//')
        urls=$(grep -o '"url": "[^"]*"' "$dist/ai-bundles.json")
        # Two allowed shapes. A bundle hosted in the app's own assets repo uses
        # it for every asset — the original rule, kept because it caught both
        # silent-404 incidents named above. A bundle whose bytes live elsewhere
        # (the speech pack lives on Hugging Face) must instead keep every asset
        # under the host and repository its own pack.sourceURL names, and every
        # asset must be pinned to a COMMIT: a branch would let the bytes change
        # under a digest that never does, which is the failure this check is here
        # to prevent in the first place.
        if command -v python3 >/dev/null 2>&1; then
            verdict=$(python3 - "$dist/ai-bundles.json" "$declared" <<'PY'
import json, sys
path, declared = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
own = f"https://github.com/{declared}/"
hexes = set("0123456789abcdef")
bad, external = [], set()
for b in doc.get("bundles", []):
    src = ((b.get("pack") or {}).get("sourceURL") or "").rstrip("/")
    for a in b.get("assets", []):
        url = a["url"]
        if declared and url.startswith(own):
            continue
        if not src:
            bad.append(f"{b['id']}/{a['install']}: not under {own} and the bundle names no pack.sourceURL")
            continue
        if not url.startswith(src + "/resolve/"):
            bad.append(f"{b['id']}/{a['install']}: not under its pack.sourceURL {src}")
            continue
        commit = url[len(src) + len("/resolve/"):].split("/", 1)[0]
        if len(commit) != 40 or any(c not in hexes for c in commit.lower()):
            bad.append(f"{b['id']}/{a['install']}: not pinned to a commit ('{commit}')")
            continue
        external.add(b["id"])
if bad:
    print("BAD " + " ; ".join(bad[:3]))
else:
    print("OK " + (", ".join(sorted(external)) if external else "none"))
PY
)
            case "$verdict" in
                OK*) ok "every catalogue URL is token-free and pinned (hosted elsewhere: ${verdict#OK })" ;;
                *)   bad "the catalogue's URLs are not all fetchable without a token and pinned" \
                        "${verdict#BAD }" ;;
            esac
        else
            skip "python3 is unavailable, so the catalogue's URL rules were not checked"
        fi
    fi
fi

# --- 5. the walk a machine cannot do ----------------------------------------
cat <<'EOF'

The half only a person can do — full steps in docs/clean-start-checklist.md:

  1. log in as a macOS account that has never run this app
  2. confirm PATH holds no python3, no ffmpeg, no Anaconda
  3. install the DMG, open it, and find an empty library
  4. open a folder, play a video, tag it by hand — all with no download
  5. Settings → AI: install the Tags bundle, watch the row light up
  6. open a video and see tag suggestions appear without a relaunch
  7. install the Safe / NSFW bundle and classify a video
  8. mark a wrong verdict and confirm the correction head grew
  9. check that the first launch wrote nothing before step 4
 10. install the Face recognition bundle (≈18 MB) and name a person once —
     the newest bundle, so it is also the check that a bundle added after a
     release installs with no app update
EOF

echo
if [ $fails -eq 0 ]; then
    echo "ALL PASS clean start"
    exit 0
fi
echo "$fails FAILURES"
exit 1
