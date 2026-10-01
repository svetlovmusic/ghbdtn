#!/bin/bash
# Shared release identity. Keep the trust requirement in ReleaseTrust.swift in sync.
DEVELOPER_TEAM_ID="DFB46VG2X3"
DEVELOPER_REQUIREMENT='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "DFB46VG2X3"'
# shellcheck disable=SC2034 # consumed by scripts that source this file
RELEASE_REQUIREMENT="identifier \"com.ghbdtn.app\" and $DEVELOPER_REQUIREMENT"

resolve_signing_identity() {
  local requested identities
  requested="${SIGNING_IDENTITY:-Developer ID Application: ALIAKSEI SHABLOUSKI (DFB46VG2X3)}"
  identities="$(security find-identity -v -p codesigning)"
  SIGN_SHA1="$(printf '%s\n' "$identities" | awk -v wanted="$requested" '
    /"Developer ID Application: .*\(DFB46VG2X3\)"/ {
      name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
      if ($2 == toupper(wanted) || name == wanted) { print $2; exit }
    }')"
  if [ -z "$SIGN_SHA1" ] && { [ "${GHBDTN_REQUIRE_DEVELOPER_ID:-0}" = "1" ] || [ -n "${SIGNING_IDENTITY:-}" ]; }; then
    echo "✗ Developer ID Application for team $DEVELOPER_TEAM_ID not found: $requested" >&2
    return 1
  fi
}
