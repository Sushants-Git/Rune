#!/usr/bin/env bash
# Generate the certificate Rune's releases are signed with.
#
#   ./scripts/make-signing-cert.sh
#
# Run this once, ever, and then keep the .p12 somewhere you will not lose it.
#
# Why any of this exists
# ---------------------
# macOS records every permission you grant an app — Documents, Desktop, Full
# Disk Access — against that app's *designated requirement*. For an ad-hoc
# signature the requirement is the cdhash of that exact build:
#
#     designated => cdhash H"bb77641afda875b8ded08e2320f211a72ff38075"
#
# So every release was a different app as far as macOS was concerned, and every
# permission had to be granted again after every update. Signed with a real
# certificate the requirement instead reads
#
#     designated => identifier "com.rune.rune" and certificate leaf = H"b8312c…"
#
# which is identical for every build ever signed with this certificate.
#
# That is also why regenerating it is not a free action: a new certificate is a
# new requirement, and every user's permissions reset one final time. Back the
# .p12 up rather than making another one.
#
# This is a self-signed certificate, not an Apple Developer ID. It fixes the
# permissions problem and nothing else: Gatekeeper still refuses the download
# until the quarantine flag is cleared, exactly as it does today.
set -euo pipefail

OUT="${OUT:-$HOME/rune-signing}"
NAME="${NAME:-Rune}"
DAYS="${DAYS:-7300}"  # 20 years — an expired certificate resets everyone.

if [ -e "$OUT/Rune.p12" ]; then
  echo "error: $OUT/Rune.p12 already exists." >&2
  echo "Signing with a *different* certificate resets every user's" >&2
  echo "permissions, so this refuses to overwrite. Move it aside if you" >&2
  echo "genuinely mean to start over." >&2
  exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
# No pipe into `head`: it closes early, `tr` takes a SIGPIPE, and `pipefail`
# turns that into a silent exit before anything is written.
PASSWORD="$(openssl rand -hex 24)"

# Both extensions are load-bearing. Without `digitalSignature` the identity
# imports but codesign rejects it as "Invalid Key Usage for policy", and
# without `codeSigning` it is not a signing identity at all.
openssl req -newkey rsa:2048 -nodes \
  -keyout "$OUT/key.pem" -x509 -days "$DAYS" -out "$OUT/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# The legacy algorithms are not optional: Sequoia's `security import` cannot
# read a PKCS#12 written with OpenSSL 3's defaults and fails with a MAC
# verification error that reads like a wrong password.
openssl pkcs12 -export \
  -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -out "$OUT/Rune.p12" \
  -passout "pass:$PASSWORD" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

rm -f "$OUT/key.pem"
chmod 600 "$OUT/Rune.p12"
printf '%s' "$PASSWORD" > "$OUT/password.txt"
chmod 600 "$OUT/password.txt"
base64 < "$OUT/Rune.p12" > "$OUT/Rune.p12.base64"
chmod 600 "$OUT/Rune.p12.base64"

cat <<EOF

Certificate written to $OUT

  Rune.p12            the certificate and its private key — back this up
  password.txt        its password
  Rune.p12.base64     the same file, ready to paste into a GitHub secret

Add two repository secrets (Settings → Secrets and variables → Actions):

  RUNE_SIGNING_P12           the contents of Rune.p12.base64
  RUNE_SIGNING_P12_PASSWORD  the contents of password.txt

  gh secret set RUNE_SIGNING_P12 < "$OUT/Rune.p12.base64"
  gh secret set RUNE_SIGNING_P12_PASSWORD < "$OUT/password.txt"

Once the secrets are set, delete Rune.p12.base64 — it is only a copy of the
same key in a form convenient for pasting, and it can be regenerated.

Keep Rune.p12 and password.txt **together**, somewhere backed up. The .p12 is
encrypted with that password and GitHub secrets cannot be read back, so
throwing the password away leaves you with a file nobody can open — and no way
to sign a release that keeps your users' permissions.

Anyone holding this key can sign a binary that inherits the permissions your
users have granted Rune. Treat it like a password.
EOF
