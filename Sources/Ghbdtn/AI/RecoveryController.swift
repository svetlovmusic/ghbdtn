import Foundation
import AppKit
import Carbon
import CoreGraphics

/// On-demand text "recovery": a global hotkey that sends the current selection
/// — or the whole focused field, if nothing is selected — through the cloud
/// corrector and pastes the fix back in place, so a single ⌘Z reverts it.
///
/// Design notes:
/// - Capture/replace goes through TextInjector's clipboard round-trip; the app
///   has no Accessibility text API, and a single ⌘V paste is what makes one ⌘Z
///   undo the whole change.
/// - Async safety mirrors the AI layout consult (AIConsult): snapshot
///   AutoSwitchEngine.editGeneration before the network round-trip and refuse to
///   paste if the user moved the caret meanwhile.
/// - Progress and errors are shown in RecoveryHUD (a non-activating overlay).
/// - Guards: never runs on a password field (secure input) or an excluded app,
///   so field contents are never captured or sent to the cloud.
@MainActor
final class RecoveryController {
    static let shared = RecoveryController()

    private let engine = AutoSwitchEngine.shared
    private let settings = Settings.shared
    private var inFlight = false

    private init() {}

    /// Global-hotkey entry point (wired in AppDelegate.setupHotkeys).
    func run() {
        guard !inFlight else { NSSound.beep(); return }

        // Never touch a password field: a synthetic ⌘C there would fail or leak
        // sensitive text to the cloud. macOS raises this flag while a secure
        // field is focused — native NSSecureTextField and browser password
        // inputs alike.
        if IsSecureEventInputEnabled() { NSSound.beep(); return }

        // Honor the same per-app exclusion list as the auto-switcher.
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           settings.excludedBundleIDs.contains(bid) {
            NSSound.beep(); return
        }

        guard !settings.aiAPIKey.isEmpty else {
            RecoveryHUD.shared.fail("Нет API-ключа — задайте его во вкладке «ИИ-слой».")
            return
        }

        inFlight = true
        RecoveryHUD.shared.working()

        let provider = OpenAICompatibleProvider(baseURL: settings.aiBaseURL,
                                                apiKey: settings.aiAPIKey,
                                                model: settings.aiModel)
        let prompt = settings.aiCorrectionPrompt

        // The hotkey chord is still physically held; a synthetic ⌘C/⌘V would
        // merge with it and reach the app as a garbage shortcut. Wait for
        // release before capturing (mirror of DictationController.insert). By
        // the time the paste fires — after a network round-trip — the chord is
        // long released.
        Self.whenModifiersReleased { [weak self] in
            guard let self else { return }
            TextInjector.shared.beginRecovery { [weak self] captured in
                guard let self else { return }
                guard let text = captured, !text.isEmpty else {
                    RecoveryHUD.shared.hide(); NSSound.beep(); self.finish(); return
                }
                // Snapshot the edit counter as late as possible — right before
                // the network Task — so a real keystroke that races in during
                // capture correctly invalidates the (now-stale) correction.
                let capturedGeneration = self.engine.editGeneration
                Task { @MainActor in
                    do {
                        let corrected = try await provider.correct(text, systemPrompt: prompt)
                        guard self.engine.editGeneration == capturedGeneration else {
                            TextInjector.shared.cancelRecovery()   // caret moved → drop it
                            RecoveryHUD.shared.hide(); self.finish(); return
                        }
                        guard corrected != text else {
                            TextInjector.shared.cancelRecovery()   // nothing to fix
                            RecoveryHUD.shared.hide(); NSSound.beep(); self.finish(); return
                        }
                        TextInjector.shared.commitRecovery(corrected)
                        RecoveryHUD.shared.hide()
                        self.finish()
                    } catch {
                        TextInjector.shared.cancelRecovery()
                        Log.error("Recovery failed: \(error)")
                        RecoveryHUD.shared.fail(Self.message(for: error))
                        self.finish()
                    }
                }
            }
        }
    }

    private func finish() { inFlight = false }

    /// Human-readable reason for the HUD — so "out of money / API down / bad
    /// key / no network" are visible, not silent.
    private static func message(for error: Error) -> String {
        if let e = error as? AIError {
            switch e {
            case .notConfigured: return "Не настроен ключ или адрес API."
            case .badResponse:   return "Непонятный ответ от API."
            case .http(401):     return "Неверный API-ключ (401)."
            case .http(403):     return "Доступ запрещён (403)."
            case .http(429):     return "Лимит запросов или закончились средства (429)."
            case .http(let code) where code >= 500: return "Сервис недоступен (\(code))."
            case .http(let code): return "Ошибка API: \(code)."
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost:
                return "Нет соединения с сервером."
            case .timedOut:
                return "Превышено время ожидания."
            default:
                return "Сеть: \(e.code.rawValue)."
            }
        }
        return "\(error)"
    }

    // MARK: - Wait for the hotkey chord to be released

    // Mirrors DictationController's helper (SpeechEngine.swift): a synthetic
    // ⌘C/⌘V posted while the hardware modifiers are down reaches the app as a
    // garbage chord and does nothing. Bails after ~2 s so a stuck key can't
    // freeze the feature.
    private static func whenModifiersReleased(attemptsLeft: Int = 40,
                                              _ action: @escaping () -> Void) {
        guard physicalModifiersDown(), attemptsLeft > 0 else { action(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            whenModifiersReleased(attemptsLeft: attemptsLeft - 1, action)
        }
    }

    private static func physicalModifiersDown() -> Bool {
        let modifierKeyCodes: [CGKeyCode] = [
            0x37, 0x36, // ⌘ left/right
            0x3A, 0x3D, // ⌥ left/right
            0x3B, 0x3E, // ⌃ left/right
            0x38, 0x3C, // ⇧ left/right
            0x3F        // fn
        ]
        return modifierKeyCodes.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
    }
}
