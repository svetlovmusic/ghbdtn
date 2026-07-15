import Foundation
import os

/// Lightweight logging wrapper. Uses the unified logging system so output is
/// visible in Console.app filtered by subsystem `com.ghbdtn.app`.
enum Log {
    private static let logger = Logger(subsystem: "com.ghbdtn.app", category: "core")

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    /// A technical message plus a payload containing the USER'S TEXT (typed
    /// words, corrections). The payload is logged `.private`: Console.app and
    /// `log show` render it as <private> unless private-data logging is
    /// explicitly enabled on the machine — this is what keeps the README's
    /// "keystrokes are never logged" promise while diagnostics stay useful.
    static func info(_ message: @autoclosure () -> String,
                     sensitive: @autoclosure () -> String) {
        let text = message()
        let payload = sensitive()
        logger.info("\(text, privacy: .public): \(payload, privacy: .private)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }
}
