import Foundation
import Carbon
import AppKit

/// A snapshot of one enabled keyboard layout (TIS input source of type
/// `kTISTypeKeyboardLayout` — input methods like Pinyin are skipped because
/// they have no static key → character table we can reason about).
struct KeyboardLayout: Identifiable, Equatable {
    let id: String              // kTISPropertyInputSourceID, e.g. "com.apple.keylayout.Russian"
    let localizedName: String   // e.g. "Russian"
    /// BCP-47-ish language codes this layout primarily types, e.g. ["ru"].
    let languages: [String]
    /// Raw 'uchr' layout data used by UCKeyTranslate.
    let layoutData: Data

    static func == (lhs: KeyboardLayout, rhs: KeyboardLayout) -> Bool {
        lhs.id == rhs.id
    }

    /// Primary language code ("ru", "en", ...) or nil for e.g. Unicode Hex Input.
    var primaryLanguage: String? {
        languages.first.map { code in
            // Normalize "en-US" style codes down to the base language.
            String(code.split(separator: "-").first ?? Substring(code))
        }
    }
}

/// Wraps the Text Input Sources (TIS) API: enumerating enabled layouts,
/// reading and changing the active one.
final class LayoutManager {
    static let shared = LayoutManager()

    /// Non-zero while *we* are switching layouts so observers can tell a
    /// programmatic switch from the user pressing the layout hotkey. A depth
    /// counter (not a bool) so rapid successive select() calls don't clear each
    /// other's window early. Mutated only on the main thread.
    private var programmaticDepth = 0
    var isProgrammaticSwitch: Bool { programmaticDepth > 0 }

    private init() {}

    /// All layouts the user has enabled in System Settings › Keyboard,
    /// in system order, that expose usable key layout data.
    func enabledLayouts() -> [KeyboardLayout] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsEnabled: true
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
                as? [TISInputSource] else {
            return []
        }
        return list.compactMap { Self.snapshot(of: $0) }
    }

    /// The currently selected layout, or nil if the active source is an input
    /// method we can't model (e.g. Chinese/Japanese IME).
    ///
    /// Uses `TISCopyCurrentKeyboardInputSource` (the *actual* current source),
    /// not `…KeyboardLayoutInputSource` (which resolves the layout backing an
    /// IME and would therefore never be nil). When an IME is active the source
    /// has no 'uchr' data, so `snapshot(of:)` returns nil and we correctly
    /// stand down.
    func currentLayout() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return Self.snapshot(of: source)
    }

    /// Select the layout with the given input source ID. Returns success.
    @discardableResult
    func select(layoutID: String) -> Bool {
        let filter: [CFString: Any] = [kTISPropertyInputSourceID: layoutID as CFString]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
                as? [TISInputSource],
              let source = list.first else {
            Log.error("Layout not found: \(layoutID)")
            return false
        }
        programmaticDepth += 1
        defer {
            // The TIS change notification is delivered asynchronously; hold the
            // flag up for a beat, then release *this* switch's claim on it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.programmaticDepth = max(0, self.programmaticDepth - 1)
            }
        }
        let status = TISSelectInputSource(source)
        if status != noErr {
            Log.error("TISSelectInputSource failed: \(status)")
            return false
        }
        return true
    }

    /// Observe user-initiated layout changes (to reset typing buffers).
    func observeLayoutChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in handler() }
    }

    // MARK: - Private

    private static func snapshot(of source: TISInputSource) -> KeyboardLayout? {
        guard let sourceID = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        guard let dataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            // Input sources without 'uchr' data (handwriting, IMEs) are skipped.
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue()
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? sourceID
        let langs = (rawProperty(source, kTISPropertyInputSourceLanguages) as? [String]) ?? []
        return KeyboardLayout(
            id: sourceID,
            localizedName: name,
            languages: langs,
            layoutData: cfData as Data
        )
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        rawProperty(source, key) as? String
    }

    private static func rawProperty(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
}
