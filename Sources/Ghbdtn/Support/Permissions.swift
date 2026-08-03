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

    // MARK: - Posting synthetic events

    /// May we post synthetic events at all? This is its own TCC bucket
    /// (`kTCCServicePostEvent`), separate from the one `AXIsProcessTrusted()`
    /// reports. Through macOS 15 an Accessibility grant implied it, so one
    /// check covered both; treating them as one is now wrong — the app can be
    /// trusted for Accessibility (the tap sees keystrokes, dictation
    /// transcribes) while every `CGEvent.post` is dropped without an error and
    /// nothing is ever typed back.
    static func canPostEvents() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Show the one-time system prompt for the post-event bucket and return the
    /// current state. A no-op once the answer is on record either way.
    @discardableResult
    static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
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
