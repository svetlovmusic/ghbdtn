#!/bin/bash
# Submit one artifact, require Accepted, staple and validate Apple's ticket.
set -euo pipefail
ARTIFACT="${1:?usage: notarize.sh <app-or-dmg> <log-directory>}"
LOG_DIR="${2:?missing log directory}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
mkdir -p "$LOG_DIR"
AUTH=(--keychain-profile "$NOTARY_PROFILE")
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then AUTH+=(--keychain "$NOTARY_KEYCHAIN"); fi
UPLOAD="$ARTIFACT"
if [[ "$ARTIFACT" == *.app ]]; then
  UPLOAD="$LOG_DIR/app.zip"
  ditto -c -k --keepParent "$ARTIFACT" "$UPLOAD"
fi
RESULT="$LOG_DIR/submission.json"
echo "▸ Submitting $(basename "$ARTIFACT") to Apple…"
SUBMIT_STATUS=0
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --wait --timeout 20m \
  --output-format json > "$RESULT" || SUBMIT_STATUS=$?
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$RESULT")"
if [ "$SUBMIT_STATUS" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
  SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$RESULT")"
  if [ -n "$SUBMISSION_ID" ]; then
    xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" "$LOG_DIR/apple-log.json" || true
  fi
  echo "✗ Notarization did not succeed ($STATUS). See $LOG_DIR" >&2
  exit 1
fi
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
if [[ "$ARTIFACT" == *.app ]]; then rm -f "$UPLOAD"; fi
echo "✓ Apple accepted $(basename "$ARTIFACT")"
