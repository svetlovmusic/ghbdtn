#!/bin/bash
# preflight-dist.sh — refuse to ship a bundle that should not leave this Mac.
#
# Checks Developer ID, Hardened Runtime, a secure timestamp, library validation,
# the pinned Apple team, build-machine traces, filesystem litter and version.
# Runs before notarization; the distribution script checks Apple's ticket later.
#
# Usage: ./tools/preflight-dist.sh <path-to-.app> [expected-version]
set -euo pipefail

APP="${1:?usage: preflight-dist.sh <path-to-.app> [expected-version]}"
EXPECT_VERSION="${2:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/signing-config.sh
source "$ROOT/tools/signing-config.sh"

fail() { echo "✗ $1" >&2; exit 1; }

[ -d "$APP" ] || fail "not a bundle: $APP"
echo "▸ Preflight on $APP"

# ---------------------------------------------------------------- signature
SIG_INFO="$(codesign -dvvv "$APP" 2>&1)"
case "$SIG_INFO" in
  *"Signature=adhoc"*)
    fail "bundle is ad-hoc signed — the grant would reset for every user on every update" ;;
esac
case "$SIG_INFO" in
  *"flags=0x10000(runtime)"*) ;;
  *) fail "Hardened Runtime is not enabled (expected flags=0x10000(runtime))" ;;
esac

case "$SIG_INFO" in
  *"Timestamp="*) ;;
  *) fail "missing secure timestamp" ;;
esac
codesign --verify --strict --deep -R "=$RELEASE_REQUIREMENT" "$APP" \
  || fail "app is not signed with the expected Developer ID"
codesign --verify --strict -R "=$DEVELOPER_REQUIREMENT" \
  "$APP/Contents/Frameworks/whisper.framework" \
  || fail "whisper.framework is not signed with the expected Developer ID"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
printf '%s' "$ENTITLEMENTS" | python3 -c '
import plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
assert p.get("com.apple.security.device.audio-input") is True, "microphone entitlement missing"
for key in ("com.apple.security.cs.disable-library-validation", "com.apple.security.get-task-allow",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.allow-unsigned-executable-memory", "com.apple.security.cs.allow-jit"):
    assert not p.get(key), "unsafe release entitlement: " + key
' || fail "release entitlements failed verification"
echo "  ✓ signature: Developer ID, timestamp, hardened runtime, library validation"

# ------------------------------------------------------- traces of this Mac
# Release builds should carry no absolute source paths, but the linker's debug
# map reintroduces them on every build unless build.sh strips it.
#
# SCAN WITH RAW grep, NOT `strings -a`. On macOS `strings -a` skips __LINKEDIT,
# which is exactly where the debug map lives — it reported a clean binary that
# in fact carried 74 copies of the builder's home directory. `strings -` and a
# byte-level grep both see it; grep needs no decisions about encoding.
# Check our executables. Upstream whisper.framework contains its own CI paths
# (/Users/runner), which coincide with our hosted runner username. Its contents
# are pinned by fetch-whisper.sh and its signature is checked above.
BUILD_USER="$(id -un)"
while IFS= read -r -d '' f; do
  file "$f" | grep -q "Mach-O" || continue
  NAME="$(basename "$f")"
  if grep -a -q -F "$HOME" "$f" 2>/dev/null; then
    fail "builder home directory baked into $NAME (is 'strip -S' still in build.sh?)
    count: $(grep -a -c -F "$HOME" "$f" 2>/dev/null)"
  fi
  if grep -a -q -F "$BUILD_USER" "$f" 2>/dev/null; then
    fail "build user name '$BUILD_USER' baked into $NAME"
  fi
  # The debug map itself, independent of what its paths happen to say. Only our
  # own code: what upstream ships inside whisper.framework is not ours to strip.
  case "$f" in
    */Contents/MacOS/*)
      if nm -pa "$f" 2>/dev/null | grep -qE ' (OSO|SO) '; then
        fail "debug map (STABS N_SO/N_OSO) left in $NAME — strip -S must run before signing"
      fi ;;
  esac
done < <(find "$APP/Contents/MacOS" -type f -print0)
echo "  ✓ binaries: no builder identity, no debug map"

# ------------------------------------------------------------------- litter
LITTER="$(find "$APP" \( -name '.DS_Store' -o -name '._*' -o -name '.fseventsd' \
                      -o -name '.Spotlight-V100' -o -name '.Trashes' \) -print)"
[ -z "$LITTER" ] || fail "filesystem litter inside the bundle:
$LITTER"

XATTRS="$(xattr -lr "$APP" 2>/dev/null || true)"
[ -z "$XATTRS" ] || fail "extended attributes on the bundle:
$XATTRS"
echo "  ✓ contents: no .DS_Store/AppleDouble, no extended attributes"

# ------------------------------------------------------------------ version
if [ -n "$EXPECT_VERSION" ]; then
  ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
  [ "$ACTUAL_VERSION" = "$EXPECT_VERSION" ] \
    || fail "version mismatch: Info.plist says '$ACTUAL_VERSION', expected '$EXPECT_VERSION'"
  echo "  ✓ version: $ACTUAL_VERSION"
fi

echo "✓ Preflight passed"
