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
                    Text("Начать / остановить диктовку")
                    Spacer()
                    HotkeyRecorder(hotkey: $settings.whisperHotkey)
                        .frame(width: 160, height: 24)
                }
                Text("Задел на будущее — движок Whisper пока не реализован.")
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

    var body: some View {
        Form {
            Section {
                Toggle("Включить голосовой ввод (Whisper)", isOn: $settings.voiceEnabled)
                Text("Раздел-задел. Хоткей и права настраиваются уже сейчас, транскрипция появится позже.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Движок") {
                Picker("Движок Whisper", selection: $settings.voiceEngine) {
                    Text("Локальный (офлайн)").tag("local")
                    Text("Облачный (OpenAI)").tag("cloud")
                }
                .pickerStyle(.radioGroup)
                if settings.voiceEngine == "local" {
                    Text("Модель whisper.cpp / CoreML будет загружаться из Application Support.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Использует тот же API-ключ, что и ИИ-слой (эндпоинт /audio/transcriptions).")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button("Запросить доступ к микрофону") {
                    DictationController.shared.requestMicrophoneAccessIfNeeded()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
