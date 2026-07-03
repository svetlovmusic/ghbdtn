import Foundation
import AVFoundation
import AppKit

/// Voice → text abstraction. The controller owns the microphone (one capture
/// session drives both the HUD waveform and the transcript), engines only see
/// the finished audio, already downsampled to Whisper's 16 kHz mono.
///
/// Two engines:
///   • `LocalWhisperEngine` — whisper.cpp (Metal), fully offline, model in
///     Application Support (see ModelDownloadManager).
///   • `CloudWhisperEngine` — OpenAI-compatible `/audio/transcriptions`
///     (OpenAI, Groq, …).
protocol SpeechEngine {
    var isAvailable: Bool { get }
    /// Shown to the user when `isAvailable == false`.
    var unavailabilityHint: String { get }
    /// `language` is an ISO-639-1 code ("ru", "en") or "auto".
    func transcribe(samples16k: [Float], language: String) async throws -> String
}

enum SpeechError: LocalizedError {
    case microphonePermissionDenied
    case noInputDevice
    case engineUnavailable(String)
    case audioConversionFailed
    case tooShort
    case transcriptionFailed(String)
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону. Разрешите его в Настройках → Конфиденциальность → Микрофон."
        case .noInputDevice:
            return "Не найден микрофон (устройство ввода звука)."
        case .engineUnavailable(let hint):
            return hint
        case .audioConversionFailed:
            return "Не удалось подготовить аудио для распознавания."
        case .tooShort:
            return "Запись слишком короткая — скажите хотя бы слово."
        case .transcriptionFailed(let detail):
            return "Распознавание не удалось: \(detail)"
        case .badResponse:
            return "Неожиданный ответ сервера транскрипции."
        case .http(let code, let message):
            return "Сервер транскрипции ответил \(code): \(message)"
        }
    }
}

/// Orchestrates a dictation session: hotkey/menu → capture + HUD → engine →
/// insertion at the caret. All UI state lives here so both the HUD and the
/// Settings "test now" flow observe the same object.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State { case idle, recording, transcribing }

    @Published private(set) var state: State = .idle
    /// Seconds since capture started; frozen while transcribing.
    @Published private(set) var elapsed: TimeInterval = 0

    let capture = AudioCapture()

    private var hud: DictationHUDPanel?
    private var timer: Timer?
    /// When set (Settings "Проверить сейчас"), the transcript is delivered
    /// here instead of being typed at the caret.
    private var testSink: ((Result<String, Error>) -> Void)?
    /// Resident local engine: the whisper context stays loaded between
    /// dictations — model load, not inference, dominates latency.
    private let localEngine = LocalWhisperEngine()

    private init() {
        capture.onLimitReached = { [weak self] in self?.recognize() }
        // Input device changed/unplugged mid-dictation: the tap dies with the
        // old format, so salvage what was captured instead of hanging "live".
        capture.onCaptureLost = { [weak self] in self?.recognize() }
    }

    /// Hotkey / tray-menu entry point: press to start, press again to
    /// recognize what was said (ignored while a transcription is running).
    func toggle() {
        switch state {
        case .idle: begin()
        case .recording: recognize()
        case .transcribing: break
        }
    }

    /// Start a test dictation from Settings: same HUD and engines, but the
    /// result comes back to the caller instead of being inserted.
    func beginTest(_ sink: @escaping (Result<String, Error>) -> Void) {
        guard state == .idle else {
            sink(.failure(SpeechError.transcriptionFailed("диктовка уже идёт")))
            return
        }
        testSink = sink
        begin(bypassEnabledCheck: true)
    }

    // MARK: - Session lifecycle

    private func begin(bypassEnabledCheck: Bool = false) {
        guard state == .idle else { return }
        guard Settings.shared.voiceEnabled || bypassEnabledCheck else {
            Notifier.show(title: "Голосовой ввод выключен",
                          body: "Включите его в настройках → Голос (Whisper).")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.beginAuthorized()
                    } else {
                        self.fail(SpeechError.microphonePermissionDenied)
                    }
                }
            }
        default:
            fail(SpeechError.microphonePermissionDenied)
        }
    }

    private func beginAuthorized() {
        // Re-check: two hotkey presses while the permission dialog was up
        // queue two requestAccess completions — only the first may start.
        guard state == .idle else { return }
        let engine = currentEngine()
        guard engine.isAvailable else {
            fail(SpeechError.engineUnavailable(engine.unavailabilityHint))
            return
        }
        do {
            try capture.start()
        } catch {
            fail(error)
            return
        }
        state = .recording
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let startedAt = self.capture.startedAt else { return }
                self.elapsed = -startedAt.timeIntervalSinceNow
            }
        }
        showHUD()
        Log.info("Dictation started (engine=\(Settings.shared.voiceEngine))")
    }

    /// Stop button: discard the recording, no transcription.
    func cancel() {
        guard state == .recording else { return }
        capture.stop()
        endSession()
        if let sink = testSink {
            testSink = nil
            sink(.failure(CancellationError()))
        }
        Log.info("Dictation cancelled")
    }

    /// Recognize button (or second hotkey press): transcribe and insert.
    func recognize() {
        guard state == .recording else { return }
        let recording = capture.stop()
        state = .transcribing
        timer?.invalidate()
        timer = nil

        let engine = currentEngine()
        let language = Settings.shared.whisperLanguage
        Task {
            do {
                let samples16k = try await Task.detached(priority: .userInitiated) {
                    try AudioCapture.convertTo16k(recording)
                }.value
                guard Double(samples16k.count) / 16_000.0 >= 0.4 else {
                    throw SpeechError.tooShort
                }
                let raw = try await engine.transcribe(samples16k: samples16k, language: language)
                let text = Self.cleanTranscript(raw)
                self.endSession()
                if let sink = self.testSink {
                    self.testSink = nil
                    sink(.success(text))
                } else if text.isEmpty {
                    Notifier.show(title: "Ничего не распозналось",
                                  body: "Попробуйте ещё раз — говорите ближе к микрофону.")
                } else {
                    self.insert(text)
                    Log.info("Dictation inserted \(text.count) chars")
                }
            } catch {
                self.endSession()
                if let sink = self.testSink {
                    self.testSink = nil
                    sink(.failure(error))
                } else {
                    Log.error("Dictation failed: \(error)")
                    Notifier.show(title: "Диктовка не удалась",
                                  body: error.localizedDescription)
                }
            }
        }
    }

    private func endSession() {
        timer?.invalidate()
        timer = nil
        state = .idle
        hideHUD()
    }

    private func fail(_ error: Error) {
        endSession()
        if let sink = testSink {
            testSink = nil
            sink(.failure(error))
        } else {
            Notifier.show(title: "Диктовка недоступна", body: error.localizedDescription)
        }
        Log.error("Dictation unavailable: \(error)")
    }

    // MARK: - Engine selection

    private func currentEngine() -> SpeechEngine {
        let settings = Settings.shared
        if settings.voiceEngine == "cloud" {
            // The dedicated dictation key falls back to the AI-layer key so
            // OpenAI users configure one key once — but ONLY when both point
            // at the same host, otherwise the AI key would leak to whatever
            // server the dictation Base URL names (e.g. Groq).
            let sameHost = URL(string: settings.whisperCloudBaseURL)?.host
                == URL(string: settings.aiBaseURL)?.host
            let key = !settings.whisperCloudAPIKey.isEmpty ? settings.whisperCloudAPIKey
                    : (sameHost ? settings.aiAPIKey : "")
            return CloudWhisperEngine(baseURL: settings.whisperCloudBaseURL,
                                      apiKey: key,
                                      model: settings.whisperCloudModel)
        }
        // Snapshot the model path here on the main actor: the transcription
        // itself runs off-main and must not touch Settings/@Published state.
        localEngine.prepare(modelURL: ModelDownloadManager.shared.installedModelURL())
        return localEngine
    }

    // MARK: - HUD

    private func showHUD() {
        if hud == nil {
            hud = DictationHUDPanel(controller: self, capture: capture)
        }
        hud?.positionTopCenter()
        // NEVER NSApp.activate here — activating the app would steal the
        // caret from the field the user is dictating into.
        hud?.orderFrontRegardless()
    }

    private func hideHUD() {
        hud?.orderOut(nil)
    }

    // MARK: - Output

    /// Insert transcribed text at the caret. The HUD never took key focus, so
    /// the target field still owns the caret and synthetic events land there.
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        // Short bursts type faster than a paste round-trip; long/multiline
        // text goes through the clipboard — a single atomic ⌘V is far more
        // reliable than hundreds of synthetic key events (Electron, autocomplete).
        if text.count <= 24 && !text.contains("\n") {
            TextInjector.shared.typeUnicode(text)
        } else {
            TextInjector.shared.paste(text)
        }
    }

    /// Whisper emits bracketed non-speech artifacts on silence/noise —
    /// "[BLANK_AUDIO]", "(music)", "♪". Square-bracket tags never appear in
    /// real dictation, so they are stripped anywhere; parentheses can be
    /// legitimate dictated text, so they are dropped only when the whole
    /// transcript is one parenthesized annotation.
    nonisolated static func cleanTranscript(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "",
                                            options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("("), text.hasSuffix(")"),
           text.dropFirst().dropLast().firstIndex(of: "(") == nil {
            text = ""
        }
        return text
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Requests microphone permission ahead of time (used from Settings) so
    /// the first real dictation starts instantly.
    func requestMicrophoneAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("Microphone access granted: \(granted)")
            }
        default:
            break
        }
    }
}
