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
        // The as-typed side can undercount letters (RU words whose б/ю/ж/э sit
        // on punctuation keys read as ",jr" in Latin), so word-length guards
        // are enforced on the CANDIDATE side below. Here only require that the
        // automatic path sees at least one as-typed letter — pure punctuation
        // runs ("...", "?!") must never auto-convert. The manual hotkey may
        // convert even those (юг → ".u" has a single as-typed letter).
        guard !letters.isEmpty || force else { return nil }

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
        // rank() may only consult the dictionary for complete words: the
        // spellcheck is a synchronous NSSpellChecker round-trip, far too slow
        // for the per-keystroke live path (it once caused tap timeouts and
        // dropped keys), and a prefix of a real word is not a dictionary word
        // anyway.
        var best: (layout: KeyboardLayout, score: LanguageScorer.Score, text: String)?
        for candidate in candidates where candidate.id != source.id {
            let candidateText = translator.interpret(strokes, layout: candidate)
            // Skip candidates that produce the same text (e.g. two Latin layouts
            // that share letters — nothing would change visually). A credible
            // intended word also has at least two letters of its own.
            guard candidateText != asTyped,
                  candidateText.filter({ $0.isLetter }).count >= 2 else { continue }
            let lang = candidate.primaryLanguage ?? "en"
            let score = scorer.score(candidateText, language: lang, completeWord: isCompleteWord)

            if best == nil || Self.rank(score, useDictionary: isCompleteWord)
                            > Self.rank(best!.score, useDictionary: isCompleteWord) {
                best = (candidate, score, candidateText)
            }
        }
        guard let best else { return nil }

        // Minimum word length (user-tunable, Settings → Детекция). Short words
        // are the biggest source of false conversions, so below the floor only
        // convert when the target is a word the user *explicitly taught*
        // (LearnedStore). The floor measures the CANDIDATE — the word the user
        // meant to type. Measuring the as-typed side punished RU words whose
        // б/ю/ж/э land on punctuation keys («бок» → ",jr" counts 2 letters and
        // was blocked at floor 3 despite being a 3-letter word). The curated
        // frequent-words list is deliberately NOT an exception here: it is full
        // of 2–3-letter tokens ("in", "he", "no", "on", "by", …) that almost
        // any short wrong-layout sequence collides with (шт→in, ру→he, ин→by),
        // which would silently defeat the floor — the user set it precisely to
        // stop short-word conversions. A learned word is a per-token decision
        // the user made, so it still overrides the floor. The manual hotkey
        // (force) ignores the floor entirely.
        let candidateLetters = best.text.filter { $0.isLetter }.count
        if !force, candidateLetters < minWordLength, !best.score.isLearnedWord {
            return nil
        }

        // The source language vouches for the as-typed word: it is curated/
        // learned, or the OS dictionary recognizes it AND the n-gram layer does
        // not score it at gibberish level. Inflected loanwords no curated list
        // can enumerate ("гите", "докере") land here. Returning nil — rather
        // than a low-confidence Decision — matters: the caller escalates
        // low-confidence decisions to the cloud layer, whose context-free guess
        // can override a perfectly correct word (гите → "ubnt"). Neither signal
        // alone suffices: the dictionary false-accepts ~1 in 13 abracadabras
        // ("ghbdtn" is "English" to it) and the n-gram alone has rare-word
        // flukes; wrong-layout junk reliably fails one of the two. This can
        // never block a local confident conversion: every rule in isConfident
        // already requires the typed side to fail one of these signals. A
        // curated/learned candidate still converts (checked above the veto) and
        // the manual hotkey (force) overrides everything.
        //
        // Complete words only: escalation happens solely at a word boundary
        // (the engine requires `final`), so in live mode nil and an unconfident
        // Decision are indistinguishable to the caller — but the dictionary leg
        // would pay a synchronous spellcheck on the event-tap thread on every
        // keystroke of ordinary correct typing (the exact regression class that
        // once caused dropped keys). Skip it there.
        let curatedTarget = isKnownWord(best.score) && !isKnownWord(typedScore)
        if !force, isCompleteWord, !curatedTarget,
           sourceVouches(for: typedScore, sensitivity: sensitivity, isCompleteWord: isCompleteWord) {
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
    /// `useDictionary` is false on the live (per-keystroke) path: the
    /// spellcheck is synchronous and slow, and prefixes aren't dictionary
    /// words — see the caller.
    private static func rank(_ s: LanguageScorer.Score, useDictionary: Bool) -> Double {
        var r = 0.0
        if s.scriptMatch { r += 1.0 }
        if isKnownWord(s) { r += 8.0 }
        if useDictionary, s.isDictionaryWord { r += 10.0 }
        r += 2.0 * (s.ngramPercentile ?? 0.0)
        return r
    }

    /// A word the top curated/learned layer vouches for: either the built-in
    /// frequent-words list or one the user taught the engine (LearnedStore).
    /// Both are trusted equally and above the OS dictionary's judgement.
    private static func isKnownWord(_ s: LanguageScorer.Score) -> Bool {
        s.isCommonWord || s.isLearnedWord
    }

    /// Above this calibrated percentile the n-gram model vouches for the typed
    /// word on its own, dictionary or not. Loanwords and domain slang the OS
    /// dictionary will never know («энвайрменте» 0.088, «алерт» 0.154, «деплой»
    /// 0.525, «гите» 0.116) sit above it; measured wrong-layout junk sits below
    /// 0.05 in ~99.6% of cases (tools/domain-corpora sweep, 2026-07), and the
    /// residual collisions are strings that genuinely read as words of the
    /// other language ("kens", "inputs") — keeping those is the safe default.
    private static let strongVouchPercentile = 0.05

    /// Does the source language itself vouch for the as-typed word? Curated and
    /// learned words always do, and so does a clearly word-like n-gram score
    /// (strongVouchPercentile) — requiring the OS dictionary on top of it sent
    /// half the user's correctly-typed domain vocabulary to the cloud layer,
    /// whose context-free guess converts real loanwords («фетч» → "fetch").
    /// In the gray zone above the gibberish threshold but below the strong
    /// vouch, require the two independent signals to agree: n-gram (checked
    /// first — it is precomputed, whereas isDictionaryWord pays a lazy
    /// synchronous spellcheck) AND the OS dictionary.
    private static func sourceVouches(for typed: LanguageScorer.Score,
                                      sensitivity: Sensitivity,
                                      isCompleteWord: Bool) -> Bool {
        if isKnownWord(typed) { return true }
        guard let p = typed.ngramPercentile else { return false }
        if p > strongVouchPercentile { return true }
        let t = sensitivity.ngramThresholds(completeWord: isCompleteWord)
        guard p > t.maxTyped else { return false }
        return typed.isDictionaryWord
    }

    /// Words the AI proposes below this n-gram percentile are refuted as
    /// hallucinations. A tripwire against confident nonsense, NOT a
    /// plausibility requirement: the cloud layer exists precisely for words no
    /// local signal recognizes, so the bar sits just above the observed
    /// hallucination ("ubnt" 0.0015) and below legitimate low-ngram brands
    /// ("ffmpeg" 0.0023, "kubectl" 0.0072). Deliberately NOT tied to the
    /// sensitivity setting — reusing maxTyped would make the cautious mode's
    /// gate the laxest, inverting the user's risk knob.
    private static let aiGibberishPercentile = 0.002

    /// Gate for cloud-escalated verdicts, applied together with the
    /// twin-equality check (AIConsult): the model's context-free choice alone
    /// must never convert a token about which the local signals can say
    /// NOTHING. Two refusals:
    ///  1. the typed side carries no gibberish evidence at all — the n-gram
    ///     can't score it and every character is in the source alphabet
    ///     («лут», "key", "eve") — unless the twin is a word the user's own
    ///     layers trust (curated/learned). Otherwise a 3-letter real word
    ///     whose twin happens to be a dictionary word ("ken", «лун») converts
    ///     on the model's word alone — the local dictionary rule already
    ///     refuses exactly this, and the cloud path must not be laxer;
    ///  2. the twin itself is unscoreable AND unknown to every signal
    ///     ("i'm" → «шэь») — nothing anywhere vouches for the result.
    /// Tokens with real gibberish evidence (фетч-class junk, foreign-char
    /// twins like ";bpym") keep their cloud recovery.
    static func aiEscalatedVerdictAllowed(typedText: String, sourceLanguage: String,
                                          twinText: String, targetLanguage: String) -> Bool {
        let scorer = LanguageScorer.shared
        let typed = scorer.score(typedText, language: sourceLanguage, completeWord: true)
        let twin = scorer.score(twinText, language: targetLanguage, completeWord: true)
        if twin.isCommonWord || twin.isLearnedWord { return true }
        if typed.ngramPercentile == nil && !typed.ngramForeign { return false }
        if twin.ngramPercentile == nil && !twin.isDictionaryWord { return false }
        return true
    }

    /// Sanity gate for cloud-AI verdicts: refuse corrected text the local
    /// signals can positively refute — wrong script, or an n-gram score at
    /// hallucination level ("ubnt") when no dictionary/curated/learned signal
    /// vouches for it. When the n-gram model abstains (short word, chars
    /// outside its alphabet, no model for the language) the gate abstains too:
    /// blocking everything it cannot score would kill the cloud layer for the
    /// very cases it exists for.
    static func aiVerdictPlausible(_ text: String, language: String) -> Bool {
        let score = LanguageScorer.shared.score(text, language: language, completeWord: true)
        guard score.scriptMatch else { return false }
        if isKnownWord(score) || score.isDictionaryWord { return true }
        guard let p = score.ngramPercentile else { return true }
        return p > aiGibberishPercentile
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

        // The dictionary layer applies to COMPLETE words only: a prefix of a
        // real word is not a dictionary word (typing «буфер» must not flip at
        // «буфе» because its twin ",eat" tokenizes to the word "eat"), and the
        // synchronous spellcheck is too slow for the per-keystroke live path.
        // The OS dictionary also false-accepts junk ("ken", "lcl", "thx"), so
        // it is decisive only when the n-gram layer agrees the typed side is
        // gibberish (or can't even score it as this language) and cannot
        // positively refute the candidate. Without that gate, correctly-typed
        // short slang converted into accidental dictionary twins («лут» → "ken",
        // "iban" → «шифт»).
        if isCompleteWord, sensitivity != .cautious,
           typedGibberish(typed, sensitivity: sensitivity, isCompleteWord: isCompleteWord),
           !(candidate.ngramPercentile.map { $0 < aiGibberishPercentile } ?? false),
           candidate.isDictionaryWord, !typed.isDictionaryWord {
            return true
        }

        return ngramConfident(typed: typed, candidate: candidate,
                              sensitivity: sensitivity, isCompleteWord: isCompleteWord)
    }

    /// The typed side reads like gibberish of its language: the n-gram model
    /// scores it at or below the sensitivity's gibberish threshold, or it
    /// cannot score it at all because the string has characters outside the
    /// language's alphabet (",jr"). An unscoreable all-letter short string
    /// («лут», "ker") is NOT gibberish — it just can't be judged.
    private static func typedGibberish(_ typed: LanguageScorer.Score,
                                       sensitivity: Sensitivity,
                                       isCompleteWord: Bool) -> Bool {
        if let p = typed.ngramPercentile {
            return p <= sensitivity.ngramThresholds(completeWord: isCompleteWord).maxTyped
        }
        return typed.ngramForeign
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
