import Foundation
import ApplicationServices
import AppKit
import AVFoundation

/// Accessibility permission is required for the CGEventTap (to observe
/// keystrokes) and for posting synthetic events. This helper checks status and
/// opens the right System Settings pane.
enum Permissions {
    /// Is the app currently trusted for Accessibility?
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user (shows the system dialog once, then a no-op) and return
    /// current trust state.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone (dictation only)

    /// Microphone permission: true = granted, false = denied/restricted,
    /// nil = the system has never asked yet.
    static func microphoneAuthorized() -> Bool? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return nil
        default: return false
        }
    }

    /// Show the one-time system microphone prompt.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
