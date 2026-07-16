# Security policy

ghbdtn is a hobby macOS utility maintained by one person, distributed outside
the Mac App Store. This document states the current trust model honestly.

## Reporting a vulnerability

Please report privately, **not** in a public issue:

- open a **GitHub Security Advisory** (repo → *Security* → *Report a vulnerability*), or
- email the address on the maintainer's GitHub profile.

Include repro steps and affected version. Expect a best-effort reply — this is
a personal project, not a funded product.

## Current trust model (know before you install)

- **No paid Apple Developer ID / notarization.** Releases are *self-signed*
  (identity "Ghbdtn Local Signing") and the `.dmg` is ad-hoc signed. macOS
  Gatekeeper will warn on first launch. Clearing the quarantine attribute from
  the single app bundle (`xattr -dr com.apple.quarantine /Applications/ghbdtn.app`,
  see the README) removes it for that one app only — grant it just to a build
  you trust (ours build from the source in this repo).
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

## Roadmap to a stronger posture

- Apple Developer ID certificate, Hardened Runtime (`--options runtime`),
  signing of nested components, and notarization.
- A Sparkle 2 updater with an embedded Ed25519 appcast key, or Developer-ID +
  Team-ID verification in the updater, before re-enabling self-install.
- Branch/tag protection rulesets, required PR checks, and signed commits/tags.

Until those land, treat releases as "trusted because you trust this author and
this repo", not "verified by Apple".
