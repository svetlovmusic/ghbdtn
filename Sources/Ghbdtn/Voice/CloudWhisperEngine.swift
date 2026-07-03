import Foundation

/// Cloud transcription via any OpenAI-compatible `POST /audio/transcriptions`
/// endpoint. Mirrors `OpenAICompatibleProvider`: a thin, dependency-free
/// URLSession client. Works against:
///   • OpenAI — base https://api.openai.com/v1, model gpt-4o-transcribe /
///     gpt-4o-mini-transcribe / whisper-1;
///   • Groq — base https://api.groq.com/openai/v1, model whisper-large-v3-turbo
///     (same Whisper weights as the local engine, near-free).
struct CloudWhisperEngine: SpeechEngine {
    let baseURL: String
    let apiKey: String
    let model: String
    var session: URLSession = .shared

    var isAvailable: Bool { !apiKey.isEmpty && !model.isEmpty && !baseURL.isEmpty }
    var unavailabilityHint: String {
        "Для облачной транскрипции нужен API-ключ (Настройки → Голос → Облачный)."
    }

    func transcribe(samples16k: [Float], language: String) async throws -> String {
        guard isAvailable else { throw SpeechError.engineUnavailable(unavailabilityHint) }
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + "/audio/transcriptions") else {
            throw SpeechError.engineUnavailable("Некорректный Base URL: \(baseURL)")
        }

        let wav = AudioCapture.wavData(samples16k: samples16k)
        let boundary = "ghbdtn-" + UUID().uuidString

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField("model", model)
        // gpt-4o-(mini-)transcribe only supports json/text response formats.
        appendField("response_format", "json")
        if language != "auto" && !language.isEmpty {
            appendField("language", language)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpeechError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SpeechError.http(http.statusCode, Self.errorMessage(from: data))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String else {
            throw SpeechError.badResponse
        }
        return text
    }

    /// Pull the human-readable message out of an OpenAI-style error payload.
    private static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "нет деталей"
    }
}
