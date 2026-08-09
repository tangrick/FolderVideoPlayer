#!/bin/bash
#
# Fetch VLCKit into vendor/, which the build bundles and git ignores.
#
# The framework is 87 MB and is not this project's code, so it is fetched
# rather than committed. Run this once after cloning; the build will not work
# without it, and the app will refuse to play anything and say so.
#
# VLCKit is LGPL v2.1+. It is linked dynamically and shipped unmodified, which
# is what that licence asks for.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-$VERSION.tar.xz"
DEST="vendor/VLCKit.framework"

if [ -d "$DEST" ] && [ "${1:-}" != "--force" ]; then
    echo "$DEST is already here. --force to fetch it again."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading VLCKit $VERSION (84 MB)"
curl -fL --progress-bar -o "$WORK/vlckit.tar.xz" "$URL"

echo "==> Unpacking"
tar -xf "$WORK/vlckit.tar.xz" -C "$WORK"

# The tarball carries every platform plus 324 MB of debug symbols. Only the
# macOS framework is wanted, and dSYMs are never shipped.
FOUND=$(find "$WORK" -type d -name "VLCKit.framework" -path "*macos*" | head -1)
if [ -z "$FOUND" ]; then
    echo "No macOS framework in that archive — VideoLAN may have changed its layout." >&2
    exit 1
fi

mkdir -p vendor
rm -rf "$DEST"
cp -R "$FOUND" "$DEST"

echo "==> Done: $DEST ($(du -sh "$DEST" | awk '{print $1}'))"
echo "    Formats it adds: .flv .webm .avi .mkv .wmv and the rest."
