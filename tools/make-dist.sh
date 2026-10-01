#!/bin/bash
# Build, sign, notarize and verify a distributable DMG. No unsigned fallback.
# Usage: NOTARY_PROFILE=ghbdtn-notary ./tools/make-dist.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ghbdtn.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
OUT_DIR="$ROOT/dist"
DMG="$OUT_DIR/ghbdtn-$VERSION.dmg"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE; see docs/RELEASING.md}"
export GHBDTN_REQUIRE_DEVELOPER_ID=1
# shellcheck source=tools/signing-config.sh
source "$ROOT/tools/signing-config.sh"
resolve_signing_identity
AUTH=(--keychain-profile "$NOTARY_PROFILE")
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then AUTH+=(--keychain "$NOTARY_KEYCHAIN"); fi
# Validate credentials before doing the expensive build. No credentials in logs.
xcrun notarytool history "${AUTH[@]}" --output-format json >/dev/null
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "$OUT_DIR/.package.XXXXXX")"
MOUNT="$WORK/mounted"
cleanup() {
  if mount | grep -Fq " on $MOUNT "; then hdiutil detach "$MOUNT" >/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
LOG_DIR="$(mktemp -d "$OUT_DIR/notarization-$VERSION.XXXXXX")"

"$ROOT/build.sh"
"$ROOT/tools/preflight-dist.sh" "$APP" "$VERSION"
# Staple the app itself as well as the DMG, so copied apps and self-updates
# retain the ticket when the container is no longer present.
"$ROOT/tools/notarize.sh" "$APP" "$LOG_DIR/app"
spctl --assess --type execute --verbose=2 "$APP"

mkdir -p "$WORK/contents"
ditto "$APP" "$WORK/contents/ghbdtn.app"
ln -s /Applications "$WORK/contents/Applications"
cat > "$WORK/contents/Установка.txt" <<'NOTE'
Установка ghbdtn
================
1. Перетащите ghbdtn.app в папку Applications (Программы).
2. Откройте ghbdtn из Программ.
3. Разрешите Универсальный доступ в Системных настройках →
   Конфиденциальность и безопасность. Для диктовки разрешите Микрофон.

Приложение живёт в строке меню (значок клавиатуры у часов).
Проверка: наберите ghbdtn → должно стать привет.
Хоткеи: ⌥⌘⏎ — ручная конвертация, ⇧⏎ — диктовка.
Обновления доступны через меню приложения.
NOTE
echo "▸ Creating signed DMG…"
hdiutil create -volname "ghbdtn $VERSION" -srcfolder "$WORK/contents" \
  -ov -format UDZO "$WORK/release.dmg" >/dev/null
codesign --force --sign "$SIGN_SHA1" --timestamp "$WORK/release.dmg"
"$ROOT/tools/notarize.sh" "$WORK/release.dmg" "$LOG_DIR/dmg"
codesign --verify --strict -R "=$DEVELOPER_REQUIREMENT" "$WORK/release.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK/release.dmg"
hdiutil attach "$WORK/release.dmg" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
codesign --verify --deep --strict -R "=$RELEASE_REQUIREMENT" "$MOUNT/ghbdtn.app"
xcrun stapler validate "$MOUNT/ghbdtn.app"
spctl --assess --type execute --verbose=2 "$MOUNT/ghbdtn.app"
hdiutil detach "$MOUNT" >/dev/null
# Only a fully verified artifact gets the final release filename.
mv "$WORK/release.dmg" "$DMG"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✓ Signed and notarized: $DMG"
