#!/usr/bin/env bats
# Tests for install.sh OS/runtime/IP detection functions

load '/opt/bats-support/load'
load '/opt/bats-assert/load'
load '../test_helper/common'
load '../test_helper/mocks'

setup() {
  setup_common
  source_functions_lax install.sh
}

teardown() {
  teardown_common
}

# ── detect_runtime: nerdctl preferred over docker ─────────────────────────

@test "detect_runtime prefers nerdctl over docker" {
  # Mock both nerdctl and docker as available
  mock_command nerdctl ""
  mock_command docker ""

  run detect_runtime
  assert_success
  assert_output --partial "nerdctl"
  [[ "${RUNTIME:-}" == "nerdctl" ]] || {
    # RUNTIME is set in the function's scope; check via output
    assert_output --partial "Using container runtime: nerdctl"
  }
}

@test "detect_runtime prefers nerdctl over docker (RUNTIME variable)" {
  mock_command nerdctl ""
  mock_command docker ""

  detect_runtime
  [[ "$RUNTIME" == "nerdctl" ]]
}

# ── detect_runtime: docker when no nerdctl ─────────────────────────────────

@test "detect_runtime uses docker when nerdctl is absent" {
  # Only mock docker; ensure nerdctl is not on PATH
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"
  rm -f "${mock_dir}/nerdctl" 2>/dev/null || true

  # Create a docker mock that also handles 'info' subcommand
  cat > "${mock_dir}/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${mock_dir}/docker"

  # Set PATH to only include mocks and essential system dirs (no nerdctl)
  export PATH="${mock_dir}:/usr/bin:/bin"

  detect_runtime
  [[ "$RUNTIME" == "docker" ]]
}

# ── detect_runtime: podman as fallback ─────────────────────────────────────

@test "detect_runtime falls back to podman" {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  # Only podman available -- create a docker mock that fails on 'info'
  cat > "${mock_dir}/podman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${mock_dir}/podman"

  # Docker mock that fails on 'info' so detect_runtime skips it
  cat > "${mock_dir}/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "info" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "${mock_dir}/docker"

  # No nerdctl, docker info fails, so podman is used
  export PATH="${mock_dir}:/usr/bin:/bin"

  detect_runtime
  [[ "$RUNTIME" == "podman" ]]
}

# ── detect_runtime: none available fails ───────────────────────────────────

@test "detect_runtime fails when no runtime found" {
  # Set PATH to an empty mock dir with no runtimes
  local mock_dir="${TEST_TMP}/empty_mocks"
  mkdir -p "$mock_dir"
  export PATH="${mock_dir}"

  run detect_runtime
  assert_failure
  assert_output --partial "No supported container runtime found"
}

# ── detect_ip: --ip flag used as-is ───────────────────────────────────────

@test "detect_ip uses ZOT_IP when already set" {
  ZOT_IP="192.168.1.100"

  detect_ip
  [[ "$ZOT_IP" == "192.168.1.100" ]]
}

@test "detect_ip returns immediately when ZOT_IP is set" {
  ZOT_IP="10.20.30.40"

  run detect_ip
  assert_success
  # Should not print auto-detected message since it returned early
  refute_output --partial "Auto-detected"
}

# ── detect_ip: auto-detect via ip command ──────────────────────────────────

@test "detect_ip auto-detects via ip command" {
  ZOT_IP=""
  setup_ip_mocks "172.16.0.5"

  detect_ip
  [[ "$ZOT_IP" == "172.16.0.5" ]]
}

# ── detect_ip: fallback to hostname -I ─────────────────────────────────────

@test "detect_ip falls back to hostname -I when ip command fails" {
  ZOT_IP=""
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  # ip command that fails / returns empty
  cat > "${mock_dir}/ip" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${mock_dir}/ip"

  # hostname that returns an IP on -I
  cat > "${mock_dir}/hostname" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-I" ]]; then
  echo "10.0.0.99 fe80::1"
else
  echo "testhost"
fi
exit 0
EOF
  chmod +x "${mock_dir}/hostname"

  # awk is needed for parsing; keep system awk on PATH
  export PATH="${mock_dir}:/usr/bin:/bin"

  detect_ip
  [[ "$ZOT_IP" == "10.0.0.99" ]]
}

# ── detect_ip: all detection fails ────────────────────────────────────────

@test "detect_ip fails when all detection methods fail" {
  ZOT_IP=""
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  # ip command fails
  cat > "${mock_dir}/ip" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${mock_dir}/ip"

  # hostname -I returns empty
  cat > "${mock_dir}/hostname" <<'EOF'
#!/usr/bin/env bash
echo ""
exit 0
EOF
  chmod +x "${mock_dir}/hostname"

  export PATH="${mock_dir}:/usr/bin:/bin"

  run detect_ip
  assert_failure
  assert_output --partial "Cannot auto-detect IP"
}
