#!/bin/bash
# Creates a self-signed code-signing identity ("WindowInvert Local Signing") in your login keychain.
# build.sh uses it automatically. A stable signature means macOS keeps the Screen Recording and
# Accessibility permissions across rebuilds (ad-hoc signatures change every build).
set -euo pipefail
NAME="WindowInvert Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists."
    exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
LEGACY=""
openssl pkcs12 -help 2>&1 | grep -q -- "-legacy" && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:windowinvert -name "$NAME"
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P windowinvert -T /usr/bin/codesign
echo "Created '$NAME'. Run ./build.sh to sign with it."
