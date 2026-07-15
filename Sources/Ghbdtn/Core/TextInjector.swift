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

    /// Paste `text` at the caret via the clipboard (⌘V). Used for dictation
    /// output: one atomic paste is far more reliable for long/multilingual
    /// text than hundreds of synthetic key events (which slow apps can drop
    /// or reorder).
    ///
    /// - Parameter keepOnClipboard: when true, the text intentionally REPLACES
    ///   the clipboard and stays there (safety net: if the paste didn't land,
    ///   the user recovers it with ⌘V). When false, the previous clipboard is
    ///   restored after a grace period.
    func paste(_ text: String, keepOnClipboard: Bool = false) {
        let pasteboard = NSPasteboard.general
        pendingRestore?.cancel()
        pendingRestore = nil
        let savedItems = keepOnClipboard ? [] : Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourWrite = pasteboard.changeCount
        postKey(keyCode: keyCode(for: "v"), flags: .maskCommand)
        if !keepOnClipboard {
            scheduleRestore(pasteboard: pasteboard, items: savedItems, ourChangeCount: ourWrite)
        }
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
    /// The from/to arguments are the caller's guess (usually current layout →
    /// other); the actual direction is re-oriented by the selection's own
    /// script once the text is read — right after an auto-switch the current
    /// system layout says nothing about what the selected text is written in.
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
            let (src, dst) = Self.orient(selection: selected, source: source, target: target)
            let converted = KeyTranslator.shared.convert(selected, from: src, to: dst)
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

    // MARK: - On-demand recovery capture (correct selection, or whole field)

    /// The user's clipboard, held between `beginRecovery` and
    /// `commitRecovery`/`cancelRecovery`. Main-thread only; a single in-flight
    /// recovery is enforced by RecoveryController's own guard.
    private var recoverySavedItems: [NSPasteboardItem]?

    /// Capture the text to correct: the current selection via a synthetic ⌘C,
    /// or — when nothing is selected — the WHOLE focused field via ⌘A then ⌘C.
    /// The user's clipboard is snapshotted and held until commit/cancel.
    /// `completion` receives the captured text, or nil if there was nothing to
    /// grab (in which case the clipboard is already restored).
    ///
    /// Caller must ensure no modifier keys are held — a synthetic ⌘C merges
    /// with them otherwise.
    func beginRecovery(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        pendingRestore?.cancel()
        pendingRestore = nil
        let savedItems = Self.snapshot(of: pasteboard)
        recoverySavedItems = savedItems
        let changeBefore = pasteboard.changeCount

        postKey(keyCode: keyCode(for: "c"), flags: .maskCommand) // copy selection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { completion(nil); return }
            if pasteboard.changeCount != changeBefore,
               let selected = pasteboard.string(forType: .string), !selected.isEmpty {
                completion(selected)
                return
            }
            // Nothing selected → select the whole field and copy that.
            self.postKey(keyCode: self.keyCode(for: "a"), flags: .maskCommand)
            self.postKey(keyCode: self.keyCode(for: "c"), flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if pasteboard.changeCount != changeBefore,
                   let all = pasteboard.string(forType: .string), !all.isEmpty {
                    completion(all)
                } else {
                    self.cancelRecovery()   // nothing to correct — put clipboard back
                    completion(nil)
                }
            }
        }
    }

    /// Paste `corrected` over the still-selected captured text. A single ⌘V is
    /// one undo group, so one ⌘Z reverts the whole correction. The user's
    /// clipboard is restored after a grace period.
    func commitRecovery(_ corrected: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = recoverySavedItems ?? []
        recoverySavedItems = nil
        pasteboard.clearContents()
        pasteboard.setString(corrected, forType: .string)
        let ourWrite = pasteboard.changeCount
        postKey(keyCode: keyCode(for: "v"), flags: .maskCommand)
        scheduleRestore(pasteboard: pasteboard, items: savedItems, ourChangeCount: ourWrite)
    }

    /// Abandon a capture without pasting: restore the user's clipboard now.
    func cancelRecovery() {
        guard let items = recoverySavedItems else { return }
        recoverySavedItems = nil
        Self.restore(pasteboard: NSPasteboard.general, items: items)
    }

    /// Pick the conversion direction from the selection's own script: convert
    /// FROM the layout whose script the text is currently written in. Only
    /// swaps the two layouts the caller already chose; an even/unclear mix
    /// keeps the caller's order.
    private static func orient(selection: String, source: KeyboardLayout,
                               target: KeyboardLayout) -> (KeyboardLayout, KeyboardLayout) {
        func cyrillicLayout(_ l: KeyboardLayout) -> Bool {
            ["ru", "uk", "be", "bg", "sr", "mk", "kk"].contains(l.primaryLanguage ?? "")
        }
        guard cyrillicLayout(source) != cyrillicLayout(target) else { return (source, target) }
        var cyr = 0, lat = 0
        for scalar in selection.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: cyr += 1
            case 0x41...0x5A, 0x61...0x7A: lat += 1
            default: break
            }
        }
        guard cyr != lat else { return (source, target) }
        let textIsCyrillic = cyr > lat
        if textIsCyrillic == cyrillicLayout(source) { return (source, target) }
        return (target, source)
    }

    /// Keycode that produces `char` under the CURRENT layout, so synthetic
    /// ⌘V/⌘C reach the target app as the right shortcut on remapped Latin
    /// layouts (Dvorak, Colemak). Non-Latin layouts (Russian, …) have no such
    /// key — there the ANSI position is correct, since their ⌘-plane emits
    /// QWERTY Latin.
    private func keyCode(for char: Character) -> UInt16 {
        guard let layout = LayoutManager.shared.currentLayout(),
              let stroke = KeyTranslator.shared.reverseMap(for: layout)[char] else {
            switch char {
            case "c": return UInt16(kVK_ANSI_C)
            case "a": return UInt16(kVK_ANSI_A)
            default:  return UInt16(kVK_ANSI_V)
            }
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
