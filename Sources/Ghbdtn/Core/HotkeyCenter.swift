import Foundation
import Carbon
import AppKit

/// Registers global shortcuts using Carbon's RegisterEventHotKey (reliable,
/// works without the event tap and independent of the frontmost app).
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    enum Action: UInt32 {
        case manualConvert = 1
        case voiceDictation = 2
        /// Registered only while a dictation session is live (it may be a
        /// bare key like Escape — must never be captured globally).
        case voiceCancel = 3
    }

    private var handlers: [Action: () -> Void] = [:]
    private var registered: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {}

    func onAction(_ action: Action, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// Install the Carbon event handler (once) and register the current hotkeys.
    func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = Action(rawValue: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { center.handlers[action]?() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    /// (Re)register a single action's hotkey. Unregisters any previous binding.
    func register(_ action: Action, hotkey: Hotkey) {
        if let existing = registered[action] {
            UnregisterEventHotKey(existing)
            registered[action] = nil
        }
        guard hotkey.enabled, !(hotkey.keyCode == 0 && hotkey.modifiers == 0) else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x47484244), id: action.rawValue) // 'GHBD'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[action] = ref
        } else {
            Log.error("RegisterEventHotKey failed for \(action): \(status)")
        }
    }

    func unregister(_ action: Action) {
        if let ref = registered[action] {
            UnregisterEventHotKey(ref)
            registered[action] = nil
        }
    }

    func unregisterAll() {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }
}
