import Foundation

/// Bridges the synchronous decision path to the async cloud provider.
/// Kept in its own file so the core engine stays offline-only by default.
extension AutoSwitchEngine {

    /// Consult the configured cloud provider about an ambiguous word.
    ///
    /// Because the network round-trip returns *after* the user may have kept
    /// typing, we snapshot `editGeneration` before firing and refuse to inject
    /// the verdict unless it is unchanged when we get back (see
    /// `applyAIVerdictIfSafe`). This prevents deleting unrelated text at a
    /// caret that has since moved.
    func consultAI(strokes: [KeyStroke], source: KeyboardLayout, fallback: Decider.Decision) {
        let settings = Settings.shared
        guard settings.aiEnabled, !settings.aiAPIKey.isEmpty else { return }

        let capturedGeneration = editGeneration
        let translator = KeyTranslator.shared
        let candidateLayouts = LayoutManager.shared.enabledLayouts()
        var candidateTexts: [String: String] = [:]
        for layout in candidateLayouts {
            candidateTexts[layout.id] = translator.interpret(strokes, layout: layout)
        }
        let asTyped = translator.interpret(strokes, layout: source)

        let provider = OpenAICompatibleProvider(
            baseURL: settings.aiBaseURL,
            apiKey: settings.aiAPIKey,
            model: settings.aiModel
        )
        let request = AILayoutRequest(asTyped: asTyped, candidates: candidateTexts, context: "")

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let response = try await provider.resolveLayout(request: request),
                      response.confidence >= 0.6,
                      response.chosenLayoutID != source.id,
                      let target = candidateLayouts.first(where: { $0.id == response.chosenLayoutID })
                else { return }

                let decision = Decider.Decision(
                    source: source, target: target,
                    originalText: asTyped, correctedText: response.correctedText,
                    confident: true, viaAI: true
                )
                await MainActor.run {
                    // The safety gate lives in the engine (it owns the buffer
                    // and the generation counter). It no-ops if the user typed
                    // anything since `capturedGeneration`.
                    self.applyAIVerdictIfSafe(decision, capturedGeneration: capturedGeneration)
                }
            } catch {
                Log.error("AI consult failed: \(error)")
            }
        }
    }
}
