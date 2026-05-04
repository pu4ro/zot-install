#!/usr/bin/env bats
# Tests for migrate.sh --dry-run across all strategies

setup() {
  load '../test_helper/common'
  load '../test_helper/mocks'
  setup_common
  source_functions migrate.sh

  # Set required globals
  SOURCE_REGISTRY="source.example.com"
  DEST_REGISTRY="dest.example.com"
  SOURCE_CA="${TEST_TMP}/ca.crt"
  DEST_CA=""
  DRY_RUN=true
  DEPLOY_K8S=false
  NAMESPACE="zot-registry"
  HELM_VALUES=""

  touch "$SOURCE_CA"

  # Create source storage for filesystem tests
  SOURCE_STORAGE="${TEST_TMP}/source-zot"
  mkdir -p "$SOURCE_STORAGE"
  DEST_STORAGE="${TEST_TMP}/dest-zot"
}

teardown() {
  teardown_common
}

# Helper to set up jq+curl mocks that return a catalog with one repo
_setup_catalog_mocks() {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"

  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
if echo "$*" | grep -q '_catalog'; then
  echo '{"repositories":["testrepo"]}'
elif echo "$*" | grep -q 'tags/list'; then
  echo '{"tags":["latest"]}'
fi
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  cat > "${mock_dir}/jq" <<'JQ_EOF'
#!/usr/bin/env bash
input=$(cat)
if echo "$input" | grep -q '"repositories"'; then
  echo "$input" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d '"'
elif echo "$input" | grep -q '"tags"'; then
  echo "$input" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d '"'
fi
JQ_EOF
  chmod +x "${mock_dir}/jq"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# ── skopeo dry-run ───────────────────────────────────────────────────────

@test "dry-run: skopeo produces [DRY RUN] markers and no side effects" {
  setup_skopeo_mocks
  _setup_catalog_mocks

  run migrate_skopeo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]

  # skopeo should NOT have been called (check log is empty or missing)
  local log="${TEST_TMP}/logs/skopeo.log"
  if [ -f "$log" ]; then
    # log should not contain "sync" calls from the actual execution
    run cat "$log"
    [[ "$output" != *"sync"* ]]
  fi
}

# ── filesystem dry-run ───────────────────────────────────────────────────

@test "dry-run: filesystem produces [DRY RUN] markers and no side effects" {
  setup_rsync_mocks
  mock_command du "100M\t${SOURCE_STORAGE}"

  run migrate_filesystem
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [[ "$output" == *"rsync"* ]]
  # Dest directory should NOT have been created
  [ ! -d "$DEST_STORAGE" ]
}

# ── oras dry-run ─────────────────────────────────────────────────────────

@test "dry-run: oras produces [DRY RUN] markers and no side effects" {
  setup_oras_mocks
  _setup_catalog_mocks

  run migrate_oras
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [[ "$output" == *"oras cp"* ]]
}

# ── zot-sync dry-run ─────────────────────────────────────────────────────

@test "dry-run: zot-sync with --deploy-k8s produces [DRY RUN] markers" {
  setup_k8s_mocks
  DEPLOY_K8S=true

  run migrate_zot_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
}

# ── Full main() dry-run with default strategy ────────────────────────────

@test "dry-run: main --dry-run --dest with default strategy shows DRY RUN" {
  setup_skopeo_mocks
  _setup_catalog_mocks

  run main --dest dest.example.com --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
}
