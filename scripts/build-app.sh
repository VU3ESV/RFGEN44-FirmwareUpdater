#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) release binary, wraps it into
# "RFGEN44 Firmware Updater.app" with the Info.plist template, embeds the icon,
# and ad-hoc signs. scripts/package-signed.sh re-signs it with Developer ID.
# Output: dist/RFGEN44 Firmware Updater.app
#
#   VERSION=1.0.0 scripts/build-app.sh
#   scripts/build-app.sh --install     # also copy it to /Applications

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="RFGEN44 Firmware Updater"
EXECUTABLE="RFGEN44Updater"
APP="$DIST/$APP_NAME.app"
VERSION="${VERSION:-0.0.0-dev}"

mkdir -p "$DIST"
cd "$ROOT"

echo "==> Building universal release binary (arm64 + x86_64) — version $VERSION"
swift build -c release --arch arm64 --arch x86_64 --product "$EXECUTABLE"
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXECUTABLE"
test -x "$BIN" || { echo "Binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
chmod +x "$APP/Contents/MacOS/$EXECUTABLE"
sed "s/__VERSION__/${VERSION}/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Icon, rendered once and cached (best effort: ships without an icon if rendering fails).
if [ ! -f "$DIST/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$DIST/AppIcon.icns" ]; then
    echo "==> Rendering icon"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    if swift "$ROOT/scripts/make-icon.swift" "$ICONSET" && iconutil -c icns "$ICONSET" -o "$DIST/AppIcon.icns"; then
        rm -rf "$ICONSET"
    else
        echo "==> WARNING: icon rendering failed, shipping without an icon"
    fi
fi
[ -f "$DIST/AppIcon.icns" ] && cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
file "$APP/Contents/MacOS/$EXECUTABLE" | sed 's/^/    /'

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
fi

echo "==> Built $APP"
