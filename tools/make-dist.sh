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
   Приложение подписано без платного сертификата Apple, поэтому macOS
   ставит на скачанное метку карантина и при запуске ругается
   («не удаётся открыть» / «повреждено»). Снимите метку одной строкой
   в Терминале (Программы → Утилиты → Терминал):

   xattr -dr com.apple.quarantine /Applications/ghbdtn.app

   Эта команда снимает карантин ТОЛЬКО с ghbdtn.app (не трогает систему и
   другие программы) — то есть подтверждает запуск, минуя проверку первого
   старта Gatekeeper. Ставьте так только сборки, которым доверяете
   (наши собираются из открытого кода github.com/svetlovmusic/ghbdtn).
   После команды приложение открывается обычным двойным кликом.

   Без Терминала: после первой неудачной попытки запуска —
   Системные настройки → Конфиденциальность и безопасность →
   внизу кнопка «Открыть всё равно».

3) Разрешите доступ (иначе не будет работать):
   Системные настройки → Конфиденциальность и безопасность →
   Универсальный доступ → включите  ghbdtn.
   Для голосового ввода также разрешите  Микрофон.

Готово. Приложение живёт в строке меню (значок клавиатуры у часов).
Проверка: наберите  ghbdtn  → должно стать  привет.

Хоткеи: ⌥⌘⏎ — ручная конвертация,  ⇧⏎ — диктовка.
Новые версии: приложение подскажет и откроет страницу загрузки; ставьте
обновление так же, как ставили в первый раз.
EOF

echo "▸ Creating ${DMG}…"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "Send this .dmg to anyone. They: open it → drag ghbdtn.app to Applications →"
echo "first launch via right-click → Open → grant Accessibility. Done."
