# Security policy

ghbdtn is a hobby macOS utility maintained by one person, distributed outside
the Mac App Store. This document states the current trust model honestly.

## Reporting a vulnerability

This is a personal project. Please report privately rather than opening a public
issue: contact the maintainer through GitHub (`@svetlovmusic`) — e.g. a DM /
profile contact, or a private Security Advisory once the repo is public and
Private Vulnerability Reporting is enabled (it is not available on this private
repo today). Include repro steps and the affected version; expect a best-effort
reply, not an SLA.

## Current trust model (know before you install)

- **No paid Apple Developer ID / notarization.** Releases are *self-signed* with
  a stable identity ("Ghbdtn Local Signing"), and since 0.6.2 the `.dmg` itself
  is signed with it too. macOS Gatekeeper will still warn on first launch,
  because only notarization removes that. Clearing the quarantine attribute from
  the single app bundle (`xattr -dr com.apple.quarantine /Applications/ghbdtn.app`,
  see the README) removes it for that one app only — grant it just to a build
  you trust (ours build from the source in this repo).
- **Where releases are built.** The `.dmg` is built, signed and uploaded from
  the maintainer's own Mac (`tools/make-dist.sh`). CI only verifies that the tag
  compiles; it never produces the artifact, because the signing key
  deliberately does not live in GitHub Actions. `tools/preflight-dist.sh` runs
  before packaging and refuses a bundle that is ad-hoc signed, lacks the
  Hardened Runtime, carries the pinned requirement wrong, or contains traces of
  the build machine.
- **What to verify before you install.** Each release note carries the SHA-256
  of the `.dmg`. The app's designated requirement is pinned to the signing
  certificate and must read exactly:
  `identifier "com.ghbdtn.app" and certificate leaf = H"a361680fa2755016c6bac34435a2cba3b12b21e9"`
  (check with `codesign -d -r- /Applications/ghbdtn.app`). Because that
  requirement is bound to a certificate rather than to a binary hash, the
  Accessibility grant now survives updates — and, by the same token, the private
  key is the one secret whose theft would let a forged build inherit your grant.
  It is stored non-extractable, offline, and never in CI.
- **Hardened Runtime is on; library validation is not.** `build.sh` signs with
  the Hardened Runtime, so `DYLD_*` injection and unsigned code are refused.
  Library validation cannot be enforced: it requires the process and every
  library it loads to share a Team ID, and a Team ID is only issued with a paid
  Developer ID. So the bundled `whisper.framework` is loaded under
  `com.apple.security.cs.disable-library-validation`. Replacing that framework
  still requires write access to the installed bundle, which macOS 14+ gates
  behind App Management.
- **The app is not sandboxed** and holds powerful TCC grants: Accessibility
  (global keyboard event tap + synthetic input) and, if you use dictation,
  Microphone. Only grant them to a build you trust.
- **Auto-update does not self-install.** Because there is no code-signing trust
  root that proves a download came from the author, the updater only *notifies*
  and opens the Releases page; it never downloads-and-swaps the app itself.
  Install updates manually. (This is gated by `UpdateChecker.selfInstallEnabled`,
  currently `false`.)
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

## Roadmap to a stronger posture

- Apple Developer ID certificate, Hardened Runtime (`--options runtime`),
  signing of nested components, and notarization.
- A Sparkle 2 updater with an embedded Ed25519 appcast key, or Developer-ID +
  Team-ID verification in the updater, before re-enabling self-install.
- Branch/tag protection rulesets, required PR checks, and signed commits/tags.

Until those land, treat releases as "trusted because you trust this author and
this repo", not "verified by Apple".
