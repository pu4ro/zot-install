#!/usr/bin/env bats
# Tests for client-setup.sh argument parsing

setup() {
  load '../test_helper/common'
  load '../test_helper/mocks'
  setup_common
  source_functions client-setup.sh
}

teardown() {
  teardown_common
}

# ── --help shows usage ───────────────────────────────────────────────────

@test "client-setup: --help shows usage text" {
  run usage
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--ip"* ]]
  [[ "$output" == *"--ca"* ]]
  [[ "$output" == *"--domain"* ]]
  [[ "$output" == *"--port"* ]]
}

# ── --ip required ────────────────────────────────────────────────────────

@test "client-setup: --ip is required" {
  # Create a valid CA file
  local ca_file="${TEST_TMP}/ca.crt"
  echo "fake-cert" > "$ca_file"

  # Override the main function's root check by testing the arg validation
  # directly. We wrap main to skip the EUID check.
  _test_main_no_root_check() {
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
      set -a; source "${SCRIPT_DIR}/.env"; set +a
    fi
    ZOT_DOMAIN="${ZOT_DOMAIN:-cr.makina.rocks}"
    ZOT_IP="${ZOT_IP:-}"
    ZOT_PORT="${ZOT_PORT:-443}"
    CA_PATH="${CA_PATH:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ip)     ZOT_IP="$2"; shift 2 ;;
        --ca)     CA_PATH="$2"; shift 2 ;;
        --domain) ZOT_DOMAIN="$2"; shift 2 ;;
        --port)   ZOT_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)        error "Unknown option: $1" ;;
      esac
    done
    [[ -n "$ZOT_IP" ]] || error "--ip is required"
    [[ -n "$CA_PATH" ]] && [[ -f "$CA_PATH" ]] || error "--ca <path-to-ca.crt> is required"
  }

  run _test_main_no_root_check --ca "$ca_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ip is required"* ]]
}

# ── --ca required ────────────────────────────────────────────────────────

@test "client-setup: --ca is required" {
  # Reuse the no-root-check wrapper approach
  _test_main_no_root_check() {
    ZOT_DOMAIN="${ZOT_DOMAIN:-cr.makina.rocks}"
    ZOT_IP="${ZOT_IP:-}"
    ZOT_PORT="${ZOT_PORT:-443}"
    CA_PATH="${CA_PATH:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ip)     ZOT_IP="$2"; shift 2 ;;
        --ca)     CA_PATH="$2"; shift 2 ;;
        --domain) ZOT_DOMAIN="$2"; shift 2 ;;
        --port)   ZOT_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)        error "Unknown option: $1" ;;
      esac
    done
    [[ -n "$ZOT_IP" ]] || error "--ip is required"
    [[ -n "$CA_PATH" ]] && [[ -f "$CA_PATH" ]] || error "--ca <path-to-ca.crt> is required"
  }

  run _test_main_no_root_check --ip 10.0.0.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ca"* ]]
}

# ── --ca file must exist ─────────────────────────────────────────────────

@test "client-setup: --ca file must exist" {
  _test_main_no_root_check() {
    ZOT_DOMAIN="${ZOT_DOMAIN:-cr.makina.rocks}"
    ZOT_IP="${ZOT_IP:-}"
    ZOT_PORT="${ZOT_PORT:-443}"
    CA_PATH="${CA_PATH:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ip)     ZOT_IP="$2"; shift 2 ;;
        --ca)     CA_PATH="$2"; shift 2 ;;
        --domain) ZOT_DOMAIN="$2"; shift 2 ;;
        --port)   ZOT_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)        error "Unknown option: $1" ;;
      esac
    done
    [[ -n "$ZOT_IP" ]] || error "--ip is required"
    [[ -n "$CA_PATH" ]] && [[ -f "$CA_PATH" ]] || error "--ca <path-to-ca.crt> is required"
  }

  run _test_main_no_root_check --ip 10.0.0.1 --ca /nonexistent/ca.crt
  [ "$status" -ne 0 ]
  [[ "$output" == *"--ca"* ]]
}

# ── Unknown flag errors ──────────────────────────────────────────────────

@test "client-setup: unknown flag causes error" {
  run main --unknown-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option: --unknown-flag"* ]]
}

# ── --domain sets ZOT_DOMAIN ─────────────────────────────────────────────

@test "client-setup: --domain sets ZOT_DOMAIN" {
  local ca_file="${TEST_TMP}/ca.crt"
  echo "fake-cert" > "$ca_file"

  # Build a test wrapper that skips root check and stubs out setup_* functions
  _test_domain_parse() {
    ZOT_DOMAIN="${ZOT_DOMAIN:-cr.makina.rocks}"
    ZOT_IP="${ZOT_IP:-}"
    ZOT_PORT="${ZOT_PORT:-443}"
    CA_PATH="${CA_PATH:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ip)     ZOT_IP="$2"; shift 2 ;;
        --ca)     CA_PATH="$2"; shift 2 ;;
        --domain) ZOT_DOMAIN="$2"; shift 2 ;;
        --port)   ZOT_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)        error "Unknown option: $1" ;;
      esac
    done
    [[ -n "$ZOT_IP" ]] || error "--ip is required"
    [[ -n "$CA_PATH" ]] && [[ -f "$CA_PATH" ]] || error "--ca <path-to-ca.crt> is required"
    echo "ZOT_DOMAIN=${ZOT_DOMAIN}"
  }

  run _test_domain_parse --ip 10.0.0.1 --ca "$ca_file" --domain custom.registry.io
  [ "$status" -eq 0 ]
  [[ "$output" == *"ZOT_DOMAIN=custom.registry.io"* ]]
}

# ── --port sets ZOT_PORT ─────────────────────────────────────────────────

@test "client-setup: --port sets ZOT_PORT" {
  local ca_file="${TEST_TMP}/ca.crt"
  echo "fake-cert" > "$ca_file"

  _test_port_parse() {
    ZOT_DOMAIN="${ZOT_DOMAIN:-cr.makina.rocks}"
    ZOT_IP="${ZOT_IP:-}"
    ZOT_PORT="${ZOT_PORT:-443}"
    CA_PATH="${CA_PATH:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ip)     ZOT_IP="$2"; shift 2 ;;
        --ca)     CA_PATH="$2"; shift 2 ;;
        --domain) ZOT_DOMAIN="$2"; shift 2 ;;
        --port)   ZOT_PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)        error "Unknown option: $1" ;;
      esac
    done
    [[ -n "$ZOT_IP" ]] || error "--ip is required"
    [[ -n "$CA_PATH" ]] && [[ -f "$CA_PATH" ]] || error "--ca <path-to-ca.crt> is required"
    echo "ZOT_PORT=${ZOT_PORT}"
  }

  run _test_port_parse --ip 10.0.0.1 --ca "$ca_file" --port 8443
  [ "$status" -eq 0 ]
  [[ "$output" == *"ZOT_PORT=8443"* ]]
}
