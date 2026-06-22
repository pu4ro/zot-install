#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Zot Registry Auto-Installer
# - Cross-OS (Ubuntu/Debian, RHEL/CentOS, SLES, macOS)
# - Cross-runtime (docker, nerdctl, podman)
# - TLS auto-generation
# - OCI Helm chart support
# - Air-gapped support
###############################################################################

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}══════ $* ══════${NC}"; }

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --domain DOMAIN       Registry domain name          (default: cr.makina.rocks)
  --ip IP               Server IP for TLS SAN         (auto-detected if omitted)
  --port PORT           Host port to expose            (default: 443)
  --data-dir DIR        Base data directory            (default: /data)
  --runtime NAME        Container runtime to use       (docker|nerdctl|podman; auto-detected if omitted)
  --image IMAGE         Zot container image            (default: ghcr.io/project-zot/zot:latest)
  --image-tar PATH      Load zot image from local tar  (for air-gapped)
  --airgap              Air-gapped mode (skip online checks, require --image-tar)
  --skip-hosts          Skip /etc/hosts modification
  --skip-certs          Skip TLS cert generation (use existing certs)
  --certs-only          Generate TLS certificates only (no container start)
  --force               Overwrite existing installation
  --uninstall           Remove zot container and data
  -h, --help            Show this help

Environment variables:
  ZOT_DOMAIN, ZOT_IP, ZOT_PORT, DATA_DIR, ZOT_IMAGE, ZOT_IMAGE_TAR, AIRGAP, CONTAINER_RUNTIME

Examples:
  # Basic install with defaults
  sudo ./install.sh --ip 192.168.135.121

  # Custom domain and port
  sudo ./install.sh --domain registry.example.com --ip 10.0.0.5 --port 8443

  # Air-gapped install
  sudo ./install.sh --airgap --image-tar ./zot-image.tar --ip 192.168.135.121

  # Generate certs only
  sudo ./install.sh --certs-only --ip 192.168.135.121

  # Uninstall
  sudo ./install.sh --uninstall
EOF
  exit 0
}

# ── Detect OS ───────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_FAMILY="${ID_LIKE:-${ID}}"
  elif [[ "$(uname)" == "Darwin" ]]; then
    OS_ID="macos"
    OS_VERSION="$(sw_vers -productVersion)"
    OS_FAMILY="macos"
  else
    OS_ID="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
  fi
  info "Detected OS: ${OS_ID} ${OS_VERSION} (family: ${OS_FAMILY})"
}

# ── Detect container runtime ───────────────────────────────────────────────
# A runtime is only usable if its binary is present AND its backend is
# reachable. docker and nerdctl both talk to a daemon (dockerd / containerd),
# so we probe `info`; podman is daemonless and only needs the binary.
runtime_works() {
  local rt="$1"
  command -v "$rt" >/dev/null 2>&1 || return 1
  case "$rt" in
    podman) return 0 ;;
    *)      "$rt" info >/dev/null 2>&1 ;;
  esac
}

detect_runtime() {
  # Explicit selection wins: --runtime flag or CONTAINER_RUNTIME env var.
  # Lets a host with both docker and nerdctl installed pick either one.
  local requested="${CONTAINER_RUNTIME:-}"
  if [[ -n "$requested" ]]; then
    case "$requested" in
      docker|nerdctl|podman) ;;
      *) error "Unsupported runtime '${requested}'. Choose one of: docker, nerdctl, podman" ;;
    esac
    command -v "$requested" >/dev/null 2>&1 \
      || error "Requested runtime '${requested}' not found in PATH"
    runtime_works "$requested" \
      || error "Requested runtime '${requested}' is installed but not functional (is its daemon running?)"
    RUNTIME="$requested"
    info "Using container runtime: ${RUNTIME} (explicitly selected)"
    return
  fi

  # Auto-detect: prefer nerdctl, then docker, then podman — but only pick a
  # runtime whose backend actually responds, so a broken nerdctl/containerd
  # install transparently falls back to a working docker (and vice versa).
  if runtime_works nerdctl; then
    RUNTIME="nerdctl"
  elif runtime_works docker; then
    RUNTIME="docker"
  elif runtime_works podman; then
    RUNTIME="podman"
  else
    RUNTIME=""
  fi

  if [[ -z "$RUNTIME" ]]; then
    error "No supported container runtime found. Install one of: docker, nerdctl (containerd), podman"
  fi
  info "Using container runtime: ${RUNTIME}"
}

# ── Detect IP ───────────────────────────────────────────────────────────────
detect_ip() {
  if [[ -n "$ZOT_IP" ]]; then
    return
  fi
  if command -v ip >/dev/null 2>&1; then
    ZOT_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
  fi
  if [[ -z "$ZOT_IP" ]] && command -v hostname >/dev/null 2>&1; then
    ZOT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [[ -z "$ZOT_IP" ]]; then
    error "Cannot auto-detect IP. Please specify --ip <SERVER_IP>"
  fi
  info "Auto-detected IP: ${ZOT_IP}"
}

# ── Uninstall ───────────────────────────────────────────────────────────────
do_uninstall() {
  detect_runtime
  step "Uninstalling Zot Registry"

  if command -v systemctl >/dev/null 2>&1 && systemctl cat zot.service >/dev/null 2>&1; then
    info "Stopping and disabling zot.service..."
    systemctl disable --now zot.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/zot.service
    systemctl daemon-reload
    info "systemd unit removed"
  fi

  info "Stopping and removing zot container..."
  ${RUNTIME} rm -f zot 2>/dev/null || true

  read -rp "Remove data directory ${DATA_DIR}? [y/N] " confirm
  if [[ "${confirm}" =~ ^[Yy] ]]; then
    rm -rf "${DATA_DIR}"
    info "Data directory removed"
  fi

  # Remove /etc/hosts entry
  if grep -q "${ZOT_DOMAIN}" /etc/hosts 2>/dev/null; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "/${ZOT_DOMAIN}/d" /etc/hosts
    else
      sed -i "/${ZOT_DOMAIN}/d" /etc/hosts
    fi
    info "Removed ${ZOT_DOMAIN} from /etc/hosts"
  fi

  info "Uninstall complete"
  exit 0
}

# ── Configure containerd certs.d ────────────────────────────────────────────
configure_containerd_certs() {
  local certs_base="/etc/containerd/certs.d"
  if [[ -d /etc/containerd ]] || command -v nerdctl >/dev/null 2>&1; then
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
    info "containerd certs.d configured at ${certs_dir}"

    if systemctl is-active containerd >/dev/null 2>&1; then
      systemctl restart containerd
      info "containerd restarted"
    fi
  fi
}

configure_docker_certs() {
  if command -v docker >/dev/null 2>&1; then
    local docker_cert_dir="/etc/docker/certs.d/${ZOT_DOMAIN}"
    if [[ "${ZOT_PORT}" != "443" ]]; then
      docker_cert_dir="/etc/docker/certs.d/${ZOT_DOMAIN}:${ZOT_PORT}"
    fi
    mkdir -p "${docker_cert_dir}"
    cp "${CERT_DIR}/ca.crt" "${docker_cert_dir}/ca.crt"
    info "Docker certs configured at ${docker_cert_dir}"
  fi
}

configure_system_ca() {
  case "${OS_ID}" in
    ubuntu|debian)
      cp "${CERT_DIR}/ca.crt" "/usr/local/share/ca-certificates/${ZOT_DOMAIN}.crt"
      update-ca-certificates 2>/dev/null
      ;;
    centos|rhel|rocky|alma|fedora)
      cp "${CERT_DIR}/ca.crt" "/etc/pki/ca-trust/source/anchors/${ZOT_DOMAIN}.crt"
      update-ca-trust 2>/dev/null
      ;;
    sles|opensuse*)
      cp "${CERT_DIR}/ca.crt" "/usr/share/pki/trust/anchors/${ZOT_DOMAIN}.crt"
      update-ca-certificates 2>/dev/null
      ;;
    macos)
      security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${CERT_DIR}/ca.crt" 2>/dev/null || true
      ;;
  esac
  info "System CA trust updated"
}

# ── systemd service ─────────────────────────────────────────────────────────
SERVICE_NAME="zot.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

# True when running under a usable systemd (Linux + systemctl + booted with systemd)
have_systemd() {
  [[ "$(uname)" == "Linux" ]] \
    && command -v systemctl >/dev/null 2>&1 \
    && [[ -d /run/systemd/system ]]
}

# Common container run arguments shared by systemd and direct-run modes.
# Intentionally excludes -d / --rm / --restart so each caller can add what it needs.
build_run_args() {
  RUN_ARGS=(
    --name zot
    -p "${ZOT_PORT}:${ZOT_INTERNAL_PORT}"
    -v "${ZOT_STORAGE}:/var/lib/registry"
    -v "${CERT_DIR}:/certs:ro"
    -v "${ZOT_STORAGE}/config.json:/etc/zot/config.json:ro"
    "${ZOT_IMAGE}"
    serve /etc/zot/config.json
  )
}

# Ensure the runtime's own daemon starts on boot, otherwise no container can
# come back up after a reboot regardless of the zot unit. Podman is daemonless.
enable_runtime_daemon() {
  local daemon_dep="$1"
  [[ -n "${daemon_dep}" ]] || return 0
  if systemctl is-enabled "${daemon_dep}" >/dev/null 2>&1; then
    info "${daemon_dep} already enabled on boot"
  elif systemctl enable "${daemon_dep}" >/dev/null 2>&1; then
    info "Enabled ${daemon_dep} on boot"
  else
    warn "Could not enable ${daemon_dep} on boot — container may not start after reboot"
  fi
}

# Generate, enable and start a systemd unit that owns the container lifecycle.
setup_service() {
  local runtime_bin daemon_dep after_line requires_line
  runtime_bin="$(command -v "${RUNTIME}")"

  # Boot-time daemon the runtime depends on (podman is daemonless).
  case "${RUNTIME}" in
    docker)  daemon_dep="docker.service" ;;
    nerdctl) daemon_dep="containerd.service" ;;
    *)       daemon_dep="" ;;
  esac

  enable_runtime_daemon "${daemon_dep}"

  after_line="network-online.target"
  requires_line=""
  if [[ -n "${daemon_dep}" ]]; then
    after_line="${after_line} ${daemon_dep}"
    requires_line="Requires=${daemon_dep}"
  fi

  build_run_args

  info "Writing systemd unit: ${SERVICE_PATH}"
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Zot OCI Registry
Documentation=https://zotregistry.dev
Wants=network-online.target
After=${after_line}
${requires_line}
RequiresMountsFor=${ZOT_STORAGE} ${CERT_DIR}

[Service]
Type=simple
Restart=always
RestartSec=5
TimeoutStartSec=300
# Clear any leftover container before each (re)start
ExecStartPre=-${runtime_bin} rm -f zot
ExecStart=${runtime_bin} run --rm ${RUN_ARGS[*]}
ExecStop=${runtime_bin} stop zot

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  if systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1; then
    info "Service enabled to start on boot"
  else
    warn "Could not enable ${SERVICE_NAME} for boot"
  fi
  systemctl restart "${SERVICE_NAME}"
  info "Service started via systemd (Restart=always)"
}

# Fallback for hosts without systemd (e.g. macOS): rely on the runtime's
# own restart policy instead of a unit file.
run_container_direct() {
  build_run_args
  warn "systemd not available — using runtime restart policy (--restart=always)"
  "${RUNTIME}" run -d --restart=always "${RUN_ARGS[@]}"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  # ── Load .env if present ���─
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
    set +a
  fi

  # ── Defaults ──
  ZOT_DOMAIN="${ZOT_DOMAIN:-cr.makina.rocks}"
  ZOT_IP="${ZOT_IP:-}"
  ZOT_PORT="${ZOT_PORT:-443}"
  ZOT_INTERNAL_PORT="${ZOT_INTERNAL_PORT:-5000}"
  DATA_DIR="${DATA_DIR:-/data}"
  CERT_DIR="${CERT_DIR:-${DATA_DIR}/cert}"
  ZOT_STORAGE="${ZOT_STORAGE:-${DATA_DIR}/zot}"
  ZOT_IMAGE="${ZOT_IMAGE:-ghcr.io/project-zot/zot:latest}"
  ZOT_IMAGE_TAR="${ZOT_IMAGE_TAR:-}"
  CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
  SKIP_HOSTS="${SKIP_HOSTS:-false}"
  SKIP_CERTS="${SKIP_CERTS:-false}"
  CERTS_ONLY="${CERTS_ONLY:-false}"
  AIRGAP="${AIRGAP:-false}"
  FORCE="${FORCE:-false}"

  # ── Parse args ──
  UNINSTALL=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)     ZOT_DOMAIN="$2"; shift 2 ;;
      --ip)         ZOT_IP="$2"; shift 2 ;;
      --port)       ZOT_PORT="$2"; shift 2 ;;
      --data-dir)   DATA_DIR="$2"; CERT_DIR="${DATA_DIR}/cert"; ZOT_STORAGE="${DATA_DIR}/zot"; shift 2 ;;
      --runtime)    CONTAINER_RUNTIME="$2"; shift 2 ;;
      --image)      ZOT_IMAGE="$2"; shift 2 ;;
      --image-tar)  ZOT_IMAGE_TAR="$2"; shift 2 ;;
      --airgap)     AIRGAP=true; shift ;;
      --skip-hosts) SKIP_HOSTS=true; shift ;;
      --skip-certs) SKIP_CERTS=true; shift ;;
      --certs-only) CERTS_ONLY=true; shift ;;
      --force)      FORCE=true; shift ;;
      --uninstall)  UNINSTALL=true; shift ;;
      -h|--help)    usage ;;
      *)            error "Unknown option: $1" ;;
    esac
  done

  # ── Root check ──
  [[ $EUID -eq 0 ]] || error "This script must be run as root (sudo)"

  [[ "$UNINSTALL" == true ]] && do_uninstall

  # ── Air-gapped validation ──
  if [[ "$AIRGAP" == true ]]; then
    [[ -n "$ZOT_IMAGE_TAR" ]] || error "Air-gapped mode requires --image-tar <path>"
    [[ -f "$ZOT_IMAGE_TAR" ]] || error "Image tar not found: ${ZOT_IMAGE_TAR}"
    info "Air-gapped mode enabled. Image: ${ZOT_IMAGE_TAR}"
  fi

  # ── Pre-flight ──
  step "Pre-flight Checks"
  detect_os
  detect_ip

  # ── /etc/hosts ──
  step "Configuring /etc/hosts"
  if [[ "$SKIP_HOSTS" == true ]]; then
    warn "Skipping /etc/hosts (--skip-hosts)"
  elif grep -q "${ZOT_DOMAIN}" /etc/hosts 2>/dev/null; then
    warn "${ZOT_DOMAIN} already exists in /etc/hosts"
  else
    echo "${ZOT_IP} ${ZOT_DOMAIN}" >> /etc/hosts
    info "Added: ${ZOT_IP} ${ZOT_DOMAIN}"
  fi

  # ── TLS Certificates ──
  step "Generating TLS Certificates"
  if [[ "$SKIP_CERTS" == true ]]; then
    warn "Skipping cert generation (--skip-certs)"
    [[ -f "${CERT_DIR}/server.crt" ]] || error "No server.crt found at ${CERT_DIR}"
    [[ -f "${CERT_DIR}/server.key" ]] || error "No server.key found at ${CERT_DIR}"
  else
    mkdir -p "${CERT_DIR}"

    # CA key & cert
    if [[ ! -f "${CERT_DIR}/ca.key" ]] || [[ "$FORCE" == true ]]; then
      info "Generating CA key and certificate..."
      openssl genrsa -out "${CERT_DIR}/ca.key" 4096 2>/dev/null
      chmod 600 "${CERT_DIR}/ca.key"
      openssl req -x509 -new -nodes \
        -key "${CERT_DIR}/ca.key" \
        -sha256 -days 3650 \
        -out "${CERT_DIR}/ca.crt" \
        -subj "/CN=${ZOT_DOMAIN}-root-ca"
    else
      info "CA already exists, reusing"
    fi

    # Server key, CSR, cert
    info "Generating server certificate..."
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

    info "Certificate generated. SAN:"
    openssl x509 -in "${CERT_DIR}/server.crt" -text -noout | grep -A1 "Subject Alternative Name" || true
  fi

  # ── Certs-only mode: exit here ──
  if [[ "${CERTS_ONLY}" == true ]]; then
    info "Certificates generated at ${CERT_DIR}"
    exit 0
  fi

  # ── Detect runtime (only needed for container operations) ──
  detect_runtime

  # ── Zot Configuration ──
  step "Creating Zot Configuration"
  mkdir -p "${ZOT_STORAGE}"

  cat > "${ZOT_STORAGE}/config.json" <<EOF
{
  "distSpecVersion": "1.1.0",
  "storage": {
    "rootDirectory": "/var/lib/registry",
    "gc": true,
    "gcDelay": "1h",
    "gcInterval": "6h"
  },
  "http": {
    "address": "0.0.0.0",
    "port": "${ZOT_INTERNAL_PORT}",
    "compat": ["docker2s2"],
    "tls": {
      "cert": "/certs/server.crt",
      "key": "/certs/server.key"
    }
  },
  "extensions": {
    "search": {
      "enable": true
    },
    "ui": {
      "enable": true
    },
    "lint": {
      "enable": true
    }
  },
  "log": {
    "level": "info"
  }
}
EOF
  info "Config written to ${ZOT_STORAGE}/config.json"

  # ── Check existing installation ──
  if have_systemd && systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
    if [[ "$FORCE" == true ]]; then
      warn "Existing zot service found. Removing (--force)..."
      systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    else
      error "Zot service already exists. Use --force to overwrite or --uninstall first."
    fi
  fi
  if ${RUNTIME} inspect zot >/dev/null 2>&1; then
    if [[ "$FORCE" == true ]]; then
      warn "Existing zot container found. Removing (--force)..."
      ${RUNTIME} rm -f zot
    else
      error "Zot container already exists. Use --force to overwrite or --uninstall first."
    fi
  fi

  # ── Load image (air-gapped) ──
  if [[ -n "$ZOT_IMAGE_TAR" ]] && [[ -f "$ZOT_IMAGE_TAR" ]]; then
    step "Loading Zot Image from Tar"
    case "${RUNTIME}" in
      docker)  docker load -i "${ZOT_IMAGE_TAR}" ;;
      nerdctl) nerdctl load -i "${ZOT_IMAGE_TAR}" ;;
      podman)  podman load -i "${ZOT_IMAGE_TAR}" ;;
    esac
    info "Image loaded from ${ZOT_IMAGE_TAR}"
  fi

  # ── Run Zot (systemd-managed when available) ──
  step "Starting Zot"

  if have_systemd; then
    setup_service
  else
    run_container_direct
  fi

  # Wait for startup
  info "Waiting for zot to start..."
  for i in $(seq 1 15); do
    if curl -sk "https://${ZOT_IP}:${ZOT_PORT}/v2/" >/dev/null 2>&1; then
      info "Zot is ready!"
      break
    fi
    if [[ $i -eq 15 ]]; then
      warn "Zot may not be ready yet. Check: ${RUNTIME} logs zot"
    fi
    sleep 2
  done

  # ── Configure Client Trust ──
  step "Configuring Client Trust"
  configure_containerd_certs
  configure_docker_certs
  configure_system_ca

  # ── Summary ──
  step "Installation Complete"
  cat <<EOF

  Registry URL:  https://${ZOT_DOMAIN}${ZOT_PORT:+:${ZOT_PORT}}
  Web UI:        https://${ZOT_IP}:${ZOT_PORT}
  Runtime:       ${RUNTIME}
  Data Dir:      ${ZOT_STORAGE}
  Certs Dir:     ${CERT_DIR}
$(if have_systemd; then cat <<SVC

  Service:       ${SERVICE_NAME} (enabled on boot, Restart=always)

  Service commands:
    systemctl status zot
    systemctl restart zot
    journalctl -u zot -f
SVC
fi)
  Test commands:
    # Check API
    curl -sk https://${ZOT_DOMAIN}/v2/_catalog

    # Push a container image
    ${RUNTIME} tag <image> ${ZOT_DOMAIN}/<repo>:<tag>
    ${RUNTIME} push ${ZOT_DOMAIN}/<repo>:<tag>

    # Push a Helm chart (OCI)
    helm push <chart>.tgz oci://${ZOT_DOMAIN}/<repo>

    # Pull a Helm chart
    helm pull oci://${ZOT_DOMAIN}/<repo>/<chart> --version <ver>

  Migration:
    ./migrate.sh --help

EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
