#!/usr/bin/env bash
# Creates a distributable DMG with the app inside and an /Applications symlink.
# Usage: VERSION=1.0.0 scripts/make-dmg.sh   → dist/RFGEN44-FirmwareUpdater-1.0.0.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="RFGEN44 Firmware Updater"
APP="$DIST/$APP_NAME.app"
VERSION="${VERSION:-0.0.0-dev}"
DMG="$DIST/RFGEN44-FirmwareUpdater-${VERSION}.dmg"

test -d "$APP" || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging DMG contents at $STAGE"
# ditto keeps the code signature, the stapled ticket and extended attributes.
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"

echo "==> Creating DMG at $DMG"
hdiutil create \
    -volname "$APP_NAME ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

ls -lh "$DMG" | awk '{ printf "    %s\n", $0 }'
echo "==> Wrote $DMG"
