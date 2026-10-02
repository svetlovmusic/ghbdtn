#!/bin/bash
# Import release secrets into a disposable CI keychain. Never enable shell tracing.
set -euo pipefail
# Validate everything before touching the keychain. On macOS bash 3.2,
# `${VAR:?}` after an EXIT trap can print an error but return status 0.
# Explicit exit statuses keep GitHub from treating a failed import as success.
require_value() {
  if [ -z "$2" ]; then
    echo "✗ Missing $1" >&2
    exit 1
  fi
}
require_value RUNNER_TEMP "${RUNNER_TEMP:-}"
require_value SIGNING_P12_BASE64 "${SIGNING_P12_BASE64:-}"
require_value SIGNING_P12_PASSWORD "${SIGNING_P12_PASSWORD:-}"
require_value NOTARY_KEYCHAIN "${NOTARY_KEYCHAIN:-}"
require_value NOTARY_PROFILE "${NOTARY_PROFILE:-}"
if [ -n "${NOTARY_KEY_P8:-}" ]; then
  require_value NOTARY_KEY_ID "${NOTARY_KEY_ID:-}"
else
  require_value APPLE_ID "${APPLE_ID:-}"
  require_value APPLE_APP_PASSWORD "${APPLE_APP_PASSWORD:-}"
fi
umask 077
P12="$RUNNER_TEMP/ghbdtn-signing.p12"
KEY="$RUNNER_TEMP/ghbdtn-notary.p8"
cleanup() {
  local status=$?
  trap - EXIT
  rm -f "$P12" "$KEY" || true
  exit "$status"
}
trap cleanup EXIT
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
  printf '%s' "$NOTARY_KEY_P8" > "$KEY"
  AUTH=(--key "$KEY" --key-id "$NOTARY_KEY_ID")
  if [ -n "${NOTARY_ISSUER_ID:-}" ]; then AUTH+=(--issuer "$NOTARY_ISSUER_ID"); fi
else
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id DFB46VG2X3)
fi
xcrun notarytool store-credentials "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" "${AUTH[@]}"
# Verify the exact profile/keychain pair the build step will use. Do not print
# the account's notarization history in a public workflow log.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --keychain "$NOTARY_KEYCHAIN" \
  --output-format json >/dev/null
echo '✓ Release credentials imported and validated'
