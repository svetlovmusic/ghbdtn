import AppKit

// ghbdtn — a local, private keyboard-layout auto-switcher for macOS.
// Entry point: a plain AppKit application driven by AppDelegate. We avoid the
// SwiftUI @main App lifecycle so we have full control over the agent
// (menu-bar-only) behavior and the CGEventTap run loop.

// Headless self-test for the detection logic: `ghbdtn --selftest`.
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
