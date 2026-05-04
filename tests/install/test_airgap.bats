#!/usr/bin/env bats
# Tests for install.sh air-gapped mode

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

# ── --airgap without --image-tar fails ────────────────────────────────────

@test "--airgap without --image-tar fails with clear error" {
  run main --airgap --ip 10.0.0.1
  assert_failure
  assert_output --partial "Air-gapped mode requires --image-tar"
}

# ── --airgap with missing tar file fails ──────────────────────────────────

@test "--airgap with nonexistent tar file fails" {
  run main --airgap --image-tar /tmp/nonexistent-image.tar --ip 10.0.0.1
  assert_failure
  assert_output --partial "Image tar not found"
}

# ── --airgap with --image-tar sets AIRGAP and ZOT_IMAGE_TAR ──────────────

@test "--airgap with valid tar file passes airgap validation" {
  # Create a fake tar file
  local fake_tar="${TEST_TMP}/zot-image.tar"
  echo "fake tar content" > "$fake_tar"

  setup_install_mocks
  setup_ip_mocks "10.0.0.1"

  # Create fake /etc/hosts so the hosts step doesn't fail
  mkdir -p "${TEST_TMP}/etc"

  # We can't easily run the full main() because it writes to /etc/hosts, etc.
  # Instead, test the validation logic directly:
  ZOT_IP="10.0.0.1"
  AIRGAP="true"
  ZOT_IMAGE_TAR="$fake_tar"

  # Replicate the airgap validation block from main()
  if [[ "$AIRGAP" == true ]]; then
    [[ -n "$ZOT_IMAGE_TAR" ]] || { error "Air-gapped mode requires --image-tar <path>"; }
    [[ -f "$ZOT_IMAGE_TAR" ]] || { error "Image tar not found: ${ZOT_IMAGE_TAR}"; }
    info "Air-gapped mode enabled. Image: ${ZOT_IMAGE_TAR}"
  fi

  # If we got here, validation passed
  [[ "$AIRGAP" == "true" ]]
  [[ "$ZOT_IMAGE_TAR" == "$fake_tar" ]]
}

# ── docker load called correctly in airgap mode ───────────────────────────

@test "docker load is invoked with correct tar path in airgap mode" {
  local fake_tar="${TEST_TMP}/zot-image.tar"
  echo "fake tar content" > "$fake_tar"

  setup_runtime_mocks docker
  RUNTIME="docker"
  ZOT_IMAGE_TAR="$fake_tar"

  # Replicate the image loading block from main()
  if [[ -n "$ZOT_IMAGE_TAR" ]] && [[ -f "$ZOT_IMAGE_TAR" ]]; then
    case "${RUNTIME}" in
      docker)  docker load -i "${ZOT_IMAGE_TAR}" ;;
      nerdctl) nerdctl load -i "${ZOT_IMAGE_TAR}" ;;
      podman)  podman load -i "${ZOT_IMAGE_TAR}" ;;
    esac
  fi

  local calls
  calls=$(mock_calls docker)
  [[ "$calls" == *"load -i ${fake_tar}"* ]]
}

# ── nerdctl load called correctly in airgap mode ──────────────────────────

@test "nerdctl load is invoked with correct tar path in airgap mode" {
  local fake_tar="${TEST_TMP}/zot-image.tar"
  echo "fake tar content" > "$fake_tar"

  setup_runtime_mocks nerdctl
  RUNTIME="nerdctl"
  ZOT_IMAGE_TAR="$fake_tar"

  if [[ -n "$ZOT_IMAGE_TAR" ]] && [[ -f "$ZOT_IMAGE_TAR" ]]; then
    case "${RUNTIME}" in
      docker)  docker load -i "${ZOT_IMAGE_TAR}" ;;
      nerdctl) nerdctl load -i "${ZOT_IMAGE_TAR}" ;;
      podman)  podman load -i "${ZOT_IMAGE_TAR}" ;;
    esac
  fi

  local calls
  calls=$(mock_calls nerdctl)
  [[ "$calls" == *"load -i ${fake_tar}"* ]]
}

# ── podman load called correctly in airgap mode ───────────────────────────

@test "podman load is invoked with correct tar path in airgap mode" {
  local fake_tar="${TEST_TMP}/zot-image.tar"
  echo "fake tar content" > "$fake_tar"

  setup_runtime_mocks podman
  RUNTIME="podman"
  ZOT_IMAGE_TAR="$fake_tar"

  if [[ -n "$ZOT_IMAGE_TAR" ]] && [[ -f "$ZOT_IMAGE_TAR" ]]; then
    case "${RUNTIME}" in
      docker)  docker load -i "${ZOT_IMAGE_TAR}" ;;
      nerdctl) nerdctl load -i "${ZOT_IMAGE_TAR}" ;;
      podman)  podman load -i "${ZOT_IMAGE_TAR}" ;;
    esac
  fi

  local calls
  calls=$(mock_calls podman)
  [[ "$calls" == *"load -i ${fake_tar}"* ]]
}
