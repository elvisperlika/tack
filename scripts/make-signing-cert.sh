#!/usr/bin/env bash
# Makes the one self-signed certificate CI signs every Tack release with, and prints the two
# commands that hand it to GitHub. Run it once. Keep the .p12 it writes somewhere safe (a
# password manager): a new certificate means every user re-grants Tack's permissions once.
set -euo pipefail

OUT="$(mktemp -d)"
PASSWORD="$(openssl rand -base64 24)"
cat > "$OUT/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Tack Release
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$OUT/cert.cnf" \
  -keyout "$OUT/key.pem" -out "$OUT/cert.pem" 2>/dev/null
# The old PKCS#12 algorithms on purpose: macOS's `security import` can't read OpenSSL 3+'s
# defaults and fails with "MAC verification failed".
openssl pkcs12 -export -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -name "Tack Release" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$PASSWORD" -out "$OUT/tack-signing.p12"
rm "$OUT/key.pem" "$OUT/cert.cnf"

cat <<MSG
Certificate written to $OUT/tack-signing.p12 (valid 10 years).
Its password: $PASSWORD

Hand both to GitHub (from the repo folder):
  base64 -i "$OUT/tack-signing.p12" | gh secret set TACK_SIGNING_P12
  printf '%s' '$PASSWORD' | gh secret set TACK_SIGNING_PASSWORD

Then store the .p12 and its password somewhere safe and delete $OUT.
MSG
