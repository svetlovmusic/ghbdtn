#!/bin/bash
# Requires a Developer ID signed app; pass --notarized after make-dist.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/ghbdtn.app}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/Sources/Ghbdtn/Support/ReleaseTrust.swift" "$ROOT/tests/release/main.swift" -o "$WORK/trust-tests"
"$WORK/trust-tests" "$APP" "${2:-}"
