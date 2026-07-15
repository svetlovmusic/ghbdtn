import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    /// Window content height — computed by AppDelegate: 960pt, capped at 90%
    /// of the screen's visible height so the window always fits.
    var height: CGFloat = 960

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("Общие", systemImage: "gearshape") }
            DetectionTab().tabItem { Label("Детекция", systemImage: "wand.and.stars") }
            DictionaryTab().tabItem { Label("Словарь", systemImage: "character.book.closed") }
            HotkeysTab().tabItem { Label("Хоткеи", systemImage: "command") }
            AITab().tabItem { Label("ИИ-слой", systemImage: "brain") }
            VoiceTab().tabItem { Label("Голос", systemImage: "mic") }
            AboutTab().tabItem { Label("О программе", systemImage: "info.circle") }
        }
        .padding(.top, 6)
        .frame(width: 616, height: height)
    }
}

private extension View {
    /// Pointing-hand cursor on hover — so links feel like links, not buttons.
    func linkCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Версия \(short) (сборка \(build))"
    }
    private static let repoURL = URL(string: "https://github.com/svetlovmusic/ghbdtn")!
    private static let releasesURL = URL(string: "https://github.com/svetlovmusic/ghbdtn/releases")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ghbdtn").font(.title2).bold()
                        Text(versionLine).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                Text("Локальная утилита для macOS: автоматически исправляет текст, набранный не в той раскладке, конвертирует по хоткею, правит целые предложения ИИ-слоем и вставляет надиктованный текст (Whisper). Нажатия анализируются в памяти и никуда не отправляются.")
                    .font(.callout)
            }

            Section("Автор") {
                Text("**svetlovmusic**. Автопереключение раскладки — давняя идея, знакомая по Punto Switcher; это независимая реализация с нуля. Идея объединить в одной локальной утилите голосовой ввод, ручную коррекцию ввода и ИИ-автокоррекцию целых предложений и текста — авторская.")
                    .font(.callout)
                Text("Лицензия MIT — используйте, изменяйте и распространяйте свободно.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Обновления и ссылки") {
                VStack(spacing: 12) {
                    HStack(spacing: 28) {
                        Link("Репозиторий на GitHub", destination: Self.repoURL)
                            .linkCursor()
                        Link("Что нового (релизы)", destination: Self.releasesURL)
                            .linkCursor()
                    }
                    Text("Приложение и так проверяет обновления раз в сутки (отключается в «Общих»); кнопка покажет окно с результатом и предложит обновиться в один клик.")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        UpdateChecker.shared.checkNowInteractive()
                    } label: {
                        Label("Проверить обновления", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.large)
                    .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Toggle("Включить автопереключение раскладки", isOn: $settings.autoSwitchEnabled)
                Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
                Toggle("Проверять обновления автоматически (раз в день)", isOn: $settings.autoCheckUpdates)
            }
            Section("Уведомления") {
                Toggle("Показывать уведомление при конвертации", isOn: $settings.showConversionNotifications)
                Toggle("Звук при переключении", isOn: $settings.playSoundOnSwitch)
            }
            Section {
                PermissionRow()
                MicPermissionRow()
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct PermissionRow: View {
    @State private var trusted = Permissions.hasAccessibility()

    var body: some View {
        HStack {
            Image(systemName: trusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundColor(trusted ? .green : .orange)
            VStack(alignment: .leading) {
                Text("Универсальный доступ")
                Text(trusted ? "Разрешён" : "Требуется для перехвата клавиш")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !trusted {
                Button("Открыть настройки") { Permissions.openAccessibilitySettings() }
            }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            trusted = Permissions.hasAccessibility()
        }
    }
}

/// Microphone permission status + the right action for its state. Used in
/// «Общие» (next to the Accessibility row) and in «Голос» (after the engine
/// block). Needed only for dictation.
private struct MicPermissionRow: View {
    @State private var granted = Permissions.microphoneAuthorized()

    var body: some View {
        HStack {
            Image(systemName: granted == true ? "checkmark.shield.fill"
                    : (granted == false ? "exclamationmark.shield.fill" : "questionmark.circle"))
                .foregroundColor(granted == true ? .green : (granted == false ? .orange : .secondary))
            VStack(alignment: .leading) {
                Text("Доступ к микрофону")
                Text(granted == true ? "Разрешён"
                        : (granted == false ? "Запрещён — диктовка не сможет слышать"
                                            : "Ещё не запрашивался — нужен только для диктовки"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if granted == nil {
                Button("Запросить доступ") {
                    Permissions.requestMicrophone { granted = $0 }
                }
            } else if granted == false {
                Button("Открыть настройки") { Permissions.openMicrophoneSettings() }
            }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            granted = Permissions.microphoneAuthorized()
        }
    }
}

// MARK: - Detection

private struct DetectionTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section("Чувствительность") {
                Picker("Режим", selection: $settings.sensitivity) {
                    ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(sensitivityHint)
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Минимальная длина слова") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(settings.minWordLength) },
                        set: { settings.minWordLength = Int($0.rounded()) }
                    ), in: 2...6, step: 1)
                    Text("\(settings.minWordLength) \(lettersWord(settings.minWordLength))")
                        .monospacedDigit()
                        .frame(width: 66, alignment: .trailing)
                }
                Text("Слова короче автоматически не переключаются — это главный источник ложных срабатываний на коротких словах. Выученные и частотные слова конвертируются всё равно; ручной хоткей длину игнорирует.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Когда переключать") {
                Picker("Триггер", selection: $settings.trigger) {
                    ForEach(ConvertTrigger.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            Section("Не переключать в этих приложениях") {
                ExclusionEditor()
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var sensitivityHint: String {
        switch settings.sensitivity {
        case .cautious: return "Меньше ложных срабатываний, но что-то может пропустить."
        case .balanced: return "Разумный баланс для повседневного набора."
        case .aggressive: return "Ловит почти всё, но иногда может ошибиться."
        }
    }

    /// Russian plural for «буква» after a number (2–4 → буквы, иначе букв).
    private func lettersWord(_ n: Int) -> String {
        switch n {
        case 2, 3, 4: return "буквы"
        default: return "букв"
        }
    }
}

private struct ExclusionEditor: View {
    @EnvironmentObject var settings: Settings
    @State private var newID = ""

    private var trimmedNewID: String { newID.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.excludedBundleIDs.isEmpty {
                Text("Список пуст").font(.caption).foregroundColor(.secondary)
            }
            ForEach(settings.excludedBundleIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    Text(id)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        settings.excludedBundleIDs.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Убрать из исключений")
                }
            }

            Divider()

            // Empty title + prompt keeps the placeholder INSIDE the field —
            // a non-empty TextField title would be pulled out as a leading
            // label by the grouped Form style and break the row.
            HStack(spacing: 8) {
                TextField(text: $newID, prompt: Text("com.example.App")) {
                    Text("Bundle ID")
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(addNew)

                Button("Добавить", action: addNew)
                    .disabled(trimmedNewID.isEmpty)
                Button("Текущее…", action: addFrontmost)
            }
        }
    }

    private func addNew() {
        guard !trimmedNewID.isEmpty, !settings.excludedBundleIDs.contains(trimmedNewID) else { return }
        settings.excludedBundleIDs.append(trimmedNewID)
        newID = ""
    }

    private func addFrontmost() {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !settings.excludedBundleIDs.contains(id) {
            settings.excludedBundleIDs.append(id)
        }
    }
}

// MARK: - Dictionary (learned words)

/// Viewer/editor for the adaptive word memory (LearnedStore): words the engine
/// learned to convert toward (positive) and words the user rejected so they are
/// kept as-typed (negative). Each row also shows the opposite-layout twin, so a
/// stored token like "bcghfdm" reads as "bcghfdm → исправь". Lets the user add,
/// prune, or clear entries.
private struct DictionaryTab: View {
    @State private var positive: [LearnedRowModel] = []
    @State private var negative: [LearnedRowModel] = []
    /// non-nil while a "clear all" confirmation is up; the value is the polarity.
    @State private var clearTarget: Bool?

    var body: some View {
        Form {
            Section {
                Text("Движок запоминает слова из твоих действий: те, что ты вручную дожал хоткеем (их он потом переключает сам), и те, что ты отклонил (их он оставляет как есть). Рядом с каждым словом — как оно выглядит в другой раскладке, чтобы было видно, что во что превращается. Слово действует после \(LearnedStore.activationCount) повторов; добавленное вручную — сразу.")
                    .font(.caption).foregroundColor(.secondary)
            }
            LearnedSection(
                title: "Всегда переключать · выучено",
                rows: positive,
                languages: Self.enabledLanguages,
                emptyText: "Пусто. Дожми слово ручным хоткеем пару раз — или добавь вручную ниже.",
                addPrompt: "слово, к которому переключать",
                onDelete: { remove($0, positive: true) },
                onAdd: { add($0, language: $1, positive: true) },
                onClear: { clearTarget = true }
            )
            LearnedSection(
                title: "Не переключать · отклонено",
                rows: negative,
                languages: Self.enabledLanguages,
                emptyText: "Пусто. Сотри автозамену слова пару раз — или добавь вручную ниже.",
                addPrompt: "слово, которое не трогать",
                onDelete: { remove($0, positive: false) },
                onAdd: { add($0, language: $1, positive: false) },
                onClear: { clearTarget = false }
            )
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: reload)
        .confirmationDialog(
            clearTarget == true
                ? "Очистить список «Всегда переключать»?"
                : "Очистить список «Не переключать»?",
            isPresented: Binding(get: { clearTarget != nil },
                                 set: { if !$0 { clearTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Очистить", role: .destructive) {
                if let polarity = clearTarget { clear(positive: polarity) }
                clearTarget = nil
            }
            Button("Отмена", role: .cancel) { clearTarget = nil }
        }
    }

    /// Distinct primary languages of the enabled layouts (for the add picker).
    private static var enabledLanguages: [String] {
        var seen = Set<String>(), out = [String]()
        for layout in LayoutManager.shared.enabledLayouts() {
            if let lang = layout.primaryLanguage, seen.insert(lang).inserted { out.append(lang) }
        }
        return out.isEmpty ? ["ru", "en"] : out
    }

    private func reload() {
        positive = LanguageScorer.shared.learnedEntries(positive: true).map(LearnedRowModel.init)
        negative = LanguageScorer.shared.learnedEntries(positive: false).map(LearnedRowModel.init)
    }

    private func remove(_ row: LearnedRowModel, positive isPositive: Bool) {
        LanguageScorer.shared.removeLearned(word: row.entry.word, language: row.entry.language, positive: isPositive)
        reload()
    }

    private func add(_ word: String, language: String, positive isPositive: Bool) {
        LanguageScorer.shared.addLearned(word: word, language: language, positive: isPositive)
        reload()
    }

    private func clear(positive isPositive: Bool) {
        LanguageScorer.shared.clearLearned(positive: isPositive)
        reload()
    }
}

/// One editor row: the stored entry plus its precomputed other-layout twin,
/// laid out as набрано → результат. For "отклонённые" the result side is dimmed —
/// it is what the word WOULD become if it weren't kept as-typed.
private struct LearnedRowModel: Identifiable {
    struct Token { let word: String; let lang: String }
    let entry: LearnedStore.Entry
    let left: Token
    let right: Token?
    let rightSuppressed: Bool
    var id: String { entry.id }

    init(_ entry: LearnedStore.Entry) {
        self.entry = entry
        let stored = Token(word: entry.word, lang: entry.language)
        let twin = LanguageScorer.shared.layoutTwin(of: entry.word, language: entry.language)
            .map { Token(word: $0.text, lang: $0.language) }
        if entry.positive {
            // Stored word is the target (real word); the twin is the as-typed side.
            if let twin { left = twin; right = stored } else { left = stored; right = nil }
            rightSuppressed = false
        } else {
            // Stored word is kept as-typed; the twin is the suppressed conversion.
            left = stored; right = twin; rightSuppressed = true
        }
    }
}

private struct LearnedSection: View {
    let title: String
    let rows: [LearnedRowModel]
    let languages: [String]
    let emptyText: String
    let addPrompt: String
    let onDelete: (LearnedRowModel) -> Void
    let onAdd: (String, String) -> Void
    let onClear: () -> Void

    @State private var newWord = ""
    @State private var newLang = ""

    var body: some View {
        Section {
            if rows.isEmpty {
                Text(emptyText).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(rows) { row in
                    LearnedRow(row: row) { onDelete(row) }
                }
            }

            Divider()

            // Empty title + prompt keeps the placeholder inside the field (a
            // non-empty TextField title is pulled out as a leading label by the
            // grouped Form style — same trick as ExclusionEditor).
            HStack(spacing: 8) {
                Picker("", selection: langBinding) {
                    ForEach(languages, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField(text: $newWord, prompt: Text(addPrompt)) { Text("Слово") }
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(commit)
                Button("Добавить", action: commit).disabled(trimmed.isEmpty)
            }

            if !rows.isEmpty {
                HStack {
                    Spacer()
                    Button("Очистить всё", action: onClear).controlSize(.small)
                }
            }
        } header: {
            Text(title)
        }
    }

    private var trimmed: String { newWord.trimmingCharacters(in: .whitespaces) }
    private var langBinding: Binding<String> {
        Binding(get: { newLang.isEmpty ? (languages.first ?? "ru") : newLang },
                set: { newLang = $0 })
    }
    private func commit() {
        let word = trimmed
        guard !word.isEmpty else { return }
        onAdd(word, langBinding.wrappedValue)
        newWord = ""
    }
}

private struct LearnedRow: View {
    let row: LearnedRowModel
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            token(row.left, secondary: false)
            if let right = row.right {
                Image(systemName: "arrow.right")
                    .font(.caption2).foregroundColor(.secondary)
                token(right, secondary: row.rightSuppressed)
            }
            if !row.entry.isActive {
                Text("· учится \(row.entry.count)/\(LearnedStore.activationCount)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("Удалить из словаря")
        }
    }

    private func token(_ t: LearnedRowModel.Token, secondary: Bool) -> some View {
        HStack(spacing: 4) {
            Text(t.lang.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(t.word)
                .textSelection(.enabled)
                .foregroundColor(secondary ? .secondary : .primary)
        }
    }
}

// MARK: - Hotkeys

private struct HotkeysTab: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        Form {
            Section("Ручная конвертация") {
                HStack {
                    Text("Конвертировать выделенное / последнее слово")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.manualConvertHotkey)
                        .frame(width: 160, height: 24)
                }
                Text("Сработает, даже если авто-режим что-то пропустил. Без выделения конвертирует последнее набранное слово.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Голосовой ввод (Whisper)") {
                HStack {
                    Text("Начать / распознать и вставить")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.whisperHotkey)
                        .frame(width: 160, height: 24)
                }
                Text("Первое нажатие показывает панель записи, второе — распознаёт и вставляет текст в позицию курсора.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Text("Отменить диктовку (без вставки)")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.voiceCancelHotkey, allowsBareKeys: true)
                        .frame(width: 160, height: 24)
                }
                Text("Действует только пока идёт запись — вне диктовки клавиша не перехватывается, поэтому можно назначить просто ⎋ Escape.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Коррекция текста (ИИ)") {
                HStack {
                    Text("Исправить выделенное / всё поле")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.correctionHotkey)
                        .frame(width: 160, height: 24)
                }
                Text("Отправляет выделенный текст (или всё содержимое поля, если ничего не выделено) в облачный ИИ-слой и заменяет на месте — один ⌘Z отменяет всю правку. Нужен ключ во вкладке «ИИ-слой». Поля пароля пропускаются.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - AI

private struct AITab: View {
    @EnvironmentObject var settings: Settings

    /// Curated model IDs for the dropdown. "Своя модель…" reveals a text field
    /// so any OpenAI-compatible endpoint (Groq, LM Studio, a newer flagship)
    /// still works — kept short on purpose, these are the sane defaults.
    private let knownModels = ["gpt-4.1-mini", "gpt-4o-mini", "gpt-4.1", "gpt-4o"]
    private let customModelTag = "__custom__"

    // In-app correction probe (no terminal, no config file): paste a mangled
    // line, hit Исправить, see the result — using the key+model entered above.
    @State private var probeInput = "окей, и мне все-таки кажется что ы не оч паравильно вьезжаешщь"
    @State private var probeOutput: String?
    @State private var probeError: String?
    @State private var probeMs: Int?
    @State private var isProbing = false

    private var isCustomModel: Bool { !knownModels.contains(settings.aiModel) }

    var body: some View {
        Form {
            Section {
                Toggle("Подключить облачный ИИ-слой", isOn: $settings.aiEnabled)
                Text("Локальный движок работает без интернета. ИИ подключается только для спорных слов и получает лишь одно слово — не весь текст.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if settings.aiEnabled {
                Section("Провайдер (OpenAI-совместимый)") {
                    TextField("Base URL", text: $settings.aiBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Picker("Модель", selection: modelSelection) {
                        ForEach(knownModels, id: \.self) { Text($0).tag($0) }
                        Text("Своя модель…").tag(customModelTag)
                    }
                    if isCustomModel {
                        TextField("Имя модели", text: $settings.aiModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    SecureField("API-ключ (хранится в Keychain)", text: $settings.aiAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Обращаться к ИИ только когда локальный движок не уверен", isOn: $settings.aiOnlyWhenUncertain)
                }

                Section("Промпт коррекции") {
                    Picker("Автор текста", selection: $settings.correctionAuthorGender) {
                        ForEach(CorrectionAuthorGender.allCases) { g in
                            Text(g.title).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Меняет пункт 7 промпта: в русском прошедшем времени род автора важен («сделал» / «сделала»). Остальной текст не трогается.")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $settings.aiCorrectionPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 130)
                    HStack {
                        Button("Сбросить к стандартному") {
                            settings.aiCorrectionPrompt =
                                Settings.defaultCorrectionPrompt(gender: settings.correctionAuthorGender)
                        }
                        Spacer()
                    }
                    Text("Инструкция для модели — правь как хочешь. Формат ответа (JSON) добавляется автоматически, его трогать не нужно.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("Проверка коррекции текста") {
                    TextField("Кривой текст для проверки", text: $probeInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    HStack {
                        Button {
                            runProbe()
                        } label: {
                            Label(isProbing ? "Проверяю…" : "Исправить", systemImage: "sparkles")
                        }
                        .disabled(isProbing || settings.aiAPIKey.isEmpty || settings.aiModel.isEmpty)
                        if let probeMs {
                            Text("\(probeMs) мс").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    if let probeOutput {
                        Text(probeOutput)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let probeError {
                        Text(probeError).font(.caption).foregroundColor(.red)
                    }
                    Text("Отправляет весь введённый здесь текст провайдеру (не одно слово). Тот же ключ и модель, что выше — так проверяется recovery-коррекция без терминала.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Bridges the dropdown to `aiModel`: a known ID selects itself; the sentinel
    /// clears the field so the revealed text field starts empty for a custom name.
    private var modelSelection: Binding<String> {
        Binding(
            get: { isCustomModel ? customModelTag : settings.aiModel },
            set: { newValue in
                if newValue == customModelTag {
                    if !isCustomModel { settings.aiModel = "" }
                } else {
                    settings.aiModel = newValue
                }
            }
        )
    }

    private func runProbe() {
        isProbing = true
        probeOutput = nil
        probeError = nil
        probeMs = nil
        let provider = OpenAICompatibleProvider(
            baseURL: settings.aiBaseURL,
            apiKey: settings.aiAPIKey,
            model: settings.aiModel
        )
        let input = probeInput
        let started = DispatchTime.now()
        Task {
            do {
                let out = try await provider.correct(input, systemPrompt: settings.aiCorrectionPrompt)
                let ms = Int((Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6).rounded())
                await MainActor.run { probeOutput = out; probeMs = ms; isProbing = false }
            } catch {
                await MainActor.run { probeError = "\(error)"; isProbing = false }
            }
        }
    }
}

// MARK: - Voice

private struct VoiceTab: View {
    @EnvironmentObject var settings: Settings
    @ObservedObject private var downloads = ModelDownloadManager.shared

    /// "Проверить сейчас" result shown inline.
    @State private var testResult: String?
    @State private var testError: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Toggle("Включить голосовой ввод (Whisper)", isOn: $settings.voiceEnabled)
                Text("Поставьте курсор в любое текстовое поле и нажмите хоткей (или пункт «Диктовка» в меню в трее): появится плавающая панель с волной и таймером. ⏹ отменяет, ✓ (или повторный хоткей) распознаёт и вставляет текст.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Панель записи", selection: $settings.whisperHUDPlacement) {
                    Text("Рядом с курсором мыши").tag("mouse")
                    Text("Сверху по центру экрана").tag("top")
                }
                Toggle("Копировать распознанный текст в буфер обмена",
                       isOn: $settings.whisperCopyToClipboard)
                Text("Страховка: если текст не вставился в поле, нажмите ⌘V — он остаётся в буфере. Прежнее содержимое буфера при этом заменяется.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Движок") {
                Picker("Движок Whisper", selection: $settings.voiceEngine) {
                    Text("Локальный (офлайн)").tag("local")
                    Text("Облачный (OpenAI-совместимый)").tag("cloud")
                }
                .pickerStyle(.radioGroup)

                if settings.voiceEngine == "local" {
                    localModelRows
                } else {
                    cloudRows
                }

                Picker("Язык речи", selection: $settings.whisperLanguage) {
                    Text("Авто").tag("auto")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
            }

            Section {
                MicPermissionRow()
                Text("Микрофон нужен только для диктовки: запись начинается по хоткею и распознаётся выбранным движком (локальный — полностью офлайн, звук никуда не уходит). Без доступа панель записи будет молчать.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Проверка") {
                HStack {
                    Button {
                        runTest()
                    } label: {
                        Label(isTesting ? "Идёт запись — нажмите ✓ на панели" : "Проверить сейчас",
                              systemImage: "mic.badge.plus")
                    }
                    .disabled(isTesting)
                    Spacer()
                }
                if let testResult {
                    Text("«\(testResult)»")
                        .textSelection(.enabled)
                    Text("Распозналось плохо? Переключите движок выше и проверьте снова.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let testError {
                    Text(testError).font(.caption).foregroundColor(.red)
                }
                Text("Результат появится здесь, а не в тексте — удобно сравнивать локальный и облачный движки.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Local model management

    @ViewBuilder
    private var localModelRows: some View {
        Picker("Модель", selection: $settings.whisperModel) {
            ForEach(ModelDownloadManager.catalog) { model in
                Text("\(model.title) · \(model.sizeLabel) — \(model.note)").tag(model.id)
            }
        }

        if let info = ModelDownloadManager.info(for: settings.whisperModel) {
            // Re-evaluated after every (un)install: installedRevision is
            // @Published, so its bump re-renders this body.
            let installed = downloads.installedURL(for: info.id) != nil
            HStack {
                if downloads.activeDownloadID == info.id {
                    ProgressView(value: downloads.progress)
                        .frame(maxWidth: 220)
                    Text("\(Int(downloads.progress * 100))%")
                        .font(.caption).monospacedDigit()
                    Button("Отмена") { downloads.cancelDownload() }
                } else if installed {
                    Label("Модель установлена", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Button("Удалить") { downloads.delete(info) }
                } else {
                    Label("Модель не скачана", systemImage: "arrow.down.circle")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Скачать (\(info.sizeLabel))") { downloads.download(info) }
                        .disabled(downloads.activeDownloadID != nil)
                }
            }
            if let error = downloads.lastError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Text("Скачивается с huggingface.co (ggerganov/whisper.cpp) в Application Support, проверяется по SHA-256. Распознавание при этом полностью офлайн.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Cloud engine config

    @ViewBuilder
    private var cloudRows: some View {
        TextField("Base URL", text: $settings.whisperCloudBaseURL)
            .textFieldStyle(.roundedBorder)
        TextField("Модель", text: $settings.whisperCloudModel)
            .textFieldStyle(.roundedBorder)
        SecureField("API-ключ (пусто — ключ ИИ-слоя, если Base URL совпадает с ним)",
                    text: $settings.whisperCloudAPIKey)
            .textFieldStyle(.roundedBorder)
        HStack {
            Text("Пресеты:").font(.caption).foregroundColor(.secondary)
            Button("OpenAI") {
                settings.whisperCloudBaseURL = "https://api.openai.com/v1"
                settings.whisperCloudModel = "gpt-4o-transcribe"
            }
            Button("Groq (дёшево, те же веса)") {
                settings.whisperCloudBaseURL = "https://api.groq.com/openai/v1"
                settings.whisperCloudModel = "whisper-large-v3-turbo"
            }
        }
        .controlSize(.small)
        Text("Внимание: аудио диктовки уходит на сервер провайдера. Ключ хранится в Keychain.")
            .font(.caption).foregroundColor(.secondary)
    }

    // MARK: Test flow

    private func runTest() {
        testResult = nil
        testError = nil
        isTesting = true
        DictationController.shared.beginTest { result in
            isTesting = false
            switch result {
            case .success(let text):
                testResult = text.isEmpty ? "(тишина — ничего не распозналось)" : text
            case .failure(let error) where error is CancellationError:
                break // user hit ⏹ — nothing to report
            case .failure(let error):
                testError = error.localizedDescription
            }
        }
    }
}
