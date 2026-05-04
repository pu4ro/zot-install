#!/usr/bin/env bats
# Tests for migrate.sh oras strategy

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

  touch "$SOURCE_CA"
}

teardown() {
  teardown_common
}

# ── oras not installed ───────────────────────────────────────────────────

@test "oras: fails when oras is not installed" {
  setup_jq_mocks
  # Override check_tool to simulate missing oras
  check_tool() {
    if [[ "$1" == "oras" ]]; then
      error "'oras' is required but not found. Install it first."
    fi
  }

  run migrate_oras
  [ "$status" -ne 0 ]
  [[ "$output" == *"oras"* ]]
  [[ "$output" == *"required but not found"* ]]
}

# ── Empty catalog errors ─────────────────────────────────────────────────

@test "oras: empty catalog errors" {
  setup_oras_mocks
  setup_jq_mocks

  local mock_dir="${TEST_TMP}/mocks"
  # Override curl to return empty repos
  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
echo '{"repositories":[]}'
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  # Override jq to return nothing for empty array
  cat > "${mock_dir}/jq" <<'JQ_EOF'
#!/usr/bin/env bash
cat > /dev/null
JQ_EOF
  chmod +x "${mock_dir}/jq"

  run migrate_oras
  [ "$status" -ne 0 ]
  [[ "$output" == *"No repositories found"* ]]
}

# ── --dry-run outputs DRY RUN markers ────────────────────────────────────

@test "oras: --dry-run outputs DRY RUN markers" {
  setup_oras_mocks

  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir"
  # curl that returns catalog then tags
  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
if echo "$*" | grep -q '_catalog'; then
  echo '{"repositories":["myrepo"]}'
elif echo "$*" | grep -q 'tags/list'; then
  echo '{"tags":["v1"]}'
fi
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  # jq that extracts array values
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

  DRY_RUN=true

  run migrate_oras
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [[ "$output" == *"oras cp"* ]]
}

# ── Individual copy failure continues ────────────────────────────────────

@test "oras: individual copy failure continues to next" {
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir" "${TEST_TMP}/logs"

  # oras that always fails
  cat > "${mock_dir}/oras" <<'ORAS_EOF'
#!/usr/bin/env bash
echo "oras $*" >> "${TEST_TMP}/logs/oras.log"
exit 1
ORAS_EOF
  chmod +x "${mock_dir}/oras"

  # curl that returns catalog then tags
  cat > "${mock_dir}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
if echo "$*" | grep -q '_catalog'; then
  echo '{"repositories":["repo-a","repo-b"]}'
elif echo "$*" | grep -q 'tags/list'; then
  echo '{"tags":["v1"]}'
fi
exit 0
CURL_EOF
  chmod +x "${mock_dir}/curl"

  # jq that extracts array values
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

  export PATH="${mock_dir}:${PATH}"

  run migrate_oras
  [ "$status" -eq 0 ]
  # Should process both repos despite failures
  [[ "$output" == *"2/2 repositories processed"* ]]
  [[ "$output" == *"Failed"* ]]
}
