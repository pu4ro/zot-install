#!/usr/bin/env bash
# Pre-built mocks for zot-install BATS tests

# ── OpenSSL ────────────────────────────────────────────────────────────────

setup_openssl_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  # openssl mock that creates expected output files based on subcommand
  cat > "${mock_dir}/openssl" <<'MOCK_EOF'
#!/usr/bin/env bash
case "$1" in
  genrsa)
    # Find -out argument and write a fake key
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -out) echo "-----BEGIN RSA PRIVATE KEY-----
MIIFake...
-----END RSA PRIVATE KEY-----" > "$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    ;;
  req)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -out) echo "-----BEGIN CERTIFICATE REQUEST-----
MIIFake...
-----END CERTIFICATE REQUEST-----" > "$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # If -x509 flag is present, it's a self-signed cert (CA cert generation)
    for arg in "$@"; do
      if [[ "$arg" == "-x509" ]]; then
        # Find -out and write a cert
        set -- "$@"
        for a in "$@"; do :; done
        break
      fi
    done
    ;;
  x509)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -out) echo "-----BEGIN CERTIFICATE-----
MIIFake...
-----END CERTIFICATE-----" > "$2"; shift 2 ;;
        -text) echo "Subject Alternative Name:
  DNS:cr.makina.rocks, IP Address:10.0.0.1"; shift ;;
        *) shift ;;
      esac
    done
    ;;
  verify)
    echo "server.crt: OK"
    ;;
esac
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/openssl"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── Container Runtime ──────────────────────────────────────────────────────

# Usage: setup_runtime_mocks <runtime>  (docker|nerdctl|podman)
setup_runtime_mocks() {
  local runtime="${1:-docker}"
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/${runtime}" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$0 \$*" >> "${TEST_TMP}/logs/${runtime}.log" 2>/dev/null || true
case "\$1" in
  inspect) exit 1 ;;  # no existing container
  info)    echo "Server Version: 24.0.0" ;;
  run)     echo "abc123def456" ;;
  rm)      echo "zot" ;;
  load)    echo "Loaded image: ghcr.io/project-zot/zot:latest" ;;
  save)    echo "Saving..." ;;
  *)       echo "mock ${runtime}: \$*" ;;
esac
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/${runtime}"
  mkdir -p "${TEST_TMP}/logs"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── curl ───────────────────────────────────────────────────────────────────

setup_curl_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/curl" <<'MOCK_EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */v2/_catalog) echo '{"repositories":["library/alpine","library/nginx"]}'; exit 0 ;;
    */v2/*/tags/list) echo '{"tags":["latest","v1.0"]}'; exit 0 ;;
    */v2/) echo '{}'; exit 0 ;;
  esac
done
echo '{}'
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/curl"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── skopeo ─────────────────────────────────────────────────────────────────

setup_skopeo_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/skopeo" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "skopeo $*" >> "${TEST_TMP}/logs/skopeo.log" 2>/dev/null || true
case "$1" in
  copy) echo "Copying..." ;;
  sync) echo "Syncing..." ;;
  inspect) echo '{"Digest":"sha256:abc123","RepoTags":["latest"]}' ;;
  list-tags) echo '{"Tags":["latest","v1.0"]}' ;;
esac
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/skopeo"
  mkdir -p "${TEST_TMP}/logs"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── oras ───────────────────────────────────────────────────────────────────

setup_oras_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/oras" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "oras $*" >> "${TEST_TMP}/logs/oras.log" 2>/dev/null || true
case "$1" in
  copy) echo "Copied successfully" ;;
  discover) echo "[]" ;;
  pull) echo "Pulled successfully" ;;
  push) echo "Pushed successfully" ;;
esac
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/oras"
  mkdir -p "${TEST_TMP}/logs"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── rsync ──────────────────────────────────────────────────────────────────

setup_rsync_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/rsync" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "rsync $*" >> "${TEST_TMP}/logs/rsync.log" 2>/dev/null || true
echo "sending incremental file list"
echo "sent 1234 bytes  received 56 bytes"
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/rsync"
  mkdir -p "${TEST_TMP}/logs"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── systemctl ──────────────────────────────────────────────────────────────

setup_systemctl_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/systemctl" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${TEST_TMP}/logs/systemctl.log" 2>/dev/null || true
case "$1" in
  is-active) echo "active"; exit 0 ;;
  restart)   exit 0 ;;
  status)    echo "active (running)"; exit 0 ;;
esac
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/systemctl"
  mkdir -p "${TEST_TMP}/logs"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── CA update commands ─────────────────────────────────────────────────────

setup_ca_update_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  for cmd in update-ca-certificates update-ca-trust security; do
    cat > "${mock_dir}/${cmd}" <<MOCK_EOF
#!/usr/bin/env bash
echo "${cmd} \$*" >> "${TEST_TMP}/logs/ca-update.log" 2>/dev/null || true
exit 0
MOCK_EOF
    chmod +x "${mock_dir}/${cmd}"
  done
  mkdir -p "${TEST_TMP}/logs"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── jq ─────────────────────────────────────────────────────────────────────

setup_jq_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/jq" <<'MOCK_EOF'
#!/usr/bin/env bash
# Passthrough: if stdin has data, cat it; otherwise echo empty object
if [[ -t 0 ]]; then
  echo '{}'
else
  cat
fi
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/jq"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── ip / hostname (network detection) ─────────────────────────────────────

# Usage: setup_ip_mocks <ip_address>
setup_ip_mocks() {
  local ip_addr="${1:-10.0.0.1}"
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/ip" <<MOCK_EOF
#!/usr/bin/env bash
echo "1.1.1.1 via 10.0.0.1 dev eth0 src ${ip_addr} uid 0"
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/ip"

  cat > "${mock_dir}/hostname" <<MOCK_EOF
#!/usr/bin/env bash
if [[ "\$1" == "-I" ]]; then
  echo "${ip_addr}"
else
  echo "testhost"
fi
exit 0
MOCK_EOF
  chmod +x "${mock_dir}/hostname"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── Convenience: all mocks for install.sh ──────────────────────────────────

setup_install_mocks() {
  setup_runtime_mocks docker
  setup_openssl_mocks
  setup_ip_mocks "10.0.0.1"
  setup_curl_mocks
  setup_systemctl_mocks
  setup_ca_update_mocks
  setup_jq_mocks
}

# ── Convenience: all mocks for migrate.sh ──────────────────────────────────

setup_migrate_mocks() {
  setup_runtime_mocks docker
  setup_curl_mocks
  setup_skopeo_mocks
  setup_oras_mocks
  setup_rsync_mocks
  setup_jq_mocks
}
