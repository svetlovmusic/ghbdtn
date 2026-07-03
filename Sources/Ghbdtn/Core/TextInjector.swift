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

    // MARK: - Pasteboard-based insertion

    /// The one scheduled clipboard restore, cancellable so overlapping
    /// paste/convert operations can't restore a stale snapshot over a newer
    /// pasteboard write. Main-thread only.
    private var pendingRestore: DispatchWorkItem?

    /// Paste `text` at the caret via the clipboard (⌘V), preserving the
    /// user's pasteboard contents. Used for dictation output: one atomic
    /// paste is far more reliable for long/multilingual text than hundreds of
    /// synthetic key events (which slow apps can drop or reorder).
    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pendingRestore?.cancel()
        let savedItems = Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourWrite = pasteboard.changeCount
        postKey(keyCode: keyCode(for: "v"), flags: .maskCommand)
        scheduleRestore(pasteboard: pasteboard, items: savedItems, ourChangeCount: ourWrite)
    }

    /// Restore the user's clipboard after the frontmost app has had time to
    /// service the paste. There is no API to observe "paste consumed", so the
    /// grace period errs long (slow apps read the pasteboard lazily); the
    /// restore is skipped when someone else wrote to the clipboard meanwhile
    /// (pasting itself never bumps `changeCount`).
    private func scheduleRestore(pasteboard: NSPasteboard, items: [NSPasteboardItem],
                                 ourChangeCount: Int, delay: TimeInterval = 0.8,
                                 completion: (() -> Void)? = nil) {
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRestore = nil
            if pasteboard.changeCount == ourChangeCount {
                Self.restore(pasteboard: pasteboard, items: items)
            }
            completion?()
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Selection conversion (manual hotkey on selected text)

    /// Convert the currently selected text between two layouts using the
    /// pasteboard: ⌘C → transform → ⌘V, preserving the user's clipboard.
    func convertSelection(from source: KeyboardLayout, to target: KeyboardLayout,
                          completion: @escaping (Bool) -> Void) {
        let pasteboard = NSPasteboard.general
        pendingRestore?.cancel()
        let savedItems = Self.snapshot(of: pasteboard)
        let changeCountBefore = pasteboard.changeCount

        postKey(keyCode: keyCode(for: "c"), flags: .maskCommand)

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
            let ourWrite = pasteboard.changeCount
            self.postKey(keyCode: self.keyCode(for: "v"), flags: .maskCommand)
            self.scheduleRestore(pasteboard: pasteboard, items: savedItems,
                                 ourChangeCount: ourWrite) {
                completion(true)
            }
        }
    }

    /// Keycode that produces `char` under the CURRENT layout, so synthetic
    /// ⌘V/⌘C reach the target app as the right shortcut on remapped Latin
    /// layouts (Dvorak, Colemak). Non-Latin layouts (Russian, …) have no such
    /// key — there the ANSI position is correct, since their ⌘-plane emits
    /// QWERTY Latin.
    private func keyCode(for char: Character) -> UInt16 {
        guard let layout = LayoutManager.shared.currentLayout(),
              let stroke = KeyTranslator.shared.reverseMap(for: layout)[char] else {
            return char == "c" ? UInt16(kVK_ANSI_C) : UInt16(kVK_ANSI_V)
        }
        return stroke.keyCode
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
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
