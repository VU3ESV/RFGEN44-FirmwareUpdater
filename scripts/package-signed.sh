#!/usr/bin/env bash
# Builds "RFGEN44 Firmware Updater.app", signs it with Developer ID and the hardened
# runtime, notarizes and staples the app, then builds, signs, notarizes and staples the
# DMG. Same scheme, certificate and notary service as RFGEN44-App's package-signed.sh.
#
#   VERSION=1.0.0 scripts/package-signed.sh
#     → dist/RFGEN44-FirmwareUpdater-1.0.0.dmg (+ .sha256)
#
# Two ways to supply credentials:
#
#   On this Mac (default). Signs with the Developer ID certificate in the login keychain,
#   selected by SHA-1 (RFGEN44's: LP-700-App's cert). Notarizes with a notarytool keychain
#   profile, created once with:
#     xcrun notarytool store-credentials RFGEN44-NOTARY --apple-id <id> --team-id Y6FT52BKDA
#   Env: CERT_SHA1 (override the cert), NOTARY_PROFILE (default RFGEN44-NOTARY).
#
#   In CI (GitHub secrets, exactly as RFGEN44-App; see docs/SIGNING.md):
#     MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, KEYCHAIN_PASSWORD,
#     NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#
# REQUIRE_NOTARIZATION=1 makes the run fail unless the DMG ends up signed, notarized and
# stapled. CI always sets it. Without it, missing credentials leave the build ad-hoc
# signed, or signed but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
APP_NAME="RFGEN44 Firmware Updater"
APP="dist/$APP_NAME.app"
DMG="dist/RFGEN44-FirmwareUpdater-${VERSION}.dmg"
TEAM_ID="Y6FT52BKDA"
CERT_SHA1="${CERT_SHA1:-A59B8647CA9706C6E8CDBB461C9801CF715132C4}"   # RFGEN44-App's (LP-700-App's) cert
NOTARY_PROFILE="${NOTARY_PROFILE:-RFGEN44-NOTARY}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION '$VERSION' is not X.Y.Z" >&2
  exit 1
fi

echo "==> Building app (v$VERSION)"
VERSION="$VERSION" ./scripts/build-app.sh

# --- choose the signing identity --------------------------------------------------------
IDENTITY=""
KC=""
cleanup() {
  # Deleting the keychain also drops it from the search list.
  if [ -n "$KC" ]; then security delete-keychain "$KC" 2>/dev/null || true; fi
}
trap cleanup EXIT

if [ -n "${MACOS_CERT_P12_BASE64:-}" ]; then
  echo "==> Importing Developer ID certificate into a temporary keychain"
  KC="$TMP/rfgen44-updater-signing.keychain-db"
  KCPW="${KEYCHAIN_PASSWORD:-rfgen44-ci-temp}"
  security create-keychain -p "$KCPW" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KCPW" "$KC"
  echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$TMP/cert.p12"
  security import "$TMP/cert.p12" -k "$KC" -P "${MACOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
  rm -f "$TMP/cert.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
  # Make the temp keychain searchable (keep the existing ones too; word-split on purpose).
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  # In the fresh keychain there is exactly one Developer ID identity, so its SHA-1 is unambiguous.
  IDENTITY="$(security find-identity -v -p codesigning "$KC" | awk '/Developer ID Application:/ { print $2; exit }')"
  test -n "$IDENTITY" || { echo "No Developer ID Application identity in the .p12" >&2; exit 1; }
elif grep -q "$CERT_SHA1" <<< "$(security find-identity -v -p codesigning)"; then
  # The team has five identically named Developer ID certs, so select by SHA-1, never by name.
  IDENTITY="$CERT_SHA1"
fi

# codesign with a few retries: Apple's secure-timestamp service is intermittently
# unavailable ("The timestamp service is not available.").
cs() {
  local n=1
  until codesign "$@"; do
    [ "$n" -ge 4 ] && return 1
    echo "  codesign attempt $n failed — retrying in 15s…" >&2; sleep 15; n=$((n + 1))
  done
}

# --- sign the app ------------------------------------------------------------------------
# One executable, no nested code. No entitlements: the app is not sandboxed; launching
# ipecmd (bash → Java) and IOKit USB/HID access to the PICkit need none under the
# hardened runtime.
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with: $(grep "$IDENTITY" <<< "$(security find-identity -v -p codesigning)" | sed 's/^ *[0-9]*) //')"
  cs --force -s "$IDENTITY" -o runtime --timestamp "$APP"
  # Fail early on anything notarization would reject. (Captured first: under pipefail,
  # `codesign | grep -q` can fail spuriously when grep stops reading early.)
  SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
  grep -q "TeamIdentifier=$TEAM_ID" <<< "$SIGNATURE" || { echo "Signed by an unexpected team" >&2; exit 1; }
  grep -q "flags=.*runtime" <<< "$SIGNATURE" || { echo "Hardened runtime missing" >&2; exit 1; }
  grep -q "^Timestamp=" <<< "$SIGNATURE" || { echo "Secure timestamp missing" >&2; exit 1; }
  ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  if grep -q "get-task-allow" <<< "$ENTITLEMENTS"; then
    echo "The app carries get-task-allow, which notarization rejects" >&2; exit 1
  fi
else
  echo "==> WARNING: no Developer ID certificate ($CERT_SHA1 not in the keychain, no MACOS_CERT_P12_BASE64) — keeping the ad-hoc signature (not distributable)"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# --- notary credentials -------------------------------------------------------------------
NOTARY_AUTH=()
if [ -n "$IDENTITY" ]; then
  if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
  elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  fi
fi
if [ "$REQUIRE_NOTARIZATION" = 1 ] && [ ${#NOTARY_AUTH[@]} -eq 0 ]; then
  if [ -z "$IDENTITY" ]; then
    echo "REQUIRE_NOTARIZATION=1 but there is no Developer ID certificate to sign with." >&2
  else
    echo "REQUIRE_NOTARIZATION=1 but there are no notary credentials. Create the profile with:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID" >&2
  fi
  exit 1
fi

# Submits to the notary service; fails unless Apple says "Accepted", printing Apple's log.
# (${arr[@]+"${arr[@]}"} keeps bash 3.2's `set -u` from rejecting an empty array.)
notarize() {  # $1 = path to a .zip or .dmg
  local out id status
  out="$(xcrun notarytool submit "$1" ${NOTARY_AUTH[@]+"${NOTARY_AUTH[@]}"} --wait --output-format json)" || true
  echo "$out"
  id="$(plutil -extract id raw -o - - <<< "$out" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<< "$out" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization of $1 failed (status: ${status:-unknown})" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" ${NOTARY_AUTH[@]+"${NOTARY_AUTH[@]}"} >&2 || true
    return 1
  fi
}

# Notarize the APP and staple it first, so the bundle carries its ticket even offline and
# once copied out of the DMG (not just while the DMG is mounted).
if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  echo "==> Notarizing the app + stapling (a few minutes)…"
  AZIP="$TMP/RFGEN44-FirmwareUpdater-app.zip"
  ditto -c -k --keepParent "$APP" "$AZIP"
  notarize "$AZIP"
  rm -f "$AZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -t exec -vv "$APP"
fi

echo "==> Building DMG"
VERSION="$VERSION" ./scripts/make-dmg.sh

# Codesign the DMG container too (so `spctl -t open` accepts it and it mounts without a
# Gatekeeper prompt), then notarize + staple the DMG itself.
if [ -n "$IDENTITY" ]; then
  echo "==> Codesigning the DMG"
  cs --force -s "$IDENTITY" --timestamp "$DMG"
fi
if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  echo "==> Notarizing the DMG + stapling (a few minutes)…"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
  echo "==> Notarized + stapled (app + DMG)."
elif [ -n "$IDENTITY" ]; then
  echo "==> Skipping notarization (no notary credentials) — signed but not notarized."
fi

( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" && cat "$(basename "$DMG").sha256" )
echo "==> Done: $DMG"
