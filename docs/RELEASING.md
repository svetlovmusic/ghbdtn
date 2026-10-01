# Выпуск ghbdtn

Релизы используют Developer ID Application команды `DFB46VG2X3`, Hardened Runtime
и нотариализацию Apple. Рабочие скрипты одинаковы локально и в GitHub Actions.

## Однократная настройка GitHub Actions

В Settings → Secrets and variables → Actions репозитория `svetlovmusic/ghbdtn`
нужны следующие **secrets**, а не обычные variables:

| Secret | Содержимое |
|---|---|
| `SIGNING_P12_BASE64` | Base64 экспорта Developer ID Application вместе с закрытым ключом в защищённый паролем `.p12` |
| `SIGNING_P12_PASSWORD` | Пароль этого `.p12` |
| `NOTARY_KEY_P8` | Приватный ключ App Store Connect API (`.p8`) |
| `NOTARY_KEY_ID` | Идентификатор API-ключа |
| `NOTARY_ISSUER_ID` | Issuer ID для командного API-ключа; для индивидуального ключа не задаётся |

Вместо трёх `NOTARY_*` secrets можно использовать `APPLE_ID` и
`APPLE_APP_PASSWORD` — Apple Account и его отдельный app-specific password.
Обычный пароль Apple Account для этого не используется.

Сертификат выпускается один раз и используется для следующих версий до истечения
срока действия. При замене сертификата обновите два `SIGNING_*` secrets.
Команда Apple и bundle ID остаются прежними: апдейтер проверяет их, а не отпечаток
конкретного сертификата. `SIGNING_IDENTITY` позволяет выбрать конкретный SHA-1
при нескольких сертификатах Developer ID одной команды.

Экспортируйте только нужный Developer ID из Keychain Access, не всю связку ключей.
Для передачи `.p12` используйте stdin, чтобы содержимое не попало в аргументы или логи:

```bash
base64 < /private/path/developer-id.p12 | gh secret set SIGNING_P12_BASE64 --repo svetlovmusic/ghbdtn
# gh запросит значение скрытым вводом:
gh secret set SIGNING_P12_PASSWORD --repo svetlovmusic/ghbdtn
```

`tools/ci-signing.sh` импортирует ключ в отдельную временную связку ключей раннера,
проверяет доступ к сервису Apple и удаляет временные файлы. Workflow удаляет
связку ключей даже при ошибке сборки. Обычный CI на pull request не получает
секреты подписи и не выпускает приложение.

## Каждая новая версия

1. Измените `CFBundleShortVersionString` и увеличьте `CFBundleVersion` в
   `Resources/Info.plist`. Добавьте описание версии в `docs/CHANGELOG.md`.
2. Проверьте изменения и отправьте коммит в `main`.
3. Создайте и отправьте новый тег, совпадающий с версией:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

Workflow **Signed release** выполняет:

1. Проверку соответствия тега версии приложения.
2. Загрузку закреплённого Whisper с проверкой SHA-256 и сборку приложения.
3. Подпись Whisper и приложения сертификатом Developer ID с защищённой меткой времени.
4. Проверку команды разработчика, целостности, Hardened Runtime, разрешений и отсутствия следов машины сборки.
5. Нотариализацию приложения, прикрепление и проверку билета Apple.
6. Создание и подпись DMG, его нотариализацию и проверку приложения из смонтированного образа.
7. Регрессионные проверки, сохранение DMG и SHA-256, загрузку файлов в черновик GitHub Release.
8. Публикацию только после успешной загрузки файлов. Уже опубликованный релиз не заменяется.

Ручной запуск **Run workflow** выполняет те же проверки, сохраняет артефакт
в Actions и **не публикует** GitHub Release. Используйте его для первой проверки
настроек до отправки тега. Нотариализация запускается для каждой распространяемой
сборки; ожидание ограничено 20 минутами на отправку. Ошибка или превышение времени
останавливает выпуск. Идентификатор отправки сохраняется в `dist/notarization-*`;
в Actions JSON-диагностика сохраняется отдельным артефактом при ошибке.
При необходимости запросите `notarytool info`/`log` перед повторным запуском.

## Локальный выпуск

Developer ID с закрытым ключом должен быть доступен в Keychain.
Сохраните отдельный профиль нотариализации (секрет вводится интерактивно):

```bash
xcrun notarytool store-credentials ghbdtn-notary --team-id DFB46VG2X3 --apple-id '<Apple Account>'
```

Либо используйте API-ключ:

```bash
xcrun notarytool store-credentials ghbdtn-notary \
  --key /private/path/AuthKey_ID.p8 --key-id '<Key ID>' --issuer '<Issuer ID>'
```

Для индивидуального API-ключа параметр `--issuer` не передаётся.
После этого:

```bash
NOTARY_PROFILE=ghbdtn-notary ./tools/make-dist.sh
./tools/test-release-trust.sh ./ghbdtn.app --notarized
```

Результат: `dist/ghbdtn-X.Y.Z.dmg` и `dist/ghbdtn-X.Y.Z.dmg.sha256`.
Приложение и DMG содержат билеты Apple. `make-dist.sh` не создаёт итоговый DMG,
пока не пройдут все проверки. Не меняйте файлы внутри подписанной сборки.

Для обычной локальной разработки достаточно `./build.sh`. Без сертификата
разработчика создаётся ad-hoc сборка; `make-dist.sh` такую сборку не распространяет.

## Переход со старых версий

У версий до 0.6.2 включительно другая схема подписи и отключена самостоятельная
установка обновлений. Первый релиз Developer ID нужно установить вручную из DMG.
При смене подписи macOS может попросить заново разрешить Универсальный доступ
и Микрофон. Дальнейшие версии устанавливаются через меню приложения после
проверки Developer ID и нотариализации.

Документация: [Apple Developer ID](https://developer.apple.com/developer-id/),
[нотариализация](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[сертификаты в GitHub Actions](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
