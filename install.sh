#!/bin/bash
# install.sh — build ghbdtn from source and install it to /Applications.
#
# Why build from source instead of shipping a .app: the app is signed locally
# (no paid Apple Developer ID / notarization), so a *downloaded* prebuilt .app
# would be quarantined by Gatekeeper ("can't be opened / is damaged"). An app
# you build locally is never quarantined — so a one-command source build is the
# smoothest way to install on any Mac.
#
# Usage:
#   ./install.sh                  # build (ad-hoc signed) and install
#   ./install.sh --stable-signing # + create a stable self-signed identity so the
#                                 #   Accessibility grant survives future updates
#   ./install.sh --clean          # ship WITHOUT the pre-taught learned words
#                                 #   (Resources/seed-learned.json); start blank
#   ./install.sh --no-launch      # don't open the app / Settings afterward
# Missing Command Line Tools are installed automatically (the script waits).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ghbdtn"
SRC_APP="$ROOT/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
MIN_MACOS="13.3"

STABLE_SIGNING="no"
DO_LAUNCH="yes"
CLEAN="no"
for arg in "$@"; do
  case "$arg" in
    --stable-signing) STABLE_SIGNING="yes" ;;
    --no-launch)      DO_LAUNCH="no" ;;
    --clean)          CLEAN="yes" ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf "\033[1;34m▸ %s\033[0m\n" "$1"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# 1. macOS version ---------------------------------------------------------
VER="$(sw_vers -productVersion)"
if [ "$(printf '%s\n%s\n' "$MIN_MACOS" "$VER" | sort -V | head -1)" != "$MIN_MACOS" ]; then
  die "macOS $MIN_MACOS or newer required (you have $VER)."
fi
ok "macOS $VER"

# 2. Swift toolchain (Command Line Tools or Xcode) -------------------------
# CLT is an Apple component and can't be bundled, but we can kick off its
# install and WAIT for it to finish, so you don't have to re-run this script.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  say "Xcode Command Line Tools missing — starting their install…"
  xcode-select --install 2>/dev/null || true
  say "A system dialog opened — click \"Install\". Waiting for it to finish…"
  waited=0
  until xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    if [ "$waited" -ge 1800 ]; then
      die "Command Line Tools still not ready after 30 min. Install them, then re-run ./install.sh"
    fi
    [ $((waited % 30)) -eq 0 ] && printf "  …still waiting (%ss)\n" "$waited"
  done
fi
ok "Swift toolchain present"

# 3. Optional stable signing (grant survives rebuilds/updates) -------------
if [ "$STABLE_SIGNING" = "yes" ]; then
  say "Setting up a stable self-signed identity…"
  "$ROOT/tools/setup-signing.sh"
  echo "  (On the build below, click **Always Allow** on the keychain prompt.)"
fi

# 4. Build (fetches whisper.cpp on first run, then compiles + bundles) ------
say "Building — first run downloads ~48 MB of whisper.cpp (checksum-verified)…"
if [ "$CLEAN" = "yes" ]; then
  say "Clean install: shipped learned-words seed will be excluded."
  GHBDTN_CLEAN=1 "$ROOT/build.sh"
else
  "$ROOT/build.sh"
fi
[ -d "$SRC_APP" ] || die "Build did not produce $SRC_APP"

# 5. Install into /Applications (stable path keeps the Accessibility grant) -
say "Installing to $DEST…"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$DEST"
cp -R "$SRC_APP" "$DEST"
ok "Installed $APP_NAME $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '') to /Applications"

# 6. Launch + point the user at the one manual step ------------------------
if [ "$DO_LAUNCH" = "yes" ]; then
  open "$DEST"
  sleep 1
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
fi

cat <<EOF

$(ok "Done.")
ghbdtn now lives in the menu bar (keyboard icon near the clock).

ONE manual step — grant permission (macOS requires this, no app can do it for you):
  System Settings → Privacy & Security → Accessibility → turn ON "ghbdtn".
  For voice dictation, also allow Microphone when first asked.

Then try it: type "ghbdtn" anywhere → it becomes "привет".
Manual convert hotkey: ⌃⌥Space.   Dictation: ⌃⌥V.

Update later:  git pull && ./install.sh
Uninstall:     ./uninstall.sh
EOF
