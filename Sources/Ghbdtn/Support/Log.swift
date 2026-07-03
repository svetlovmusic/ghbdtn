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

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }
}
