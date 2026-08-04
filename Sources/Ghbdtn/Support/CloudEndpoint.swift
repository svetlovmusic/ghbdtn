import Foundation

/// Where the app is allowed to send text and audio.
///
/// The base URLs live in UserDefaults, which is a plain file owned by the user
/// — anything running as that user can rewrite it. Before this gate an attacker
/// needed no TCC grant of their own: one `defaults write com.ghbdtn.app
/// aiBaseURL https://theirs.example` turned an app that already sees every
/// keystroke into an exfiltration channel, and handed over the API key in the
/// Authorization header of the very first request.
///
/// So the set of reachable hosts is a COMPILE-TIME constant, not a setting.
/// There is deliberately no UserDefaults escape hatch: an override switch would
/// be writable by exactly the attacker it is meant to stop. Adding a provider
/// is a code change, which is a signed release.
///
/// The gate lives at the point of use, not in the settings UI, so a value
/// written straight into the defaults file is refused just the same.
enum CloudEndpoint {
    /// Hosts the app may talk to. These are the providers the settings UI
    /// itself offers; anything else is refused with a visible reason.
    static let allowedHosts: Set<String> = [
        "api.openai.com",
        "api.groq.com",
    ]

    /// Lowercased host of an https URL, or nil if the string is not an https
    /// URL with a host. Rejects http:// (cleartext), file://, and garbage.
    static func host(of urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// May the app send anything to this base URL?
    static func isAllowed(_ urlString: String) -> Bool {
        guard let host = host(of: urlString) else { return false }
        return allowedHosts.contains(host)
    }

    /// Human-readable reason a base URL was refused, for the settings row and
    /// the failure HUD. Nil when the URL is fine.
    static func rejectionReason(_ urlString: String) -> String? {
        guard let host = host(of: urlString) else {
            return "Адрес должен быть https и содержать имя хоста"
        }
        guard allowedHosts.contains(host) else {
            return "Хост \(host) не в списке разрешённых (\(allowedHosts.sorted().joined(separator: ", ")))"
        }
        return nil
    }
}
