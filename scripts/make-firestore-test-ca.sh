#!/bin/bash
# Generates a throwaway test CA and a server certificate for 127.0.0.1,
# installs the CA into the System keychain so the Firestore client's
# default TLS credentials trust it, and exports the server cert/key paths
# for the CV-C59 TLS demo test.
#
# This exists only for the demo: the CA is generated fresh on every run,
# lives only on the runner, and is never committed anywhere. The server
# certificate has an IP SAN for 127.0.0.1, which must match the host string
# in settings.host exactly.
#
# Usage: bash scripts/make-firestore-test-ca.sh
# Outputs (via $GITHUB_ENV when present, else stdout):
#   FIRESTORE_DEMO_TLS_CERT, FIRESTORE_DEMO_TLS_KEY

set -euo pipefail

OUT_DIR="${RUNNER_TEMP:-/tmp}/firestore-demo-ca"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# Test CA, valid 2 days.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout ca-key.pem -out ca.pem -days 2 \
  -subj "/CN=Firestore Demo Test CA" 2>/dev/null

# Server key + CSR with an IP SAN for 127.0.0.1.
openssl req -newkey rsa:2048 -nodes \
  -keyout server-key.pem -out server.csr \
  -subj "/CN=127.0.0.1" 2>/dev/null
printf "subjectAltName=IP:127.0.0.1\n" > server-ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out server.pem -days 2 -extfile server-ext.cnf 2>/dev/null

# Trust the test CA for this run only.
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ca.pem

echo "FIRESTORE_DEMO_TLS_CERT=$OUT_DIR/server.pem" >> "${GITHUB_ENV:-/dev/null}"
echo "FIRESTORE_DEMO_TLS_KEY=$OUT_DIR/server-key.pem" >> "${GITHUB_ENV:-/dev/null}"
echo "Test CA installed; server cert: $OUT_DIR/server.pem"
