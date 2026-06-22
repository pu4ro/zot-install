#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Zot Registry Migration Script
# Migrate from temporary standalone Zot to K8s-based registry
#
# Strategies:
#   1. zot-sync   : Use zot's built-in sync extension (K8s zot pulls from temp zot)
#   2. skopeo     : Bulk copy all images/charts via skopeo sync
#   3. filesystem : Direct rsync of OCI storage directory to PV
#   4. oras       : OCI artifact-aware copy (preserves referrers/signatures)
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}══════ $* ══════${NC}"; }

usage() {
  cat <<'EOF'
Usage: migrate.sh [OPTIONS]

Migration Strategies:
  --strategy skopeo       Bulk copy via skopeo sync (default, recommended)
  --strategy zot-sync     Generate zot sync config for K8s deployment
  --strategy filesystem   Direct rsync of OCI storage to target
  --strategy oras         Copy via oras (preserves referrers/signatures)

Required:
  --dest REGISTRY         Destination registry URL (e.g., harbor.example.com)

Options:
  --source REGISTRY       Source registry               (default: cr.makina.rocks)
  --src-creds USER:PASS   Source registry credentials    (e.g. Harbor login)
  --dest-creds USER:PASS  Destination registry credentials
  --source-storage DIR    Source storage directory       (default: /data/zot)
  --source-ca PATH        Source CA cert path            (default: /data/cert/ca.crt)
  --dest-storage DIR      Destination storage path       (for filesystem strategy)
  --dest-ca PATH          Destination CA cert path
  --namespace NS          K8s namespace                  (default: zot-registry)
  --insecure              Skip TLS verify on src/dest     (self-signed / HTTP test registries)
  --dry-run               Preview actions without executing
  --deploy-k8s            Deploy zot on K8s with Helm (includes sync config)
  --helm-values FILE      Custom Helm values file
  -h, --help              Show this help

Examples:
  # Skopeo bulk copy (most common)
  ./migrate.sh --strategy skopeo --dest harbor.example.com

  # Harbor -> zot, images only, with Harbor read credentials
  ./migrate.sh --strategy skopeo \
    --source harbor.example.com --src-creds robot$puller:TOKEN \
    --dest   zot.example.com    --dest-creds admin:zotpass

  # Deploy zot on K8s with built-in sync from temp registry
  ./migrate.sh --strategy zot-sync --dest zot-k8s.example.com --deploy-k8s

  # Direct filesystem copy to a PV
  ./migrate.sh --strategy filesystem --dest-storage /mnt/k8s-pv/zot

  # Dry run to preview
  ./migrate.sh --strategy skopeo --dest harbor.example.com --dry-run
EOF
  exit 0
}

# ── Validation ──────────────────────────────────────────────────────────────
check_tool() {
  command -v "$1" >/dev/null 2>&1 || error "'$1' is required but not found. Install it first."
}

# ── Catalog fetch (auth + pagination aware) ──────────────────────────────────
# Harbor returns _catalog in pages and requires auth for private projects.
# Echoes one repository path per line, sorted/unique.
fetch_catalog() {
  local registry="$1"
  local curl_args=(-sk)
  [[ -f "$SOURCE_CA" ]] && curl_args+=(--cacert "$SOURCE_CA")
  [[ -n "$SRC_CREDS" ]] && curl_args+=(-u "$SRC_CREDS")

  local hdr last="" all=""
  hdr=$(mktemp)
  while :; do
    local url="https://${registry}/v2/_catalog?n=1000"
    [[ -n "$last" ]] && url+="&last=${last}"

    local body
    body=$(curl "${curl_args[@]}" -D "$hdr" "$url" 2>/dev/null || true)

    local page
    page=$(echo "$body" | jq -r '.repositories[]?' 2>/dev/null || true)
    [[ -z "$page" ]] && break

    all+="${page}"$'\n'

    # Continue only if the server advertises a next page (RFC5988 Link header).
    if grep -qi '^link:.*rel="next"' "$hdr"; then
      last=$(echo "$page" | tail -n1)
    else
      break
    fi
  done
  rm -f "$hdr"

  echo "$all" | sed '/^[[:space:]]*$/d' | sort -u
}

# ── Strategy: skopeo ────────────────────────────────────────────────────────
migrate_skopeo() {
  step "Migration via skopeo sync"
  check_tool skopeo
  check_tool jq

  [[ -n "$DEST_REGISTRY" ]] || error "--dest is required for skopeo strategy"

  info "Fetching repository catalog from ${SOURCE_REGISTRY}..."

  local repos
  repos=$(fetch_catalog "$SOURCE_REGISTRY")

  if [[ -z "$repos" ]]; then
    warn "No repositories found or catalog API unavailable."
    warn "Trying skopeo sync with --scoped flag..."

    local cmd=(skopeo sync
      --src docker
      --dest docker
      --all
      --keep-going
      --retry-times 3
    )
    [[ -f "$SOURCE_CA" ]] && cmd+=(--src-cert-dir "$(dirname "$SOURCE_CA")")
    [[ -n "$DEST_CA" ]] && [[ -f "$DEST_CA" ]] && cmd+=(--dest-cert-dir "$(dirname "$DEST_CA")")
    [[ -n "$SRC_CREDS" ]] && cmd+=(--src-creds "$SRC_CREDS")
    [[ -n "$DEST_CREDS" ]] && cmd+=(--dest-creds "$DEST_CREDS")
    [[ "$INSECURE" == true ]] && cmd+=(--src-tls-verify=false --dest-tls-verify=false)

    cmd+=("${SOURCE_REGISTRY}" "${DEST_REGISTRY}")

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY RUN] Would execute: ${cmd[*]}"
    else
      info "Executing: ${cmd[*]}"
      "${cmd[@]}"
    fi
    return
  fi

  local total
  total=$(echo "$repos" | wc -l)
  info "Found ${total} repositories to migrate"

  # NOTE: per-tag `skopeo copy` with an explicit destination ref is used instead
  # of `skopeo sync`. `skopeo sync` of a single source repo only appends the
  # repo *basename* to the destination, which does NOT preserve a nested
  # namespace (testproj/alpine -> alpine). Copying each tag with a fully
  # qualified dest ref guarantees the source path is reproduced exactly, so the
  # same image address works against the destination registry after cutover.
  local tls_flag="" auth_flag=""
  [[ -f "$SOURCE_CA" ]] && tls_flag="--cacert ${SOURCE_CA}"
  [[ -n "$SRC_CREDS" ]] && auth_flag="-u ${SRC_CREDS}"

  local count=0 copied=0 failed=0
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    count=$((count + 1))

    local tags
    tags=$(curl -sk ${tls_flag} ${auth_flag} \
      "https://${SOURCE_REGISTRY}/v2/${repo}/tags/list" | jq -r '.tags[]?' 2>/dev/null || true)
    if [[ -z "$tags" ]]; then
      warn "[${count}/${total}] ${repo}: no tags, skipping"
      continue
    fi
    info "[${count}/${total}] Copying ${repo} ($(echo "$tags" | wc -w) tags)..."

    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue

      local cmd=(skopeo copy --all --retry-times 3)
      [[ -f "$SOURCE_CA" ]] && cmd+=(--src-cert-dir "$(dirname "$SOURCE_CA")")
      [[ -n "$DEST_CA" ]] && [[ -f "$DEST_CA" ]] && cmd+=(--dest-cert-dir "$(dirname "$DEST_CA")")
      [[ -n "$SRC_CREDS" ]] && cmd+=(--src-creds "$SRC_CREDS")
      [[ -n "$DEST_CREDS" ]] && cmd+=(--dest-creds "$DEST_CREDS")
      [[ "$INSECURE" == true ]] && cmd+=(--src-tls-verify=false --dest-tls-verify=false)
      cmd+=("docker://${SOURCE_REGISTRY}/${repo}:${tag}" "docker://${DEST_REGISTRY}/${repo}:${tag}")

      if [[ "$DRY_RUN" == true ]]; then
        info "  [DRY RUN] ${cmd[*]}"
      elif "${cmd[@]}"; then
        copied=$((copied + 1))
      else
        warn "  Failed: ${repo}:${tag}"
        failed=$((failed + 1))
      fi
    done <<< "$tags"
  done <<< "$repos"

  info "Migration complete: ${count}/${total} repos, ${copied} tags copied, ${failed} failed"
}

# ── Strategy: zot-sync ──────────────────────────────────────────────────────
migrate_zot_sync() {
  step "Migration via Zot Sync Extension"

  local sync_config_dir="/tmp/zot-k8s-config"
  mkdir -p "${sync_config_dir}"

  info "Generating zot config with sync extension..."

  cat > "${sync_config_dir}/config.json" <<EOF
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
    "port": "5000",
    "tls": {
      "cert": "/certs/tls.crt",
      "key": "/certs/tls.key"
    }
  },
  "extensions": {
    "sync": {
      "enable": true,
      "registries": [
        {
          "urls": ["https://${SOURCE_REGISTRY}"],
          "onDemand": false,
          "pollInterval": "10m",
          "tlsVerify": true,
          "maxRetries": 5,
          "retryDelay": "5m",
          "content": [
            {
              "prefix": "**"
            }
          ]
        }
      ]
    },
    "search": {
      "enable": true
    },
    "ui": {
      "enable": true
    }
  },
  "log": {
    "level": "info"
  }
}
EOF

  info "Sync config generated at: ${sync_config_dir}/config.json"

  cat > "${sync_config_dir}/helm-values.yaml" <<EOF
# Zot K8s Deployment with Sync from temporary registry
# Source: ${SOURCE_REGISTRY}
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

replicaCount: 1

image:
  repository: ghcr.io/project-zot/zot-linux-amd64
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 5000

ingress:
  enabled: true
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  hosts:
    - host: ${DEST_REGISTRY:-registry.local}
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: zot-tls
      hosts:
        - ${DEST_REGISTRY:-registry.local}

persistence:
  enabled: true
  storageClass: ""
  size: 100Gi
  accessMode: ReadWriteOnce

configFiles:
  config.json: |
$(sed 's/^/    /' "${sync_config_dir}/config.json")
EOF

  info "Helm values generated at: ${sync_config_dir}/helm-values.yaml"

  if [[ "$DEPLOY_K8S" == true ]]; then
    step "Deploying Zot on Kubernetes"
    check_tool helm
    check_tool kubectl

    if [[ -f "$SOURCE_CA" ]]; then
      info "Creating source CA secret..."
      if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] kubectl create namespace ${NAMESPACE}"
        info "[DRY RUN] kubectl create secret generic zot-source-ca --from-file=ca.crt=${SOURCE_CA}"
      else
        kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
        kubectl -n "${NAMESPACE}" create secret generic zot-source-ca \
          --from-file=ca.crt="${SOURCE_CA}" \
          --dry-run=client -o yaml | kubectl apply -f -
      fi
    fi

    local helm_cmd=(helm upgrade --install zot project-zot/zot
      --namespace "${NAMESPACE}"
      --create-namespace
      --values "${sync_config_dir}/helm-values.yaml"
    )
    [[ -n "$HELM_VALUES" ]] && helm_cmd+=(--values "$HELM_VALUES")

    if [[ "$DRY_RUN" == true ]]; then
      info "[DRY RUN] ${helm_cmd[*]}"
    else
      helm repo add project-zot http://zotregistry.dev/helm-charts 2>/dev/null || true
      helm repo update
      "${helm_cmd[@]}"
      info "Zot deployed! Check status: kubectl -n ${NAMESPACE} get pods"
    fi

    cat <<EOF

  Sync will start automatically.
  Monitor: kubectl -n ${NAMESPACE} logs -f deploy/zot

  Once sync is complete:
    1. Update DNS/ingress to point to K8s registry
    2. Decommission temp registry: ./install.sh --uninstall
    3. Remove sync extension from config and restart pod
EOF
  else
    cat <<EOF

  Generated files:
    ${sync_config_dir}/config.json        - Zot config with sync
    ${sync_config_dir}/helm-values.yaml   - Helm values for K8s deploy

  To deploy manually:
    helm repo add project-zot http://zotregistry.dev/helm-charts
    helm install zot project-zot/zot \\
      --namespace ${NAMESPACE} --create-namespace \\
      --values ${sync_config_dir}/helm-values.yaml

EOF
  fi
}

# ── Strategy: filesystem ────────────────────────────────────────────────────
migrate_filesystem() {
  step "Migration via Filesystem Copy"

  [[ -n "$DEST_STORAGE" ]] || error "--dest-storage is required for filesystem strategy"
  [[ -d "$SOURCE_STORAGE" ]] || error "Source storage not found: ${SOURCE_STORAGE}"

  local size
  size=$(du -sh "${SOURCE_STORAGE}" | awk '{print $1}')
  info "Source storage size: ${size}"
  info "Source: ${SOURCE_STORAGE}"
  info "Destination: ${DEST_STORAGE}"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would execute:"
    info "  rsync -avH --progress ${SOURCE_STORAGE}/ ${DEST_STORAGE}/"
    return
  fi

  check_tool rsync

  mkdir -p "${DEST_STORAGE}"

  info "Starting rsync (preserving hard links)..."
  rsync -avH --progress "${SOURCE_STORAGE}/" "${DEST_STORAGE}/"

  info "Filesystem migration complete"
  info "Point your K8s zot deployment's PV to: ${DEST_STORAGE}"
}

# ── Strategy: oras ──────────────────────────────────────────────────────────
migrate_oras() {
  step "Migration via ORAS"
  check_tool oras
  check_tool jq

  [[ -n "$DEST_REGISTRY" ]] || error "--dest is required for oras strategy"

  info "Fetching repository catalog from ${SOURCE_REGISTRY}..."

  local tls_flag=""
  [[ -f "$SOURCE_CA" ]] && tls_flag="--cacert ${SOURCE_CA}"
  local auth_flag=""
  [[ -n "$SRC_CREDS" ]] && auth_flag="-u ${SRC_CREDS}"

  local repos
  repos=$(fetch_catalog "$SOURCE_REGISTRY")

  if [[ -z "$repos" ]]; then
    error "No repositories found. Check source registry connectivity."
  fi

  local total
  total=$(echo "$repos" | wc -l)
  info "Found ${total} repositories to migrate"

  local count=0
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    count=$((count + 1))

    local tags_url="https://${SOURCE_REGISTRY}/v2/${repo}/tags/list"
    local tags
    tags=$(curl -sk ${tls_flag} ${auth_flag} "${tags_url}" | jq -r '.tags[]' 2>/dev/null || true)

    if [[ -z "$tags" ]]; then
      warn "[${count}/${total}] ${repo}: no tags found, skipping"
      continue
    fi

    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      local src="${SOURCE_REGISTRY}/${repo}:${tag}"
      local dst="${DEST_REGISTRY}/${repo}:${tag}"

      local oras_cmd=(oras cp -r)
      [[ -n "$SRC_CREDS" ]] && oras_cmd+=(--from-username "${SRC_CREDS%%:*}" --from-password "${SRC_CREDS#*:}")
      [[ -n "$DEST_CREDS" ]] && oras_cmd+=(--to-username "${DEST_CREDS%%:*}" --to-password "${DEST_CREDS#*:}")
      [[ "$INSECURE" == true ]] && oras_cmd+=(--from-insecure --to-insecure)
      oras_cmd+=("${src}" "${dst}")

      if [[ "$DRY_RUN" == true ]]; then
        info "  [DRY RUN] oras cp -r ${src} ${dst}"
      else
        info "[${count}/${total}] Copying ${src} -> ${dst}"
        "${oras_cmd[@]}" || warn "  Failed: ${src}"
      fi
    done <<< "$tags"
  done <<< "$repos"

  info "ORAS migration complete: ${count}/${total} repositories processed"
}

# ── Main ────────────────────────────────────────────────────────────────────
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

  # ── Defaults ──
  SOURCE_REGISTRY="${SOURCE_REGISTRY:-cr.makina.rocks}"
  DEST_REGISTRY="${DEST_REGISTRY:-}"
  STRATEGY="${STRATEGY:-skopeo}"
  SOURCE_STORAGE="${SOURCE_STORAGE:-/data/zot}"
  DEST_STORAGE="${DEST_STORAGE:-}"
  SOURCE_CA="${SOURCE_CA:-/data/cert/ca.crt}"
  DEST_CA="${DEST_CA:-}"
  SRC_CREDS="${SRC_CREDS:-}"
  DEST_CREDS="${DEST_CREDS:-}"
  INSECURE=false
  NAMESPACE="${NAMESPACE:-zot-registry}"
  DRY_RUN=false
  HELM_VALUES=""
  DEPLOY_K8S=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)         SOURCE_REGISTRY="$2"; shift 2 ;;
      --dest)           DEST_REGISTRY="$2"; shift 2 ;;
      --strategy)       STRATEGY="$2"; shift 2 ;;
      --source-storage) SOURCE_STORAGE="$2"; shift 2 ;;
      --dest-storage)   DEST_STORAGE="$2"; shift 2 ;;
      --source-ca)      SOURCE_CA="$2"; shift 2 ;;
      --dest-ca)        DEST_CA="$2"; shift 2 ;;
      --src-creds)      SRC_CREDS="$2"; shift 2 ;;
      --dest-creds)     DEST_CREDS="$2"; shift 2 ;;
      --insecure)       INSECURE=true; shift ;;
      --namespace)      NAMESPACE="$2"; shift 2 ;;
      --dry-run)        DRY_RUN=true; shift ;;
      --deploy-k8s)     DEPLOY_K8S=true; shift ;;
      --helm-values)    HELM_VALUES="$2"; shift 2 ;;
      -h|--help)        usage ;;
      *)                error "Unknown option: $1" ;;
    esac
  done

  step "Zot Registry Migration (${STRATEGY})"
  info "Source: ${SOURCE_REGISTRY}"
  info "Destination: ${DEST_REGISTRY:-${DEST_STORAGE:-<not set>}}"

  case "$STRATEGY" in
    skopeo)     migrate_skopeo ;;
    zot-sync)   migrate_zot_sync ;;
    filesystem) migrate_filesystem ;;
    oras)       migrate_oras ;;
    *)          error "Unknown strategy: ${STRATEGY}. Use: skopeo, zot-sync, filesystem, oras" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
