import Foundation
import Security

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
// A valid Developer ID signature alone doesn't guarantee a stable TCC identity:
// an explicit requirement could pin a build hash or a particular certificate.
// Gate releases on the same designated requirement as the Developer ID baseline.
func canonicalRequirement(_ requirement: SecRequirement) -> String {
    // Generated and parsed requirements may associate the same AND clauses
    // differently in binary form. Security's own text renderer normalizes that.
    var text: CFString?
    precondition(SecRequirementCopyString(requirement, [], &text) == errSecSuccess)
    return text! as String
}
func designatedRequirement(_ path: String) -> SecRequirement {
    var code: SecStaticCode?
    precondition(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess)
    var requirement: SecRequirement?
    precondition(SecCodeCopyDesignatedRequirement(code!, [], &requirement) == errSecSuccess)
    return requirement!
}
var expectedRequirement: SecRequirement?
precondition(SecRequirementCreateWithString(ReleaseTrust.appRequirement as CFString, [], &expectedRequirement) == errSecSuccess)
let identity = canonicalRequirement(designatedRequirement(app))
precondition(identity == canonicalRequirement(expectedRequirement!), "Release changed its stable permission identity")
checks += 1
print("PASS: stable designated requirement (no build hash or certificate fingerprint)")
if let index = CommandLine.arguments.firstIndex(of: "--previous-app") {
    precondition(index + 1 < CommandLine.arguments.count, "--previous-app needs a path")
    let previous = CommandLine.arguments[index + 1]
    try ReleaseTrust.verifySignature(at: previous, requirement: ReleaseTrust.appRequirement)
    precondition(identity == canonicalRequirement(designatedRequirement(previous)), "Permission identity changed between releases")
    checks += 1
    print("PASS: previous and new release have identical permission identities")
}
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
