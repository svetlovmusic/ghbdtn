#!/bin/bash
# Fetch the prebuilt whisper.cpp XCFramework (pinned release, checksum-verified)
# into Vendor/whisper.xcframework so Package.swift can link it as a local
# binaryTarget.
#
# Why local and not a SwiftPM `binaryTarget(url:)`: the upstream release zip
# nests the .xcframework under build-apple/, and SwiftPM requires it at the
# archive root — so we unpack it ourselves. We also strip the iOS/tvOS/visionOS
# slices (the zip carries all platforms, ~184 MB unpacked; macOS alone is ~33 MB).
#
# Idempotent: skips work when the pinned version is already in place.
set -euo pipefail

WHISPER_VERSION="v1.9.1"
ZIP_SHA256="8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
ZIP_URL="https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}/whisper-${WHISPER_VERSION}-xcframework.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/whisper.xcframework"
STAMP="$DEST/.ghbdtn-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WHISPER_VERSION" ]; then
  echo "✓ whisper.cpp XCFramework $WHISPER_VERSION already in Vendor/"
  exit 0
fi

echo "▸ Fetching whisper.cpp XCFramework ${WHISPER_VERSION}…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fL --retry 3 -o "$TMP/xcf.zip" "$ZIP_URL"

echo "▸ Verifying checksum…"
ACTUAL="$(shasum -a 256 "$TMP/xcf.zip" | awk '{print $1}')"
if [ "$ACTUAL" != "$ZIP_SHA256" ]; then
  echo "✗ Checksum mismatch for $ZIP_URL" >&2
  echo "  expected: $ZIP_SHA256" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

echo "▸ Unpacking (macOS slice only)…"
unzip -q "$TMP/xcf.zip" -d "$TMP"
XCF="$TMP/build-apple/whisper.xcframework"
if [ ! -d "$XCF/macos-arm64_x86_64" ]; then
  echo "✗ Unexpected archive layout: $XCF/macos-arm64_x86_64 missing" >&2
  exit 1
fi

# Drop non-macOS slices and rewrite the xcframework Info.plist to match,
# otherwise SwiftPM refuses the bundle (slice list must mirror the dirs).
python3 - "$XCF" <<'PY'
import plistlib, shutil, sys, os
xcf = sys.argv[1]
with open(os.path.join(xcf, "Info.plist"), "rb") as f:
    info = plistlib.load(f)
keep = [lib for lib in info["AvailableLibraries"]
        if lib["LibraryIdentifier"] == "macos-arm64_x86_64"]
assert keep, "macOS slice not found in xcframework Info.plist"
info["AvailableLibraries"] = keep
with open(os.path.join(xcf, "Info.plist"), "wb") as f:
    plistlib.dump(info, f)
for entry in os.listdir(xcf):
    path = os.path.join(xcf, entry)
    if os.path.isdir(path) and entry != "macos-arm64_x86_64":
        shutil.rmtree(path)
PY

# The dSYMs are debug symbols for the prebuilt dylib — not needed to link/run.
rm -rf "$XCF/macos-arm64_x86_64/dSYMs"

mkdir -p "$ROOT/Vendor"
rm -rf "$DEST"
mv "$XCF" "$DEST"
echo "$WHISPER_VERSION" > "$STAMP"
echo "✓ Vendor/whisper.xcframework ready ($WHISPER_VERSION, macOS slice)"
