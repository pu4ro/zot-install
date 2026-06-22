#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Harbor -> zot Full Replacement
#
# Replaces a Harbor registry with a zot registry at the SAME address, so that
# every client keeps pulling `cr.makina.rocks/<repo>:<tag>` with no change.
#
# Design constraints (built for live, air-gapped, containerd/nerdctl hosts):
#   * NEVER touches /etc/containerd/certs.d, the system CA store, or Harbor.
#     The cutover only stops Harbor and rebinds zot to :443 -- existing client
#     trust (certs.d hosts.toml for the domain) keeps working unchanged.
#   * Air-gap friendly: the zot image is loaded from a local tar (--image-tar);
#     no registry pulls are required on the target host.
#   * Path-preserving: each tag is copied with a fully-qualified destination
#     reference, so nested namespaces (charts/gitea/actions) are reproduced
#     exactly -- a plain `skopeo sync` would flatten them.
#   * Resumable: a tag whose manifest digest already matches on the destination
#     is skipped, so a run interrupted by a Harbor disconnect (see
#     docs/harbor-registry-disconnect.md) can simply be re-run.
#
# Phases (run individually or via --phase all):
#   deploy   stand up the destination zot on --dest-port (default 5000)
#   migrate  copy every Harbor repo/tag to zot (path-preserving, resumable)
#   verify   compare catalogs and per-tag manifest digests
#   cutover  stop Harbor, rebind zot to :443  (DISRUPTIVE -- opt-in only)
#   all      deploy + migrate + verify   (NOT cutover)
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}══════ $* ══════${NC}"; }

usage() {
  cat <<'EOF'
Usage: harbor-to-zot-replace.sh --phase <deploy|migrate|verify|cutover|all> [OPTIONS]

Required:
  --phase NAME            deploy | migrate | verify | cutover | all
  --src-creds USER:PASS   Harbor credentials (read access is enough)

Options:
  --domain DOMAIN         Registry domain, shared by Harbor and zot  (default: cr.makina.rocks)
  --ip IP                 Host IP for the cert SAN                    (default: auto-detect)
  --dest-port PORT        Staging port for zot before cutover         (default: 5000)
  --runtime NAME          Container runtime: nerdctl|docker|podman    (default: auto-detect)
  --work DIR              Working dir (certs, config, data, image tar) (default: /root/zot-mig)
  --image IMAGE           zot image reference          (default: ghcr.io/project-zot/zot-linux-amd64:latest)
  --image-tar PATH        Load zot image from this tar (AIR-GAP; skips any pull)
  --harbor-compose DIR    Harbor docker-compose dir, for cutover       (default: /opt/harbor)
  --insecure              Use self-signed/!verify TLS for skopeo       (default: on)
  --yes                   Do not prompt on the cutover confirmation
  -h, --help              Show this help

Examples:
  # Air-gapped full validation (no cutover): deploy zot, migrate, verify
  ./harbor-to-zot-replace.sh --phase all \
      --src-creds admin:Harbor12345 --image-tar ./zot-image.tar

  # Later, during a maintenance window, perform the actual cutover
  ./harbor-to-zot-replace.sh --phase cutover --yes
EOF
  exit 0
}

# ── Defaults ──────────────────────────────────────────────────────────────
PHASE=""
DOMAIN="${DOMAIN:-cr.makina.rocks}"
IP="${IP:-}"
DEST_PORT="${DEST_PORT:-5000}"
RUNTIME="${RUNTIME:-}"
WORK="${WORK:-/root/zot-mig}"
IMAGE="${IMAGE:-ghcr.io/project-zot/zot-linux-amd64:latest}"
IMAGE_TAR="${IMAGE_TAR:-}"
HARBOR_COMPOSE="${HARBOR_COMPOSE:-/opt/harbor}"
SRC_CREDS="${SRC_CREDS:-}"
INSECURE=true
ASSUME_YES=false
ZOT_NAME="zot-mig"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)          PHASE="$2"; shift 2 ;;
    --domain)         DOMAIN="$2"; shift 2 ;;
    --ip)             IP="$2"; shift 2 ;;
    --dest-port)      DEST_PORT="$2"; shift 2 ;;
    --runtime)        RUNTIME="$2"; shift 2 ;;
    --work)           WORK="$2"; shift 2 ;;
    --image)          IMAGE="$2"; shift 2 ;;
    --image-tar)      IMAGE_TAR="$2"; shift 2 ;;
    --harbor-compose) HARBOR_COMPOSE="$2"; shift 2 ;;
    --src-creds)      SRC_CREDS="$2"; shift 2 ;;
    --insecure)       INSECURE=true; shift ;;
    --yes)            ASSUME_YES=true; shift ;;
    -h|--help)        usage ;;
    *)                error "Unknown option: $1" ;;
  esac
done

CERTS="${WORK}/certs"
DATA="${WORK}/data"
CONFIG="${WORK}/config.json"
DEST="${DOMAIN}:${DEST_PORT}"

# ── Runtime detection (nerdctl preferred, validated) ────────────────────────
detect_runtime() {
  [[ -n "$RUNTIME" ]] && { command -v "$RUNTIME" >/dev/null || error "runtime '$RUNTIME' not found"; return; }
  for rt in nerdctl docker podman; do
    if command -v "$rt" >/dev/null 2>&1; then RUNTIME="$rt"; break; fi
  done
  [[ -n "$RUNTIME" ]] || error "No container runtime found (nerdctl/docker/podman)"
}

detect_ip() {
  [[ -n "$IP" ]] && return
  IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
  [[ -z "$IP" ]] && IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$IP" ]] || error "Cannot auto-detect IP; pass --ip"
}

# ── skopeo helpers ──────────────────────────────────────────────────────────
curl_src() {  # curl against Harbor (source)
  local args=(-sk)
  [[ -n "$SRC_CREDS" ]] && args+=(-u "$SRC_CREDS")
  curl "${args[@]}" "$@"
}

# Content fingerprint = sha256 of the raw manifest bytes, via skopeo.
# NOTE: do NOT compare the registry's Docker-Content-Digest header here -- zot's
# `docker2s2` compat re-renders manifests on the fly, so the HEAD digest can
# differ from Harbor's even when the stored content is identical. `skopeo
# inspect --raw` returns the stored bytes, which match by digest after a
# `skopeo copy --all`.
raw_sha() {  # raw_sha <registry> <repo> <tag> [creds]
  local reg="$1" repo="$2" tag="$3" creds="${4:-}"
  local args=(inspect --raw --tls-verify=false)
  [[ -n "$creds" ]] && args+=(--creds "$creds")
  skopeo "${args[@]}" "docker://${reg}/${repo}:${tag}" 2>/dev/null | sha256sum | awk '{print $1}'
}

fetch_catalog() {  # echoes one repo per line
  local reg="$1" last="" hdr page all=""
  hdr=$(mktemp)
  while :; do
    local url="https://${reg}/v2/_catalog?n=1000"
    [[ -n "$last" ]] && url+="&last=${last}"
    page=$(curl_src -D "$hdr" "$url" 2>/dev/null | jq -r '.repositories[]?' 2>/dev/null || true)
    [[ -z "$page" ]] && break
    all+="${page}"$'\n'
    if grep -qi '^link:.*rel="next"' "$hdr"; then last=$(echo "$page" | tail -n1); else break; fi
  done
  rm -f "$hdr"
  echo "$all" | sed '/^[[:space:]]*$/d' | sort -u
}

# ── Phase: deploy ───────────────────────────────────────────────────────────
phase_deploy() {
  step "Deploy destination zot on :${DEST_PORT} (non-disruptive)"
  detect_runtime; detect_ip
  info "runtime=${RUNTIME}  domain=${DOMAIN}  ip=${IP}  dest=${DEST}"
  mkdir -p "$CERTS" "$DATA"

  if [[ ! -f "${CERTS}/server.crt" ]]; then
    info "Generating self-signed cert (SAN=${DOMAIN}) -- local to ${CERTS}, NOT added to any trust store"
    openssl genrsa -out "${CERTS}/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "${CERTS}/ca.key" -sha256 -days 3650 \
      -out "${CERTS}/ca.crt" -subj "/CN=${DOMAIN}-zot-ca" 2>/dev/null
    openssl genrsa -out "${CERTS}/server.key" 4096 2>/dev/null
    openssl req -new -key "${CERTS}/server.key" -out "${CERTS}/server.csr" -subj "/CN=${DOMAIN}" 2>/dev/null
    printf 'subjectAltName=@a\n[a]\nDNS.1=%s\nIP.1=%s\n' "$DOMAIN" "$IP" > "${CERTS}/v3.ext"
    openssl x509 -req -in "${CERTS}/server.csr" -CA "${CERTS}/ca.crt" -CAkey "${CERTS}/ca.key" \
      -CAcreateserial -out "${CERTS}/server.crt" -days 365 -sha256 -extfile "${CERTS}/v3.ext" 2>/dev/null
  fi

  cat > "$CONFIG" <<EOF
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/var/lib/registry", "gc": false },
  "http": {
    "address": "0.0.0.0", "port": "${DEST_PORT}",
    "compat": ["docker2s2"],
    "tls": { "cert": "/certs/server.crt", "key": "/certs/server.key" }
  },
  "log": { "level": "info" }
}
EOF

  if [[ -n "$IMAGE_TAR" ]]; then
    [[ -f "$IMAGE_TAR" ]] || error "image tar not found: ${IMAGE_TAR}"
    info "Loading zot image from tar (air-gap): ${IMAGE_TAR}"
    "$RUNTIME" load -i "$IMAGE_TAR"
  elif ! "$RUNTIME" images | grep -q "${IMAGE%%:*}"; then
    info "Pulling zot image: ${IMAGE} (online host)"
    "$RUNTIME" pull "$IMAGE"
  fi

  "$RUNTIME" rm -f "$ZOT_NAME" 2>/dev/null || true
  "$RUNTIME" run -d --name "$ZOT_NAME" --restart=no \
    -p "${DEST_PORT}:${DEST_PORT}" \
    -v "${CONFIG}:/etc/zot/config.json:ro" \
    -v "${CERTS}:/certs:ro" \
    -v "${DATA}:/var/lib/registry" \
    "$IMAGE" serve /etc/zot/config.json

  for i in $(seq 1 20); do
    curl -sk "https://${DEST}/v2/" >/dev/null 2>&1 && { info "zot READY on ${DEST}"; return; }
    [[ $i -eq 20 ]] && { "$RUNTIME" logs "$ZOT_NAME" | tail -20; error "zot did not become ready"; }
    sleep 2
  done
}

# ── Phase: migrate ──────────────────────────────────────────────────────────
phase_migrate() {
  step "Migrate Harbor -> zot (path-preserving, resumable)"
  command -v skopeo >/dev/null || error "skopeo is required"
  command -v jq >/dev/null || error "jq is required"
  [[ -n "$SRC_CREDS" ]] || warn "no --src-creds given; private Harbor projects will be skipped"

  local repos total count=0 copied=0 skipped=0 failed=0
  repos=$(fetch_catalog "$DOMAIN")
  [[ -n "$repos" ]] || error "empty catalog from ${DOMAIN} (auth? connectivity?)"
  total=$(echo "$repos" | wc -l)
  info "Found ${total} repositories"

  local tls=()
  [[ "$INSECURE" == true ]] && tls=(--src-tls-verify=false --dest-tls-verify=false)

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    count=$((count + 1))
    local tags
    tags=$(curl_src "https://${DOMAIN}/v2/${repo}/tags/list" | jq -r '.tags[]?' 2>/dev/null || true)
    [[ -z "$tags" ]] && { warn "[${count}/${total}] ${repo}: no tags, skip"; continue; }
    info "[${count}/${total}] ${repo} ($(echo "$tags" | wc -w) tags)"
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      # Resume: skip when destination already holds the identical manifest.
      local sd dd
      sd=$(raw_sha "$DOMAIN" "$repo" "$tag" "$SRC_CREDS")
      dd=$(raw_sha "$DEST" "$repo" "$tag" "")
      if [[ -n "$sd" && "$sd" == "$dd" ]]; then
        skipped=$((skipped + 1)); continue
      fi
      if skopeo copy --all --retry-times 5 "${tls[@]}" \
           ${SRC_CREDS:+--src-creds "$SRC_CREDS"} \
           "docker://${DOMAIN}/${repo}:${tag}" "docker://${DEST}/${repo}:${tag}" >/dev/null 2>&1; then
        copied=$((copied + 1))
      else
        warn "  failed: ${repo}:${tag}"; failed=$((failed + 1))
      fi
    done <<< "$tags"
  done <<< "$repos"

  info "Migrate done: ${total} repos, ${copied} copied, ${skipped} already-present, ${failed} failed"
  [[ "$failed" -eq 0 ]] || warn "Re-run --phase migrate to retry the ${failed} failed tag(s) (resumable)."
}

# ── Phase: verify ───────────────────────────────────────────────────────────
phase_verify() {
  step "Verify catalog + per-tag digest equality"
  local repos total=0 tags_total=0 match=0 mismatch=0 missing=0
  repos=$(fetch_catalog "$DOMAIN")
  total=$(echo "$repos" | wc -l)

  local src_cat dst_cat
  src_cat=$(echo "$repos" | tr '\n' ' ')
  dst_cat=$(curl -sk "https://${DEST}/v2/_catalog?n=5000" | jq -r '.repositories[]?' 2>/dev/null | sort -u | tr '\n' ' ')
  info "Harbor repos=${total}; zot repos=$(echo "$dst_cat" | wc -w)"

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    local tags
    tags=$(curl_src "https://${DOMAIN}/v2/${repo}/tags/list" | jq -r '.tags[]?' 2>/dev/null || true)
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      tags_total=$((tags_total + 1))
      local sd dd
      sd=$(raw_sha "$DOMAIN" "$repo" "$tag" "$SRC_CREDS")
      dd=$(raw_sha "$DEST" "$repo" "$tag" "")
      if [[ -z "$dd" ]]; then missing=$((missing + 1)); warn "MISSING ${repo}:${tag}"
      elif [[ "$sd" == "$dd" ]]; then match=$((match + 1))
      else mismatch=$((mismatch + 1)); warn "MISMATCH ${repo}:${tag} src=${sd} dst=${dd}"; fi
    done <<< "$tags"
  done <<< "$repos"

  info "Digest check: ${match} match, ${mismatch} mismatch, ${missing} missing (of ${tags_total} tags)"
  [[ "$mismatch" -eq 0 && "$missing" -eq 0 ]] && info "VERIFY PASSED" || error "VERIFY FAILED"
}

# ── Phase: cutover ──────────────────────────────────────────────────────────
phase_cutover() {
  step "Cutover: stop Harbor, rebind zot to :443 (DISRUPTIVE)"
  detect_runtime
  warn "This stops Harbor and serves zot at https://${DOMAIN} (:443)."
  warn "Clients keep their existing certs.d/CA trust for ${DOMAIN} -- nothing there is changed."
  if [[ "$ASSUME_YES" != true ]]; then
    read -rp "Proceed with cutover? [y/N] " a; [[ "$a" =~ ^[Yy] ]] || { warn "aborted"; exit 0; }
  fi

  if command -v docker >/dev/null 2>&1 && [[ -f "${HARBOR_COMPOSE}/docker-compose.yml" ]]; then
    info "Stopping Harbor compose project at ${HARBOR_COMPOSE}"
    (cd "$HARBOR_COMPOSE" && docker compose down) || warn "compose down reported an error; verify :443 is free"
  else
    warn "Harbor compose not found at ${HARBOR_COMPOSE}; stop Harbor manually so :443 is free"
  fi

  info "Re-launching zot on :443"
  sed "s/\"port\": \"${DEST_PORT}\"/\"port\": \"443\"/" "$CONFIG" > "${WORK}/config.443.json"
  "$RUNTIME" rm -f "$ZOT_NAME" 2>/dev/null || true
  "$RUNTIME" run -d --name "$ZOT_NAME" --restart=always \
    -p "443:443" \
    -v "${WORK}/config.443.json:/etc/zot/config.json:ro" \
    -v "${CERTS}:/certs:ro" \
    -v "${DATA}:/var/lib/registry" \
    "$IMAGE" serve /etc/zot/config.json
  for i in $(seq 1 20); do
    curl -sk "https://${DOMAIN}/v2/_catalog" >/dev/null 2>&1 && { info "zot now serving :443"; break; }
    [[ $i -eq 20 ]] && error "zot not serving on :443"
    sleep 2
  done
  info "Cutover complete. Validate a real pull, then decommission Harbor data when satisfied."
}

case "$PHASE" in
  deploy)  phase_deploy ;;
  migrate) phase_migrate ;;
  verify)  phase_verify ;;
  cutover) phase_cutover ;;
  all)     phase_deploy; phase_migrate; phase_verify ;;
  "")      usage ;;
  *)       error "Unknown phase: ${PHASE}" ;;
esac
