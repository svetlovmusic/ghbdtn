import Foundation
import CryptoKit

/// A downloadable GGML Whisper model. Checksums/sizes are pinned to the
/// upstream HuggingFace LFS metadata (huggingface.co/ggerganov/whisper.cpp).
struct WhisperModelInfo: Identifiable, Equatable {
    let id: String        // Settings.whisperModel value
    let title: String     // picker label
    let note: String      // one-line quality hint
    let fileName: String
    let sha256: String
    let sizeBytes: Int64

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Downloads GGML models into Application Support and verifies their SHA-256
/// before install. Dependency-free: URLSession download task + CryptoKit.
/// The Voice settings tab observes `activeDownloadID`/`progress`.
final class ModelDownloadManager: NSObject, ObservableObject {
    static let shared = ModelDownloadManager()

    /// Quantized variants: near-identical quality to f16 at a fraction of the
    /// disk/RAM. Russian degrades sharply below `small`; `large-v3-turbo` is
    /// the ru+en sweet spot (see README «Голосовой ввод»).
    static let catalog: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "tiny-q5_1", title: "tiny", note: "черновик, англ.",
            fileName: "ggml-tiny-q5_1.bin",
            sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
            sizeBytes: 32_152_673),
        WhisperModelInfo(
            id: "base-q5_1", title: "base", note: "быстрый, англ.",
            fileName: "ggml-base-q5_1.bin",
            sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
            sizeBytes: 59_707_625),
        WhisperModelInfo(
            id: "small-q5_1", title: "small", note: "компромисс ru/en",
            fileName: "ggml-small-q5_1.bin",
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            sizeBytes: 190_085_487),
        WhisperModelInfo(
            id: "large-v3-turbo-q5_0", title: "large-v3-turbo", note: "лучший ru/en — рекомендуется",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            sizeBytes: 574_041_195)
    ]

    static let defaultModelID = "large-v3-turbo-q5_0"

    // Published on the main queue only.
    @Published private(set) var activeDownloadID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    /// Bumped after every install/delete so SwiftUI re-checks `isInstalled`.
    @Published private(set) var installedRevision = 0

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self,
                                          delegateQueue: nil)

    /// Same directory the n-gram extension models use
    /// (~/Library/Application Support/Ghbdtn/Models).
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ghbdtn/Models", isDirectory: true)
    }

    static func info(for id: String) -> WhisperModelInfo? {
        catalog.first { $0.id == id }
    }

    /// Installed = file present with the exact pinned size (the full SHA-256
    /// is verified once, at install time).
    func installedURL(for id: String) -> URL? {
        guard let info = Self.info(for: id) else { return nil }
        let url = Self.modelsDirectory.appendingPathComponent(info.fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? Int64) == info.sizeBytes else { return nil }
        return url
    }

    /// URL of the model currently selected in Settings, if installed.
    func installedModelURL() -> URL? {
        installedURL(for: Settings.shared.whisperModel)
    }

    // MARK: - Download

    func download(_ info: WhisperModelInfo) {
        guard activeDownloadID == nil else { return }
        lastError = nil
        activeDownloadID = info.id
        progress = 0
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(info.fileName)")!
        Log.info("Downloading whisper model \(info.fileName) (\(info.sizeLabel))")
        let task = session.downloadTask(with: url)
        // The delegate identifies the model from the task itself: set before
        // resume() and never mutated, so delegate-queue reads are safe —
        // unlike @Published activeDownloadID, which is main-thread-only.
        task.taskDescription = info.id
        self.task = task
        task.resume()
    }

    /// Main-thread only (invoked from the settings UI). Nils `task` first so
    /// the cancelled task's late delegate callbacks fail the identity guard.
    func cancelDownload() {
        task?.cancel()
        task = nil
        activeDownloadID = nil
        progress = 0
    }

    func delete(_ info: WhisperModelInfo) {
        let url = Self.modelsDirectory.appendingPathComponent(info.fileName)
        try? FileManager.default.removeItem(at: url)
        installedRevision += 1
    }

    // MARK: - Internals

    /// Streaming SHA-256 so the 0.5 GB model never sits in memory whole.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finish(task: URLSessionTask, error: String?) {
        DispatchQueue.main.async {
            // Whatever happened, the on-disk install state may have changed.
            self.installedRevision += 1
            // But only the CURRENT download may touch the UI state — a stale
            // callback from a cancelled/replaced task must not clobber it.
            guard task.taskIdentifier == self.task?.taskIdentifier else { return }
            self.lastError = error
            self.activeDownloadID = nil
            self.progress = 0
            self.task = nil
        }
    }
}

// MARK: - URLSessionDownloadDelegate (background queue)

extension ModelDownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            guard downloadTask.taskIdentifier == self.task?.taskIdentifier else { return }
            self.progress = fraction
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file dies when this method returns — stage it first.
        guard let id = downloadTask.taskDescription, let info = Self.info(for: id) else { return }
        let staging = location.deletingLastPathComponent()
            .appendingPathComponent("ghbdtn-staging-\(info.fileName)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw SpeechError.http(http.statusCode, "не удалось скачать модель")
            }
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)

            let digest = try Self.sha256(of: staging)
            guard digest == info.sha256 else {
                try? FileManager.default.removeItem(at: staging)
                throw SpeechError.transcriptionFailed(
                    "контрольная сумма модели не совпала — скачивание повреждено, попробуйте ещё раз")
            }

            try FileManager.default.createDirectory(at: Self.modelsDirectory,
                                                    withIntermediateDirectories: true)
            let destination = Self.modelsDirectory.appendingPathComponent(info.fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staging, to: destination)
            Log.info("Installed whisper model \(info.fileName)")
            finish(task: downloadTask, error: nil)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            Log.error("Model install failed: \(error)")
            finish(task: downloadTask, error: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return } // success handled in didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled {
            DispatchQueue.main.async {
                guard task.taskIdentifier == self.task?.taskIdentifier else { return }
                self.activeDownloadID = nil
                self.progress = 0
                self.task = nil
            }
            return
        }
        Log.error("Model download failed: \(error)")
        finish(task: task, error: error.localizedDescription)
    }
}
