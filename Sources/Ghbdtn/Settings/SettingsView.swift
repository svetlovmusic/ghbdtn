import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("Общие", systemImage: "gearshape") }
            DetectionTab().tabItem { Label("Детекция", systemImage: "wand.and.stars") }
            HotkeysTab().tabItem { Label("Хоткеи", systemImage: "command") }
            AITab().tabItem { Label("ИИ-слой", systemImage: "brain") }
            VoiceTab().tabItem { Label("Голос", systemImage: "mic") }
        }
        .padding(.top, 6)
        .frame(width: 560, height: 526)
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
            }
            Section("Уведомления") {
                Toggle("Показывать уведомление при конвертации", isOn: $settings.showConversionNotifications)
                Toggle("Звук при переключении", isOn: $settings.playSoundOnSwitch)
            }
            Section {
                PermissionRow()
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - AI

private struct AITab: View {
    @EnvironmentObject var settings: Settings

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
                    TextField("Модель", text: $settings.aiModel)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API-ключ (хранится в Keychain)", text: $settings.aiAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Обращаться к ИИ только когда локальный движок не уверен", isOn: $settings.aiOnlyWhenUncertain)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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

            Section {
                Button("Запросить доступ к микрофону") {
                    DictationController.shared.requestMicrophoneAccessIfNeeded()
                }
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
