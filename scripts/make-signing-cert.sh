#!/bin/bash
# Creates a local code-signing identity "Tempo Local Signing" in the login keychain (once).
# Builds signed with the same identity keep the same code signature, so macOS remembers the
# Keychain "Always Allow" for the API token across rebuilds. The certificate is self-signed and
# only for local builds; for a clean install on other Macs, use a Developer ID (see README).
set -euo pipefail
NAME="Tempo Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="tempo-$RANDOM$RANDOM"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null
# -T /usr/bin/codesign: codesign may use the key without a prompt.
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\"."
