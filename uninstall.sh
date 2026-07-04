#!/bin/bash
# uninstall.sh — remove ghbdtn.
#
# Usage:
#   ./uninstall.sh          # remove the app from /Applications
#   ./uninstall.sh --purge  # also delete downloaded Whisper models + learned words
set -euo pipefail

APP_NAME="ghbdtn"
DEST="/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/Ghbdtn"
PURGE="no"
[ "${1:-}" = "--purge" ] && PURGE="yes"

ok() { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

if [ -d "$DEST" ]; then rm -rf "$DEST"; ok "Removed $DEST"; else echo "Not installed in /Applications."; fi
# Also drop a copy built in the repo, if any.
rm -rf "$(cd "$(dirname "$0")" && pwd)/$APP_NAME.app"

if [ "$PURGE" = "yes" ]; then
  rm -rf "$SUPPORT"
  ok "Removed $SUPPORT (Whisper models + learned words)"
else
  echo "Kept $SUPPORT (Whisper models + learned words). Delete with --purge."
fi

cat <<EOF

Two things macOS keeps that you may want to clear manually:
  • System Settings → Privacy & Security → Accessibility → remove "ghbdtn".
  • System Settings → General → Login Items → remove "ghbdtn" if present.
EOF
