#!/bin/bash
# One-time: create a stable self-signed code-signing identity so macOS TCC grants
# (Accessibility / Input Monitoring) survive rebuilds. Without this, ad-hoc
# signing changes the binary's cdhash every build and every grant is lost.
set -euo pipefail

NAME="LayoutSwitcher Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl genrsa -out "$TMP/key.pem" 2048
openssl req -x509 -new -key "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo ""
echo "Created code-signing identity '$NAME'."
echo "First time codesign uses it, macOS may ask for keychain access → click 'Always Allow'."
echo "Now run: bash scripts/build_app.sh"
