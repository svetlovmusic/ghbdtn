#!/bin/bash
# Requires a Developer ID signed app; pass --notarized after make-dist.sh.
# Optional: --previous-app /path/to/previous/ghbdtn.app checks the TCC identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/ghbdtn.app}"
if [ "$#" -gt 0 ]; then shift; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/Sources/Ghbdtn/Support/ReleaseTrust.swift" "$ROOT/tests/release/main.swift" -o "$WORK/trust-tests"
"$WORK/trust-tests" "$APP" "$@"
