import Foundation

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
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "[": 0x21, "]": 0x1E
    ]

    static func strokes(for keys: String) -> [KeyStroke] {
        keys.compactMap { ch in k[ch].map { KeyStroke(keyCode: $0, shift: false, capsLock: false) } }
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

        measureLatency()
        return pass == cases.count
    }

    // MARK: - Diagnostics

    private static func reportModels() {
        for lang in ["en", "ru"] {
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
        print("     typed \(asTyped)[\(srcLang)]: dict=\(t.isDictionaryWord) common=\(t.isCommonWord) ngramP=\(t.ngramPercentile.map { String(format: "%.4f", $0) } ?? "nil") foreign=\(t.ngramForeign)")
        if let d = decision {
            let lang = d.target.primaryLanguage ?? "?"
            let c = scorer.score(d.correctedText, language: lang, completeWord: complete)
            print("     cand  \(d.correctedText)[\(lang)]: dict=\(c.isDictionaryWord) common=\(c.isCommonWord) ngramP=\(c.ngramPercentile.map { String(format: "%.4f", $0) } ?? "nil") foreign=\(c.ngramForeign)")
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
