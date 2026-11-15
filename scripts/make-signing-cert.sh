#!/bin/bash
# One-time: creates the self-signed code signing certificate "TakeItEasy Self-Signed" (valid 10 years)
# in the login keychain, and a backup signing.p12 in $BACKUP_DIR (default ~/TakeItEasy-signing, outside
# the repo and iCloud). Password from $P12_PASSWORD, else asked.
# Same certificate on every release = macOS keeps the users' permissions across updates.
set -euo pipefail
NAME="TakeItEasy Self-Signed"
KEYCHAIN=~/Library/Keychains/login.keychain-db
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "«$NAME» exists already: nothing to do." && exit 0
fi
BACKUP_DIR=${BACKUP_DIR:-~/TakeItEasy-signing}
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
P12="$BACKUP_DIR/signing.p12"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
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
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
PASS=${P12_PASSWORD:-}
[ -n "$PASS" ] || { read -r -s -p "Password for the backup signing.p12: " PASS; echo; }
# -legacy: the macOS keychain can't read OpenSSL 3's default p12 encryption.
LEGACY=$(openssl version | grep -q '^OpenSSL 3' && echo -legacy || true)
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$P12" -passout pass:"$PASS"
chmod 600 "$P12"
security import "$P12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security find-identity -p codesigning | grep "$NAME"
echo "Done. Keep $P12 and its password safe: losing them = users re-grant permissions once."
