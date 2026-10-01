import Foundation

let app = CommandLine.arguments[1]
let notarized = CommandLine.arguments.contains("--notarized")
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("ghbdtn-trust-tests-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
var checks = 0
func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Accepted unsafe update: \(label)") }
    catch { checks += 1; print("PASS: \(label)") }
}
try ReleaseTrust.verifySignature(at: app, requirement: ReleaseTrust.appRequirement)
checks += 1
print("PASS: real Developer ID signature")
rejects("another Apple team") {
    try ReleaseTrust.verifySignature(at: app,
        requirement: ReleaseTrust.appRequirement.replacingOccurrences(of: "DFB46VG2X3", with: "XXXXXXXXXX"))
}
rejects("wrong version") { try ReleaseTrust.verifyApp(at: app, expectedVersion: "99999.0.0") }
let version = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")!["CFBundleShortVersionString"] as! String
if notarized {
    try ReleaseTrust.verifyApp(at: app, expectedVersion: version)
    checks += 1
    print("PASS: notarized app")
} else {
    rejects("signed app without notarization") { try ReleaseTrust.verifyApp(at: app, expectedVersion: version) }
}
let changed = root.appendingPathComponent("changed.app").path
try fm.copyItem(atPath: app, toPath: changed)
let file = changed + "/Contents/Info.plist"
var contents = try Data(contentsOf: URL(fileURLWithPath: file))
contents.append(Data("\n".utf8))
try contents.write(to: URL(fileURLWithPath: file))
rejects("tampered sealed resource") {
    try ReleaseTrust.verifySignature(at: changed, requirement: ReleaseTrust.appRequirement)
}
let sign = Process()
sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
sign.arguments = ["--force", "--deep", "--sign", "-", changed]
try sign.run(); sign.waitUntilExit()
precondition(sign.terminationStatus == 0)
rejects("ad-hoc replacement with matching bundle ID") {
    try ReleaseTrust.verifySignature(at: changed, requirement: ReleaseTrust.appRequirement)
}
print("\(checks) release trust checks passed")
