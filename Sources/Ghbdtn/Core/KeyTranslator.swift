import Foundation
import Carbon

/// One physical keypress as captured from the event tap.
struct KeyStroke: Equatable {
    let keyCode: UInt16
    let shift: Bool
    /// Caps Lock state at press time (affects letters in most layouts).
    let capsLock: Bool
    /// Option/Alt held — needed to translate alt-graph characters correctly.
    let option: Bool

    init(keyCode: UInt16, shift: Bool, capsLock: Bool, option: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
        self.option = option
    }
}

/// Translates physical keycodes into characters for *any* installed layout via
/// UCKeyTranslate, and builds reverse maps (character → keystroke) so text can
/// be converted between layouts.
final class KeyTranslator {
    static let shared = KeyTranslator()

    /// character → keystroke, per layout ID. Built lazily, invalidated when
    /// the enabled-layout set changes.
    private var reverseMaps: [String: [Character: KeyStroke]] = [:]
    private let lock = NSLock()

    private init() {}

    func invalidateCaches() {
        lock.lock(); defer { lock.unlock() }
        reverseMaps.removeAll()
    }

    /// The character(s) this keystroke produces under the given layout.
    /// Dead keys are resolved to their standalone character (option
    /// `kUCKeyTranslateNoDeadKeysMask`), which is what we want for scoring.
    func translate(_ stroke: KeyStroke, layout: KeyboardLayout) -> String? {
        layout.layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let layoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            var modifiers: UInt32 = 0
            if stroke.shift { modifiers |= UInt32(shiftKey) }
            if stroke.capsLock { modifiers |= UInt32(alphaLock) }
            if stroke.option { modifiers |= UInt32(optionKey) }
            let modifierKeyState = (modifiers >> 8) & 0xFF

            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0

            let status = UCKeyTranslate(
                layoutPtr,
                stroke.keyCode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Interpret a whole keystroke sequence under a layout.
    func interpret(_ strokes: [KeyStroke], layout: KeyboardLayout) -> String {
        strokes.compactMap { translate($0, layout: layout) }.joined()
    }

    /// Convert text typed under `source` into what the same physical keys
    /// would have produced under `target`. Characters that don't exist in the
    /// source layout (digits usually map identically; emoji etc.) pass through.
    func convert(_ text: String, from source: KeyboardLayout, to target: KeyboardLayout) -> String {
        let map = reverseMap(for: source)
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            if let stroke = map[ch], let converted = translate(stroke, layout: target), !converted.isEmpty {
                out += converted
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// character → keystroke map for a layout, covering unshifted and shifted
    /// states of every key the ANSI/ISO keyboard exposes.
    func reverseMap(for layout: KeyboardLayout) -> [Character: KeyStroke] {
        lock.lock(); defer { lock.unlock() }
        if let cached = reverseMaps[layout.id] { return cached }

        var map: [Character: KeyStroke] = [:]
        // 0..<128 covers all printable keys on Mac keyboards.
        for code in UInt16(0)..<128 {
            for shift in [false, true] {
                let stroke = KeyStroke(keyCode: code, shift: shift, capsLock: false)
                guard let s = translate(stroke, layout: layout), s.count == 1,
                      let ch = s.first else { continue }
                // Prefer the unshifted stroke when both produce the same char.
                if map[ch] == nil {
                    map[ch] = stroke
                }
            }
        }
        reverseMaps[layout.id] = map
        return map
    }

    /// True when the keycode is a letter/number/punctuation key (i.e. it can
    /// contribute to a word), as opposed to function/arrow/media keys.
    static func isTypingKey(_ keyCode: UInt16) -> Bool {
        // Keycodes >= 0x33 that we still consider typing-relevant are handled
        // by the caller (space 0x31, delete 0x33, return 0x24 are control-ish).
        switch keyCode {
        case 0x24, 0x30, 0x31, 0x33, 0x35, 0x39, 0x3A...0x7F:
            return false // return, tab, space, delete, esc, caps, modifiers, F-keys, arrows...
        default:
            return keyCode < 0x33
        }
    }
}
