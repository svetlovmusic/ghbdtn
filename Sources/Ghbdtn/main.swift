import AppKit

// ghbdtn — a local, private keyboard-layout auto-switcher for macOS.
// Entry point: a plain AppKit application driven by AppDelegate. We avoid the
// SwiftUI @main App lifecycle so we have full control over the agent
// (menu-bar-only) behavior and the CGEventTap run loop.

// Headless self-test for the detection logic: `ghbdtn --selftest`.
// Exits non-zero when any case fails, so it can gate commits/CI.
// Diagnostic: load the REAL learned.json and run the Decider on given keys.
if CommandLine.arguments.contains("--learncheck") {
    exit(SelfTest.learnCheck() ? 0 : 1)
}

if CommandLine.arguments.contains("--selftest") {
    // Keep learned-word tests in-memory: never read or write the user's file.
    LanguageScorer.persistLearning = false
    exit(SelfTest.run() ? 0 : 1)
}

// Validation probe for the on-demand cloud correction backend:
// `ghbdtn --correct-eval [--model <name>]`. Reads tools/correct-eval/{config,examples}.
if CommandLine.arguments.contains("--correct-eval") {
    exit(CorrectEval.runBlocking() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
