#!/usr/bin/env bash
#
# Creates the stable local code-signing identity "CleanAppCache Local".
#
# Why it exists: the default build is ad-hoc signed, and an ad-hoc identity is
# derived from the binary's hash — it changes on EVERY rebuild. macOS ties
# Full Disk Access, folder permissions and Automation grants to the signing
# identity, so each rebuild silently revoked everything and the app re-prompted
# for the same permissions again and again.
#
# A self-signed certificate gives the app one identity for good: permissions
# granted once survive every future rebuild on this Mac. The certificate lives
# only in your login keychain and is useless for distribution (that still needs
# Developer ID + notarization).
#
# Run it once:  ./Scripts/make_signing_identity.sh
# macOS will show ONE dialog asking to confirm a change to certificate Trust
# Settings — that is you trusting your own new certificate; enter your password
# there. After that, build.py picks the identity up automatically.
#
set -euo pipefail

IDENTITY="CleanAppCache Local"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
    echo "✓ Identity '${IDENTITY}' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"

# The certificate must carry the codeSigning extended key usage or `codesign`
# will refuse it; everything else is a plain self-signed leaf.
cat > "${WORK}/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = CleanAppCache Local
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
EOF

echo "▶︎ Generating key and certificate (valid 10 years)…"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
    -config "${WORK}/cert.cnf" 2>/dev/null

# Random one-shot password just to move the pair through PKCS#12.
P12PASS="$(openssl rand -hex 16)"
# Force the legacy PKCS#12 algorithms (3DES + SHA-1 MAC). OpenSSL 3 defaults
# to AES-256/PBKDF2 with a SHA-256 MAC, which `security import` cannot parse —
# it fails with the misleading "MAC verification failed (wrong password?)".
# This only affects the throwaway transport container, not the signature.
openssl pkcs12 -export -out "${WORK}/id.p12" \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:${P12PASS}" -name "${IDENTITY}"

echo "▶︎ Importing into the login keychain…"
# -T pre-authorizes codesign so signing doesn't prompt on every build.
security import "${WORK}/id.p12" -k "${KEYCHAIN}" -P "${P12PASS}" -T /usr/bin/codesign

echo "▶︎ Trusting the certificate for code signing…"
echo "   macOS will ask you to confirm — this is you trusting your own certificate."
security add-trusted-cert -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "${IDENTITY}"; then
    echo "✓ Done. Rebuild with python3 build.py — it now signs as '${IDENTITY}'."
    echo "  Grant Full Disk Access once more to the new build; after that it sticks."
else
    echo "✗ The identity did not become valid. If you cancelled the trust dialog,"
    echo "  run this script again. Otherwise open Keychain Access → login →"
    echo "  My Certificates → '${IDENTITY}' → Trust → Code Signing: Always Trust."
    exit 1
fi
