#!/usr/bin/env bash
###############################################################################
# Host registry -> host zot migration integration test
#
# Exercises migrate.sh end-to-end against two live registries running on the
# host. Source and destination are both zot, which exposes the same OCI
# distribution-spec surface (/v2/_catalog + manifest/blob endpoints) that
# migrate.sh relies on — so this is a faithful stand-in for the original
# "host Harbor -> host zot" scenario under the same-registry assumption.
# (Harbor's /v2/ is served by an embedded distribution registry; the skopeo
#  copy + catalog path migrate.sh uses behaves identically.)
#
# What it validates:
#   - skopeo strategy: nested repo paths preserved, content digests identical,
#     pull from destination works, real TLS trust via --source-ca/--dest-ca
#   - filesystem strategy: rsync of the OCI layout is byte-identical (zot->zot)
#
# Requirements: docker (daemon up), skopeo, jq, curl, openssl, rsync,
#               outbound pull access for the seed images + the zot image.
#
# Usage:  tests/integration/test_host_migration.sh
# Env overrides: SRC_PORT, DST_PORT, ZOT_IMAGE, WORK
###############################################################################
set -euo pipefail

# Resolve repo root from this script's location (tests/integration/..).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

WORK="${WORK:-/tmp/zot-mig-test}"          # MUST live outside the repo
CERTS="${WORK}/certs"
SRC_DATA="${WORK}/src-data"
DST_DATA="${WORK}/dst-data"
FS_DATA="${WORK}/fs-dest"
SRC_PORT="${SRC_PORT:-5000}"
DST_PORT="${DST_PORT:-5001}"
ZOT_IMAGE="${ZOT_IMAGE:-ghcr.io/project-zot/zot:latest}"

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILED=1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
step() { echo -e "\n${BLUE}== $* ==${NC}"; }
FAILED=0

cleanup() { docker rm -f mig-src mig-dst >/dev/null 2>&1 || true; }
trap cleanup EXIT

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1"; exit 2; }; }
for t in docker skopeo jq curl openssl rsync; do require "$t"; done
docker info >/dev/null 2>&1 || { echo "docker daemon is not available"; exit 2; }

step "1. Workspace + self-signed cert (SAN: localhost, 127.0.0.1)"
rm -rf "$WORK"; mkdir -p "$CERTS" "$SRC_DATA" "$DST_DATA" "$FS_DATA" "${WORK}/ca"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${CERTS}/server.key" -out "${CERTS}/server.crt" \
  -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
chmod 644 "${CERTS}/server.key"
# skopeo --cert-dir treats a stray *.key as a client-cert pair, so the CA the
# migration trusts must live alone (just ca.crt). Self-signed: cert == CA.
cp "${CERTS}/server.crt" "${WORK}/ca/ca.crt"
ok "cert + CA-only trust dir generated"

mk_config() {  # $1=port  $2=outfile
  cat > "$2" <<EOF
{
  "distSpecVersion": "1.1.1",
  "storage": { "rootDirectory": "/var/lib/registry" },
  "http": {
    "address": "0.0.0.0",
    "port": "${1}",
    "tls": { "cert": "/certs/server.crt", "key": "/certs/server.key" }
  },
  "log": { "level": "warn" }
}
EOF
}
mk_config "$SRC_PORT" "${WORK}/src-config.json"
mk_config "$DST_PORT" "${WORK}/dst-config.json"

step "2. Start source + destination zot (HTTPS)"
docker run -d --name mig-src -p ${SRC_PORT}:${SRC_PORT} \
  -v "${WORK}/src-config.json":/etc/zot/config.json:ro \
  -v "${CERTS}":/certs:ro -v "${SRC_DATA}":/var/lib/registry "$ZOT_IMAGE" >/dev/null
docker run -d --name mig-dst -p ${DST_PORT}:${DST_PORT} \
  -v "${WORK}/dst-config.json":/etc/zot/config.json:ro \
  -v "${CERTS}":/certs:ro -v "${DST_DATA}":/var/lib/registry "$ZOT_IMAGE" >/dev/null

for p in $SRC_PORT $DST_PORT; do
  for i in $(seq 1 30); do
    curl -sk "https://localhost:${p}/v2/" >/dev/null 2>&1 && break
    sleep 1
    [ "$i" -eq 30 ] && { fail "zot on :${p} did not become ready"; docker logs mig-src; exit 1; }
  done
done
ok "source :${SRC_PORT} and dest :${DST_PORT} ready"

step "3. Seed source with nested-path images (skopeo, no docker daemon change)"
declare -A SEED=(
  ["testproj/alpine:1.0"]="docker://docker.io/library/alpine:3.19"
  ["testproj/alpine:2.0"]="docker://docker.io/library/alpine:3.20"
  ["testproj/busybox:1.0"]="docker://docker.io/library/busybox:1.36"
)
for ref in "${!SEED[@]}"; do
  skopeo copy --dest-tls-verify=false --retry-times 3 \
    "${SEED[$ref]}" "docker://localhost:${SRC_PORT}/${ref}" >/dev/null 2>&1 \
    && ok "seeded ${ref}" || fail "seed failed ${ref}"
done

step "4. Run migrate.sh --strategy skopeo (real TLS trust via CA)"
cd "$REPO_DIR"
./migrate.sh --strategy skopeo \
  --source "localhost:${SRC_PORT}" --dest "localhost:${DST_PORT}" \
  --source-ca "${WORK}/ca/ca.crt" --dest-ca "${WORK}/ca/ca.crt"

step "5. Verify catalog parity (path preservation)"
SRC_CAT=$(curl -sk "https://localhost:${SRC_PORT}/v2/_catalog" | jq -cS '.repositories|sort')
DST_CAT=$(curl -sk "https://localhost:${DST_PORT}/v2/_catalog" | jq -cS '.repositories|sort')
echo "  src: $SRC_CAT"; echo "  dst: $DST_CAT"
[ "$SRC_CAT" == "$DST_CAT" ] && ok "catalog matches (nested paths preserved)" || fail "catalog mismatch"

step "6. Verify per-tag manifest digest parity (content identity)"
for ref in "testproj/alpine:1.0" "testproj/alpine:2.0" "testproj/busybox:1.0"; do
  sd=$(skopeo inspect --tls-verify=false "docker://localhost:${SRC_PORT}/${ref}" | jq -r .Digest)
  dd=$(skopeo inspect --tls-verify=false "docker://localhost:${DST_PORT}/${ref}" | jq -r .Digest)
  if [ "$sd" == "$dd" ] && [ -n "$sd" ]; then ok "${ref}  ${sd}  [MATCH]"
  else fail "${ref}  src=${sd}  dst=${dd}  [MISMATCH]"; fi
done

step "7. Verify real pull from destination (full blob fetch)"
if skopeo copy --src-tls-verify=false \
     "docker://localhost:${DST_PORT}/testproj/alpine:1.0" "dir:${WORK}/pull-check" >/dev/null 2>&1; then
  ok "pulled testproj/alpine:1.0 from destination"
else fail "pull from destination failed"; fi

step "8. Verify filesystem strategy (zot -> zot, rsync of OCI layout)"
docker stop mig-src >/dev/null     # quiesce source before copying its storage
./migrate.sh --strategy filesystem \
  --source-storage "${SRC_DATA}" --dest-storage "${FS_DATA}" >/dev/null
if diff -r "${SRC_DATA}" "${FS_DATA}" >/dev/null 2>&1; then
  ok "filesystem rsync produced identical OCI layout"
else fail "filesystem rsync mismatch"; fi

echo ""
if [ "$FAILED" -eq 0 ]; then echo -e "${GREEN}ALL CHECKS PASSED${NC}"; else echo -e "${RED}SOME CHECKS FAILED${NC}"; exit 1; fi
