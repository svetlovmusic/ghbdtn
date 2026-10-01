# Security policy

ghbdtn is a hobby macOS utility maintained by one person, distributed outside
the Mac App Store. This document states the current trust model honestly.

## Reporting a vulnerability

Please report vulnerabilities privately through a GitHub Security Advisory if
available, or through the maintainer's profile contact (`@svetlovmusic`). Include
reproduction steps and the affected version; expect a best-effort reply, not an SLA.

## Current trust model (know before you install)

- **Developer ID and Apple notarization.** Release builds use Developer ID
  Application for the project's signing team. Both the app and DMG are notarized, with
  tickets stapled so they remain available after copying the app and offline.
  The app identifier is `com.ghbdtn.app`. Older releases through 0.6.2 predate
  this distribution process; upgrade to the first Developer ID release manually.
- **Release pipeline.** A version tag runs `.github/workflows/release.yml`:
  build, sign nested code, preflight, notarize, staple, verify, then publish.
  Manual workflow runs save verified artifacts without publishing. Failed
  signing or notarization prevents publication. The same pipeline is available
  locally via `tools/make-dist.sh`. SHA-256 accompanies each DMG.
- **Signing credentials.** The private key is stored as a password-protected
  PKCS#12 in GitHub Actions Secrets, with its password and notarization credentials
  in separate secrets. A disposable runner keychain imports the key as
  non-extractable; temporary files and the keychain are removed after the job.
  Repository administrators and workflows using those secrets are trusted.
- **Hardened Runtime and library validation are enabled.** The app and
  `whisper.framework` are signed by the same Apple team. The only release
  entitlement is microphone input; no library-validation or unsigned-code
  exceptions are enabled. Local ad-hoc development builds are not distributable
  releases and do not enable Hardened Runtime.
- **The app is not sandboxed.** Accessibility is required for global keyboard
  access and synthetic input; Microphone is required for dictation. The user
  grants these permissions in macOS. Switching from the old signature may
  require granting them again.
- **Updates authenticate the publisher.** The updater verifies the DMG before
  mounting it, then the copied app. It requires an Apple-issued Developer ID
  for the pinned team, the expected bundle ID/version, intact nested signatures,
  and Gatekeeper's `Notarized Developer ID` assessment. It preserves macOS
  quarantine metadata. Replacement is prepared and checked before exiting;
  a failed rename restores the original app. Developer builds outside the normal
  installation path open the release page instead.
- **Cloud AI and cloud dictation are opt-in and off by default.** With them off,
  nothing you type or say leaves the machine. API keys live in the Keychain
  (device-only, when-unlocked) and are only sent to the provider origin you
  configured.
- **Cloud endpoints are an allowlist in code, not a setting.** Since 0.6.2 the
  app only talks to `api.openai.com` and `api.groq.com` over https. Base URLs
  live in UserDefaults, a plain file that anything running as you can rewrite —
  before this gate, one `defaults write` pointed an app that sees every
  keystroke at an attacker's server and handed over the API key in the first
  request header. There is deliberately no override switch, because a switch
  would be writable by exactly the attacker it is meant to stop; adding a
  provider is a code change. Changing the configured host also drops the stored
  API key, so one provider's key is never offered to another.

## Further improvements

- Branch/tag protection rulesets, required PR checks, and signed commits/tags.
- A dedicated update framework such as Sparkle for richer recovery and rollout controls.
