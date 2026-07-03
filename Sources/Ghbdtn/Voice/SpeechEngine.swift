import Foundation
import AVFoundation
import AppKit

/// Voice → text abstraction. This is a *scaffold* per the product spec: the
/// hotkey, permission flow, engine selection and insertion path are wired, but
/// the actual Whisper transcription is intentionally left unimplemented.
///
/// Two concrete engines are planned:
///   • `LocalWhisperEngine`  — bundled whisper.cpp / CoreML model, fully offline.
///   • `CloudWhisperEngine`   — OpenAI `/audio/transcriptions` (whisper-1 / gpt-4o-transcribe).
protocol SpeechEngine {
    var isAvailable: Bool { get }
    /// Begin capturing audio. Implementations should stream or buffer until
    /// `stop()` is called, then return the transcript.
    func start() throws
    /// Stop capture and return the transcript (empty string in the scaffold).
    func stop() async throws -> String
}

enum SpeechError: Error {
    case notImplemented
    case microphonePermissionDenied
    case engineUnavailable
}

/// Placeholder local engine. Ships disabled; the real implementation will load
/// a Whisper model (GGML/CoreML) from Application Support.
struct LocalWhisperEngine: SpeechEngine {
    var isAvailable: Bool { false } // no model bundled yet

    func start() throws { throw SpeechError.notImplemented }
    func stop() async throws -> String { throw SpeechError.notImplemented }
}

/// Placeholder cloud engine (OpenAI-compatible audio transcription).
struct CloudWhisperEngine: SpeechEngine {
    let apiKey: String
    var isAvailable: Bool { !apiKey.isEmpty }

    func start() throws { throw SpeechError.notImplemented }
    func stop() async throws -> String { throw SpeechError.notImplemented }
}

/// Coordinates the dictation hotkey with a `SpeechEngine` and inserts the
/// resulting text at the caret. In the scaffold it surfaces a clear
/// "coming soon" notice instead of transcribing.
final class DictationController {
    static let shared = DictationController()
    private var isCapturing = false

    private init() {}

    /// Called by the voice-dictation hotkey (press to start, press to stop).
    func toggle() {
        let settings = Settings.shared
        guard settings.voiceEnabled else {
            Notifier.show(title: "Голосовой ввод выключен",
                          body: "Включите его в настройках → Голос (Whisper).")
            return
        }
        // Scaffold: no engine implemented yet.
        Notifier.show(
            title: "Голосовой ввод (Whisper) — в разработке",
            body: "Задел готов: выбран движок «\(settings.voiceEngine == "local" ? "локальный" : "облачный")». "
                + "Транскрипция появится в следующей версии."
        )
        Log.info("Dictation hotkey pressed — scaffold, engine=\(settings.voiceEngine)")
    }

    /// Requests microphone permission ahead of time (used when the user enables
    /// voice in settings) so the first real use is instant.
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

    /// Insert transcribed text at the caret (used by the real engine later).
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        TextInjector.shared.typeUnicode(text)
    }
}
