import Foundation
import AVFoundation
import Accelerate

/// Captures microphone audio for dictation. One `AVAudioEngine` tap feeds two
/// consumers at once: raw samples are buffered for Whisper, and a per-buffer
/// RMS drives the live waveform in the HUD.
///
/// Whisper (local and cloud) wants 16 kHz mono; the mic delivers its native
/// format (typically 44.1/48 kHz float). We record at the native rate and
/// downsample once at the end with `AVAudioConverter` — feeding native-rate
/// audio to whisper.cpp yields garbled transcripts.
final class AudioCapture: ObservableObject {
    /// Rolling window of recent input levels (0…1), oldest first. Drives the
    /// HUD waveform. Mutated on the main thread only.
    @Published private(set) var levelHistory: [Float]

    /// Set while capturing; the HUD timer counts from it.
    @Published private(set) var startedAt: Date?

    struct Recording {
        let samples: [Float]      // mono, at `sampleRate`
        let sampleRate: Double
    }

    /// Hard cap so an abandoned session can't grow unbounded (5 min at 48 kHz
    /// mono Float32 ≈ 55 MB). The controller auto-recognizes when hit.
    static let maxDuration: TimeInterval = 300
    var onLimitReached: (() -> Void)?

    /// Fired (on main) when the input device changes mid-capture — the tap
    /// holds the old device's format, so the session can't continue; the
    /// controller salvages what was recorded.
    var onCaptureLost: (() -> Void)?

    static let historyLength = 30

    private let engine = AVAudioEngine()
    private var sampleRate: Double = 0
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private(set) var isRunning = false
    private var limitFired = false
    private var configObserver: NSObjectProtocol?

    init() {
        levelHistory = Array(repeating: 0, count: Self.historyLength)
    }

    /// Begin capturing from the default input device. Caller must have
    /// microphone permission already (the controller gates on it).
    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechError.noInputDevice
        }
        sampleRate = format.sampleRate
        limitFired = false
        samplesLock.lock()
        samples.removeAll(keepingCapacity: false)
        samples.reserveCapacity(Int(format.sampleRate * 60))
        samplesLock.unlock()

        let maxSamples = Int(format.sampleRate * Self.maxDuration)
        // The tap runs on the realtime audio thread: copy samples + compute
        // RMS there, publish UI state only via the main queue.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(count))

            self.samplesLock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            let reachedLimit = self.samples.count >= maxSamples
            self.samplesLock.unlock()

            DispatchQueue.main.async {
                self.pushLevel(rms)
                if reachedLimit && !self.limitFired {
                    self.limitFired = true
                    self.onLimitReached?()
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            Log.info("Audio configuration changed mid-dictation — salvaging capture")
            self.onCaptureLost?()
        }
        isRunning = true
        startedAt = Date()
    }

    /// Stop capture and hand back everything recorded (mono, native rate).
    @discardableResult
    func stop() -> Recording {
        guard isRunning else { return Recording(samples: [], sampleRate: sampleRate) }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        startedAt = nil
        levelHistory = Array(repeating: 0, count: Self.historyLength)
        samplesLock.lock()
        let recorded = samples
        samples = []
        samplesLock.unlock()
        return Recording(samples: recorded, sampleRate: sampleRate)
    }

    private func pushLevel(_ rms: Float) {
        guard isRunning else { return }
        // Typical speech RMS is well under 0.15; scale up so the waveform is
        // lively, then smooth against the previous bar to avoid flicker.
        let scaled = min(1, rms * 7)
        let previous = levelHistory.last ?? 0
        levelHistory.removeFirst()
        levelHistory.append(previous * 0.35 + scaled * 0.65)
    }

    // MARK: - Conversion for Whisper

    /// Downsample a captured recording to Whisper's 16 kHz mono.
    static func convertTo16k(_ recording: Recording) throws -> [Float] {
        guard !recording.samples.isEmpty else { return [] }
        if recording.sampleRate == 16_000 { return recording.samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: recording.sampleRate,
                                           channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                              frameCapacity: AVAudioFrameCount(recording.samples.count))
        else {
            throw SpeechError.audioConversionFailed
        }

        inBuffer.frameLength = AVAudioFrameCount(recording.samples.count)
        recording.samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }

        let ratio = 16_000.0 / recording.sampleRate
        let outCapacity = AVAudioFrameCount(Double(recording.samples.count) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw SpeechError.audioConversionFailed
        }

        // Single-shot conversion: feed the whole buffer, then end-of-stream so
        // the resampler flushes its tail.
        var fed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if let conversionError { throw conversionError }

        let count = Int(outBuffer.frameLength)
        guard count > 0, let channel = outBuffer.floatChannelData else {
            throw SpeechError.audioConversionFailed
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }

    /// Encode 16 kHz mono float samples as a 16-bit PCM WAV blob — the upload
    /// body for the cloud `/audio/transcriptions` endpoint.
    static func wavData(samples16k: [Float]) -> Data {
        let sampleRate: UInt32 = 16_000
        let bytesPerSample: UInt32 = 2

        var pcm = [Int16](repeating: 0, count: samples16k.count)
        for i in 0..<samples16k.count {
            pcm[i] = Int16(max(-1, min(1, samples16k[i])) * 32767)
        }
        let dataChunk = pcm.withUnsafeBufferPointer { Data(buffer: $0) }

        var wav = Data(capacity: 44 + dataChunk.count)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }

        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataChunk.count))          // RIFF chunk size
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                            // fmt chunk size
        append(UInt16(1))                             // PCM
        append(UInt16(1))                             // mono
        append(sampleRate)
        append(sampleRate * bytesPerSample)           // byte rate
        append(UInt16(bytesPerSample))                // block align
        append(UInt16(16))                            // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(dataChunk.count))
        wav.append(dataChunk)
        return wav
    }
}
