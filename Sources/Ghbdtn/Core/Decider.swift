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
    ///   - isCompleteWord: false when the word is still being typed (live
    ///     trigger) — the n-gram layer then scores it as a prefix and applies
    ///     stricter thresholds.
    static func decide(strokes: [KeyStroke],
                       source: KeyboardLayout,
                       candidates: [KeyboardLayout],
                       sensitivity: Sensitivity,
                       minWordLength: Int = 2,
                       force: Bool = false,
                       isCompleteWord: Bool = true) -> Decision? {
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
        let typedScore = scorer.score(asTyped, language: sourceLang, completeWord: isCompleteWord)

        // The user has repeatedly rejected converting this exact word in this
        // layout (adaptive negative learning) — never auto-convert it. The
        // manual hotkey (force) can still override.
        if !force, typedScore.isKeepWord { return nil }

        // Evaluate every *other* enabled layout as a possible intended target.
        var best: (layout: KeyboardLayout, score: LanguageScorer.Score, text: String)?
        for candidate in candidates where candidate.id != source.id {
            let candidateText = translator.interpret(strokes, layout: candidate)
            // Skip candidates that produce the same text (e.g. two Latin layouts
            // that share letters — nothing would change visually).
            guard candidateText != asTyped else { continue }
            let lang = candidate.primaryLanguage ?? "en"
            let score = scorer.score(candidateText, language: lang, completeWord: isCompleteWord)

            if best == nil || Self.rank(score) > Self.rank(best!.score) {
                best = (candidate, score, candidateText)
            }
        }
        guard let best else { return nil }

        // Minimum word length (user-tunable, Settings → Детекция). Short words
        // are the biggest source of false conversions, so below the floor only
        // convert when the target is a curated/learned word we explicitly trust;
        // otherwise leave the word alone. The manual hotkey (force) ignores it.
        if !force, letters.count < minWordLength, !isKnownWord(best.score) {
            return nil
        }

        // How much better is the swapped interpretation than what was typed?
        let confident = Self.isConfident(
            typed: typedScore,
            candidate: best.score,
            sensitivity: sensitivity,
            isCompleteWord: isCompleteWord
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
    /// frequent-word) wins outright; the calibrated n-gram percentile breaks
    /// ties between unknown candidates; script match breaks the rest.
    /// Bigram coverage is intentionally NOT used: with a 120k-word corpus it
    /// saturates (~1.0 for almost any letter sequence, incl. "ghbdtn"), so it
    /// carries no signal here.
    private static func rank(_ s: LanguageScorer.Score) -> Double {
        var r = 0.0
        if s.scriptMatch { r += 1.0 }
        if isKnownWord(s) { r += 8.0 }
        if s.isDictionaryWord { r += 10.0 }
        r += 2.0 * (s.ngramPercentile ?? 0.0)
        return r
    }

    /// A word the top curated/learned layer vouches for: either the built-in
    /// frequent-words list or one the user taught the engine (LearnedStore).
    /// Both are trusted equally and above the OS dictionary's judgement.
    private static func isKnownWord(_ s: LanguageScorer.Score) -> Bool {
        s.isCommonWord || s.isLearnedWord
    }

    /// The core heuristic, layered by reliability:
    ///  1. curated frequent-words list — immune to the OS dictionary's rare
    ///     false-accepts (it calls "ghbdtn" a valid English word), so it comes
    ///     first; this is exactly the flagship ghbdtn→привет case;
    ///  2. the OS spelling dictionary (balanced/aggressive);
    ///  3. the calibrated character 4-gram layer — for words neither of the
    ///     above recognizes: names, slang, rare words, word prefixes.
    /// Bigram statistics are deliberately ignored (they don't discriminate
    /// real words from wrong-layout gibberish).
    private static func isConfident(typed: LanguageScorer.Score,
                                    candidate: LanguageScorer.Score,
                                    sensitivity: Sensitivity,
                                    isCompleteWord: Bool) -> Bool {
        // The swapped text must actually be in the target language's script,
        // otherwise "converting" produces nonsense.
        guard candidate.scriptMatch else { return false }

        if isKnownWord(candidate) && !isKnownWord(typed) {
            return true
        }
        // A curated or user-learned word typed as-is is trusted unconditionally —
        // never second-guess it with weaker signals.
        if isKnownWord(typed) { return false }

        switch sensitivity {
        case .cautious:
            // Don't trust the dictionary — it won't convert obscure
            // dictionary words. The n-gram layer below still applies, with
            // the strictest thresholds.
            break

        case .balanced:
            // Dictionary decisive: swapped is a real word, typed is not.
            if candidate.isDictionaryWord && !typed.isDictionaryWord { return true }

        case .aggressive:
            if candidate.isDictionaryWord && !typed.isDictionaryWord { return true }
            // Both are valid dictionary words: prefer the candidate when it is
            // also a curated/learned word (rarely both — this nudges ambiguous
            // cases toward the more-likely-intended word).
            if candidate.isDictionaryWord && isKnownWord(candidate) { return true }
        }

        return ngramConfident(typed: typed, candidate: candidate,
                              sensitivity: sensitivity, isCompleteWord: isCompleteWord)
    }

    /// The out-of-vocabulary layer: character 4-gram models calibrated to
    /// per-language percentiles (LanguageScorer.Score.ngramPercentile), so the
    /// two interpretations are compared on a common scale despite different
    /// training corpora. Convert only when the swapped text reads like real
    /// language AND the as-typed text reads like gibberish — both thresholds
    /// come from an offline zero-false-positive sweep (tools/eval_thresholds.py).
    ///
    /// The typed side deliberately does NOT get a dictionary veto here: the OS
    /// spellchecker false-accepts ~1 in 13 abracadabras, and a typed score at
    /// gibberish level (≤ maxTyped, i.e. worse than 99.5% of real words)
    /// combined with a plausible candidate outweighs such an accept. The
    /// curated common-word veto above stays absolute.
    private static func ngramConfident(typed: LanguageScorer.Score,
                                       candidate: LanguageScorer.Score,
                                       sensitivity: Sensitivity,
                                       isCompleteWord: Bool) -> Bool {
        // A candidate the model can't score (no model, too short, or chars
        // outside the target alphabet) is never trusted.
        guard let candP = candidate.ngramPercentile else { return false }

        // As-typed percentile. A string with characters outside the source
        // language's alphabet (";bpym" scored as English) is by definition
        // not a word of that language — that IS the gibberish verdict, not a
        // missing one. Any other unscoreable case means we can't judge — abstain.
        let typedP: Double
        if let p = typed.ngramPercentile {
            typedP = p
        } else if typed.ngramForeign {
            typedP = 0.0
        } else {
            return false
        }

        let t = sensitivity.ngramThresholds(completeWord: isCompleteWord)
        return candP >= t.minCandidate && typedP <= t.maxTyped
    }
}
