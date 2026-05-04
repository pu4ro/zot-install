#!/usr/bin/env bats
# Tests for migrate.sh strategy validation and check_tool

setup() {
  load '../test_helper/common'
  load '../test_helper/mocks'
  setup_common
  source_functions migrate.sh
}

teardown() {
  teardown_common
}

# ── Unknown strategy ─────────────────────────────────────────────────────

@test "migrate: unknown strategy errors" {
  run main --strategy banana --dest test.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown strategy: banana"* ]]
}

# ── skopeo requires --dest ───────────────────────────────────────────────

@test "migrate: skopeo strategy requires --dest" {
  setup_migrate_mocks

  # Set DEST_REGISTRY empty explicitly
  run main --strategy skopeo
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dest is required"* ]]
}

# ── oras requires --dest ─────────────────────────────────────────────────

@test "migrate: oras strategy requires --dest" {
  setup_migrate_mocks

  run main --strategy oras
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dest is required"* ]]
}

# ── filesystem requires --dest-storage ───────────────────────────────────

@test "migrate: filesystem strategy requires --dest-storage" {
  setup_migrate_mocks

  run main --strategy filesystem
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dest-storage is required"* ]]
}

# ── filesystem with missing source storage errors ────────────────────────

@test "migrate: filesystem with nonexistent source storage errors" {
  setup_migrate_mocks

  run main --strategy filesystem \
    --source-storage /nonexistent/path \
    --dest-storage "${TEST_TMP}/dest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Source storage not found"* ]]
}

# ── check_tool with missing tool ─────────────────────────────────────────

@test "migrate: check_tool errors when tool is missing" {
  run check_tool definitely_not_a_real_command_xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"required but not found"* ]]
}

# ── check_tool with present tool ─────────────────────────────────────────

@test "migrate: check_tool succeeds for installed tool" {
  run check_tool bash
  [ "$status" -eq 0 ]
}
