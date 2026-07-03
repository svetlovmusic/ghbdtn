import Foundation

/// Headless diagnostic exercised via `ghbdtn --selftest`. Runs the REAL
/// Decider + LanguageScorer against known keystroke sequences so detection
/// behavior can be validated without the GUI. Physical keycodes are shared
/// across layouts, so the same keys yield "ghbdtn" under ABC and "привет"
/// under Russian — exactly the case the user tests.
enum SelfTest {
    // Virtual keycodes for common letters.
    static let k: [Character: UInt16] = [
        "g": 0x05, "h": 0x04, "b": 0x0B, "d": 0x02, "t": 0x11, "n": 0x2D,
        "e": 0x0E, "l": 0x25, "o": 0x1F, "w": 0x0D, "r": 0x0F, "s": 0x01,
        "a": 0x00, "c": 0x08, "p": 0x23, "i": 0x22, "v": 0x09, "m": 0x2E
    ]

    static func strokes(for latin: String) -> [KeyStroke] {
        latin.compactMap { ch in k[ch].map { KeyStroke(keyCode: $0, shift: false, capsLock: false) } }
    }

    static func run() {
        let layouts = LayoutManager.shared.enabledLayouts()
        print("Enabled layouts: \(layouts.map { "\($0.localizedName)[\($0.primaryLanguage ?? "?")]" }.joined(separator: ", "))")
        guard layouts.count >= 2 else {
            print("⚠️  Need at least 2 layouts enabled to test. Aborting."); return
        }
        // Give the async bigram seeding a moment (not required for the dict/
        // common-word signals, but harmless).
        Thread.sleep(forTimeInterval: 0.5)

        func find(_ needle: String) -> KeyboardLayout? {
            layouts.first { $0.id.lowercased().contains(needle) || ($0.primaryLanguage ?? "") == needle }
        }
        guard let en = find("en") ?? layouts.first(where: { $0.id.contains("ABC") }),
              let ru = find("ru") ?? layouts.first(where: { $0.id.lowercased().contains("russian") }) else {
            print("⚠️  Could not find both an English and a Russian layout."); return
        }

        struct Case { let keys: String; let source: KeyboardLayout; let expectConvert: Bool; let note: String }
        let cases: [Case] = [
            Case(keys: "ghbdtn", source: en, expectConvert: true,  note: "ghbdtn → привет (flagship)"),
            Case(keys: "ghbdtn", source: ru, expectConvert: false, note: "привет typed correctly → keep"),
            Case(keys: "hello",  source: ru, expectConvert: true,  note: "руддщ → hello"),
            Case(keys: "hello",  source: en, expectConvert: false, note: "hello typed correctly → keep"),
            Case(keys: "world",  source: en, expectConvert: false, note: "world typed correctly → keep"),
            Case(keys: "spasibo",source: ru, expectConvert: false, note: "cgfcb,j (has punct) → keep/none")
        ]

        var pass = 0
        for c in cases {
            let st = strokes(for: c.keys)
            let asTyped = KeyTranslator.shared.interpret(st, layout: c.source)
            let decision = Decider.decide(strokes: st, source: c.source,
                                          candidates: layouts, sensitivity: .balanced)
            let converted = decision?.confident == true
            let arrow = converted ? "\(asTyped) → \(decision!.correctedText)" : "\(asTyped) (kept)"
            let ok = converted == c.expectConvert
            if ok { pass += 1 }
            print("\(ok ? "✅" : "❌") [\(c.source.primaryLanguage ?? "?")] \(arrow)   — \(c.note)")
        }
        print("\n\(pass)/\(cases.count) passed")
    }
}
