#!/usr/bin/env bats
# Tests for migrate.sh argument parsing and defaults

setup() {
  load '../test_helper/common'
  load '../test_helper/mocks'
  setup_common
  source_functions migrate.sh
}

teardown() {
  teardown_common
}

# ── --help ────────────────────────────────────────────────────────────────

@test "migrate: --help shows usage text" {
  run usage
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: migrate.sh"* ]]
  [[ "$output" == *"--strategy"* ]]
  [[ "$output" == *"--dest"* ]]
}

# ── Unknown flag ──────────────────────────────────────────────────────────

@test "migrate: unknown flag causes error" {
  run main --bogus-flag
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option: --bogus-flag"* ]]
}

# ── Default strategy ─────────────────────────────────────────────────────

@test "migrate: default strategy is skopeo" {
  # Call main with --dry-run and --dest so it gets past validation
  # We need mocks for skopeo strategy
  setup_migrate_mocks

  run main --dest test.example.com --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"skopeo"* ]]
}

# ── .env loading ──────────────────────────────────────────────────────────

@test "migrate: .env file is loaded when present" {
  # Create a .env in the script dir (PROJECT_DIR)
  local env_file="${PROJECT_DIR}/.env"
  echo 'SOURCE_REGISTRY=from-env.example.com' > "$env_file"

  setup_migrate_mocks

  run main --dest test.example.com --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"from-env.example.com"* ]]

  # Cleanup
  rm -f "$env_file"
}
