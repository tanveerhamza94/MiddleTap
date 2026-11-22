#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate in your login keychain.
# Signing every build with the same certificate lets macOS remember MiddleTap's
# Accessibility permission across rebuilds.
set -euo pipefail

NAME="MiddleTap Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # Apple's LibreSSL makes a .p12 that `security import` accepts

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Certificate \"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:middletap

security import "$TMP/id.p12" -k "$KEYCHAIN" -P middletap -T /usr/bin/codesign
echo
echo "Marking the certificate as trusted for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Done. \"$NAME\" is ready. Run ./build.sh --install."
