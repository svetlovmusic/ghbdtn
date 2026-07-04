#!/bin/bash
# make-dist.sh — build a drag-to-Applications .dmg for non-technical users.
#
# Produces dist/ghbdtn-<version>.dmg containing ghbdtn.app, an Applications
# shortcut, and a plain-language install note.
#
# NOTE ON GATEKEEPER: the app is signed locally (no paid Apple Developer ID /
# notarization), so a *downloaded* .dmg is quarantined — the recipient must do a
# one-time bypass on first launch (right-click → Open → Open, or System Settings
# → Privacy & Security → "Open Anyway"). Fully warning-free requires notarizing
# with a $99/yr Apple Developer account.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/ghbdtn.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo 0)"
OUT_DIR="$ROOT/dist"
DMG="$OUT_DIR/ghbdtn-$VERSION.dmg"
VOL="ghbdtn $VERSION"

echo "▸ Building the app…"
"$ROOT/build.sh"
[ -d "$APP" ] || { echo "✗ build did not produce $APP" >&2; exit 1; }

echo "▸ Staging .dmg contents…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/❗️ ПРОЧТИ — установка.txt" <<'EOF'
Установка ghbdtn
================

1) Перетащите  ghbdtn.app  →  в папку Applications (ярлык рядом).

2) ПЕРВЫЙ запуск (нужен один раз):
   Откройте папку «Программы» (Applications), нажмите на ghbdtn
   ПРАВОЙ кнопкой мыши → «Открыть» → в окне ещё раз «Открыть».
   (macOS так проверяет приложения не из App Store. Двойной клик
    в первый раз может ругаться — используйте правый клик → Открыть.)

   Если пишет «повреждён» — откройте Терминал и выполните одну строку:
   xattr -dr com.apple.quarantine /Applications/ghbdtn.app
   затем снова правый клик → Открыть.

3) Разрешите доступ (иначе не будет работать):
   Системные настройки → Конфиденциальность и безопасность →
   Универсальный доступ → включите  ghbdtn.
   Для голосового ввода также разрешите  Микрофон.

Готово. Приложение живёт в строке меню (значок клавиатуры у часов).
Проверка: наберите  ghbdtn  → должно стать  привет.

Хоткеи: ⌃⌥Space — ручная конвертация,  ⌃⌥V — диктовка.
EOF

echo "▸ Creating $DMG…"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "Send this .dmg to anyone. They: open it → drag ghbdtn.app to Applications →"
echo "first launch via right-click → Open → grant Accessibility. Done."
