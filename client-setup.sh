#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Zot Registry Client Setup
# Run this on each worker/client node that needs to pull from the Zot registry
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --ip <ZOT_IP> --ca <CA_CERT_PATH> [OPTIONS]

Required:
  --ip IP         Zot server IP address
  --ca PATH       Path to CA certificate (ca.crt)

Options:
  --domain NAME   Registry domain (default: cr.makina.rocks)
  --port PORT     Registry port   (default: 443)
  -h, --help      Show this help

Example:
  # Copy ca.crt from zot server first, then:
  sudo ./client-setup.sh --ip 192.168.135.121 --ca ./ca.crt
  sudo ./client-setup.sh --ip 192.168.135.121 --ca ./ca.crt --port 8443
EOF
  exit 0
}

# ── Functions ───────────────────────────────────────────────────────────────
setup_etc_hosts() {
  if ! grep -q "${ZOT_DOMAIN}" /etc/hosts; then
    echo "${ZOT_IP} ${ZOT_DOMAIN}" >> /etc/hosts
    info "Added ${ZOT_IP} ${ZOT_DOMAIN} to /etc/hosts"
  else
    warn "${ZOT_DOMAIN} already in /etc/hosts"
  fi
}

setup_system_ca() {
  case "${OS_ID}" in
    ubuntu|debian)
      cp "${CA_PATH}" "/usr/local/share/ca-certificates/${ZOT_DOMAIN}.crt"
      update-ca-certificates
      ;;
    centos|rhel|rocky|alma|fedora)
      cp "${CA_PATH}" "/etc/pki/ca-trust/source/anchors/${ZOT_DOMAIN}.crt"
      update-ca-trust
      ;;
    sles|opensuse*)
      cp "${CA_PATH}" "/usr/share/pki/trust/anchors/${ZOT_DOMAIN}.crt"
      update-ca-certificates
      ;;
    macos)
      security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${CA_PATH}" 2>/dev/null || true
      ;;
  esac
  info "System CA trust updated"
}

setup_containerd_certs() {
  if [[ -d /etc/containerd ]] || command -v nerdctl >/dev/null 2>&1; then
    local host_with_port="${ZOT_DOMAIN}"
    [[ "${ZOT_PORT}" != "443" ]] && host_with_port="${ZOT_DOMAIN}:${ZOT_PORT}"

    CERTS_DIR="/etc/containerd/certs.d/${host_with_port}"
    mkdir -p "${CERTS_DIR}"
    cp "${CA_PATH}" "${CERTS_DIR}/ca.crt"

    cat > "${CERTS_DIR}/hosts.toml" <<EOF
server = "https://${host_with_port}"

[host."https://${host_with_port}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "${CERTS_DIR}/ca.crt"
EOF
    info "containerd certs.d configured"

    if systemctl is-active containerd >/dev/null 2>&1; then
      systemctl restart containerd
      info "containerd restarted"
    fi
  fi
}

setup_docker_certs() {
  if command -v docker >/dev/null 2>&1; then
    local docker_dir="/etc/docker/certs.d/${ZOT_DOMAIN}"
    [[ "${ZOT_PORT}" != "443" ]] && docker_dir="/etc/docker/certs.d/${ZOT_DOMAIN}:${ZOT_PORT}"
    mkdir -p "${docker_dir}"
    cp "${CA_PATH}" "${docker_dir}/ca.crt"
    info "Docker certs configured"
  fi
}

# ── Main ───��────────────────────────────────────────────────────────────────
main() {
  # ── Load .env if present ──
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
    set +a
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

  [[ $EUID -eq 0 ]] || error "Run as root (sudo)"
  [[ -n "$ZOT_IP" ]] || error "--ip is required"
  [[ -n "$CA_PATH" ]] && [[ -f "$CA_PATH" ]] || error "--ca <path-to-ca.crt> is required"

  # Detect OS
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
  elif [[ "$(uname)" == "Darwin" ]]; then
    OS_ID="macos"
  else
    OS_ID="unknown"
  fi

  setup_etc_hosts
  setup_system_ca
  setup_containerd_certs
  setup_docker_certs

  info "Client setup complete. Test: curl -s https://${ZOT_DOMAIN}/v2/_catalog"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
