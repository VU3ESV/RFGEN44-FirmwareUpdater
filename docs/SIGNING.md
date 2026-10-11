# Release signing (RFGEN44 Firmware Updater)

Releases are signed and notarized exactly as [RFGEN44-App](https://github.com/VU3ESV/RFGEN44-App)'s are, with the same certificate, the same notary service and the same scripts.

[`scripts/package-signed.sh`](../scripts/package-signed.sh) builds a universal app. It signs the app with Developer ID, the hardened runtime and a secure timestamp, then notarizes and staples it. It then builds the DMG and signs, notarizes and staples that too, and writes a `.sha256` next to it.

## The certificate

The app uses RFGEN44-App's Developer ID Application certificate, which was originally LP-700-App's: SHA-1 `A59B8647CA9706C6E8CDBB461C9801CF715132C4`, team `Y6FT52BKDA`.

The team has five Developer ID Application certificates, Apple's limit, and they all have the same name. The script therefore selects this one by SHA-1, never by name.

All of the team's certificates expire on **2027-02-01**. After renewing, pass the new one with `CERT_SHA1=<sha1>`.

The app has no entitlements. It isn't sandboxed, and launching `ipecmd` (bash → Java) and USB/HID access to the PICkit need none under the hardened runtime.

## Releasing from this Mac

You only need to do this once. It stores the notary credentials in your login keychain, using the same Apple ID and app-specific password as RFGEN44-App:

```sh
xcrun notarytool store-credentials RFGEN44-NOTARY --apple-id <apple-id> --team-id Y6FT52BKDA
```

Then, for each release:

```sh
REQUIRE_NOTARIZATION=1 VERSION=1.0.0 scripts/package-signed.sh
# → dist/RFGEN44-FirmwareUpdater-1.0.0.dmg and .dmg.sha256
```

Then tag the commit you released and push the tag together with the branch, for example `git tag v1.0.0 && git push origin main v1.0.0`. If the branch is pushed without the tag, the GitHub workflow (below) treats that push as a new release and publishes the version again.

Without `REQUIRE_NOTARIZATION=1`, missing credentials don't stop the build:

| What's missing | What you get |
|---|---|
| Notary profile | A signed but not notarized DMG |
| Certificate | An ad-hoc signed DMG |

Neither one opens cleanly on another Mac. To use a different profile name, set `NOTARY_PROFILE=<name>`.

## Releasing from GitHub Actions

[`.github/workflows/release.yml`](../.github/workflows/release.yml) is RFGEN44-App's workflow with the names changed. Once this project is on GitHub, the triggers are:

- a merge to `main`, which releases the next patch version;
- a pushed `vX.Y.Z` tag;
- a manual `gh workflow run release.yml -f version=X.Y.Z`.

Each run signs, notarizes and publishes the DMG and its checksum as a GitHub Release.

It needs the same six repository secrets as RFGEN44-App. GitHub secrets can't be read back, so set them again on this repo. The wizard walks you through exporting the certificate and checks everything with Apple:

```sh
scripts/setup-signing-secrets.sh
```

| Secret | What it is |
|--------|------------|
| `MACOS_CERT_P12_BASE64` | The Developer ID Application certificate + private key, exported as `.p12` and base64-encoded |
| `MACOS_CERT_PASSWORD` | The `.p12` export password |
| `KEYCHAIN_PASSWORD` | Any value; it only unlocks the throwaway CI keychain |
| `NOTARY_APPLE_ID` | The Apple ID used for notarization |
| `NOTARY_TEAM_ID` | `Y6FT52BKDA` |
| `NOTARY_PASSWORD` | An app-specific password for that Apple ID |

## Checking a release

```sh
spctl -a -t open --context context:primary-signature -vv dist/RFGEN44-FirmwareUpdater-<v>.dmg
xcrun stapler validate dist/RFGEN44-FirmwareUpdater-<v>.dmg
codesign -dvv "dist/RFGEN44 Firmware Updater.app"   # Developer ID, Y6FT52BKDA, runtime, timestamp
```
