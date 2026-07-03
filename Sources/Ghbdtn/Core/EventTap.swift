import Foundation
import CoreGraphics
import Carbon
import AppKit

/// Listen-only CGEventTap that feeds keystrokes to the engine.
///
/// Privacy note: keystrokes are interpreted in memory to detect wrong-layout
/// typing and are never persisted or sent anywhere (unless the user has
/// explicitly enabled the cloud-AI assist for ambiguous words).
final class EventTap {
    enum TapEvent {
        case key(KeyStroke, hasCommandLikeModifiers: Bool)
        case backspace
        case wordDelimiter(KeyStroke, Character?) // space / return / tab; punctuation is classified by the engine (it needs the active layout)
        case navigationOrClick                    // arrows, clicks — caret moved
        case secureInputActive
    }

    var handler: ((TapEvent) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// True while a physical (non-synthetic) event is being processed.
    private(set) var isRunning = false

    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        // `listenOnly` — we never modify events in flight; corrections are
        // posted separately. Requires Accessibility (or Input Monitoring).
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                me.process(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("Failed to create event tap — missing Accessibility permission?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        Log.info("Event tap started")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
        Log.info("Event tap stopped")
    }

    // MARK: - Processing

    private func process(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall or when the user re-locks the screen.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.info("Event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
            return
        }

        // Ignore our own synthetic events.
        if event.getIntegerValueField(.eventSourceUserData) == TextInjector.magicMarker {
            return
        }

        // Never process anything while a password field has secure input.
        if IsSecureEventInputEnabled() {
            dispatch(.secureInputActive)
            return
        }

        switch type {
        case .leftMouseDown, .rightMouseDown:
            dispatch(.navigationOrClick)

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            // Command / Control shortcuts (⌘C, ⌃A, …) are not typing. Option is
            // NOT in this set: it produces real characters (alt-graph / dead
            // keys) that we translate faithfully via KeyStroke.option.
            if flags.contains(.maskCommand) || flags.contains(.maskControl) {
                dispatch(.key(KeyStroke(keyCode: keyCode, shift: false, capsLock: false),
                              hasCommandLikeModifiers: true))
                return
            }

            let shift = flags.contains(.maskShift)
            let caps = flags.contains(.maskAlphaShift)
            let option = flags.contains(.maskAlternate)
            let stroke = KeyStroke(keyCode: keyCode, shift: shift, capsLock: caps, option: option)

            switch Int(keyCode) {
            case kVK_Delete:
                dispatch(.backspace)
            case kVK_ForwardDelete:
                // Forward-delete removes text *ahead* of the caret, which our
                // trailing-word buffer can't track — treat as a caret move.
                dispatch(.navigationOrClick)
            case kVK_Space:
                dispatch(.wordDelimiter(stroke, " "))
            case kVK_Return, kVK_ANSI_KeypadEnter:
                dispatch(.wordDelimiter(stroke, "\n"))
            case kVK_Tab:
                dispatch(.wordDelimiter(stroke, "\t"))
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                 kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Escape:
                dispatch(.navigationOrClick)
            default:
                dispatch(.key(stroke, hasCommandLikeModifiers: false))
            }

        default:
            break
        }
    }

    private func dispatch(_ event: TapEvent) {
        // The tap callback already runs on the main run loop (we added the
        // source there), so we can call straight through.
        handler?(event)
    }

    deinit {
        stop()
    }
}
