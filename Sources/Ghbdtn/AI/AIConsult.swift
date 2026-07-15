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
        let twinTexts = candidateTexts

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let response = try await provider.resolveLayout(request: request),
                      response.confidence >= 0.6,
                      response.chosenLayoutID != source.id,
                      let target = candidateLayouts.first(where: { $0.id == response.chosenLayoutID })
                else { return }

                // Layout conversion is deterministic: the ONLY legitimate
                // correction is the chosen layout's twin of the same physical
                // keys. A verdict whose text differs is the model translating
                // or paraphrasing, not fixing the layout — that is exactly how
                // a correctly-typed loanword got "converted" to its English
                // meaning («фетч» → "fetch", twin "atnx"). Reject those; the
                // twin text itself is used for the injection so capitalization
                // stays faithful to the keys actually pressed.
                let twin = twinTexts[target.id] ?? ""
                guard response.correctedText.lowercased() == twin.lowercased() else {
                    Log.info("AI verdict rejected: not the \(target.id) layout twin",
                             sensitive: "\"\(response.correctedText)\" ≠ \"\(twin)\" for \"\(asTyped)\"")
                    return
                }

                let decision = Decider.Decision(
                    source: source, target: target,
                    originalText: asTyped, correctedText: twin,
                    confident: true, viaAI: true
                )
                await MainActor.run {
                    // Local sanity gate: the model answers from a single token
                    // with no context, so it can hallucinate a "correction"
                    // that is not a word of the target language at all (гите →
                    // "ubnt"). Refuse any verdict whose text no local signal
                    // finds plausible. Runs on the main actor because the gate
                    // consults NSSpellChecker, which the rest of the app only
                    // ever touches from the main thread.
                    let targetLang = target.primaryLanguage ?? "en"
                    guard Decider.aiVerdictPlausible(decision.correctedText,
                                                     language: targetLang) else {
                        Log.info("AI verdict rejected: implausible in \(targetLang)",
                                 sensitive: "\"\(decision.correctedText)\"")
                        return
                    }
                    // Second gate: the model's context-free choice alone must
                    // not convert tokens no local signal can judge («лут» →
                    // "ken", "i'm" → «шэь») — see aiEscalatedVerdictAllowed.
                    guard Decider.aiEscalatedVerdictAllowed(
                        typedText: asTyped,
                        sourceLanguage: source.primaryLanguage ?? "en",
                        twinText: decision.correctedText,
                        targetLanguage: targetLang) else {
                        Log.info("AI verdict rejected: no local signal",
                                 sensitive: "\"\(asTyped)\" → \"\(decision.correctedText)\"")
                        return
                    }
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
