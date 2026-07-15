import Foundation
import Combine

/// How aggressively the auto-switcher acts on ambiguous words.
enum Sensitivity: String, CaseIterable, Identifiable, Codable {
    case cautious   // only convert when the evidence is overwhelming
    case balanced
    case aggressive // convert on weaker signals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cautious: return "Осторожный"
        case .balanced: return "Сбалансированный"
        case .aggressive: return "Агрессивный"
        }
    }

    /// Minimum lead in bigram-coverage the swapped interpretation must have
    /// over the as-typed one before we auto-convert.
    var coverageMargin: Double {
        switch self {
        case .cautious: return 0.45
        case .balanced: return 0.30
        case .aggressive: return 0.18
        }
    }

    /// Minimum absolute coverage of the swapped interpretation.
    var minTargetCoverage: Double {
        switch self {
        case .cautious: return 0.80
        case .balanced: return 0.70
        case .aggressive: return 0.60
        }
    }

    /// Thresholds for the character 4-gram layer (out-of-vocabulary words:
    /// names, slang, word prefixes). Values are percentiles among real words
    /// of the language (see NgramModel.percentile). Convert only when the
    /// swapped interpretation reads like real text (≥ minCandidate) AND the
    /// as-typed one reads like gibberish (≤ maxTyped).
    ///
    /// Tuned by tools/eval_thresholds.py over the full training vocabulary —
    /// now including the curated domain terms (tools/domain-corpora) mixed into
    /// the model — in both layout directions. With the retrained model the
    /// zero-false-positive frontier is (0.35, 0.030) for complete words and
    /// (0.05, 0.005) for prefixes; balanced/cautious keep headroom, aggressive
    /// sits on the frontier. Prefix thresholds stay stricter than the frontier
    /// allows because live mode re-fires on every keystroke.
    func ngramThresholds(completeWord: Bool) -> (minCandidate: Double, maxTyped: Double) {
        switch (self, completeWord) {
        case (.cautious, true):    return (0.50, 0.003)
        case (.cautious, false):   return (0.30, 0.001)
        case (.balanced, true):    return (0.36, 0.010)
        case (.balanced, false):   return (0.20, 0.003)
        case (.aggressive, true):  return (0.35, 0.020)
        case (.aggressive, false): return (0.10, 0.004)
        }
    }
}

/// When the auto-switcher evaluates a word.
enum ConvertTrigger: String, CaseIterable, Identifiable, Codable {
    case wordBoundary // on space / punctuation / enter (safe default)
    case live         // re-evaluate on every keystroke (snappier, riskier)

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wordBoundary: return "По завершении слова"
        case .live: return "На лету (по каждой клавише)"
        }
    }
}

/// Whose voice the correction prompt assumes for first-person text — swaps
/// rule 7 of the prompt (grammatical gender matters in Russian past tense).
enum CorrectionAuthorGender: String, CaseIterable, Identifiable, Codable {
    case male
    case female

    var id: String { rawValue }
    var title: String {
        switch self {
        case .male: return "Мужчина"
        case .female: return "Женщина"
        }
    }

    /// Rule 7 of the correction prompt for this gender. Kept as exact, known
    /// strings so the gender picker can swap one for the other inside a
    /// user-edited prompt without touching anything else.
    var promptParagraph: String {
        switch self {
        case .male:
            return "7. Автор текста — мужчина. Если текст выглядит написанным от первого лица, используй мужской род: «задолбался», «устал», «пошёл», «сделал». Если в побитом тексте видна женская форма, считай её ошибкой распознавания/набора и исправляй на мужскую, если контекст не указывает на цитату или чужую речь."
        case .female:
            return "7. Автор текста — женщина. Если текст выглядит написанным от первого лица, используй женский род: «задолбалась», «устала», «пошла», «сделала». Если в побитом тексте видна мужская форма, считай её ошибкой распознавания/набора и исправляй на женскую, если контекст не указывает на цитату или чужую речь."
        }
    }
}

/// A user-recordable global shortcut (Carbon keycode + Cocoa modifier mask).
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags (cmdKey, optionKey, ...)
    var enabled: Bool

    static let disabled = Hotkey(keyCode: 0, modifiers: 0, enabled: false)
}

/// Central, observable preferences object. Persisted to `UserDefaults`.
/// The API key is the one exception — it lives in the Keychain.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()
    /// Suppress persistence while we load initial values into @Published props.
    private var isLoading = false

    // MARK: General
    @Published var autoSwitchEnabled: Bool
    @Published var launchAtLogin: Bool
    @Published var playSoundOnSwitch: Bool
    @Published var showConversionNotifications: Bool
    /// Daily check of GitHub Releases for a newer version (UpdateChecker).
    @Published var autoCheckUpdates: Bool

    // MARK: Detection
    @Published var sensitivity: Sensitivity
    @Published var trigger: ConvertTrigger
    /// Auto-conversion floor: words shorter than this (in letters) are left
    /// alone unless the target is a curated/learned word. Cuts short-word false
    /// positives; the manual hotkey ignores it. Range 2…6.
    @Published var minWordLength: Int
    /// Bundle identifiers where the auto-switcher is disabled (password fields,
    /// terminals, games, etc.).
    @Published var excludedBundleIDs: [String]

    // MARK: Hotkeys
    @Published var manualConvertHotkey: Hotkey
    @Published var whisperHotkey: Hotkey
    /// Cancels a live dictation without inserting. May be a bare key (Escape
    /// by default): it is registered only for the duration of a session.
    @Published var voiceCancelHotkey: Hotkey
    /// Runs the on-demand cloud text-correction ("recovery") pass on the current
    /// selection — or the whole focused field if nothing is selected —
    /// replacing it in place (one ⌘Z reverts).
    @Published var correctionHotkey: Hotkey

    // MARK: Cloud AI
    @Published var aiEnabled: Bool
    @Published var aiBaseURL: String
    @Published var aiModel: String
    /// User-editable instructions for the on-demand text-correction ("recovery")
    /// pass. The JSON response contract is appended in code, not here.
    @Published var aiCorrectionPrompt: String
    /// Author gender assumed by the correction prompt (rule 7); changing it
    /// swaps that rule inside `aiCorrectionPrompt` in place.
    @Published var correctionAuthorGender: CorrectionAuthorGender
    /// Only consult the cloud model when the local detector is unsure.
    @Published var aiOnlyWhenUncertain: Bool
    /// Not persisted to defaults — mirrored from Keychain.
    @Published var aiAPIKey: String

    // MARK: Voice (Whisper)
    @Published var voiceEnabled: Bool
    @Published var voiceEngine: String // "local" | "cloud"
    /// GGML model id from ModelDownloadManager.catalog (local engine).
    @Published var whisperModel: String
    /// ISO-639-1 speech language ("ru", "en") or "auto".
    @Published var whisperLanguage: String
    /// Cloud transcription endpoint (OpenAI-compatible /audio/transcriptions).
    @Published var whisperCloudBaseURL: String
    @Published var whisperCloudModel: String
    /// Keychain-backed; empty = fall back to the AI-layer key.
    @Published var whisperCloudAPIKey: String
    /// Where the dictation HUD appears: "mouse" (next to the cursor) | "top".
    @Published var whisperHUDPlacement: String
    /// Leave the transcript on the clipboard after insertion, so a failed
    /// insert is recoverable with ⌘V.
    @Published var whisperCopyToClipboard: Bool

    private init() {
        isLoading = true
        // Register sensible defaults on first launch.
        defaults.register(defaults: [
            Keys.autoSwitchEnabled: true,
            Keys.launchAtLogin: false,
            Keys.playSoundOnSwitch: false,
            // Off by default: a conversion notification shows the corrected
            // word itself, which would otherwise land on the lock screen and
            // in Notification Center. Opt in via «Общие».
            Keys.showConversionNotifications: false,
            Keys.autoCheckUpdates: true,
            Keys.sensitivity: Sensitivity.balanced.rawValue,
            Keys.trigger: ConvertTrigger.wordBoundary.rawValue,
            Keys.minWordLength: 4,
            Keys.aiEnabled: false,
            Keys.aiBaseURL: "https://api.openai.com/v1",
            Keys.aiModel: "gpt-4.1-mini",
            Keys.aiCorrectionPrompt: Settings.defaultCorrectionPrompt,
            Keys.correctionAuthorGender: CorrectionAuthorGender.male.rawValue,
            Keys.aiOnlyWhenUncertain: true,
            Keys.voiceEnabled: false,
            Keys.voiceEngine: "local",
            Keys.whisperModel: "large-v3-turbo-q5_0",
            Keys.whisperLanguage: "auto",
            Keys.whisperCloudBaseURL: "https://api.openai.com/v1",
            Keys.whisperCloudModel: "gpt-4o-transcribe",
            Keys.whisperHUDPlacement: "mouse",
            Keys.whisperCopyToClipboard: true
        ])

        autoSwitchEnabled = defaults.bool(forKey: Keys.autoSwitchEnabled)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        playSoundOnSwitch = defaults.bool(forKey: Keys.playSoundOnSwitch)
        showConversionNotifications = defaults.bool(forKey: Keys.showConversionNotifications)
        autoCheckUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)

        sensitivity = Sensitivity(rawValue: defaults.string(forKey: Keys.sensitivity) ?? "") ?? .balanced
        trigger = ConvertTrigger(rawValue: defaults.string(forKey: Keys.trigger) ?? "") ?? .wordBoundary
        minWordLength = max(2, defaults.integer(forKey: Keys.minWordLength))
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? Settings.defaultExclusions

        manualConvertHotkey = Settings.decodeHotkey(defaults.data(forKey: Keys.manualConvertHotkey))
            ?? Hotkey(keyCode: 0x24, modifiers: UInt32(cmdKeyMask | optionKeyMask), enabled: true) // ⌥⌘⏎
        whisperHotkey = Settings.decodeHotkey(defaults.data(forKey: Keys.whisperHotkey))
            ?? Hotkey(keyCode: 0x24, modifiers: UInt32(shiftKeyMask), enabled: true) // ⇧⏎
        voiceCancelHotkey = Settings.decodeHotkey(defaults.data(forKey: Keys.voiceCancelHotkey))
            ?? Hotkey(keyCode: 0x35, modifiers: 0, enabled: true) // ⎋ Escape
        correctionHotkey = Settings.decodeHotkey(defaults.data(forKey: Keys.correctionHotkey))
            ?? Hotkey(keyCode: 0x24, modifiers: UInt32(shiftKeyMask | cmdKeyMask), enabled: true) // ⇧⌘⏎

        aiEnabled = defaults.bool(forKey: Keys.aiEnabled)
        aiBaseURL = defaults.string(forKey: Keys.aiBaseURL) ?? "https://api.openai.com/v1"
        aiModel = defaults.string(forKey: Keys.aiModel) ?? "gpt-4.1-mini"
        aiCorrectionPrompt = defaults.string(forKey: Keys.aiCorrectionPrompt) ?? Settings.defaultCorrectionPrompt
        correctionAuthorGender = CorrectionAuthorGender(
            rawValue: defaults.string(forKey: Keys.correctionAuthorGender) ?? "") ?? .male
        aiOnlyWhenUncertain = defaults.bool(forKey: Keys.aiOnlyWhenUncertain)
        aiAPIKey = Keychain.get(account: "ai-api-key") ?? ""

        voiceEnabled = defaults.bool(forKey: Keys.voiceEnabled)
        voiceEngine = defaults.string(forKey: Keys.voiceEngine) ?? "local"
        whisperModel = defaults.string(forKey: Keys.whisperModel) ?? "large-v3-turbo-q5_0"
        whisperLanguage = defaults.string(forKey: Keys.whisperLanguage) ?? "auto"
        whisperCloudBaseURL = defaults.string(forKey: Keys.whisperCloudBaseURL) ?? "https://api.openai.com/v1"
        whisperCloudModel = defaults.string(forKey: Keys.whisperCloudModel) ?? "gpt-4o-transcribe"
        whisperCloudAPIKey = Keychain.get(account: "whisper-api-key") ?? ""
        whisperHUDPlacement = defaults.string(forKey: Keys.whisperHUDPlacement) ?? "mouse"
        whisperCopyToClipboard = defaults.bool(forKey: Keys.whisperCopyToClipboard)

        isLoading = false
        wireUp()
    }

    /// Persist each published property back to its store on change.
    private func wireUp() {
        func persist<T>(_ publisher: Published<T>.Publisher, _ apply: @escaping (T) -> Void) {
            publisher
                .dropFirst() // ignore the initial synchronous value
                .sink { [weak self] value in
                    guard let self, !self.isLoading else { return }
                    apply(value)
                }
                .store(in: &cancellables)
        }

        persist($autoSwitchEnabled) { self.defaults.set($0, forKey: Keys.autoSwitchEnabled) }
        persist($launchAtLogin) { self.defaults.set($0, forKey: Keys.launchAtLogin) }
        persist($playSoundOnSwitch) { self.defaults.set($0, forKey: Keys.playSoundOnSwitch) }
        persist($showConversionNotifications) { self.defaults.set($0, forKey: Keys.showConversionNotifications) }
        persist($autoCheckUpdates) { self.defaults.set($0, forKey: Keys.autoCheckUpdates) }
        persist($sensitivity) { self.defaults.set($0.rawValue, forKey: Keys.sensitivity) }
        persist($trigger) { self.defaults.set($0.rawValue, forKey: Keys.trigger) }
        persist($minWordLength) { self.defaults.set($0, forKey: Keys.minWordLength) }
        persist($excludedBundleIDs) { self.defaults.set($0, forKey: Keys.excludedBundleIDs) }
        persist($manualConvertHotkey) { self.defaults.set(Settings.encodeHotkey($0), forKey: Keys.manualConvertHotkey) }
        persist($whisperHotkey) { self.defaults.set(Settings.encodeHotkey($0), forKey: Keys.whisperHotkey) }
        persist($voiceCancelHotkey) { self.defaults.set(Settings.encodeHotkey($0), forKey: Keys.voiceCancelHotkey) }
        persist($correctionHotkey) { self.defaults.set(Settings.encodeHotkey($0), forKey: Keys.correctionHotkey) }
        persist($aiEnabled) { self.defaults.set($0, forKey: Keys.aiEnabled) }
        persist($aiBaseURL) { self.defaults.set($0, forKey: Keys.aiBaseURL) }
        persist($aiModel) { self.defaults.set($0, forKey: Keys.aiModel) }
        persist($aiCorrectionPrompt) { self.defaults.set($0, forKey: Keys.aiCorrectionPrompt) }
        persist($correctionAuthorGender) {
            self.defaults.set($0.rawValue, forKey: Keys.correctionAuthorGender)
            self.applyCorrectionGender($0)
        }
        persist($aiOnlyWhenUncertain) { self.defaults.set($0, forKey: Keys.aiOnlyWhenUncertain) }
        persist($aiAPIKey) { Keychain.set($0, account: "ai-api-key") }
        persist($voiceEnabled) { self.defaults.set($0, forKey: Keys.voiceEnabled) }
        persist($voiceEngine) { self.defaults.set($0, forKey: Keys.voiceEngine) }
        persist($whisperModel) { self.defaults.set($0, forKey: Keys.whisperModel) }
        persist($whisperLanguage) { self.defaults.set($0, forKey: Keys.whisperLanguage) }
        persist($whisperCloudBaseURL) { self.defaults.set($0, forKey: Keys.whisperCloudBaseURL) }
        persist($whisperCloudModel) { self.defaults.set($0, forKey: Keys.whisperCloudModel) }
        persist($whisperCloudAPIKey) { Keychain.set($0, account: "whisper-api-key") }
        persist($whisperHUDPlacement) { self.defaults.set($0, forKey: Keys.whisperHUDPlacement) }
        persist($whisperCopyToClipboard) { self.defaults.set($0, forKey: Keys.whisperCopyToClipboard) }
    }

    // MARK: - Helpers

    /// Swap rule 7 of the correction prompt to the chosen gender's variant.
    /// Only the two known paragraphs are recognized — a fully rewritten custom
    /// prompt is left untouched (the stored choice still drives «Сбросить к
    /// стандартному»).
    private func applyCorrectionGender(_ gender: CorrectionAuthorGender) {
        let other: CorrectionAuthorGender = gender == .male ? .female : .male
        guard aiCorrectionPrompt.contains(other.promptParagraph) else { return }
        aiCorrectionPrompt = aiCorrectionPrompt.replacingOccurrences(
            of: other.promptParagraph, with: gender.promptParagraph)
    }

    private static func encodeHotkey(_ hk: Hotkey) -> Data {
        (try? JSONEncoder().encode(hk)) ?? Data()
    }

    private static func decodeHotkey(_ data: Data?) -> Hotkey? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    static let defaultExclusions = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.keychainaccess"
    ]

    /// Default, user-editable instructions for the correction pass. Edit in
    /// Settings → «ИИ-слой» → «Промпт коррекции»; «Сбросить к стандартному»
    /// restores this text (with the currently selected author gender in
    /// rule 7 — see CorrectionAuthorGender).
    static func defaultCorrectionPrompt(gender: CorrectionAuthorGender) -> String {
        """
        Ты аккуратно исправляешь русский и смешанный русско-английский текст, набранный небрежно.

        На входе может быть сильная «каша»: опечатки, переставленные/задвоенные/пропущенные буквы, неправильная раскладка, лишние или пропущенные пробелы, слипшиеся или разорванные слова, пропущенные заглавные буквы и знаки препинания.

        Задача: восстановить наиболее вероятный исходный текст, который человек хотел написать, правильным и естественным русским языком.

        Правила:

        1. Исправляй механику текста:
           — опечатки;
           — пропущенные, лишние и переставленные буквы;
           — слипшиеся и разорванные слова;
           — неправильную раскладку;
           — пунктуацию и заглавные буквы.

        2. Не меняй смысл, стиль и степень грубости/разговорности. Не делай текст более вежливым, литературным или нейтральным.

        3. Разрешено восстанавливать пропущенные буквы, пробелы и очевидные части слов, если без них фраза получается неестественной или грамматически кривой.

        4. Не добавляй новые смысловые слова. Но если слово явно восстановлено из побитого фрагмента, это не считается добавлением.

        5. При выборе между несколькими вариантами выбирай тот, который:
           — грамматически естественнее;
           — чаще встречается в живой русской речи;
           — лучше соответствует контексту;
           — требует минимального изменения смысла, а не минимального количества символов.

        6. Не выбирай буквальный вариант, если он грамматически хуже. Например, если фрагмент можно прочитать как «я как задолбался» или «я так задолбался», выбирай «я так задолбался», потому что это естественная русская конструкция.

        \(gender.promptParagraph)

        8. Уже правильный текст оставляй без изменений.

        9. Сохраняй сленг, мат, имена, термины, числа, эмодзи и переносы строк.

        10. Если фраза неоднозначна, выбери наиболее вероятное прочтение. Не выводи объяснения, варианты или комментарии — только исправленный текст.
        """
    }

    static let defaultCorrectionPrompt = defaultCorrectionPrompt(gender: .male)

    private enum Keys {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let playSoundOnSwitch = "playSoundOnSwitch"
        static let showConversionNotifications = "showConversionNotifications"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let sensitivity = "sensitivity"
        static let trigger = "trigger"
        static let minWordLength = "minWordLength"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let manualConvertHotkey = "manualConvertHotkey"
        static let whisperHotkey = "whisperHotkey"
        static let voiceCancelHotkey = "voiceCancelHotkey"
        static let correctionHotkey = "correctionHotkey"
        static let aiEnabled = "aiEnabled"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
        static let aiCorrectionPrompt = "aiCorrectionPrompt"
        static let correctionAuthorGender = "correctionAuthorGender"
        static let aiOnlyWhenUncertain = "aiOnlyWhenUncertain"
        static let voiceEnabled = "voiceEnabled"
        static let voiceEngine = "voiceEngine"
        static let whisperModel = "whisperModel"
        static let whisperLanguage = "whisperLanguage"
        static let whisperCloudBaseURL = "whisperCloudBaseURL"
        static let whisperCloudModel = "whisperCloudModel"
        static let whisperHUDPlacement = "whisperHUDPlacement"
        static let whisperCopyToClipboard = "whisperCopyToClipboard"
    }
}

// Carbon modifier constants re-exported for readability where we build Hotkeys.
import Carbon.HIToolbox
let cmdKeyMask = Int(cmdKey)
let optionKeyMask = Int(optionKey)
let controlKeyMask = Int(controlKey)
let shiftKeyMask = Int(shiftKey)
