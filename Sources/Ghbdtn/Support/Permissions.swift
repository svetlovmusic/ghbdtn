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
    /// reports. The two are independent rows in TCC; the Accessibility toggle
    /// happens to set both for keyboard apps, which is why one check appeared
    /// to cover both for years.
    ///
    /// CAUTION — this answer is only live until something calls
    /// `requestPostEventAccess()`. That call latches the result inside
    /// CoreGraphics for the rest of the process (SLSTCCService caches it under
    /// a `std::call_once`), after which this function returns the frozen value
    /// and no grant given or revoked in System Settings will move it. Unlike
    /// `AXIsProcessTrusted()`, which is always live. Do not call the request on
    /// a code path that runs at launch.
    static func canPostEvents() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Show the one-time system prompt for the post-event bucket and return the
    /// current state. A no-op once the answer is on record either way.
    ///
    /// Only call this from an explicit user action, and tell the user to
    /// restart afterwards: it freezes `canPostEvents()` for this process (see
    /// above), so whatever it latches is what the UI will report until relaunch.
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
