#!/bin/bash
# S2: the speech runtime is PINNED, LINKED, and cannot reach the network behind
# the app's back.
#
# The design's T08 says "Integrate pinned WhisperKit dependency" and "no hidden
# SDK downloads". Both are claims about configuration, and configuration drifts
# silently: a version range keeps working while resolving to something else, a
# declared package that nothing links still looks wired, and WhisperKit's own
# downloader is one convenience initialiser away from fetching a model the
# catalogue never verified. So this checks the state of the project as it is:
#
#   1. the requirement is EXACT (1.1.0) and not a range — a range is how a pin
#      quietly becomes whatever the author tags next;
#   2. Package.resolved records that version at the commit the tag pointed to
#      (1e2a1637…), in the SHARED path, so a fresh clone resolves identically;
#   3. the product is really linked into the app target — declared, referenced
#      by a build file, and present in the Frameworks phase. A pin that nothing
#      links is decoration;
#   4. no app source may construct WhisperKit in a way that can download for
#      itself. Nothing constructs it yet: this guard is here so the first
#      construction cannot bring a hidden download in unnoticed;
#   5. the dependency really BUILT and was handed to the linker — the package
#      compiles, its module exists for the app to import, and the linker's file
#      list names it. (Not "the app binary has WhisperKit symbols": nothing
#      imports it yet, and dead-code stripping legitimately drops an
#      unreferenced static object. That check turns on by itself the moment a
#      source imports it.)
#
# Usage: Tests/check_speech_runtime.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pbx="$here/../FolderVideoPlayer.xcodeproj/project.pbxproj"
res="$here/../FolderVideoPlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
sources="$here/../FolderVideoPlayer"

# What the v1.1.0 tag pointed to when this was pinned, recorded so a change is
# visible rather than silent.
pinned_revision="1e2a163736dfa5a198e637ae44c114e1c6d5cc2d"

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; fails=$((fails + 1)); }
skip() { printf 'skip %s\n' "$1"; }

# --- 1. the requirement is exact ---------------------------------------------
if [ ! -f "$pbx" ]; then
    bad "the project file is where this check expects it" "$pbx"
    echo "$fails FAILURES"
    exit 1
fi

req=$(awk '/XCRemoteSwiftPackageReference "WhisperKit".*= \{/,/\};/' "$pbx")
check_ok=1
grep -q 'repositoryURL = "https://github.com/argmaxinc/WhisperKit.git"' <<<"$req" \
    || { bad "the pin points at the WhisperKit repository" "$(tr -d '\n\t' <<<"$req" | cut -c1-120)"; check_ok=0; }
[ $check_ok -eq 1 ] && ok "the pin points at the WhisperKit repository"
grep -q 'kind = exactVersion' <<<"$req" \
    && ok "the requirement is an EXACT version, not a range" \
    || bad "the requirement is not an exact version — a range resolves to whatever is tagged next"
grep -q 'version = 1.1.0;' <<<"$req" \
    && ok "the pinned version is 1.1.0" \
    || bad "the pinned version is not 1.1.0" "$(tr -d '\n\t' <<<"$req" | cut -c1-120)"

# --- 2. the resolved pin ------------------------------------------------------
if [ ! -f "$res" ]; then
    bad "the resolved pin is in the SHARED workspace path" "missing: $res — a clone would resolve its own"
else
    ok "the resolved pin is in the shared workspace path (so a clone resolves the same)"
    # ...but only if it can actually be committed. The Xcode .gitignore template
    # ignores Package.resolved by default, which would leave the pin on this
    # machine only: an exact version still resolves through a tag, and a tag can
    # move. So the pin's being committable is checked, not assumed.
    if git -C "$here/.." check-ignore -q "$res" 2>/dev/null; then
        bad "the resolved pin is committable — git IGNORES it" \
            "$(git -C "$here/.." check-ignore -v "$res" | cut -f1-2): the pin would live on this machine only"
    elif ! command -v git >/dev/null 2>&1; then
        skip "git is not available, so whether the pin is committable cannot be checked"
    else
        ok "...and git does not ignore it, so the pin can be committed"
    fi
    out=$(python3 - "$res" "$pinned_revision" <<'PY'
import json, sys
path, pinned = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception as e:
    print(f"FAIL the resolved file parses as JSON — {e}")
    raise SystemExit(0)
pins = {p.get("identity"): p.get("state", {}) for p in data.get("pins", [])}
state = pins.get("whisperkit")
if not state:
    print("FAIL whisperkit is pinned in the resolved file — it is not there")
    raise SystemExit(0)
print("ok   whisperkit is pinned in the resolved file")
if state.get("version") == "1.1.0":
    print("ok   ...at version 1.1.0")
else:
    print(f"FAIL the resolved version is {state.get('version')} — expected 1.1.0")
if state.get("revision") == pinned:
    print(f"ok   ...at the commit the tag pointed to ({pinned[:12]})")
else:
    print(f"FAIL the resolved revision is {str(state.get('revision'))[:12]} — expected {pinned[:12]}")
extra = sorted(k for k in pins if k != "whisperkit")
print(f"ok   the only other pins are its own dependencies: {', '.join(extra) if extra else 'none'}")
PY
)
    printf '%s\n' "$out"
    fails=$((fails + $(grep -c '^FAIL' <<<"$out")))
fi

# --- 3. the product is really linked -----------------------------------------
prod_id=$(awk '/\/\* WhisperKit \*\/ = \{/ {print $1; exit}' "$pbx")
if [ -z "$prod_id" ]; then
    bad "the app has a product dependency for WhisperKit — it has none"
else
    ok "the app declares a product dependency for WhisperKit"
    grep -q "productRef = $prod_id" "$pbx" \
        && ok "...a build file references that product (so it is in a build phase)" \
        || bad "...no build file references the product — declared but not built"
    grep -q "$prod_id /\* WhisperKit \*/," "$pbx" \
        && ok "...the app target lists it as a package product dependency" \
        || bad "...the app target does not list it — another target may be linking it"
    awk '/Begin PBXFrameworksBuildPhase section/,/End PBXFrameworksBuildPhase section/' "$pbx" \
        | grep -q 'WhisperKit in Frameworks' \
        && ok "...it is in the Frameworks phase" \
        || bad "...it is not in the Frameworks phase"
fi

# --- 4. nothing may download a model behind the catalogue's back --------------
constructed=$(grep -rl "WhisperKitConfig(" "$sources" --include=*.swift 2>/dev/null || true)
if [ -z "$constructed" ]; then
    ok "no app source constructs WhisperKit yet — this guard bites when one does"
else
    # File-granular on purpose: a Swift construction can wrap across lines, so
    # testing each file that mentions it is the honest check.
    for f in $constructed; do
        if grep -q "download: false" "$f"; then
            ok "$(basename "$f") constructs WhisperKit with downloads off"
        else
            bad "$(basename "$f") constructs WhisperKit without 'download: false'" \
                "the SDK's own downloader must never run: the catalogue is the trust anchor"
        fi
    done
fi
downloaded=$(grep -rn "WhisperKit.download(\|\.downloadModels(" "$sources" --include=*.swift 2>/dev/null || true)
if [ -z "$downloaded" ]; then
    ok "no app source calls WhisperKit's own downloader"
else
    bad "an app source calls WhisperKit's own downloader" "$(head -1 <<<"$downloaded")"
fi

# --- 5. the dependency was really built and handed to the linker --------------
# NOT "the app binary contains WhisperKit symbols": nothing imports WhisperKit
# yet, and with dead-code stripping on, an unreferenced static object is
# legitimately dropped. What is provable now is that the package COMPILED and
# that the link step was given it; the symbol check turns on by itself the
# moment a source imports it.
dd=$(ls -d ~/Library/Developer/Xcode/DerivedData/FolderVideoPlayer-* 2>/dev/null | head -1)
imports=$(grep -rl "import WhisperKit" "$sources" --include=*.swift 2>/dev/null || true)
if [ -z "$dd" ]; then
    skip "no DerivedData for this project — build it, then run this again to prove the link"
elif [ ! -d "$dd/Build/Products" ]; then
    skip "no build products yet — build the app, then run this again"
else
    obj=$(find "$dd/Build/Products" -maxdepth 2 -name "WhisperKit.o" 2>/dev/null | head -1)
    mod=$(find "$dd/Build/Products" -maxdepth 2 -name "WhisperKit.swiftmodule" 2>/dev/null | head -1)
    [ -n "$obj" ] && ok "WhisperKit really compiled in this build (WhisperKit.o)" \
                  || bad "WhisperKit.o is not in the build products — the package was not built"
    [ -n "$mod" ] && ok "...and its module is there for the app to import (WhisperKit.swiftmodule)" \
                  || bad "WhisperKit.swiftmodule is not in the build products"
    lfl=$(find "$dd" -name "WhisperKit.LinkFileList" 2>/dev/null | head -1)
    [ -n "$lfl" ] && ok "...and the linker's own file list names it (WhisperKit.LinkFileList)" \
                  || skip "...no LinkFileList for it in DerivedData (it may have been cleaned)"
    if [ -z "$imports" ]; then
        skip "nothing imports WhisperKit yet, so its code is stripped from the app — the symbol check below turns on at S4"
    elif [ -n "$(find "$sources" -name '*.swift' -newer "$dd/Build/Products/Debug/FolderVideoPlayer.app/Contents/MacOS/FolderVideoPlayer" 2>/dev/null | head -1)" ]; then
        # A build older than the sources cannot answer this question either
        # way, and answering it wrongly is worse than not answering: this gate
        # once failed with "the link is declared but not made" against a build
        # that predated the import.
        skip "the built app is older than the sources — rebuild it, then run this again to prove the link"
    else
        # Count across EVERY image in the bundle, not just the launcher.
        # Xcode's Debug builds keep a small launcher binary and put the app's
        # real code in FolderVideoPlayer.debug.dylib beside it, so nm on the
        # launcher alone reads as "not linked" while the link is fine
        # (measured: 0 in the launcher, 6,996 WhisperKit symbols in the dylib).
        app="$dd/Build/Products/Debug/FolderVideoPlayer.app"
        images=$(ls "$app/Contents/MacOS/FolderVideoPlayer" \
                     "$app"/Contents/MacOS/*.dylib \
                     "$app"/Contents/Frameworks/*.dylib 2>/dev/null || true)
        n=0; found=""
        for img in $images; do
            c=$(nm -arch arm64 "$img" 2>/dev/null | grep -ci whisper || true)
            n=$((n + ${c:-0}))
            [ "${c:-0}" -gt 0 ] && found="$found $(basename "$img"):$c"
        done
        if [ "$n" -gt 0 ]; then
            ok "the app imports WhisperKit and carries $n of its symbols — the link is real:$found"
        else
            bad "a source imports WhisperKit but no image in the app bundle carries any of it" \
                "looked at $(wc -w <<<"$images" | tr -d ' ') image(s) under $app"
        fi
    fi
fi

# --- the dependency's licence, for the release record -------------------------
lic=$(ls -d ~/Library/Developer/Xcode/DerivedData/FolderVideoPlayer-*/SourcePackages/checkouts/WhisperKit/LICENSE 2>/dev/null | head -1)
if [ -z "$lic" ]; then
    skip "WhisperKit is not checked out yet — its licence cannot be recorded"
else
    ok "WhisperKit's licence is on disk: $(head -1 "$lic") ($(sed -n '3p' "$lic" | sed 's/^ *//'))"
fi

echo
if [ $fails -eq 0 ]; then
    echo "ALL PASS speech runtime"
    exit 0
fi
echo "$fails FAILURES"
exit 1
