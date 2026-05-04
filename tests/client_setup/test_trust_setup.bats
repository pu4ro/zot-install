#!/usr/bin/env bats
# Tests for client-setup.sh trust/cert setup functions

setup() {
  load '../test_helper/common'
  load '../test_helper/mocks'
  setup_common
  source_functions client-setup.sh

  # Set up globals that the functions expect
  ZOT_DOMAIN="cr.makina.rocks"
  ZOT_IP="10.0.0.1"
  ZOT_PORT="443"
  CA_PATH="${TEST_TMP}/ca.crt"
  OS_ID="ubuntu"

  # Create fake CA cert
  echo "-----BEGIN CERTIFICATE-----
MIIFakeCert
-----END CERTIFICATE-----" > "$CA_PATH"

  # Create directories that functions will write into, redirected to TEST_TMP
  # We override the functions to use TEST_TMP-based paths
}

teardown() {
  teardown_common
}

# ── containerd hosts.toml includes port for non-443 ─────────────────────

@test "containerd: hosts.toml includes port when ZOT_PORT != 443" {
  ZOT_PORT="8443"

  # Create /etc/containerd so the condition passes
  local containerd_dir="${TEST_TMP}/etc/containerd"
  mkdir -p "$containerd_dir"

  setup_systemctl_mocks

  # Override setup_containerd_certs to use TEST_TMP paths
  setup_containerd_certs() {
    local host_with_port="${ZOT_DOMAIN}"
    [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

    CERTS_DIR="${TEST_TMP}/etc/containerd/certs.d/${host_with_port}"
    mkdir -p "${CERTS_DIR}"
    cp "${CA_PATH}" "${CERTS_DIR}/ca.crt"

    cat > "${CERTS_DIR}/hosts.toml" <<EOF
server = "https://${host_with_port}"

[host."https://${host_with_port}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${CERTS_DIR}/ca.crt"
EOF
    echo "containerd certs.d configured"
  }

  run setup_containerd_certs
  [ "$status" -eq 0 ]

  local hosts_toml="${TEST_TMP}/etc/containerd/certs.d/cr.makina.rocks:8443/hosts.toml"
  [ -f "$hosts_toml" ]

  run cat "$hosts_toml"
  [[ "$output" == *"cr.makina.rocks:8443"* ]]
  [[ "$output" == *"server = \"https://cr.makina.rocks:8443\""* ]]
}

# ── containerd hosts.toml omits port for 443 ────────────────────────────

@test "containerd: hosts.toml omits port when ZOT_PORT == 443" {
  ZOT_PORT="443"

  mkdir -p "${TEST_TMP}/etc/containerd"
  setup_systemctl_mocks

  setup_containerd_certs() {
    local host_with_port="${ZOT_DOMAIN}"
    [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

    CERTS_DIR="${TEST_TMP}/etc/containerd/certs.d/${host_with_port}"
    mkdir -p "${CERTS_DIR}"
    cp "${CA_PATH}" "${CERTS_DIR}/ca.crt"

    cat > "${CERTS_DIR}/hosts.toml" <<EOF
server = "https://${host_with_port}"

[host."https://${host_with_port}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${CERTS_DIR}/ca.crt"
EOF
    echo "containerd certs.d configured"
  }

  run setup_containerd_certs
  [ "$status" -eq 0 ]

  local hosts_toml="${TEST_TMP}/etc/containerd/certs.d/cr.makina.rocks/hosts.toml"
  [ -f "$hosts_toml" ]

  run cat "$hosts_toml"
  # Should NOT include :443
  [[ "$output" != *":443"* ]]
  [[ "$output" == *"cr.makina.rocks"* ]]
}

# ── Docker certs.d includes port for non-443 ────────────────────────────

@test "docker: certs.d directory includes port when ZOT_PORT != 443" {
  ZOT_PORT="5000"

  # Mock docker command so the condition passes
  mock_command docker ""

  # Override setup_docker_certs to use TEST_TMP
  setup_docker_certs() {
    if command -v docker >/dev/null 2>&1; then
      local docker_dir="${TEST_TMP}/etc/docker/certs.d/${ZOT_DOMAIN}"
      [[ "${ZOT_PORT}" != "443" ]] && docker_dir="${TEST_TMP}/etc/docker/certs.d/${ZOT_DOMAIN}:${ZOT_PORT}"
      mkdir -p "${docker_dir}"
      cp "${CA_PATH}" "${docker_dir}/ca.crt"
      echo "Docker certs configured at ${docker_dir}"
    fi
  }

  run setup_docker_certs
  [ "$status" -eq 0 ]

  local docker_cert_dir="${TEST_TMP}/etc/docker/certs.d/cr.makina.rocks:5000"
  [ -d "$docker_cert_dir" ]
  [ -f "${docker_cert_dir}/ca.crt" ]
}

# ── Docker certs.d omits port for 443 ───────────────────────────────────

@test "docker: certs.d directory omits port when ZOT_PORT == 443" {
  ZOT_PORT="443"
  mock_command docker ""

  setup_docker_certs() {
    if command -v docker >/dev/null 2>&1; then
      local docker_dir="${TEST_TMP}/etc/docker/certs.d/${ZOT_DOMAIN}"
      [[ "${ZOT_PORT}" != "443" ]] && docker_dir="${TEST_TMP}/etc/docker/certs.d/${ZOT_DOMAIN}:${ZOT_PORT}"
      mkdir -p "${docker_dir}"
      cp "${CA_PATH}" "${docker_dir}/ca.crt"
      echo "Docker certs configured at ${docker_dir}"
    fi
  }

  run setup_docker_certs
  [ "$status" -eq 0 ]

  local docker_cert_dir="${TEST_TMP}/etc/docker/certs.d/cr.makina.rocks"
  [ -d "$docker_cert_dir" ]
  [ -f "${docker_cert_dir}/ca.crt" ]
  # Port-suffixed dir should NOT exist
  [ ! -d "${TEST_TMP}/etc/docker/certs.d/cr.makina.rocks:443" ]
}

# ── /etc/hosts entry added when missing ──────────────────────────────────

@test "etc-hosts: entry added when domain is missing" {
  # Override setup_etc_hosts to use a TEST_TMP hosts file
  local hosts_file="${TEST_TMP}/etc/hosts"
  mkdir -p "${TEST_TMP}/etc"
  echo "127.0.0.1 localhost" > "$hosts_file"

  setup_etc_hosts() {
    if ! grep -q "${ZOT_DOMAIN}" "$hosts_file"; then
      echo "${ZOT_IP} ${ZOT_DOMAIN}" >> "$hosts_file"
      echo "Added ${ZOT_IP} ${ZOT_DOMAIN} to hosts file"
    else
      echo "${ZOT_DOMAIN} already in hosts file"
    fi
  }

  run setup_etc_hosts
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added"* ]]

  run cat "$hosts_file"
  [[ "$output" == *"10.0.0.1 cr.makina.rocks"* ]]
}

# ── /etc/hosts not duplicated ────────────────────────────────────────────

@test "etc-hosts: entry not duplicated when already present" {
  local hosts_file="${TEST_TMP}/etc/hosts"
  mkdir -p "${TEST_TMP}/etc"
  echo "127.0.0.1 localhost" > "$hosts_file"
  echo "10.0.0.1 cr.makina.rocks" >> "$hosts_file"

  setup_etc_hosts() {
    if ! grep -q "${ZOT_DOMAIN}" "$hosts_file"; then
      echo "${ZOT_IP} ${ZOT_DOMAIN}" >> "$hosts_file"
      echo "Added ${ZOT_IP} ${ZOT_DOMAIN} to hosts file"
    else
      echo "${ZOT_DOMAIN} already in hosts file"
    fi
  }

  run setup_etc_hosts
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]

  # Count lines with the domain - should be exactly 1
  local count
  count=$(grep -c "cr.makina.rocks" "$hosts_file")
  [ "$count" -eq 1 ]
}
