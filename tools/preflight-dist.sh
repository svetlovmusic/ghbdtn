#!/bin/bash
# preflight-dist.sh — refuse to ship a bundle that should not leave this Mac.
#
# Releases are now built and signed LOCALLY (the signing key never goes to CI),
# which means the machine that produces the artifact is also the machine that
# holds the developer's home directory. This script is the checklist that stops
# a bad artifact from being published, so "safe" does not depend on remembering.
#
# It checks, and FAILS on:
#   - ad-hoc signature, or a designated requirement that is not the pinned one
#     (an ad-hoc release is what broke the Accessibility grant in issue #7)
#   - a missing Hardened Runtime flag
#   - traces of this machine in any Mach-O: /Users/... paths, the build user's
#     name
#   - filesystem litter: .DS_Store, ._* AppleDouble, .fseventsd, .Spotlight-V100
#   - extended attributes on the bundle (quarantine, Finder metadata)
#   - a version in Info.plist that disagrees with the expected one
#
# Usage: ./tools/preflight-dist.sh <path-to-.app> [expected-version]
set -euo pipefail

APP="${1:?usage: preflight-dist.sh <path-to-.app> [expected-version]}"
EXPECT_VERSION="${2:-}"

# The designated requirement every release must carry. Pinned to the SHA-1 of
# the "Ghbdtn Local Signing" leaf certificate: that is the only thing an
# attacker cannot forge without the private key, and it is what lets a TCC
# grant survive an update.
EXPECTED_DR='identifier "com.ghbdtn.app" and certificate leaf = H"a361680fa2755016c6bac34435a2cba3b12b21e9"'

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

ACTUAL_DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
[ "$ACTUAL_DR" = "$EXPECTED_DR" ] || fail "designated requirement mismatch
    expected: $EXPECTED_DR
    actual:   ${ACTUAL_DR:-<none>}"

codesign --verify --strict --deep "$APP" 2>/dev/null \
  || fail "codesign --verify --strict --deep failed"
echo "  ✓ signature: stable identity, hardened runtime, DR pinned"

# ------------------------------------------------------- traces of this Mac
# Release builds should carry no absolute source paths, but the linker's debug
# map reintroduces them on every build unless build.sh strips it.
#
# SCAN WITH RAW grep, NOT `strings -a`. On macOS `strings -a` skips __LINKEDIT,
# which is exactly where the debug map lives — it reported a clean binary that
# in fact carried 74 copies of the builder's home directory. `strings -` and a
# byte-level grep both see it; grep needs no decisions about encoding.
# The check is for THIS machine's identity, not for absolute paths in general:
# the vendored whisper.framework legitimately carries /Users/runner/... from
# GitHub's own builder, which says nothing about anyone.
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
done < <(find "$APP" -type f -perm -u+x -print0)
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
