#!/bin/bash
# Build ghbdtn and assemble a runnable macOS .app bundle.
#
# Usage:
#   ./build.sh            # release build + bundle
#   ./build.sh debug      # debug build + bundle
#   ./build.sh run        # build, bundle, and launch
set -euo pipefail

CONFIG="release"
DO_RUN="no"
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG="debug" ;;
    release) CONFIG="release" ;;
    run) DO_RUN="yes" ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ghbdtn"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/$APP_NAME.app"

# whisper.cpp XCFramework (local binaryTarget) — fetched once, cached.
"$ROOT/tools/fetch-whisper.sh"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Strip the debug map before signing. The linker leaves STABS N_SO/N_OSO
# entries in __LINKEDIT pointing at every .o it consumed, which bakes the
# builder's home directory, username and full source tree into a binary that
# then ships to strangers. Releases are built on a personal Mac, so this is a
# privacy leak about a real person, not just noise.
#   -S = debug symbols only. A full strip would take the symbol table and the
#   __swift5_* reflection sections Swift needs.
# Must run BEFORE codesign: stripping after signing invalidates the signature.
# Note: `strings -a` does NOT read __LINKEDIT, so it reports a false clean here
# — verify with `strings -` or a raw grep (see tools/preflight-dist.sh).
strip -S "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM resource bundle with the n-gram language models. The app searches
# Contents/Resources/Ghbdtn_Ghbdtn.bundle/Models/ (see NgramModel.locateModel).
RESOURCE_BUNDLE="$BUILD_DIR/Ghbdtn_Ghbdtn.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "✗ Missing resource bundle: $RESOURCE_BUNDLE (n-gram models)" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

# Clean install: drop the shipped learned-words seed so the app starts with no
# pre-taught words (install.sh --clean sets GHBDTN_CLEAN=1).
if [ "${GHBDTN_CLEAN:-0}" = "1" ]; then
  rm -f "$APP/Contents/Resources/Ghbdtn_Ghbdtn.bundle/seed-learned.json"
  echo "▸ Clean build: shipped learned-words seed excluded"
fi

# whisper.framework is a dynamic library; the executable links it via
# @rpath = @executable_path/../Frameworks (see Package.swift linker flags).
WHISPER_FRAMEWORK="$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
if [ ! -d "$WHISPER_FRAMEWORK" ]; then
  echo "✗ Missing $WHISPER_FRAMEWORK (run tools/fetch-whisper.sh)" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$WHISPER_FRAMEWORK" "$APP/Contents/Frameworks/"

# Code signature. Accessibility permission is bound to the signature's
# designated requirement, so the identity must be STABLE across rebuilds or the
# grant resets every build. A stable self-signed identity ("Ghbdtn Local
# Signing", created by tools/setup-signing.sh) has a cert-based requirement that
# never changes; ad-hoc's requirement is the cdhash, which changes every build.
ENTITLEMENTS="$ROOT/Resources/ghbdtn.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "✗ Missing entitlements file: $ENTITLEMENTS" >&2
  exit 1
fi
SIGN_IDENTITY="Ghbdtn Local Signing"
# Sign by SHA-1 FINGERPRINT, not by name. With two certificates sharing a
# common name, `codesign --sign "<name>"` silently picks whichever comes first
# in the search list — a namesake in the keychain would decide which key signs
# a release. The fingerprint is unambiguous. Empty on machines that never ran
# setup-signing.sh, which is what selects the ad-hoc branch below.
SIGN_SHA1="$(security find-identity -p codesigning \
  | awk -v name="$SIGN_IDENTITY" '$0 ~ name {print $2; exit}')"

# --options runtime enables the Hardened Runtime. Without it any process running
# as the same user can load its own code into a process that holds the
# Accessibility grant, which is a cheaper path to a keylogger than stealing the
# signing key. It also turns on library validation, so the nested
# whisper.framework must carry the same signature — --deep does that here.
SIGN_FLAGS=(--force --deep --options runtime --timestamp=none
            --entitlements "$ENTITLEMENTS")

# No stderr suppression and no silent fallback to an entitlement-less bundle:
# if signing fails we want a loud error (set -e aborts).
if [ -n "$SIGN_SHA1" ]; then
  echo "▸ Signing (stable identity: $SIGN_IDENTITY / $SIGN_SHA1)…"
  codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_SHA1" "$APP"
else
  # A release must never go out ad-hoc: its designated requirement is the
  # cdhash, so every user loses the Accessibility grant on every update
  # (issue #7). Source builds still fall back, that is the point of the flag.
  if [ "${GHBDTN_REQUIRE_STABLE_SIGNING:-0}" = "1" ]; then
    echo "✗ Stable signing identity '$SIGN_IDENTITY' not found, and" >&2
    echo "  GHBDTN_REQUIRE_STABLE_SIGNING=1 forbids the ad-hoc fallback." >&2
    echo "  Run ./tools/setup-signing.sh on the machine that cuts releases." >&2
    exit 1
  fi
  echo "▸ Signing (ad-hoc — run ./tools/setup-signing.sh once so the"
  echo "  Accessibility grant survives rebuilds)…"
  codesign "${SIGN_FLAGS[@]}" --sign - "$APP"
fi

echo "✓ Built $APP"

if [ "$DO_RUN" = "yes" ]; then
  echo "▸ Launching…"
  # Kill a previous instance so the fresh signature is the one TCC sees.
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
