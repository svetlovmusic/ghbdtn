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
    /// Tuned by tools/eval_thresholds.py over the full training vocabulary in
    /// both layout directions: the zero-false-positive frontier is at
    /// (0.34, 0.010) for complete words and (0.08, 0.005) for prefixes;
    /// balanced/cautious add safety headroom, aggressive sits on the frontier.
    /// Mid-word (prefix) evaluation uses stricter typed-thresholds because
    /// live mode re-fires on every keystroke.
    func ngramThresholds(completeWord: Bool) -> (minCandidate: Double, maxTyped: Double) {
        switch (self, completeWord) {
        case (.cautious, true):    return (0.55, 0.002)
        case (.cautious, false):   return (0.30, 0.001)
        case (.balanced, true):    return (0.40, 0.005)
        case (.balanced, false):   return (0.20, 0.003)
        case (.aggressive, true):  return (0.34, 0.010)
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

    // MARK: Detection
    @Published var sensitivity: Sensitivity
    @Published var trigger: ConvertTrigger
    /// Bundle identifiers where the auto-switcher is disabled (password fields,
    /// terminals, games, etc.).
    @Published var excludedBundleIDs: [String]

    // MARK: Hotkeys
    @Published var manualConvertHotkey: Hotkey
    @Published var whisperHotkey: Hotkey

    // MARK: Cloud AI
    @Published var aiEnabled: Bool
    @Published var aiBaseURL: String
    @Published var aiModel: String
    /// Only consult the cloud model when the local detector is unsure.
    @Published var aiOnlyWhenUncertain: Bool
    /// Not persisted to defaults — mirrored from Keychain.
    @Published var aiAPIKey: String

    // MARK: Voice (Whisper) — scaffold only
    @Published var voiceEnabled: Bool
    @Published var voiceEngine: String // "local" | "cloud"

    private init() {
        isLoading = true
        // Register sensible defaults on first launch.
        defaults.register(defaults: [
            Keys.autoSwitchEnabled: true,
            Keys.launchAtLogin: false,
            Keys.playSoundOnSwitch: false,
            Keys.showConversionNotifications: true,
            Keys.sensitivity: Sensitivity.balanced.rawValue,
            Keys.trigger: ConvertTrigger.wordBoundary.rawValue,
            Keys.aiEnabled: false,
            Keys.aiBaseURL: "https://api.openai.com/v1",
            Keys.aiModel: "gpt-4o-mini",
            Keys.aiOnlyWhenUncertain: true,
            Keys.voiceEnabled: false,
            Keys.voiceEngine: "local"
        ])

        autoSwitchEnabled = defaults.bool(forKey: Keys.autoSwitchEnabled)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        playSoundOnSwitch = defaults.bool(forKey: Keys.playSoundOnSwitch)
        showConversionNotifications = defaults.bool(forKey: Keys.showConversionNotifications)

        sensitivity = Sensitivity(rawValue: defaults.string(forKey: Keys.sensitivity) ?? "") ?? .balanced
        trigger = ConvertTrigger(rawValue: defaults.string(forKey: Keys.trigger) ?? "") ?? .wordBoundary
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? Settings.defaultExclusions

        manualConvertHotkey = Settings.decodeHotkey(defaults.data(forKey: Keys.manualConvertHotkey))
            ?? Hotkey(keyCode: 0x31, modifiers: UInt32(controlKeyMask | optionKeyMask), enabled: true) // ⌃⌥Space
        whisperHotkey = Settings.decodeHotkey(defaults.data(forKey: Keys.whisperHotkey))
            ?? Hotkey(keyCode: 0x09, modifiers: UInt32(controlKeyMask | optionKeyMask), enabled: false) // ⌃⌥V

        aiEnabled = defaults.bool(forKey: Keys.aiEnabled)
        aiBaseURL = defaults.string(forKey: Keys.aiBaseURL) ?? "https://api.openai.com/v1"
        aiModel = defaults.string(forKey: Keys.aiModel) ?? "gpt-4o-mini"
        aiOnlyWhenUncertain = defaults.bool(forKey: Keys.aiOnlyWhenUncertain)
        aiAPIKey = Keychain.get(account: "ai-api-key") ?? ""

        voiceEnabled = defaults.bool(forKey: Keys.voiceEnabled)
        voiceEngine = defaults.string(forKey: Keys.voiceEngine) ?? "local"

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
        persist($sensitivity) { self.defaults.set($0.rawValue, forKey: Keys.sensitivity) }
        persist($trigger) { self.defaults.set($0.rawValue, forKey: Keys.trigger) }
        persist($excludedBundleIDs) { self.defaults.set($0, forKey: Keys.excludedBundleIDs) }
        persist($manualConvertHotkey) { self.defaults.set(Settings.encodeHotkey($0), forKey: Keys.manualConvertHotkey) }
        persist($whisperHotkey) { self.defaults.set(Settings.encodeHotkey($0), forKey: Keys.whisperHotkey) }
        persist($aiEnabled) { self.defaults.set($0, forKey: Keys.aiEnabled) }
        persist($aiBaseURL) { self.defaults.set($0, forKey: Keys.aiBaseURL) }
        persist($aiModel) { self.defaults.set($0, forKey: Keys.aiModel) }
        persist($aiOnlyWhenUncertain) { self.defaults.set($0, forKey: Keys.aiOnlyWhenUncertain) }
        persist($aiAPIKey) { Keychain.set($0, account: "ai-api-key") }
        persist($voiceEnabled) { self.defaults.set($0, forKey: Keys.voiceEnabled) }
        persist($voiceEngine) { self.defaults.set($0, forKey: Keys.voiceEngine) }
    }

    // MARK: - Helpers

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

    private enum Keys {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let playSoundOnSwitch = "playSoundOnSwitch"
        static let showConversionNotifications = "showConversionNotifications"
        static let sensitivity = "sensitivity"
        static let trigger = "trigger"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let manualConvertHotkey = "manualConvertHotkey"
        static let whisperHotkey = "whisperHotkey"
        static let aiEnabled = "aiEnabled"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
        static let aiOnlyWhenUncertain = "aiOnlyWhenUncertain"
        static let voiceEnabled = "voiceEnabled"
        static let voiceEngine = "voiceEngine"
    }
}

// Carbon modifier constants re-exported for readability where we build Hotkeys.
import Carbon.HIToolbox
let cmdKeyMask = Int(cmdKey)
let optionKeyMask = Int(optionKey)
let controlKeyMask = Int(controlKey)
let shiftKeyMask = Int(shiftKey)
