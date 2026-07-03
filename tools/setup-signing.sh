#!/bin/bash
# Create a stable, self-signed code-signing identity for ghbdtn so the macOS
# Accessibility grant survives rebuilds.
#
# Why: build.sh signs the .app so the CGEventTap can run. macOS binds the
# Accessibility (and Input Monitoring) grant to the signature's *designated
# requirement*. Ad-hoc signing's requirement is the binary's cdhash, which
# changes on every build — so each rebuild looks like a brand-new app and the
# grant is lost. A self-signed certificate gives a cert-based requirement that
# stays identical across rebuilds, so you grant Accessibility exactly once.
#
# Idempotent: does nothing if the identity already exists. Run once:
#   ./tools/setup-signing.sh
#
# The first build after this pops a one-time keychain prompt
# ("codesign wants to use the private key …") — click **Always Allow**.
set -euo pipefail

IDENTITY="Ghbdtn Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "✓ Signing identity '$IDENTITY' already present — nothing to do."
  exit 0
fi

echo "▸ Creating self-signed code-signing certificate '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Ghbdtn Local Signing
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1

# macOS's Security.framework can't import OpenSSL 3's default PKCS#12 encryption;
# -legacy (SHA1/3DES) imports cleanly. Fall back if the flag is unavailable.
if ! openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/identity.p12" -name "$IDENTITY" -passout pass:ghbdtn >/dev/null 2>&1; then
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -name "$IDENTITY" -passout pass:ghbdtn >/dev/null 2>&1
fi

# -T /usr/bin/codesign puts codesign on the key's access list.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P ghbdtn -T /usr/bin/codesign

echo "✓ Identity '$IDENTITY' imported into the login keychain."
echo
echo "Next:"
echo "  1. Run ./build.sh (or ./build.sh run). On the FIRST signing you'll get a"
echo "     keychain prompt — click **Always Allow** (not just Allow)."
echo "  2. Grant Accessibility to the built ghbdtn.app once, in"
echo "     System Settings → Privacy & Security → Accessibility."
echo "  From then on the grant persists across rebuilds."
