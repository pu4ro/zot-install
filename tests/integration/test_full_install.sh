#!/usr/bin/env bash
set -euo pipefail
TEST_DATA_DIR="/tmp/zot-test-$$"
TEST_DOMAIN="zot-test.local"
TEST_IP="127.0.0.1"
TEST_PORT="15443"
cleanup() {
  docker rm -f zot 2>/dev/null || true
  rm -rf "${TEST_DATA_DIR}"
  sed -i "/${TEST_DOMAIN}/d" /etc/hosts 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Fresh install ==="
./install.sh --domain "${TEST_DOMAIN}" --ip "${TEST_IP}" --port "${TEST_PORT}" --data-dir "${TEST_DATA_DIR}"
openssl x509 -in "${TEST_DATA_DIR}/cert/server.crt" -text -noout | grep -q "DNS:${TEST_DOMAIN}"
echo "PASS: Cert has correct DNS SAN"
[ -f "${TEST_DATA_DIR}/zot/config.json" ]
echo "PASS: config.json created"
grep -q "${TEST_DOMAIN}" /etc/hosts
echo "PASS: /etc/hosts entry created"

echo "=== Duplicate install should fail ==="
if ./install.sh --domain "${TEST_DOMAIN}" --ip "${TEST_IP}" --port "${TEST_PORT}" --data-dir "${TEST_DATA_DIR}" 2>&1; then
  echo "FAIL: Should have errored"; exit 1
else
  echo "PASS: Duplicate install blocked"
fi

echo "=== Force reinstall ==="
./install.sh --domain "${TEST_DOMAIN}" --ip "${TEST_IP}" --port "${TEST_PORT}" --data-dir "${TEST_DATA_DIR}" --force
echo "PASS: Force reinstall succeeded"

echo "=== Certs-only mode ==="
rm -rf /tmp/certs-only-test
./install.sh --certs-only --ip "${TEST_IP}" --data-dir /tmp/certs-only-test
[ -f /tmp/certs-only-test/cert/server.crt ]
echo "PASS: Certs-only generated certificates"
rm -rf /tmp/certs-only-test

echo "=== ALL INTEGRATION TESTS PASSED ==="
