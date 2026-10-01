import Foundation

/// Trust decisions shared by update staging and the release verification tests.
enum ReleaseTrust {
    // Keep aligned with tools/signing-config.sh. Pin the Apple-issued Developer
    // ID and team, not a leaf fingerprint, so certificate renewal remains possible.
    static let developerRequirement = #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "DFB46VG2X3""#
    static let appRequirement = #"identifier "com.ghbdtn.app" and "# + developerRequirement

    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static func verifySignature(at path: String, requirement: String) throws {
        let result = run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                          "--all-architectures", "-R", "=" + requirement, path])
        guard result.status == 0 else {
            throw Failure(detail: "Не удалось подтвердить подпись разработчика: \(result.output)")
        }
    }

    static func verifyNotarization(at path: String, diskImage: Bool = false) throws {
        var args = ["/usr/sbin/spctl", "--assess", "--verbose=2", "--type", diskImage ? "open" : "execute"]
        if diskImage { args += ["--context", "context:primary-signature"] }
        let result = run(args + [path])
        // Local user exceptions must not substitute for Apple's notarization.
        guard result.status == 0, result.output.contains("source=Notarized Developer ID") else {
            throw Failure(detail: "Не удалось подтвердить проверку Apple: \(result.output)")
        }
    }

    static func verifyApp(at path: String, expectedVersion: String) throws {
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        guard info?["CFBundleIdentifier"] as? String == "com.ghbdtn.app",
              info?["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw Failure(detail: "Обновление содержит другую версию или приложение")
        }
        try verifySignature(at: path, requirement: appRequirement)
        try verifyNotarization(at: path)
    }

    private static func run(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
