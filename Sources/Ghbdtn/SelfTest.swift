import Foundation
import whisper

/// Headless diagnostic exercised via `ghbdtn --selftest`. Runs the REAL
/// Decider + LanguageScorer against known keystroke sequences so detection
/// behavior can be validated without the GUI. Physical keycodes are shared
/// across layouts, so the same keys yield "ghbdtn" under ABC and "привет"
/// under Russian — exactly the case the user tests.
enum SelfTest {
    // Virtual ANSI keycodes for letter and punctuation keys.
    static let k: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        // Punctuation keys that carry Cyrillic letters in the Russian layout
        // (ж э б ю х ъ). Words containing them show up with punctuation chars
        // when typed in the wrong layout — e.g. "жизнь" appears as ";bpym".
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "[": 0x21, "]": 0x1E,
        // The ABC '/' key — carries no letter in either layout; it is the
        // Russian '.' and must never end up inside a converted word.
        "/": 0x2C
    ]

    static func strokes(for keys: String) -> [KeyStroke] {
        keys.compactMap { ch in k[ch].map { KeyStroke(keyCode: $0, shift: false, capsLock: false) } }
    }

    /// Diagnostic (`--learncheck`): loads the user's REAL learned.json (does NOT
    /// disable persistence) and reports whether the Decider converts the learned
    /// words' wrong-layout twins. Read-only — never writes.
    static func learnCheck() -> Bool {
        let layouts = LayoutManager.shared.enabledLayouts()
        guard let en = layouts.first(where: { ($0.primaryLanguage ?? "") == "en" || $0.id.contains("ABC") }),
              let ru = layouts.first(where: { ($0.primaryLanguage ?? "") == "ru" }) else {
            print("⚠️  need both en and ru layouts enabled"); return false
        }
        _ = ru
        let scorer = LanguageScorer.shared
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !(scorer.hasNgramModel(for: "en") && scorer.hasNgramModel(for: "ru")) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        print("Enabled layouts: \(layouts.map { "\($0.localizedName)[\($0.primaryLanguage ?? "?")]" }.joined(separator: ", "))")
        for w in ["пэд", "пэды"] {
            let c = scorer.learnedCount(word: w, language: "ru", positive: true)
            let s = scorer.score(w, language: "ru", completeWord: true)
            print("  \(w)[ru]: learnedCount=\(c) isLearnedWord=\(s.isLearnedWord) isCommon=\(s.isCommonWord)")
        }
        for keys in ["g'l", "g'ls"] {
            let st = strokes(for: keys)
            let asTyped = KeyTranslator.shared.interpret(st, layout: en)
            let d = Decider.decide(strokes: st, source: en, candidates: layouts, sensitivity: .balanced)
            if let d, d.confident {
                print("  [\(keys)] en \(asTyped) → \(d.correctedText)  ✅ CONVERTS")
            } else {
                print("  [\(keys)] en \(asTyped) → kept  (decision=\(d.map { "\($0.correctedText) confident=\($0.confident)" } ?? "nil"))")
            }
        }
        return true
    }

    static func run() -> Bool {
        let layouts = LayoutManager.shared.enabledLayouts()
        print("Enabled layouts: \(layouts.map { "\($0.localizedName)[\($0.primaryLanguage ?? "?")]" }.joined(separator: ", "))")
        guard layouts.count >= 2 else {
            print("⚠️  Need at least 2 layouts enabled to test. Aborting."); return false
        }

        func find(_ needle: String) -> KeyboardLayout? {
            layouts.first { $0.id.lowercased().contains(needle) || ($0.primaryLanguage ?? "") == needle }
        }
        guard let en = find("en") ?? layouts.first(where: { $0.id.contains("ABC") }),
              let ru = find("ru") ?? layouts.first(where: { $0.id.lowercased().contains("russian") }) else {
            print("⚠️  Could not find both an English and a Russian layout."); return false
        }

        // The n-gram models load asynchronously; give them a moment.
        let scorer = LanguageScorer.shared
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !(scorer.hasNgramModel(for: "en") && scorer.hasNgramModel(for: "ru")) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        reportModels()

        struct Case {
            let keys: String
            let source: KeyboardLayout
            let expectConvert: Bool
            let complete: Bool
            let sensitivity: Sensitivity
            let note: String
            init(keys: String, source: KeyboardLayout, expectConvert: Bool,
                 complete: Bool = true, sensitivity: Sensitivity = .balanced, note: String) {
                self.keys = keys; self.source = source
                self.expectConvert = expectConvert; self.complete = complete
                self.sensitivity = sensitivity; self.note = note
            }
        }
        // Note: veps→музы converts in balanced/aggressive via the DICTIONARY
        // layer ("музы" is a real Russian word, "veps" unknown to every English
        // signal), independent of the n-gram layer. That pre-existing behavior
        // is out of scope here; the `sensitivity` field is kept so per-mode
        // n-gram regressions can be pinned in future.
        let cases: [Case] = [
            // -- The original six: dictionary + curated-list layers.
            Case(keys: "ghbdtn", source: en, expectConvert: true,  note: "ghbdtn → привет (flagship)"),
            Case(keys: "ghbdtn", source: ru, expectConvert: false, note: "привет typed correctly → keep"),
            Case(keys: "hello",  source: ru, expectConvert: true,  note: "руддщ → hello"),
            Case(keys: "hello",  source: en, expectConvert: false, note: "hello typed correctly → keep"),
            Case(keys: "world",  source: en, expectConvert: false, note: "world typed correctly → keep"),
            Case(keys: "spasibo", source: ru, expectConvert: false, note: "translit typed in RU layout → keep"),

            // -- Out-of-vocabulary conversions: the character 4-gram layer.
            Case(keys: "fylhtq", source: en, expectConvert: true,  note: "OOV name: fylhtq → андрей"),
            Case(keys: "unfollow", source: ru, expectConvert: true, note: "OOV slang: гтащддщц → unfollow"),
            Case(keys: "brandon", source: ru, expectConvert: true,  note: "OOV name: икфтвщт → brandon"),
            Case(keys: ";bpym", source: en, expectConvert: true,    note: "punct keys: ;bpym → жизнь"),

            // -- OOV anti-cases: correct rare text must NOT be converted.
            Case(keys: "fylhtq", source: ru, expectConvert: false,  note: "андрей typed correctly → keep"),
            Case(keys: "vibecoding", source: en, expectConvert: false, note: "OOV slang typed correctly → keep"),
            Case(keys: "cvepb", source: ru, expectConvert: false,   note: "смузи (OOV loanword) typed correctly → keep"),
            Case(keys: "sdfgsdfg", source: en, expectConvert: false, note: "keyboard mash → keep"),
            Case(keys: "brandon", source: en, expectConvert: false, note: "brandon typed correctly → keep"),

            // -- Issue #1: a real Russian word must not become punctuation
            //    junk — ",l" / ",l/" are not English words, whatever the OS
            //    spellchecker's tokenizer thinks.
            Case(keys: ",l", source: ru, expectConvert: false, note: "бд (real word) → keep, not ,l"),
            Case(keys: ",l/", source: ru, expectConvert: false, note: "бд. → keep, not ,l/"),
            // 'э' sits on the apostrophe key, so a RU word with 'э' in the
            // middle becomes a letter'letter Latin twin the spellchecker
            // rubber-stamps (it accepts single-letter tokens): "пэд" → "g'l".
            // A real word needs a ≥2-letter run, so it must be kept.
            Case(keys: "g'l", source: ru, expectConvert: false, note: "пэд (real word) → keep, not g'l"),
            // Same trap one letter longer: 'ls' is a token the spellchecker
            // accepts, so require a ≥2-letter stem before the apostrophe.
            Case(keys: "g'ls", source: ru, expectConvert: false, note: "пэды (real word) → keep, not g'ls"),
            // Domain terminology mixed into the n-gram model (tools/domain-corpora):
            // "сэмпл" now reads as plausible Russian → auto-converts, and is kept
            // when typed correctly.
            Case(keys: "c'vgk", source: en, expectConvert: true,  note: "сэмпл (domain term) → convert"),
            Case(keys: "c'vgk", source: ru, expectConvert: false, note: "сэмпл typed correctly → keep"),
            // Apostrophe words must still convert via the dictionary layer.
            Case(keys: "don't", source: ru, expectConvert: true, note: "вщтэе → don't (apostrophe allowed)"),
            // A correctly-typed word carrying trailing sentence punctuation
            // (the '.' key is 'ю' in Russian, so it stays in the buffer) must
            // not read as junk and flip to the other layout: "it." → шею.
            Case(keys: "it.", source: en, expectConvert: false, note: "it. (real word + period) → keep, not шею"),
            Case(keys: "at.", source: en, expectConvert: false, note: "at. → keep, not фею"),

            // -- Mid-word (live-trigger) evaluation on word prefixes.
            Case(keys: "ghjuhfvvb", source: en, expectConvert: true, complete: false,
                 note: "prefix: ghjuhfvvb → программи (партиал)"),
            Case(keys: "unfoll", source: ru, expectConvert: true, complete: false,
                 note: "prefix: гтащдд → unfoll"),
            Case(keys: "entit", source: en, expectConvert: false, complete: false,
                 note: "prefix of correct word → keep"),
        ]

        var pass = 0
        for c in cases {
            let st = strokes(for: c.keys)
            let asTyped = KeyTranslator.shared.interpret(st, layout: c.source)
            let decision = Decider.decide(strokes: st, source: c.source,
                                          candidates: layouts, sensitivity: c.sensitivity,
                                          isCompleteWord: c.complete)
            let converted = decision?.confident == true
            let arrow = converted ? "\(asTyped) → \(decision!.correctedText)" : "\(asTyped) (kept)"
            let ok = converted == c.expectConvert
            if ok { pass += 1 }
            print("\(ok ? "✅" : "❌") [\(c.source.primaryLanguage ?? "?")\(c.complete ? "" : ", partial")] \(arrow)   — \(c.note)")
            if !ok {
                diagnose(asTyped: asTyped, source: c.source, decision: decision,
                         complete: c.complete)
            }
        }
        print("\n\(pass)/\(cases.count) passed")

        let learnOK = runLearningTests(layouts: layouts)

        measureLatency()
        let voiceOK = voicePipelineChecks()
        return pass == cases.count && learnOK && voiceOK
    }

    // MARK: - Adaptive learning

    /// Exercises the LearnedStore end-to-end through the real Decider: forced
    /// conversions teach positive words, rejections teach keep-words, and both
    /// only take effect after `activationCount` repeats. Runs in-memory
    /// (LanguageScorer.persistLearning is false under --selftest).
    private static func runLearningTests(layouts: [KeyboardLayout]) -> Bool {
        guard let en = layouts.first(where: { ($0.primaryLanguage ?? "") == "en" || $0.id.contains("ABC") }),
              let ru = layouts.first(where: { ($0.primaryLanguage ?? "") == "ru" }) else { return true }
        let scorer = LanguageScorer.shared
        var pass = 0, total = 0
        func check(_ cond: Bool, _ desc: String) {
            total += 1; if cond { pass += 1 }
            print("\(cond ? "✅" : "❌") [learn] \(desc)")
        }
        func converts(_ keys: String, _ src: KeyboardLayout) -> Bool {
            Decider.decide(strokes: strokes(for: keys), source: src,
                           candidates: layouts, sensitivity: .balanced)?.confident == true
        }
        print("\n-- Adaptive learning (threshold \(LearnedStore.activationCount)) --")

        // Positive: a name the n-gram finds implausible ("juno", pct≈0.06).
        check(!converts("juno", ru), "before: огтщ kept (juno unknown)")
        scorer.learnPositive(word: "juno", language: "en")
        check(!converts("juno", ru), "after 1× force: still kept")
        scorer.learnPositive(word: "juno", language: "en")
        check(converts("juno", ru), "after 2× force: огтщ → juno converts")

        // Positive short loanword below the n-gram 4-char floor: "пэд".
        check(!converts("g'l", en), "before: g'l kept (пэд has no signal)")
        scorer.learnPositive(word: "пэд", language: "ru")
        scorer.learnPositive(word: "пэд", language: "ru")
        check(converts("g'l", en), "after 2× force: g'l → пэд converts")
        check(!converts("g'l", ru), "learned пэд kept when typed in RU")

        // Negative: "fylhtq"(en) → андрей converts by default; reject 2× → keep.
        check(converts("fylhtq", en), "before: fylhtq → андрей converts")
        scorer.learnNegative(word: "fylhtq", language: "en")
        check(converts("fylhtq", en), "after 1× reject: still converts")
        scorer.learnNegative(word: "fylhtq", language: "en")
        check(!converts("fylhtq", en), "after 2× reject: fylhtq kept")

        print("\(pass)/\(total) learning checks passed")
        return pass == total
    }

    // MARK: - Voice pipeline (dictation) sanity

    /// Mic-free checks of the dictation plumbing: whisper.cpp linkage, the
    /// 16 kHz resampler, WAV encoding, and transcript cleanup.
    private static func voicePipelineChecks() -> Bool {
        var ok = true
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(condition ? "✅" : "❌") voice: \(name)\(condition ? "" : "  — \(detail())")")
            if !condition { ok = false }
        }

        // whisper.cpp dylib linked and callable.
        let sysinfo = String(cString: whisper_print_system_info())
        check("whisper.cpp linked", !sysinfo.isEmpty, "empty system info")

        // Resampler: 1 s of 48 kHz sine → ~16k samples at 16 kHz.
        let sr = 48_000.0
        let sine = (0..<Int(sr)).map { Float(sin(2 * .pi * 440 * Double($0) / sr)) }
        let recording = AudioCapture.Recording(samples: sine, sampleRate: sr)
        do {
            let converted = try AudioCapture.convertTo16k(recording)
            check("resample 48k→16k count", abs(converted.count - 16_000) < 100,
                  "got \(converted.count) samples")
            let peak = converted.map(abs).max() ?? 0
            check("resample amplitude preserved", peak > 0.9 && peak <= 1.01,
                  "peak \(peak)")
        } catch {
            check("resample 48k→16k", false, "\(error)")
        }

        // WAV encoding: header fields + payload size.
        let wav = AudioCapture.wavData(samples16k: [0, 0.5, -0.5, 1])
        check("wav size", wav.count == 44 + 8, "got \(wav.count) bytes")
        check("wav RIFF/WAVE header",
              wav.prefix(4) == Data("RIFF".utf8) && wav[8..<12] == Data("WAVE".utf8))
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        check("wav sample rate 16000", UInt32(littleEndian: rate) == 16_000, "got \(rate)")

        // Transcript cleanup: artifacts stripped, real parentheses kept.
        check("clean [BLANK_AUDIO]",
              DictationController.cleanTranscript(" [BLANK_AUDIO] ").isEmpty)
        check("clean (music)-only", DictationController.cleanTranscript("(music)").isEmpty)
        check("keep real text",
              DictationController.cleanTranscript("Привет, мир (тест)!") == "Привет, мир (тест)!")

        return ok
    }

    // MARK: - Diagnostics

    private static func reportModels() {
        for lang in ["en", "ru", "uk"] {
            guard let url = NgramModel.locateModel(language: lang),
                  let model = NgramModel(contentsOf: url) else {
                print("⚠️  n-gram model for \(lang): NOT FOUND — OOV layer disabled")
                continue
            }
            print("n-gram model \(lang): \(String(format: "%.2f", Double(model.sizeBytes) / 1e6)) MB at \(url.path)")
        }
    }

    private static func diagnose(asTyped: String, source: KeyboardLayout,
                                 decision: Decider.Decision?, complete: Bool) {
        let scorer = LanguageScorer.shared
        let srcLang = source.primaryLanguage ?? "en"
        let t = scorer.score(asTyped, language: srcLang, completeWord: complete)
        print("     typed \(asTyped)[\(srcLang)]: dict=\(t.isDictionaryWord) common=\(t.isCommonWord) learned=\(t.isLearnedWord) keep=\(t.isKeepWord) ngramP=\(t.ngramPercentile.map { String(format: "%.4f", $0) } ?? "nil") foreign=\(t.ngramForeign)")
        if let d = decision {
            let lang = d.target.primaryLanguage ?? "?"
            let c = scorer.score(d.correctedText, language: lang, completeWord: complete)
            print("     cand  \(d.correctedText)[\(lang)]: dict=\(c.isDictionaryWord) common=\(c.isCommonWord) learned=\(c.isLearnedWord) keep=\(c.isKeepWord) ngramP=\(c.ngramPercentile.map { String(format: "%.4f", $0) } ?? "nil") foreign=\(c.ngramForeign)")
        }
    }

    private static func measureLatency() {
        guard let url = NgramModel.locateModel(language: "ru"),
              let model = NgramModel(contentsOf: url) else { return }
        let words = ["привет", "андрей", "клавиатура", "ызфышищ", "программист",
                     "тусовка", "смузи", "перплексия", "ждлоа", "выфпролд"]
        let iterations = 2_000
        let start = DispatchTime.now()
        var sink = 0.0
        for i in 0..<iterations {
            sink += model.percentile(of: words[i % words.count], complete: true) ?? 0
        }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
        print(String(format: "n-gram scoring: %.1f µs/word (avg over %d, checksum %.1f)",
                     ns / Double(iterations) / 1000, iterations, sink))
    }
}
