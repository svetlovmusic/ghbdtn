import Foundation

/// A pluggable backend for the on-demand *recovery* pass: a full, context-aware
/// correction of a whole chunk of text, triggered explicitly (hotkey) — as
/// opposed to the always-on, per-word deterministic layer.
///
/// One method, deliberately, so a cloud model (`OpenAICompatibleProvider`) and,
/// later, a local model can be swapped without touching the capture/apply
/// plumbing. Pressing the hotkey is the user's consent signal, which is what
/// lets this pass be more aggressive than the ambient auto-switcher.
protocol TextCorrector {
    /// Correct `text` using the given (user-editable) instructions. The JSON
    /// response contract is appended by the implementation, so editing the
    /// prompt can never break output parsing.
    func correct(_ text: String, systemPrompt: String) async throws -> String
}

extension OpenAICompatibleProvider: TextCorrector {
    func correct(_ text: String, systemPrompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError.notConfigured }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/chat/completions") else {
            throw AIError.notConfigured
        }

        // The instructions are user-editable (Settings.aiCorrectionPrompt). The
        // machine contract — respond with {"text": ...} JSON — is appended here
        // so the user can rewrite the prompt without breaking parsing.
        let system = systemPrompt
            + "\n\nВерни ТОЛЬКО компактный JSON без пояснений: {\"text\":\"<исправленный текст>\"}"

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
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
              let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let corrected = parsed["text"] as? String
        else {
            throw AIError.badResponse
        }
        return corrected
    }
}
