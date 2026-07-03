import Foundation

/// Pure decision logic: given the keystrokes of a word and the set of enabled
/// layouts, decide whether the word was typed in the wrong layout and, if so,
/// which layout it should have been.
///
/// This is deliberately free of side effects and UI so it can be unit-tested
/// and so the cloud-AI layer can override its verdict cleanly.
enum Decider {
    struct Decision {
        let source: KeyboardLayout        // layout the word was typed in
        let target: KeyboardLayout        // layout it should be in
        let originalText: String          // as-typed (wrong) text
        let correctedText: String         // text after re-interpretation in target
        let confident: Bool               // strong enough to auto-apply
        var viaAI: Bool = false
    }

    /// - Parameters:
    ///   - force: if true, always return the best alternative even if weak
    ///     (used by the manual hotkey).
    static func decide(strokes: [KeyStroke],
                       source: KeyboardLayout,
                       candidates: [KeyboardLayout],
                       sensitivity: Sensitivity,
                       force: Bool = false) -> Decision? {
        let translator = KeyTranslator.shared
        let scorer = LanguageScorer.shared

        let asTyped = translator.interpret(strokes, layout: source)
        let letters = asTyped.filter { $0.isLetter }
        guard letters.count >= 2 else { return nil }

        // On the automatic path, never touch alphanumeric tokens (codes, IDs,
        // passwords like "qwe123"): digits are identical across layouts, so
        // converting only the letters would corrupt a token typed on purpose.
        // The manual hotkey (`force`) may still convert them.
        if !force && asTyped.contains(where: { $0.isNumber }) { return nil }

        let sourceLang = source.primaryLanguage ?? "en"
        let typedScore = scorer.score(asTyped, language: sourceLang)

        // Evaluate every *other* enabled layout as a possible intended target.
        var best: (layout: KeyboardLayout, score: LanguageScorer.Score, text: String)?
        for candidate in candidates where candidate.id != source.id {
            let candidateText = translator.interpret(strokes, layout: candidate)
            // Skip candidates that produce the same text (e.g. two Latin layouts
            // that share letters — nothing would change visually).
            guard candidateText != asTyped else { continue }
            let lang = candidate.primaryLanguage ?? "en"
            let score = scorer.score(candidateText, language: lang)

            if best == nil || Self.rank(score) > Self.rank(best!.score) {
                best = (candidate, score, candidateText)
            }
        }
        guard let best else { return nil }

        // How much better is the swapped interpretation than what was typed?
        let confident = Self.isConfident(
            typed: typedScore,
            candidate: best.score,
            sensitivity: sensitivity
        )

        guard confident || force else {
            // Not confident enough and not forced — return a low-confidence
            // decision so the caller can optionally escalate to AI.
            return Decision(
                source: source, target: best.layout,
                originalText: asTyped, correctedText: best.text,
                confident: false
            )
        }

        return Decision(
            source: source, target: best.layout,
            originalText: asTyped, correctedText: best.text,
            confident: confident
        )
    }

    /// Rank a candidate interpretation. A known word (dictionary or curated
    /// frequent-word) wins outright; script match breaks remaining ties.
    /// Bigram coverage is intentionally NOT used: with a 120k-word corpus it
    /// saturates (~1.0 for almost any letter sequence, incl. "ghbdtn"), so it
    /// carries no signal here.
    private static func rank(_ s: LanguageScorer.Score) -> Double {
        var r = 0.0
        if s.scriptMatch { r += 1.0 }
        if s.isCommonWord { r += 8.0 }
        if s.isDictionaryWord { r += 10.0 }
        return r
    }

    /// The core heuristic. We trust two reliable signals — the OS spelling
    /// dictionary and a curated frequent-words list — and deliberately ignore
    /// bigram statistics (they don't discriminate real words from
    /// wrong-layout gibberish for this corpus).
    ///
    /// Ordering matters: the common-word override comes first because the OS
    /// spellchecker occasionally *false-accepts* a wrong-layout string (it
    /// calls "ghbdtn" a valid English word), which would otherwise veto the
    /// obviously-correct conversion to "привет".
    private static func isConfident(typed: LanguageScorer.Score,
                                    candidate: LanguageScorer.Score,
                                    sensitivity: Sensitivity) -> Bool {
        // The swapped text must actually be in the target language's script,
        // otherwise "converting" produces nonsense.
        guard candidate.scriptMatch else { return false }

        // The curated frequent-words override applies in every mode: it's the
        // one signal immune to the OS dictionary's rare false-accepts (it calls
        // "ghbdtn" a valid English word), which is exactly the flagship case.
        if candidate.isCommonWord && !typed.isCommonWord {
            return true
        }

        switch sensitivity {
        case .cautious:
            // Trust only the curated list — most conservative, fewest false
            // positives (e.g. won't convert obscure dictionary words).
            return false

        case .balanced:
            if typed.isCommonWord { return false }
            // Dictionary decisive: swapped is a real word, typed is not.
            return candidate.isDictionaryWord && !typed.isDictionaryWord

        case .aggressive:
            if typed.isCommonWord { return false }
            if candidate.isDictionaryWord && !typed.isDictionaryWord { return true }
            // Both are valid dictionary words: prefer the candidate when it is
            // also a curated common word (rarely both — this nudges ambiguous
            // cases toward the more-likely-intended word).
            return candidate.isDictionaryWord && candidate.isCommonWord
        }
    }
}
