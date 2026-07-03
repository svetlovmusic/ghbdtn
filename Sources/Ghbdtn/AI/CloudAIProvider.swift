import Foundation

/// Optional cloud-AI layer ("special abilities"). Off by default; the local
/// heuristic engine works fully offline. When enabled, the engine consults a
/// provider only for words it is unsure about (configurable), sending the
/// single ambiguous token — never a keystroke stream or full text.
protocol CloudAIProvider {
    /// Given an ambiguous token and its two candidate interpretations, decide
    /// which layout the user most likely meant. Returns the chosen layout ID
    /// and the corrected text, or nil to leave the word untouched.
    func resolveLayout(request: AILayoutRequest) async throws -> AILayoutResponse?
}

struct AILayoutRequest {
    let asTyped: String
    /// candidate layout ID → text under that layout
    let candidates: [String: String]
    /// Surrounding words for context (optional; empty by default for privacy).
    let context: String
}

struct AILayoutResponse {
    let chosenLayoutID: String
    let correctedText: String
    let confidence: Double
}

enum AIError: Error {
    case notConfigured
    case badResponse
    case http(Int)
}

/// OpenAI-compatible chat-completions client (also works with any endpoint
/// exposing `/chat/completions`: OpenAI, together.ai, local LM Studio, etc.).
///
/// This is intentionally a thin, self-contained implementation so the app has
/// zero third-party dependencies.
struct OpenAICompatibleProvider: CloudAIProvider {
    let baseURL: String
    let apiKey: String
    let model: String
    var session: URLSession = .shared

    func resolveLayout(request: AILayoutRequest) async throws -> AILayoutResponse? {
        guard !apiKey.isEmpty else { throw AIError.notConfigured }
        guard let url = URL(string: baseURL.trimmingSlash + "/chat/completions") else {
            throw AIError.notConfigured
        }

        let candidateList = request.candidates
            .map { "- \($0.key): \"\($0.value)\"" }
            .joined(separator: "\n")
        let system = """
        You fix text typed in the wrong keyboard layout. Respond ONLY with \
        compact JSON: {"layout":"<id>","text":"<corrected>","confidence":<0..1>}. \
        If the original text is already correct, return the original layout id \
        with confidence 0.
        """
        let user = """
        Typed: "\(request.asTyped)"
        Candidate interpretations by layout id:
        \(candidateList)
        \(request.context.isEmpty ? "" : "Context: \(request.context)")
        Which layout did the user intend?
        """

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIError.http(http.statusCode) }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        else {
            throw AIError.badResponse
        }

        guard let layoutID = parsed["layout"] as? String,
              let text = parsed["text"] as? String else {
            return nil
        }
        let confidence = (parsed["confidence"] as? NSNumber)?.doubleValue ?? 0.5
        return AILayoutResponse(chosenLayoutID: layoutID, correctedText: text, confidence: confidence)
    }
}

private extension String {
    var trimmingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
