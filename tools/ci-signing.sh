#!/bin/bash
# Import release secrets into a disposable CI keychain. Never enable shell tracing.
set -euo pipefail
: "${RUNNER_TEMP:?This script is for a GitHub Actions runner}"
: "${SIGNING_P12_BASE64:?Missing SIGNING_P12_BASE64 secret}"
: "${SIGNING_P12_PASSWORD:?Missing SIGNING_P12_PASSWORD secret}"
: "${NOTARY_KEYCHAIN:?Missing NOTARY_KEYCHAIN}"
: "${NOTARY_PROFILE:?Missing NOTARY_PROFILE}"
umask 077
P12="$RUNNER_TEMP/ghbdtn-signing.p12"
KEY="$RUNNER_TEMP/ghbdtn-notary.p8"
trap 'rm -f "$P12" "$KEY"' EXIT
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN"
security set-keychain-settings -lut 3600 "$NOTARY_KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN"
# Hosted runner: only this keychain is needed to sign. Do not use on a personal Mac.
security list-keychains -d user -s "$NOTARY_KEYCHAIN"
printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$P12"
security import "$P12" -k "$NOTARY_KEYCHAIN" -P "$SIGNING_P12_PASSWORD" \
  -T /usr/bin/codesign -x >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$NOTARY_KEYCHAIN" >/dev/null
if [ -n "${NOTARY_KEY_P8:-}" ]; then
  : "${NOTARY_KEY_ID:?Missing NOTARY_KEY_ID secret}"
  printf '%s' "$NOTARY_KEY_P8" > "$KEY"
  AUTH=(--key "$KEY" --key-id "$NOTARY_KEY_ID")
  if [ -n "${NOTARY_ISSUER_ID:-}" ]; then AUTH+=(--issuer "$NOTARY_ISSUER_ID"); fi
else
  : "${APPLE_ID:?Set NOTARY_KEY_P8 + NOTARY_KEY_ID, or APPLE_ID + APPLE_APP_PASSWORD}"
  : "${APPLE_APP_PASSWORD:?Missing APPLE_APP_PASSWORD secret}"
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id DFB46VG2X3)
fi
xcrun notarytool store-credentials "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" "${AUTH[@]}"
echo '✓ Release credentials imported and validated'
