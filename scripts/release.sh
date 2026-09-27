#!/bin/bash
# Build the release DMG: test, archive with Developer ID and the hardened
# runtime, export, stage with the drag-to-Applications shortcut, sign the image,
# notarize, staple, and check Gatekeeper accepts it. The finished image is
# dist/FolderVideoPlayer-v<version>.dmg, version read from the project.
#
# Nothing secret is in this file or this repo. The signing identity is looked
# up in the login Keychain by team at run time, and notarization uses a stored
# notarytool Keychain profile, referred to only by name.
#
# Usage: scripts/release.sh [--skip-tests]
#   FVP_TEAM            Developer team ID (default: the one in exportOptions.plist)
#   FVP_NOTARY_PROFILE  notarytool Keychain profile (default: FolderVideoPlayer)
#
# Publishing (a GitHub release, the website) is deliberately NOT done here.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
project=FolderVideoPlayer.xcodeproj
options=scripts/exportOptions.plist
team=${FVP_TEAM:-$(/usr/libexec/PlistBuddy -c "Print teamID" "$options")}
profile=${FVP_NOTARY_PROFILE:-FolderVideoPlayer}
version=$(grep -m1 'MARKETING_VERSION = ' "$project/project.pbxproj" | sed 's/.*= \(.*\);/\1/')
work=build/release-$version
dmg="dist/FolderVideoPlayer-v$version.dmg"

say() { printf '\n== %s\n' "$*"; }
die() { printf 'release: %s\n' "$*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes; a release must match a commit"
[ ! -e "$dmg" ] || die "$dmg already exists — move it aside rather than overwrite a published image"

identity=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "($team)" | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$identity" ] || die "no Developer ID Application certificate for team $team in the Keychain"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || die "notarytool profile '$profile' not found (xcrun notarytool store-credentials $profile --team-id $team)"

echo "FolderVideoPlayer $version from $(git rev-parse --short HEAD), team $team"

if [ "${1:-}" != "--skip-tests" ]; then
    say "tests"
    sh Tests/run.sh
fi

say "archive"
rm -rf "$work"
mkdir -p "$work" dist
xcodebuild archive -quiet \
    -project "$project" -scheme FolderVideoPlayer -configuration Release \
    -archivePath "$work/FolderVideoPlayer.xcarchive" \
    CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

say "export"
xcodebuild -exportArchive -quiet \
    -archivePath "$work/FolderVideoPlayer.xcarchive" \
    -exportOptionsPlist "$options" -exportPath "$work/export"
app="$work/export/FolderVideoPlayer.app"
built=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
[ "$built" = "$version" ] || die "the exported app says $built, the project says $version"

say "check the signed app"
codesign --verify --deep --strict "$app"
details=$(codesign -dv --verbose=4 "$app" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$details" || die "not signed with a Developer ID"
grep -q "runtime" <<<"$details" || die "hardened runtime missing — notarization would refuse it"
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q "get-task-allow"; then
    die "get-task-allow is set (a debug entitlement) — notarization would refuse it"
fi
sh Tests/check_clean_start.sh "$app"

say "disk image"
stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/FolderVideoPlayer.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "FolderVideoPlayer" -srcfolder "$stage" -ov -format UDZO "$work/FolderVideoPlayer.dmg"
codesign --force --timestamp --sign "$identity" "$work/FolderVideoPlayer.dmg"
hdiutil verify -quiet "$work/FolderVideoPlayer.dmg"

say "notarize (minutes)"
result=$(xcrun notarytool submit "$work/FolderVideoPlayer.dmg" --keychain-profile "$profile" --wait 2>&1) || true
echo "$result" | tail -4
grep -q "status: Accepted" <<<"$result" || {
    id=$(grep -m1 "id:" <<<"$result" | awk '{print $2}')
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" || true
    die "notarization was not accepted"
}

say "staple and check Gatekeeper"
xcrun stapler staple -q "$work/FolderVideoPlayer.dmg"
xcrun stapler validate -q "$work/FolderVideoPlayer.dmg"
spctl -a -t open --context context:primary-signature -vv "$work/FolderVideoPlayer.dmg" 2>&1 | grep -q "accepted" \
    || die "Gatekeeper does not accept the image"

cp "$work/FolderVideoPlayer.dmg" "$dmg"
say "done"
echo "$dmg  $(stat -f%z "$dmg") bytes"
echo "SHA-256 $(shasum -a 256 "$dmg" | awk '{print $1}')"
