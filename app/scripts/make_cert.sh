#!/bin/bash
# One-time: create a stable self-signed code-signing identity so macOS TCC grants
# (Accessibility / Input Monitoring) survive rebuilds. Without this, ad-hoc
# signing changes the binary's cdhash every build and every grant is lost.
set -euo pipefail

NAME="LayoutSwitcher Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# NB: no -v. A self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED) so it is
# absent from the "valid" (-v) list, but codesign signs with it fine and TCC
# keys on its (stable) leaf hash — which is the whole point.
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
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

# Non-empty p12 password: macOS `security import` fails MAC verification on an
# empty-password PKCS#12. `-legacy` (OpenSSL 3 only) keeps algorithms that the
# macOS Security framework can read; LibreSSL ignores it (not supported there).
PW="layoutswitcher"
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY="-legacy"; fi

openssl genrsa -out "$TMP/key.pem" 2048
openssl req -x509 -new -key "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PW"

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo ""
    echo "Created code-signing identity '$NAME'."
    echo "First time codesign uses it, macOS may ask for keychain access -> click 'Always Allow'."
    echo "Now run: bash scripts/build_app.sh"
else
    echo "ERROR: identity not found after import. Try Keychain Access -> Certificate Assistant" >&2
    exit 1
fi
