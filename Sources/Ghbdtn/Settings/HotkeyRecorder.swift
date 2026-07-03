import SwiftUI
import AppKit
import Carbon

/// A SwiftUI control that records a global shortcut. Click it, press a combo,
/// and it stores the Carbon keycode + modifier flags into a `Hotkey` binding.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = { self.hotkey = $0 }
        button.hotkey = hotkey
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.hotkey = hotkey
    }

    final class RecorderButton: NSButton {
        var onChange: ((Hotkey) -> Void)?
        var hotkey: Hotkey = .disabled { didSet { refreshTitle() } }
        private var recording = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(beginRecording)
            refreshTitle()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }

        @objc private func beginRecording() {
            recording = true
            title = "Нажмите сочетание…"
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            // Escape cancels; Delete clears.
            if event.keyCode == UInt16(kVK_Escape) {
                recording = false; refreshTitle(); return
            }
            if event.keyCode == UInt16(kVK_Delete) {
                recording = false
                hotkey = .disabled
                onChange?(.disabled)
                return
            }
            let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier to avoid stealing plain keys.
            guard carbonMods != 0 else { NSSound.beep(); return }
            let hk = Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbonMods, enabled: true)
            recording = false
            hotkey = hk
            onChange?(hk)
        }

        override func flagsChanged(with event: NSEvent) {
            super.flagsChanged(with: event)
        }

        private func refreshTitle() {
            if recording { return }
            title = hotkey.enabled ? Self.describe(hotkey) : "Не задано"
        }

        // MARK: - Formatting

        static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var m: UInt32 = 0
            if flags.contains(.command) { m |= UInt32(cmdKey) }
            if flags.contains(.option) { m |= UInt32(optionKey) }
            if flags.contains(.control) { m |= UInt32(controlKey) }
            if flags.contains(.shift) { m |= UInt32(shiftKey) }
            return m
        }

        static func describe(_ hk: Hotkey) -> String {
            var s = ""
            if hk.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if hk.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if hk.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if hk.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            s += keyName(UInt16(hk.keyCode))
            return s
        }

        static func keyName(_ code: UInt16) -> String {
            let map: [Int: String] = [
                kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                kVK_Escape: "⎋", kVK_ANSI_V: "V", kVK_ANSI_C: "C", kVK_ANSI_A: "A",
                kVK_ANSI_S: "S", kVK_ANSI_D: "D", kVK_ANSI_L: "L", kVK_ANSI_K: "K",
                kVK_ANSI_R: "R", kVK_ANSI_T: "T", kVK_ANSI_G: "G", kVK_ANSI_B: "B",
                kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
                kVK_F5: "F5", kVK_F6: "F6", kVK_ANSI_Grave: "`"
            ]
            if let name = map[Int(code)] { return name }
            // Fall back to the layout-independent character for the keycode.
            if let layout = LayoutManager.shared.enabledLayouts().first {
                let stroke = KeyStroke(keyCode: code, shift: false, capsLock: false)
                if let ch = KeyTranslator.shared.translate(stroke, layout: layout)?.uppercased() {
                    return ch
                }
            }
            return "key\(code)"
        }
    }
}
