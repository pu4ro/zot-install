#!/usr/bin/env bash
# Common BATS test helpers for zot-install project

PROJECT_DIR="/root/zot-install"

# ── setup / teardown ───────────────────────────────────────────────────────

setup_common() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  ORIG_PATH="$PATH"
  export ORIG_PATH
}

teardown_common() {
  PATH="$ORIG_PATH"
  if [[ -d "${TEST_TMP:-}" ]]; then
    rm -rf "$TEST_TMP"
  fi
}

# ── Source helpers ─────────────────────────────────────────────────────────

# Source a script's functions without executing main().
# The main guard `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
# prevents execution when sourced.
# Also overrides error() so it returns 1 instead of exit 1 (which kills BATS).
source_functions() {
  local script="$1"
  if [[ "$script" != /* ]]; then
    script="${PROJECT_DIR}/${script}"
  fi
  # shellcheck source=/dev/null
  source "$script"
  # Use exit 1 so that error() stops execution inside `run` subshells.
  # exit 1 inside a `run` subshell only exits that subshell, not the BATS process.
  error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }
}

# Same as source_functions but disables errexit and nounset for failure-path tests.
source_functions_lax() {
  local script="$1"
  if [[ "$script" != /* ]]; then
    script="${PROJECT_DIR}/${script}"
  fi
  set +eu
  # shellcheck source=/dev/null
  source "$script"
  # Use exit 1 so that error() stops execution inside `run` subshells.
  # exit 1 inside a `run` subshell only exits that subshell, not the BATS process.
  error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }
}

# ── Mock helpers ──────────────────────────────────────────────────────────

# Create a mock binary that outputs fixed text and returns a fixed exit code.
# Usage: mock_command <name> [output] [exit_code]
mock_command() {
  local cmd="$1"
  local output="${2:-}"
  local exit_code="${3:-0}"
  local mock_dir="${TEST_TMP}/mocks"

  mkdir -p "$mock_dir"
  cat > "${mock_dir}/${cmd}" <<MOCK_EOF
#!/usr/bin/env bash
echo "${output}"
exit ${exit_code}
MOCK_EOF
  chmod +x "${mock_dir}/${cmd}"

  # Prepend mock dir to PATH if not already there
  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# Create a mock binary that also logs each invocation to a call log file.
# Usage: mock_command_log <name> [output] [exit_code]
mock_command_log() {
  local cmd="$1"
  local output="${2:-}"
  local exit_code="${3:-0}"
  local mock_dir="${TEST_TMP}/mocks"
  local log_dir="${TEST_TMP}/logs"

  mkdir -p "$mock_dir" "$log_dir"
  cat > "${mock_dir}/${cmd}" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$0 \$*" >> "${log_dir}/${cmd}.log"
echo "${output}"
exit ${exit_code}
MOCK_EOF
  chmod +x "${mock_dir}/${cmd}"

  if [[ ":$PATH:" != *":${mock_dir}:"* ]]; then
    export PATH="${mock_dir}:${PATH}"
  fi
}

# Read the call log for a mock command.
# Usage: mock_calls <name>
mock_calls() {
  local cmd="$1"
  local log_file="${TEST_TMP}/logs/${cmd}.log"
  if [[ -f "$log_file" ]]; then
    cat "$log_file"
  fi
}

# Create a fake /etc/os-release file in TEST_TMP.
# Usage: fake_os_release <id> <version_id> <id_like>
fake_os_release() {
  local id="$1"
  local version="${2:-}"
  local like="${3:-}"
  local target="${TEST_TMP}/etc"
  mkdir -p "$target"
  cat > "${target}/os-release" <<EOF
ID=${id}
VERSION_ID=${version}
ID_LIKE=${like}
EOF
}

# Create a .env file in TEST_TMP with the given key=value pairs.
# Usage: create_env_file KEY1=value1 KEY2=value2 ...
create_env_file() {
  local env_file="${TEST_TMP}/.env"
  for kv in "$@"; do
    echo "$kv" >> "$env_file"
  done
}
