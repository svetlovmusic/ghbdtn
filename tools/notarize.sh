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
# notarytool writes some failures (including timeout JSON) to stderr. Keep both
# streams, and tolerate empty/malformed JSON without losing the submission ID.
json_field() {
  python3 - "$@" <<'PY'
import json, sys
for path in sys.argv[2:]:
    try:
        with open(path) as stream:
            value = json.load(stream)
    except (OSError, ValueError):
        continue
    field = value.get(sys.argv[1]) if isinstance(value, dict) else None
    if isinstance(field, str) and field.strip():
        print(field)
        break
PY
}
RESULT="$LOG_DIR/submission.json"
SUBMIT_ERROR="$LOG_DIR/submission.stderr.log"
echo "▸ Submitting $(basename "$ARTIFACT") to Apple…"
SUBMIT_STATUS=0
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --output-format json \
  > "$RESULT" 2> "$SUBMIT_ERROR" || SUBMIT_STATUS=$?
SUBMISSION_ID="$(json_field id "$RESULT" "$SUBMIT_ERROR")"
if [ -n "$SUBMISSION_ID" ]; then
  printf '%s\n' "$SUBMISSION_ID" > "$LOG_DIR/submission-id.txt"
fi
if [ "$SUBMIT_STATUS" -ne 0 ] || [ -z "$SUBMISSION_ID" ]; then
  echo "✗ Submission failed or returned no valid submission ID. See $LOG_DIR" >&2
  exit 1
fi
# Save the ID before waiting: a timeout ends this script, not Apple's processing.
echo "▸ Waiting for Apple submission ${SUBMISSION_ID}…"
WAIT_RESULT="$LOG_DIR/wait.json"
WAIT_ERROR="$LOG_DIR/wait.stderr.log"
WAIT_STATUS=0
xcrun notarytool wait "$SUBMISSION_ID" "${AUTH[@]}" --timeout 20m \
  --output-format json > "$WAIT_RESULT" 2> "$WAIT_ERROR" || WAIT_STATUS=$?
STATUS="$(json_field status "$WAIT_RESULT" "$WAIT_ERROR")"
if [ "$WAIT_STATUS" -ne 0 ] || [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" "$LOG_DIR/apple-log.json" \
    > "$LOG_DIR/apple-log.stdout.log" 2> "$LOG_DIR/apple-log.stderr.log" || true
  echo "✗ Notarization did not succeed (${STATUS:-no valid status}; submission $SUBMISSION_ID). See $LOG_DIR" >&2
  exit 1
fi
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
if [[ "$ARTIFACT" == *.app ]]; then rm -f "$UPLOAD"; fi
echo "✓ Apple accepted $(basename "$ARTIFACT")"
