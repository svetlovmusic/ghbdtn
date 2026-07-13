import Foundation
import whisper

/// Fully offline transcription via whisper.cpp (prebuilt XCFramework, Metal
/// GPU on Apple Silicon). The GGML model file lives in Application Support
/// (downloaded by `ModelDownloadManager`), never in the app bundle.
///
/// The whisper context is loaded lazily and kept resident between dictations:
/// loading a model takes seconds while transcribing a short burst takes
/// fractions of a second — dropping the context after each use would put the
/// model load on every dictation's critical path.
final class LocalWhisperEngine: SpeechEngine {
    /// whisper_full is not reentrant; a serial queue owns the context.
    private let queue = DispatchQueue(label: "com.ghbdtn.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    private var loadedModelPath: String?
    /// Bumped on every run; an idle-eviction block fires only if its
    /// generation is still current. Queue-confined.
    private var generation = 0

    /// Keep the ~0.5–1 GB context resident between dictations (model load,
    /// not inference, dominates latency), but give the memory back after a
    /// stretch of silence.
    private static let idleEviction: TimeInterval = 10 * 60

    /// Segments whose no-speech probability exceeds this are discarded before
    /// they reach the transcript: on silence Whisper still decodes tokens
    /// (typically a memorized subtitle credit). 0.6 mirrors Whisper's own
    /// `no_speech_thold` default, so only segments Whisper itself would judge
    /// non-speech are dropped — quiet real speech is kept.
    private static let noSpeechDropThreshold: Float = 0.6

    /// Model path snapshotted on the main actor by the controller before each
    /// session — the transcription thread must not read Settings/@Published.
    private let modelURLLock = NSLock()
    private var preparedModelURL: URL?

    var isAvailable: Bool { ModelDownloadManager.shared.installedModelURL() != nil }
    var unavailabilityHint: String {
        "Локальная модель Whisper не скачана. Настройки → Голос → Скачать модель."
    }

    init() {
        // whisper.cpp logs every inference to stderr; keep the Console clean —
        // load/failure events are logged through our own Log below.
        whisper_log_set({ _, _, _ in }, nil)
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Called on the main actor before a session starts (see currentEngine()).
    func prepare(modelURL: URL?) {
        modelURLLock.lock()
        preparedModelURL = modelURL
        modelURLLock.unlock()
    }

    /// Synchronous accessor so the async transcribe doesn't hold the lock
    /// across suspension points (and to satisfy the Swift 6 NSLock rule).
    private func snapshotModelURL() -> URL? {
        modelURLLock.lock()
        defer { modelURLLock.unlock() }
        return preparedModelURL
    }

    func transcribe(samples16k: [Float], language: String) async throws -> String {
        guard let modelURL = snapshotModelURL() else {
            throw SpeechError.engineUnavailable(unavailabilityHint)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let text = try self.run(samples: samples16k,
                                            language: language,
                                            modelPath: modelURL.path)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Serial-queue internals

    private func run(samples: [Float], language: String, modelPath: String) throws -> String {
        generation += 1
        defer { scheduleIdleEviction() }
        try ensureContext(modelPath: modelPath)
        guard let context else { throw SpeechError.transcriptionFailed("контекст не загружен") }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.suppress_blank = true
        // Drop the tokenizer's non-speech token set ("[music]", sound-tag
        // glyphs) at decode time — one class of silence artifacts, gone before
        // it can reach the transcript.
        params.suppress_nst = true
        // Decode each 30s window independently. On the silent tail / long
        // pauses of a dictation Whisper emits memorized subtitle-credit
        // boilerplate ("Субтитры сделал DimaTorzok", "Thank you for watching").
        // With the default (no_context = false) that hallucination becomes the
        // decoder prompt for the next window and snowballs into repeated,
        // byte-identical lines. Cutting cross-window context breaks the loop.
        params.no_context = true
        params.translate = false
        // Leave a couple of cores for the UI; Metal does the heavy lifting anyway.
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        let lang = language.isEmpty ? "auto" : language
        let started = Date()
        // params.language borrows the C string — whisper_full must run inside
        // the withCString closure so the pointer stays valid.
        let status: Int32 = lang.withCString { cLang in
            params.language = cLang
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else {
            throw SpeechError.transcriptionFailed("whisper_full вернул \(status)")
        }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            // A silent 30s window (the quiet tail or a long pause of a
            // dictation) carries a high no-speech probability. Whisper still
            // emits *something* for it — usually a subtitle-credit
            // hallucination — so drop those segments before concatenating.
            if whisper_full_get_segment_no_speech_prob(context, i) > Self.noSpeechDropThreshold {
                continue
            }
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        Log.info(String(format: "Local whisper: %.1fs audio → %.2fs compute",
                        Double(samples.count) / 16_000.0,
                        -started.timeIntervalSinceNow))
        return text
    }

    /// Load the model if needed; reload when the user switches models.
    private func ensureContext(modelPath: String) throws {
        if loadedModelPath != modelPath, let old = context {
            whisper_free(old)
            context = nil
            loadedModelPath = nil
        }
        guard context == nil else { return }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        let started = Date()
        guard let fresh = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw SpeechError.engineUnavailable(
                "Не удалось загрузить модель Whisper — файл повреждён? Перекачайте её в Настройках → Голос.")
        }
        context = fresh
        loadedModelPath = modelPath
        Log.info(String(format: "Loaded whisper model %@ in %.2fs",
                        (modelPath as NSString).lastPathComponent,
                        -started.timeIntervalSinceNow))
    }

    /// Free the context after `idleEviction` of no dictations. Runs on the
    /// owning serial queue; a newer run's generation bump disarms stale blocks.
    private func scheduleIdleEviction() {
        let armed = generation
        queue.asyncAfter(deadline: .now() + Self.idleEviction) { [weak self] in
            guard let self, self.generation == armed, let context = self.context else { return }
            whisper_free(context)
            self.context = nil
            self.loadedModelPath = nil
            Log.info("Whisper context evicted after \(Int(Self.idleEviction))s idle")
        }
    }
}
