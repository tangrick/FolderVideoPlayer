#!/bin/bash
#
# Build, sign, notarize and package a release.
#
# Notarization is what stops Gatekeeper warning everyone who downloads the app.
# It needs two things this script does not contain and never should: a
# Developer ID Application certificate in your keychain, and an App Store
# Connect credential. Both are set up once, by you — see "First time" below.
#
#   Tools/release.sh                 build, sign, notarize, staple, package
#   Tools/release.sh --no-notarize   build and sign only, for a quick local test
#
# First time only:
#
#   1. Xcode > Settings > Accounts > Manage Certificates > + >
#      "Developer ID Application". An "Apple Development" certificate is not
#      the same thing and cannot be notarized with.
#
#   2. Store an App Store Connect credential under a profile name, so no
#      password is ever typed into a script or saved in this repository:
#
#        xcrun notarytool store-credentials FolderVideoPlayer \
#            --apple-id you@example.com --team-id YOURTEAMID
#
#      It asks for an app-specific password, which you make at
#      appleid.apple.com > Sign-In and Security > App-Specific Passwords.
#      It goes into your keychain, and Apple's tool is the only thing that
#      reads it.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/FolderVideoPlayer.app"
DMG="FolderVideoPlayer.dmg"
PROFILE="${NOTARY_PROFILE:-FolderVideoPlayer}"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

VERSION=$(sed -n 's/.*"CFBundleShortVersionString": "\([^"]*\)".*/\1/p' setup.py)
echo "==> FolderVideoPlayer $VERSION"

# The identity is found rather than hard-coded, so this file carries nothing
# specific to one machine or one developer.
IDENTITY=$(security find-identity -v -p codesigning |
           sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)

if [ -z "$IDENTITY" ]; then
    if [ "$NOTARIZE" = 1 ]; then
        echo "No Developer ID Application certificate found." >&2
        echo "Create one first (see the top of this script), or run with" >&2
        echo "--no-notarize to build an ad-hoc signed copy for local testing." >&2
        exit 1
    fi
    echo "==> No Developer ID certificate; signing ad-hoc"
    IDENTITY="-"
    # --force is carried in the array purely so it is never empty: this runs on
    # the bash macOS ships, where expanding an empty array under `set -u` is an
    # error rather than nothing.
    SIGN=(--force)
else
    echo "==> Signing as: $IDENTITY"
    # The hardened runtime and a secure timestamp are both required for
    # notarization. Neither is compatible with ad-hoc signing, hence the split.
    SIGN=(--force --timestamp --options runtime)
fi

echo "==> Building"
rm -rf build dist
# py2app reports every module it decided not to bundle, which is hundreds of
# lines of setuptools internals and none of it actionable. Kept in a file so a
# real failure is still readable.
if ! ./venv/bin/python setup.py py2app >build.log 2>&1; then
    echo "Build failed; last 40 lines of build.log:" >&2
    tail -40 build.log >&2
    exit 1
fi

# Inside out. A bundle is signed from the leaves up: sign the outer app first
# and the nested binaries you sign afterwards invalidate the signature you
# just made. --deep would do this in one go but is deprecated and applies the
# app's entitlements to everything, which is not what is wanted here.
echo "==> Signing $(find "$APP" \( -name "*.so" -o -name "*.dylib" \) | wc -l | tr -d ' ') nested binaries"
find "$APP" \( -name "*.so" -o -name "*.dylib" \) -print0 |
    xargs -0 -n1 codesign "${SIGN[@]}" --sign "$IDENTITY" 2>/dev/null

for framework in "$APP"/Contents/Frameworks/*.framework; do
    [ -d "$framework" ] || continue
    codesign "${SIGN[@]}" --sign "$IDENTITY" "$framework"/Versions/* 2>/dev/null || true
done

echo "==> Signing the app"
codesign "${SIGN[@]}" \
         --entitlements Tools/entitlements.plist \
         --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

if [ "$NOTARIZE" = 1 ]; then
    # The app is notarized and stapled before the DMG is built, so the ticket
    # travels inside the app itself. Staple only the DMG and the app works
    # until somebody drags it out of the disk image onto a Mac that happens to
    # be offline, which is a miserable thing to discover later.
    echo "==> Notarizing the app (a few minutes)"
    rm -f dist/app.zip
    ditto -c -k --keepParent "$APP" dist/app.zip
    xcrun notarytool submit dist/app.zip --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f dist/app.zip
fi

echo "==> Packaging the DMG"
rm -rf dist/dmg "$DMG"
mkdir -p dist/dmg
cp -R "$APP" dist/dmg/
cp Readme.txt dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "FolderVideoPlayer" -srcfolder dist/dmg \
               -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

if [ "$NOTARIZE" = 1 ]; then
    echo "==> Notarizing the DMG"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo
    echo "Done. $DMG is notarized — it opens with no warning on any Mac."
    spctl -a -t open --context context:primary-signature -v "$DMG" || true
elif [ "$IDENTITY" = "-" ]; then
    echo
    echo "Done. $DMG is ad-hoc signed — Gatekeeper will warn on first launch."
else
    # Signed properly but not sent to Apple, which Gatekeeper still refuses:
    # "Unnotarized Developer ID". Worth saying plainly, because the signature
    # looks entirely correct and it is not obvious why the warning persists.
    echo
    echo "Done. $DMG is signed with a Developer ID but NOT notarized, so"
    echo "Gatekeeper will still warn. Re-run without --no-notarize to ship it."
fi
