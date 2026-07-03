import Foundation
import CoreGraphics
import AppKit
import Carbon

/// Synthesizes keyboard events: deleting the just-typed word and retyping it
/// as the correct-layout text. All events we post are tagged with a magic
/// marker so the event tap ignores them (no feedback loop).
final class TextInjector {
    static let shared = TextInjector()

    /// Marker stamped into `.eventSourceUserData` of every synthetic event.
    static let magicMarker: Int64 = 0x6768_6264_746E // "ghbdtn"

    private let source: CGEventSource?

    private init() {
        source = CGEventSource(stateID: .privateState)
        // Suppress local keyboard events only very briefly while we type;
        // default interval is 0.25s which feels laggy.
        source?.localEventsSuppressionInterval = 0.01
    }

    /// Replace the last `count` typed characters with `text`:
    /// deletes backwards, then types the replacement as Unicode events
    /// (layout-independent), optionally switching the system layout first.
    ///
    /// - Parameters:
    ///   - deleteCount: number of characters to delete (the misinterpreted word
    ///     plus any delimiter that was already typed).
    ///   - text: replacement text, typed after the deletions.
    ///   - switchToLayoutID: layout to activate before typing, so the user
    ///     continues in the right language.
    func replaceText(deleteCount: Int, with text: String, switchToLayoutID: String?) {
        if let layoutID = switchToLayoutID {
            LayoutManager.shared.select(layoutID: layoutID)
        }
        // Deletions
        for _ in 0..<deleteCount {
            postKey(keyCode: UInt16(kVK_Delete))
        }
        typeUnicode(text)
    }

    /// Type an arbitrary string as synthetic Unicode key events. Works
    /// regardless of the active layout because the characters ride in the
    /// event payload, not in the keycode.
    func typeUnicode(_ text: String) {
        // Chunk to stay well under the CGEvent Unicode payload limit and to
        // keep apps that process events slowly (Electron) from dropping input.
        let chunkSize = 16
        var units = Array(text.utf16)
        while !units.isEmpty {
            let chunk = Array(units.prefix(chunkSize))
            units.removeFirst(chunk.count)

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            stampAndPost(down)
            stampAndPost(up)
        }
    }

    /// Press-and-release of a single (unmodified) key.
    func postKey(keyCode: UInt16, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        stampAndPost(down)
        stampAndPost(up)
    }

    // MARK: - Selection conversion (manual hotkey on selected text)

    /// Convert the currently selected text between two layouts using the
    /// pasteboard: ⌘C → transform → ⌘V, preserving the user's clipboard.
    func convertSelection(from source: KeyboardLayout, to target: KeyboardLayout,
                          completion: @escaping (Bool) -> Void) {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
        let changeCountBefore = pasteboard.changeCount

        postKey(keyCode: UInt16(kVK_ANSI_C), flags: .maskCommand)

        // Give the frontmost app time to service the copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { completion(false); return }
            guard pasteboard.changeCount != changeCountBefore,
                  let selected = pasteboard.string(forType: .string), !selected.isEmpty else {
                // Nothing was selected; restore and bail.
                Self.restore(pasteboard: pasteboard, items: savedItems)
                completion(false)
                return
            }
            let converted = KeyTranslator.shared.convert(selected, from: source, to: target)
            pasteboard.clearContents()
            pasteboard.setString(converted, forType: .string)
            self.postKey(keyCode: UInt16(kVK_ANSI_V), flags: .maskCommand)

            // Restore the user's clipboard after the paste lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Self.restore(pasteboard: pasteboard, items: savedItems)
                completion(true)
            }
        }
    }

    private static func restore(pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Private

    private func stampAndPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.magicMarker)
        event.post(tap: .cghidEventTap)
    }
}
