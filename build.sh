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

# Resolve credentials before compiling; distributable builds fail closed.
# shellcheck source=tools/signing-config.sh
source "$ROOT/tools/signing-config.sh"
resolve_signing_identity
cd "$ROOT"

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

# Sign nested code first, then the app. Entitlements belong to the executable,
# not to the framework. Developer ID enables library validation and timestamping.
ENTITLEMENTS="$ROOT/Resources/ghbdtn.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "✗ Missing entitlements file: $ENTITLEMENTS" >&2
  exit 1
fi
if [ -n "$SIGN_SHA1" ]; then
  echo "▸ Signing with Developer ID…"
  codesign --force --sign "$SIGN_SHA1" --timestamp --options runtime \
    "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --sign "$SIGN_SHA1" --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP"
  codesign --verify --strict --deep -R "=$RELEASE_REQUIREMENT" "$APP"
else
  # Contributors can compile without the maintainer's private key. These
  # builds are local only; make-dist.sh requires Developer ID before building.
  echo "▸ Signing local development build (ad-hoc)…"
  codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --strict --deep "$APP"

echo "✓ Built $APP"

if [ "$DO_RUN" = "yes" ]; then
  echo "▸ Launching…"
  # Kill a previous instance so the fresh signature is the one TCC sees.
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
