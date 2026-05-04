#!/usr/bin/env bats
# Tests for migrate.sh filesystem strategy

setup() {
  load '../test_helper/common'
  load '../test_helper/mocks'
  setup_common
  source_functions migrate.sh

  # Set required globals
  SOURCE_REGISTRY="source.example.com"
  DEST_REGISTRY=""
  SOURCE_CA="${TEST_TMP}/ca.crt"
  DEST_CA=""
  DRY_RUN=false

  # Create a fake source storage with content
  SOURCE_STORAGE="${TEST_TMP}/source-zot"
  mkdir -p "${SOURCE_STORAGE}/docker/registry/v2"
  echo "blob-data" > "${SOURCE_STORAGE}/docker/registry/v2/testblob"

  DEST_STORAGE="${TEST_TMP}/dest-zot"
}

teardown() {
  teardown_common
}

# ── Missing --dest-storage errors ────────────────────────────────────────

@test "filesystem: errors when --dest-storage is empty" {
  DEST_STORAGE=""

  run migrate_filesystem
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dest-storage is required"* ]]
}

# ── Missing source storage errors ────────────────────────────────────────

@test "filesystem: errors when source storage does not exist" {
  SOURCE_STORAGE="/nonexistent/source"

  run migrate_filesystem
  [ "$status" -ne 0 ]
  [[ "$output" == *"Source storage not found"* ]]
}

# ── --dry-run shows command without executing ────────────────────────────

@test "filesystem: --dry-run shows rsync command without executing" {
  setup_rsync_mocks
  # Also need du mock
  mock_command du "100M\t${SOURCE_STORAGE}"

  DRY_RUN=true

  run migrate_filesystem
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [[ "$output" == *"rsync"* ]]
  # Destination should NOT be created in dry run
  [ ! -d "$DEST_STORAGE" ]
}

# ── Normal copy creates destination files ────────────────────────────────

@test "filesystem: normal copy creates destination with mock rsync that copies" {
  # Create a mock rsync that actually copies files
  local mock_dir="${TEST_TMP}/mocks"
  mkdir -p "$mock_dir" "${TEST_TMP}/logs"
  cat > "${mock_dir}/rsync" <<'RSYNC_MOCK'
#!/usr/bin/env bash
echo "rsync $*" >> "${TEST_TMP}/logs/rsync.log"
# Parse source and dest from the last two arguments
args=("$@")
src="${args[-2]}"
dst="${args[-1]}"
# Actually copy files
mkdir -p "$dst"
cp -a "$src"/* "$dst"/ 2>/dev/null || true
exit 0
RSYNC_MOCK
  chmod +x "${mock_dir}/rsync"
  export PATH="${mock_dir}:${PATH}"

  # Also need du mock
  mock_command du "100M\t${SOURCE_STORAGE}"

  run migrate_filesystem
  [ "$status" -eq 0 ]
  [[ "$output" == *"Filesystem migration complete"* ]]

  # Verify destination was created and has content
  [ -d "$DEST_STORAGE" ]
  [ -f "${DEST_STORAGE}/docker/registry/v2/testblob" ]
}
