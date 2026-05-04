#!/usr/bin/env bats
# Tests for migrate.sh skopeo strategy

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
  DRY_RUN=false

  # Create a fake CA so the tls_flag logic can work
  touch "$SOURCE_CA"
}

teardown() {
  teardown_common
}

# ── skopeo not installed ─────────────────────────────────────────────────

@test "skopeo: fails when skopeo is not installed" {
  # Shadow skopeo with a script that mimics "command not found"
  # check_tool uses 'command -v' so we need to ensure it's not on PATH
  # Override check_tool to simulate missing skopeo
  check_tool() {
    if [[ "$1" == "skopeo" ]]; then
      error "'skopeo' is required but not found. Install it first."
    fi
  }

  run migrate_skopeo
  [ "$status" -ne 0 ]
  [[ "$output" == *"skopeo"* ]]
  [[ "$output" == *"required but not found"* ]]
}

# ── jq not installed ─────────────────────────────────────────────────────

@test "skopeo: fails when jq is not installed" {
  setup_skopeo_mocks
  # Override check_tool to simulate missing jq (skopeo passes, jq fails)
  check_tool() {
    if [[ "$1" == "jq" ]]; then
      error "'jq' is required but not found. Install it first."
    fi
  }

  run migrate_skopeo
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"required but not found"* ]]
}

# ── Catalog fetch returns repos, skopeo sync called per repo ─────────────

@test "skopeo: fetches catalog and syncs each repo" {
  setup_curl_mocks
  setup_skopeo_mocks
  setup_jq_mocks

  # Override curl to return a known catalog
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "${TEST_TMP}/logs"
  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
echo '{"repositories":["repo-a","repo-b"]}'
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  # Override jq to extract repo names
  cat > "${mock_dir}/jq" <<'JQ_EOF'
#!/usr/bin/env bash
input=$(cat)
echo "$input" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d '"'
JQ_EOF
  chmod +x "${mock_dir}/jq"

  run migrate_skopeo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 2 repositories"* ]]
  [[ "$output" == *"Syncing repo-a"* ]]
  [[ "$output" == *"Syncing repo-b"* ]]
  [[ "$output" == *"2/2 repositories processed"* ]]
}

# ── Empty catalog falls back to scoped sync ──────────────────────────────

@test "skopeo: empty catalog falls back to scoped sync" {
  setup_skopeo_mocks

  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"
  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
echo '{"repositories":[]}'
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  cat > "${mock_dir}/jq" <<'JQ_EOF'
#!/usr/bin/env bash
cat > /dev/null
JQ_EOF
  chmod +x "${mock_dir}/jq"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi

  run migrate_skopeo
  [ "$status" -eq 0 ]
  [[ "$output" == *"No repositories found"* ]]
  [[ "$output" == *"scoped"* ]]
}

# ── --dry-run outputs DRY RUN markers ────────────────────────────────────

@test "skopeo: --dry-run outputs DRY RUN markers" {
  setup_curl_mocks
  setup_skopeo_mocks

  local mock_dir="${TEST_TMP}/mocks"
  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
echo '{"repositories":["myrepo"]}'
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  cat > "${mock_dir}/jq" <<'JQ_EOF'
#!/usr/bin/env bash
input=$(cat)
echo "$input" | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d '"'
JQ_EOF
  chmod +x "${mock_dir}/jq"

  DRY_RUN=true
  run migrate_skopeo
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
}
