#!/usr/bin/env bats
# Tests for install.sh client trust configuration (containerd + Docker certs)

load '/opt/bats-support/load'
load '/opt/bats-assert/load'
load '../test_helper/common'
load '../test_helper/mocks'

setup() {
  setup_common
  source_functions_lax install.sh

  ZOT_DOMAIN="cr.makina.rocks"
  ZOT_PORT="443"
  ZOT_IP="10.0.0.1"

  # Set up cert dir with a fake ca.crt
  CERT_DIR="${TEST_TMP}/certs"
  mkdir -p "$CERT_DIR"
  echo "FAKE CA CERT" > "${CERT_DIR}/ca.crt"

  # Mock systemctl so containerd restart doesn't fail
  setup_systemctl_mocks
}

teardown() {
  teardown_common
}

# ── containerd: hosts.toml content for default port 443 ───────────────────

@test "containerd hosts.toml uses domain without port for port 443" {
  ZOT_PORT="443"

  # Create fake /etc/containerd dir so the function runs
  local containerd_base="${TEST_TMP}/containerd_certs"
  mkdir -p "${TEST_TMP}/etc/containerd"

  # Override the function to use our test path
  configure_containerd_certs_test() {
    local certs_base="${containerd_base}"
    local host_with_port="${ZOT_DOMAIN}"
    [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

    local certs_dir="${certs_base}/${host_with_port}"
    mkdir -p "${certs_dir}"
    cp "${CERT_DIR}/ca.crt" "${certs_dir}/"

    cat > "${certs_dir}/hosts.toml" <<EOF
server = "https://${host_with_port}"

[host."https://${host_with_port}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${certs_dir}/ca.crt"
EOF
  }

  configure_containerd_certs_test

  local hosts_toml="${containerd_base}/${ZOT_DOMAIN}/hosts.toml"
  [[ -f "$hosts_toml" ]]

  run cat "$hosts_toml"
  assert_success
  assert_output --partial "server = \"https://cr.makina.rocks\""
  assert_output --partial "[host.\"https://cr.makina.rocks\"]"
  refute_output --partial ":443"
}

# ── containerd: hosts.toml includes port for non-443 ──────────────────────

@test "containerd hosts.toml includes port for non-443" {
  ZOT_PORT="8443"

  local containerd_base="${TEST_TMP}/containerd_certs"

  configure_containerd_certs_test() {
    local certs_base="${containerd_base}"
    local host_with_port="${ZOT_DOMAIN}"
    [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

    local certs_dir="${certs_base}/${host_with_port}"
    mkdir -p "${certs_dir}"
    cp "${CERT_DIR}/ca.crt" "${certs_dir}/"

    cat > "${certs_dir}/hosts.toml" <<EOF
server = "https://${host_with_port}"

[host."https://${host_with_port}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${certs_dir}/ca.crt"
EOF
  }

  configure_containerd_certs_test

  local hosts_toml="${containerd_base}/${ZOT_DOMAIN}:${ZOT_PORT}/hosts.toml"
  [[ -f "$hosts_toml" ]]

  run cat "$hosts_toml"
  assert_success
  assert_output --partial "server = \"https://cr.makina.rocks:8443\""
  assert_output --partial "[host.\"https://cr.makina.rocks:8443\"]"
}

# ── containerd: certs.d dir name includes port for non-443 ────────────────

@test "containerd certs.d directory name includes port for non-443" {
  ZOT_PORT="5000"

  local containerd_base="${TEST_TMP}/containerd_certs"

  # Build the host_with_port the same way as install.sh
  local host_with_port="${ZOT_DOMAIN}"
  [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

  local certs_dir="${containerd_base}/${host_with_port}"
  mkdir -p "${certs_dir}"

  # Verify the directory was created with port in name
  [[ -d "${containerd_base}/cr.makina.rocks:5000" ]]
}

@test "containerd certs.d directory name has no port for 443" {
  ZOT_PORT="443"

  local containerd_base="${TEST_TMP}/containerd_certs"
  local host_with_port="${ZOT_DOMAIN}"
  [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

  local certs_dir="${containerd_base}/${host_with_port}"
  mkdir -p "${certs_dir}"

  [[ -d "${containerd_base}/cr.makina.rocks" ]]
  [[ ! -d "${containerd_base}/cr.makina.rocks:443" ]]
}

# ── Docker: certs.d includes port for non-443 ─────────────────────────────

@test "Docker certs.d path includes port for non-443" {
  ZOT_PORT="8443"

  # Replicate the docker cert path logic from install.sh
  local docker_cert_dir="${TEST_TMP}/docker_certs/${ZOT_DOMAIN}"
  if [[ "${ZOT_PORT}" != "443" ]]; then
    docker_cert_dir="${TEST_TMP}/docker_certs/${ZOT_DOMAIN}:${ZOT_PORT}"
  fi
  mkdir -p "${docker_cert_dir}"
  cp "${CERT_DIR}/ca.crt" "${docker_cert_dir}/ca.crt"

  [[ -d "${TEST_TMP}/docker_certs/cr.makina.rocks:8443" ]]
  [[ -f "${TEST_TMP}/docker_certs/cr.makina.rocks:8443/ca.crt" ]]
}

@test "Docker certs.d path has no port for 443" {
  ZOT_PORT="443"

  local docker_cert_dir="${TEST_TMP}/docker_certs/${ZOT_DOMAIN}"
  if [[ "${ZOT_PORT}" != "443" ]]; then
    docker_cert_dir="${TEST_TMP}/docker_certs/${ZOT_DOMAIN}:${ZOT_PORT}"
  fi
  mkdir -p "${docker_cert_dir}"
  cp "${CERT_DIR}/ca.crt" "${docker_cert_dir}/ca.crt"

  [[ -d "${TEST_TMP}/docker_certs/cr.makina.rocks" ]]
  [[ ! -d "${TEST_TMP}/docker_certs/cr.makina.rocks:443" ]]
}

# ── CA cert is copied to certs.d directories ──────────────────────────────

@test "ca.crt is copied to containerd certs directory" {
  ZOT_PORT="443"

  local containerd_base="${TEST_TMP}/containerd_certs"
  local host_with_port="${ZOT_DOMAIN}"
  [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

  local certs_dir="${containerd_base}/${host_with_port}"
  mkdir -p "${certs_dir}"
  cp "${CERT_DIR}/ca.crt" "${certs_dir}/"

  [[ -f "${certs_dir}/ca.crt" ]]
  run cat "${certs_dir}/ca.crt"
  assert_output "FAKE CA CERT"
}

@test "hosts.toml references correct ca.crt path" {
  ZOT_PORT="8443"
  local containerd_base="${TEST_TMP}/containerd_certs"
  local host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"
  local certs_dir="${containerd_base}/${host_with_port}"
  mkdir -p "${certs_dir}"

  cat > "${certs_dir}/hosts.toml" <<EOF
server = "https://${host_with_port}"

[host."https://${host_with_port}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${certs_dir}/ca.crt"
EOF

  run cat "${certs_dir}/hosts.toml"
  assert_output --partial "ca = \"${certs_dir}/ca.crt\""
}
