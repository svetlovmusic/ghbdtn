# Порт ghbdtn на Windows — план

> Статус: **план на будущее.** Порт начинаем после нескольких апдейтов macOS-версии.
> Отслеживание: см. связанный GitHub issue.
> Исходник на момент составления: **v0.3.2** (Swift, ~6.5k LOC).

Переключатель раскладки, диктовка и AI-коррекция — целиком на Windows. Паритет достижим: «мозг» приложения (детекция раскладки) переносится дословно, платформенный слой замещается штатными Win32/.NET-эквивалентами.

Документ составлен на основе инвентаризации 49 компонентов исходника и веб-разведки Windows-эквивалентов (перехват ввода, спелчек, whisper, дистрибуция, prior art).

---

## Вердикт

**Порт реалистичен для одного разработчика.** Рекомендованный стек: **C#/.NET 10 + Avalonia** (или WPF), прямой P/Invoke `SetWindowsHookEx(WH_KEYBOARD_LL)` + `SendInput`, ядро переписывается на C#, **Whisper.net** с теми же ggml-моделями, установщик Inno Setup + автообновление Velopack + winget.

Главная оговорка честности: **это не 1:1-паритет.** Четыре вещи на Windows принципиально слабее, чем на macOS (правка текста в admin-окнах, смена раскладки чужого приложения, secure desktop, детекция полей пароля). Их надо принять как известные ограничения — см. раздел «Дивергенции».

---

## 1. Что переносится «как есть», а что переписать

Ключевая хорошая новость: детекция раскладки — чистая логика без единого вызова ОС. Она переносится дословно и **обязана** вести себя бит-в-бит, иначе регрессируют golden-тесты (`SelfTest.swift`).

| Доля | Категория | Что входит |
|---|---|---|
| **~40%** | Чистая логика (порт дословно) | Decider, NgramModel, WordBuffer, LearnedStore, ядро Scorer, оркестрация Engine, cloud-провайдеры |
| **~35%** | Нужен эквивалент (1:1-замена API) | Хук, инъекция, раскладки, спелчек, захват звука, whisper, хоткеи, секреты, автозапуск |
| **~25%** | Переосмыслить | Меню-бар → трей, SwiftUI-окна → Avalonia/WPF, HUD-оверлеи, разрешения, сборка/подпись/дистрибуция |

### Покомпонентно

| Компонент | Статус | Что делать на Windows | LOC |
|---|---|---|---:|
| **Decider** (brain) | 🟢 дословно | Только логика. Веса `rank()`, source-vouch-вето, порог 0.002 — без изменений. | 273 |
| **NgramModel** | 🟢 дословно | Парсер формата `GNG1` — little-endian (Windows тоже LE). Байты `.bin` грузятся без конверсии. | 272 |
| **LanguageScorer** | 🟡 эквивалент | Ядро (курир. списки, скрипт-детекция, чистка токенов) — дословно; заменить только `NSSpellChecker`. | 431 |
| **WordBuffer / LearnedStore** | 🟢 дословно | Foundation-only. Сохранить TTL+cap вето (20 мин / 500) — иначе «деградация за сутки». | 259 |
| **AutoSwitchEngine** | 🟡 эквивалент | ~85% оркестрации дословно (`editGeneration`-счётчик критичен). Заменить: фронт-апп, звук, publisher. | 417 |
| **EventTap** | 🔴 переосмыслить | `CGEventTap` → `WH_KEYBOARD_LL`. Самая сложная поверхность порта. | 157 |
| **TextInjector** | 🔴 переосмыслить | → `SendInput` (`KEYEVENTF_UNICODE` + `VK_BACK`). 2-я по сложности. | 273 |
| **KeyTranslator** | 🟡 эквивалент | `UCKeyTranslate` → `ToUnicodeEx` (флаг 0x04!). Предпосчёт VK→char при старте. | 131 |
| **LayoutManager** | 🟡 эквивалент | TIS → `GetKeyboardLayout(tid)` фронт-треда. Раскладка на Windows — per-thread, не сессионная. | 135 |
| **Voice** (Local/Cloud/Capture) | 🟡 эквивалент | → Whisper.net + NAudio WASAPI. Модели, каталог, SHA-пины — переиспользуются 1:1. | 460 |
| **AI-слои** (Consult/Corrector/Provider) | 🟢 дословно | Промпты и JSON-контракт дословно; заменить только `URLSession` → `HttpClient`. | 249 |
| **HUD-оверлеи** (Dictation/Recovery) | 🔴 переосмыслить | NSPanel non-activating → WPF layered-окно `WS_EX_NOACTIVATE\|TRANSPARENT\|TOPMOST`. | 326 |
| **Оболочка** (AppDelegate/Settings-UI) | 🔴 переосмыслить | Меню-бар → трей (H.NotifyIcon), 5 вкладок настроек — перерисовать, архитектура переносится. | ~1300 |
| **Keychain / LoginItem / Notifier** | 🟡 эквивалент | Credential Manager · `HKCU\…\Run` · тосты через AUMID-ярлык. | 114 |
| **SelfTest** (golden-тесты) | 🟡 эквивалент | → xUnit. Семантика пар слов 1:1; пересобрать VK/scancode-таблицу — это **гейт корректности**. | 408 |

**Переиспользуемые ассеты (байт-в-байт):** `ngram-en.bin` (457 782 B), `ngram-ru.bin` (522 607 B), `ngram-uk.bin` (497 323 B) — формат `GNG1`, little-endian; `seed-learned.json`. Ggml-модели whisper (`ggml-large-v3-turbo-q5_0.bin` и др.) с теми же HuggingFace-URL и SHA-256 — без переконвертации.

---

## 2. Рекомендованный стек

Оптимизировано под solo-dev / open-source: максимум готовых библиотек, минимум налога на тулчейн.

| Область | Выбор | Почему / анти-совет |
|---|---|---|
| Язык / рантайм | **C# / .NET 10** (LTS) | Лучшее покрытие библиотек для трея и хуков; один тулчейн и отладчик. |
| UI | **Avalonia** · или WPF | Встроенный TrayIcon, NativeAOT (нет JIT-пауз в колбэке), ARM64. WPF — если важнее готовые ответы и скорость. **✕ WinUI 3 unpackaged.** |
| Ввод | **P/Invoke** LL-хук + SendInput | ~50 строк, полный контроль. Колбэк = только enqueue, всё тяжёлое — на воркер. |
| Ядро логики | переписать на **C#** | Парсинг байт-формата + поиск по спискам — механический порт. **✕ Swift-on-Windows мост (`@_cdecl` ломается с Foundation).** |
| Спелчек | **Hunspell** + ISpellChecker | WeCantSpell.Hunspell (en/ru/uk) как гарантир. база; ISpellChecker — когда язык установлен. |
| Диктовка | **Whisper.net** + NAudio | Те же ggml `.bin`, тот же каталог и SHA-пины. CPU-рантайм всегда, GPU (CUDA/Vulkan) — опционально. |
| Секреты | **Credential Manager** | Ближайший аналог Keychain. Или DPAPI. Ключ никогда не в plaintext-настройках. |
| Установщик | **Inno Setup** | Полный доступ к реестру/автозапуску, тихая установка (нужно winget). **✕ MSIX для always-on трея.** |
| Обновления | **Velopack** + winget | Delta-обновления прямо из GitHub Releases; winget — бесплатный сигнал доверия и находимость. |
| Подпись | **Azure Trusted Signing** | ~$10/мес, без токена — если доступно. **✕ EV ради SmartScreen** (EV больше не даёт мгновенный обход). |

**Оговорка по подписи:** individual-тариф Azure Trusted Signing в превью открыт только для US/Canada. Из другой юрисдикции — дешёвый OV-сертификат на токене (~$130–200/год) или сначала unsigned + набор репутации через winget и объём загрузок.

---

## 3. Архитектура: модель из трёх потоков

Конвейер macOS (`CGEventTap → WordBuffer → Decider → TextInjector`) раскладывается на Windows по потокам так, чтобы **ни один тяжёлый вызов не попал в колбэк хука**:

| Поток | Роль | Обязанности |
|---|---|---|
| **T1 · HOOK** | Хук-тред | message loop + `WH_KEYBOARD_LL`; фильтр своих событий (`LLKHF_INJECTED` + magic `dwExtraInfo`); только enqueue нажатия; мгновенный `CallNextHookEx`. |
| **T2 · WORKER** | Решатель | Decider + n-gram + LearnedStore; спелчек (Hunspell/ISpellChecker); готовит команды коррекции → инъекция через SendInput. |
| **T3 · STATE (MTA)** | UIA / состояние | `EVENT_SYSTEM_FOREGROUND` → exe + HKL; focus-changed → флаг «пароль»; публикует кэш, T2 читает. **UIA никогда из хука.** |

**Почему это критично.** Колбэк `WH_KEYBOARD_LL` обязан вернуться за `LowLevelHooksTimeout` (≈1000 мс, Win10 1709+). Медленный колбэк Windows **молча снимает хук** — хуже, чем на macOS: там был таймаут-и-восстановление, тут хук умирает до рестарта приложения. Это ровно тот же класс бага, что уже задокументирован на Mac (синхронный спелчек на потоке EventTap ронял клавиши). Дополнительные враги на .NET — GC-пауза и первый JIT колбэка: лечится enqueue-only, pinned delegate и NativeAOT.

---

## 4. Карта API: macOS → Windows

| Задача | macOS | Windows |
|---|---|---|
| Перехват клавиш | `CGEventTap` (listen-only) | `WH_KEYBOARD_LL` |
| Инъекция текста | `keyboardSetUnicodeString` | `SendInput` · `KEYEVENTF_UNICODE` |
| Фильтр своих событий | `eventSourceUserData` magic | `LLKHF_INJECTED` + `dwExtraInfo` |
| Клавиша → символ раскладки | `UCKeyTranslate` | `ToUnicodeEx` (флаг 0x04) |
| Текущая раскладка | `TISCopyCurrentKeyboard…` | `GetKeyboardLayout(tid)` |
| Сменить раскладку | `TISSelectInputSource` | `WM_INPUTLANGCHANGEREQUEST` * |
| Поле пароля | `IsSecureEventInputEnabled` | UIA `IsPasswordProperty` * |
| Фронт-приложение | `NSWorkspace.frontmost…` | `GetForegroundWindow` + PID |
| Глобальные хоткеи | `RegisterEventHotKey` | `RegisterHotKey` / `WM_HOTKEY` |
| Спелчек | `NSSpellChecker` | Hunspell + ISpellChecker |
| Локальный whisper | `whisper.xcframework` (Metal) | Whisper.net (CUDA/Vulkan/CPU) |
| Захват микрофона | `AVAudioEngine` | NAudio WASAPI + WDL-ресемпл |
| Ключ API | Keychain (Security.fw) | Credential Manager / DPAPI |
| Меню-бар | `NSStatusItem` | Трей · H.NotifyIcon |
| Автозапуск | `SMAppService` | `HKCU\…\Run` |
| Уведомления | `UNUserNotificationCenter` | Toast (AUMID-ярлык) |

\* — best-effort: работает не во всех целевых приложениях (см. дивергенции).

---

## 5. Честные дивергенции от паритета

У этих пяти пунктов нет чистого Windows-аналога. Их нужно спроектировать как известные ограничения — а не выдавать за паритет.

- **Правка текста в elevated-окнах** — 🔴 *жёсткая потеря.* UIPI не даёт Medium-IL приложению инжектить в admin-окна (admin Notepad, elevated-терминалы, часть игр). Отказ молчаливый — даже `GetLastError` не сообщает. На macOS грант Accessibility такой стены не знает.
  **Решение:** детектить integrity level цели (`GetTokenInformation`), тихо пропускать; opt-in `uiAccess=true` (подпись + Program Files) — позже.

- **Смена раскладки чужого приложения** — 🟡 *best-effort.* `WM_INPUTLANGCHANGEREQUEST` — это запрос, и его игнорят ровно те цели, что важны: консоль/conhost, UWP/Store, диалоги «Открыть файл».
  **Решение:** текст гарантируем через `KEYEVENTF_UNICODE` (не зависит от раскладки); флип раскладки — как получится. Проверять HKL после и, где отказано, корректировать пословно.

- **Поля пароля** — 🟡 *приближение.* Нет глобального secure-input-события. UIA `IsPasswordProperty` — кросс-процессный и медленный, нельзя звать из хука.
  **Решение:** один async focus-changed-обработчик на MTA-потоке, кэш-флаг; при смене фокуса и до ответа UIA — стоять смирно (unknown трактовать как пароль).

- **Антивирус / анти-чит** — 🟡 *репутация.* Глобальный клавиатурный хук триггерит keylogger-эвристику AV; swallow-хук может пометить анти-чит в соревновательных играх.
  **Решение:** Authenticode-подпись; **не писать нажатия на диск**; open-source; заявки вендорам AV на whitelist; listen-only хук (всегда `CallNextHookEx`), кроме краткого окна ретайпа.

- **Secure desktop** — 🔴 *непрозрачен.* UAC-промпт, Ctrl+Alt+Del, экран входа идут на отдельном изолированном десктопе — нажатия там невидимы (аналогично macOS, но упомянуть).
  **Решение:** принять как есть; на secure desktop приложение просто неактивно.

---

## 6. Prior art — на кого смотреть

- **dotSwitcher, Mahou** (open-source) — используют ровно связку LL-хук + SendInput, что и рекомендуется здесь. Лучший референс архитектуры и того, как они обходят anti-cheat/AV-претензии.
- **Punto Switcher** (Yandex) — закрытый, эталон категории; частые жалобы на Win11 и телеметрию. Показывает, чего пользователи *не* хотят.
- **Caramba Switcher** — преемник от авторов Punto: «умнее без пользовательских словарей». Контраст к нашему подходу с курируемыми списками + n-gram.

---

## 7. Роадмап — вертикальными срезами

- [ ] **Фаза 0 · Ядро.** Переписать Decider / NgramModel / Scorer / LearnedStore на C#. Портировать `SelfTest` в xUnit. Пересобрать VK/scancode-таблицу входа.
  *Выход: зелёные golden-тесты на тех же парах слов.*
- [ ] **Фаза 1 · Автопереключатель.** 3-поточная модель, `WH_KEYBOARD_LL`, `SendInput`, best-effort флип раскладки. Первый рабочий срез «ghbdtn → привет».
  *Выход: конверсия работает в Notepad/браузере/Word.*
- [ ] **Фаза 2 · Контекст.** Hunspell-база + ISpellChecker, UIA-детекция пароля и фронт-exe, per-app исключения — всё вне потока хука.
  *Выход: паритет детекции + защита полей пароля.*
- [ ] **Фаза 3 · Голос.** Самый автономный срез, ассеты 100% переиспользуемы. Whisper.net + NAudio + WPF-HUD + общий хук для PTT.
  *Выход: локальная и облачная диктовка.*
- [ ] **Фаза 4 · AI-слои.** AIConsult-вето и recovery-хоткей. Промпты/JSON дословно, транспорт → HttpClient, `editGeneration`-гард сохранить.
  *Выход: паритет AI-слоёв.*
- [ ] **Фаза 5 · Оболочка.** Трей + 5 вкладок настроек, автозапуск, Credential Manager, Inno Setup + Velopack + winget, Authenticode.
  *Выход: устанавливаемый подписанный релиз.*

---

## 8. Открытые решения (рекомендованные дефолты)

| Развилка | Рекомендованный дефолт |
|---|---|
| Блокирующий хук vs listen-only | Listen-only, всегда `CallNextHookEx`; swallow только на краткое окно backspace+ретайп (иначе anti-cheat-флаги). |
| MSIX vs unpackaged | Unpackaged (Inno Setup). Заблокированный микрофон детектить и вести в `ms-settings:privacy-microphone`. |
| UI-тулкит vs HUD-латентность | Решать вместе: если NativeAOT ради anti-JIT — то Avalonia; click-through HUD на layered-окне проверить на Avalonia, иначе отдельное WPF-окно под HUD. |
| Хранилище моделей | `%LOCALAPPDATA%\Ghbdtn\Models` — 574 МБ не должны попасть в роуминг `%APPDATA%`. |
| Миграция настроек | Версионированный JSON + функция миграции; хоткеи перекодировать из Carbon-кодов в VK. |
| Порог AI-гейта по чувствительности | Оставить фикс-константу 0.002 (как в свежем фиксе), не привязывать к sensitivity. |
| Синк выученных слов | PowerShell-аналог `save-learned.sh` + флаг `--clean` сборки. Схема `seed-learned.json` портируется дословно. |

---

## 9. Реестр рисков

| Риск | Класс | Митигация |
|---|---|---|
| Молчаливое снятие хука по таймауту | 🔴 высокий | enqueue-only колбэк, NativeAOT, pinned delegate, watchdog-переустановка хука. |
| AV/анти-чит помечают хук как keylogger | 🔴 высокий | подпись, не логировать нажатия на диск, open-source, заявки на whitelist. |
| Дрейф поведения детекции при переписывании | 🟡 средний | golden-тесты как гейт; пересборка VK-таблицы — отдельная проверка корректности, не механика. |
| Юрисдикция подписи (Azure only US/CA) | 🟡 средний | fallback на OV-токен-сертификат или unsigned + winget-репутация. |
| `ToUnicodeEx` портит dead-key-состояние | 🟡 средний | флаг 0x04 (Win10 1607+), предпосчёт VK→char таблицы при старте. |
| ru/uk словари ISpellChecker отсутствуют | 🟡 средний | Hunspell как гарантированная база (внимание: uk_UA — только MPL-1.1 пакет, не CC-BY-NC-SA данные). |
| Whisper без GPU медленный на turbo | 🟢 низкий | детект железа: GPU-рантайм опционально, иначе дефолт на модель поменьше. |

---

## Первый шаг

**Фаза 0** — каркас C#-решения с портом `Decider` и golden-тестами (`SelfTest.swift` → xUnit). Начинаем после того, как macOS-версия дойдёт до стабильного плато.

---

<sub>Один пробел разведки — детальный prior-art — был заблокирован cyber-фильтром модели и закрыт из общих знаний. Оценки процентов и трудозатрат прикидочные (из инвентаризации компонентов), это план, а не смета.</sub>
