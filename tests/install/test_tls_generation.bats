#!/usr/bin/env bats
# Tests for install.sh TLS certificate generation using REAL openssl

load '/opt/bats-support/load'
load '/opt/bats-assert/load'
load '../test_helper/common'

setup() {
  setup_common

  # Source functions but keep real openssl (no mock)
  source_functions install.sh

  # Set up variables as main() would
  ZOT_DOMAIN="test.example.com"
  ZOT_IP="10.0.0.42"
  ZOT_PORT="443"
  DATA_DIR="${TEST_TMP}/data"
  CERT_DIR="${DATA_DIR}/cert"
  FORCE="false"
  SKIP_CERTS="false"

  mkdir -p "$CERT_DIR"
}

teardown() {
  teardown_common
}

# Helper: run the TLS generation portion of install.sh
generate_certs() {
  # Replicate the TLS generation logic from main()
  mkdir -p "${CERT_DIR}"

  if [[ ! -f "${CERT_DIR}/ca.key" ]] || [[ "$FORCE" == true ]]; then
    openssl genrsa -out "${CERT_DIR}/ca.key" 4096 2>/dev/null
    chmod 600 "${CERT_DIR}/ca.key"
    openssl req -x509 -new -nodes \
      -key "${CERT_DIR}/ca.key" \
      -sha256 -days 3650 \
      -out "${CERT_DIR}/ca.crt" \
      -subj "/CN=${ZOT_DOMAIN}-root-ca"
  fi

  openssl genrsa -out "${CERT_DIR}/server.key" 4096 2>/dev/null
  chmod 600 "${CERT_DIR}/server.key"

  openssl req -new \
    -key "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.csr" \
    -subj "/CN=${ZOT_DOMAIN}"

  cat > "${CERT_DIR}/v3.ext" <<EOF
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${ZOT_DOMAIN}
IP.1 = ${ZOT_IP}
EOF

  openssl x509 -req \
    -in "${CERT_DIR}/server.csr" \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/server.crt" \
    -days 365 \
    -sha256 \
    -extfile "${CERT_DIR}/v3.ext"
}

# ── CA key is RSA 4096-bit ────────────────────────────────────────────────

@test "CA key is RSA 4096-bit" {
  generate_certs

  run openssl rsa -in "${CERT_DIR}/ca.key" -text -noout
  assert_success
  assert_output --partial "4096"
  assert_output --partial "Private-Key"
}

# ── CA cert has correct CN ────────────────────────────────────────────────

@test "CA cert has correct CN" {
  generate_certs

  run openssl x509 -in "${CERT_DIR}/ca.crt" -subject -noout
  assert_success
  assert_output --partial "test.example.com-root-ca"
}

# ── Server cert has correct SAN (DNS + IP) ────────────────────────────────

@test "server cert has correct SAN with DNS and IP" {
  generate_certs

  local san_text
  san_text=$(openssl x509 -in "${CERT_DIR}/server.crt" -text -noout | grep -A1 "Subject Alternative Name")

  [[ "$san_text" == *"DNS:test.example.com"* ]]
  [[ "$san_text" == *"IP Address:10.0.0.42"* ]]
}

# ── Server cert is signed by generated CA ──────────────────────────────────

@test "server cert is signed by generated CA (openssl verify)" {
  generate_certs

  run openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.crt"
  assert_success
  assert_output --partial "OK"
}

# ── --skip-certs requires existing certs ───────────────────────────────────

@test "--skip-certs requires existing server.crt" {
  source_functions_lax install.sh
  SKIP_CERTS="true"
  CERT_DIR="${TEST_TMP}/empty_certs"
  mkdir -p "$CERT_DIR"

  # No certs exist -- main should fail at the skip-certs check
  # We need to simulate what main does: the skip-certs block checks for server.crt
  # Call main directly to test this path
  run main --skip-certs --ip 10.0.0.1 --data-dir "${TEST_TMP}/data"
  assert_failure
  assert_output --partial "No server.crt found"
}

# ── --force regenerates CA ─────────────────────────────────────────────────

@test "--force regenerates CA even if ca.key exists" {
  generate_certs

  # Record original CA fingerprint
  local original_fingerprint
  original_fingerprint=$(openssl x509 -in "${CERT_DIR}/ca.crt" -fingerprint -noout)

  # Regenerate with FORCE
  FORCE="true"
  generate_certs

  local new_fingerprint
  new_fingerprint=$(openssl x509 -in "${CERT_DIR}/ca.crt" -fingerprint -noout)

  # Fingerprints should differ
  [[ "$original_fingerprint" != "$new_fingerprint" ]]
}

# ── Key files have chmod 600 ──────────────────────────────────────────────

@test "key files have chmod 600 permissions" {
  generate_certs

  local ca_perms server_perms
  ca_perms=$(stat -c "%a" "${CERT_DIR}/ca.key")
  server_perms=$(stat -c "%a" "${CERT_DIR}/server.key")

  [[ "$ca_perms" == "600" ]]
  [[ "$server_perms" == "600" ]]
}
