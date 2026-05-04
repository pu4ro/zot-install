#!/usr/bin/env bats
# Tests for install.sh /etc/hosts management

load '/opt/bats-support/load'
load '/opt/bats-assert/load'
load '../test_helper/common'
load '../test_helper/mocks'

setup() {
  setup_common
  source_functions_lax install.sh

  ZOT_DOMAIN="cr.makina.rocks"
  ZOT_IP="10.0.0.1"
  SKIP_HOSTS="false"

  # Create a fake /etc/hosts in TEST_TMP
  FAKE_HOSTS="${TEST_TMP}/hosts"
  echo "127.0.0.1 localhost" > "$FAKE_HOSTS"
}

teardown() {
  teardown_common
}

# Helper: replicate the /etc/hosts logic from main() but targeting our fake file
add_hosts_entry() {
  local hosts_file="$1"
  if [[ "$SKIP_HOSTS" == true ]]; then
    warn "Skipping /etc/hosts (--skip-hosts)"
    return 0
  elif grep -q "${ZOT_DOMAIN}" "$hosts_file" 2>/dev/null; then
    warn "${ZOT_DOMAIN} already exists in /etc/hosts"
    return 0
  else
    echo "${ZOT_IP} ${ZOT_DOMAIN}" >> "$hosts_file"
    info "Added: ${ZOT_IP} ${ZOT_DOMAIN}"
  fi
}

# ── Entry added when missing ──────────────────────────────────────────────

@test "hosts entry is added when domain is missing" {
  add_hosts_entry "$FAKE_HOSTS"

  run grep "${ZOT_DOMAIN}" "$FAKE_HOSTS"
  assert_success
  assert_output --partial "10.0.0.1 cr.makina.rocks"
}

@test "hosts file retains original content after adding entry" {
  add_hosts_entry "$FAKE_HOSTS"

  run grep "127.0.0.1 localhost" "$FAKE_HOSTS"
  assert_success
}

# ── Entry not duplicated ──────────────────────────────────────────────────

@test "hosts entry is not duplicated if already present" {
  # Add the entry once
  echo "${ZOT_IP} ${ZOT_DOMAIN}" >> "$FAKE_HOSTS"

  # Try adding again
  run add_hosts_entry "$FAKE_HOSTS"
  assert_success
  assert_output --partial "already exists"

  # Count occurrences -- should be exactly 1
  local count
  count=$(grep -c "${ZOT_DOMAIN}" "$FAKE_HOSTS")
  [[ "$count" -eq 1 ]]
}

@test "hosts entry not duplicated on repeated calls" {
  add_hosts_entry "$FAKE_HOSTS"
  add_hosts_entry "$FAKE_HOSTS"
  add_hosts_entry "$FAKE_HOSTS"

  local count
  count=$(grep -c "${ZOT_DOMAIN}" "$FAKE_HOSTS")
  [[ "$count" -eq 1 ]]
}

# ── --skip-hosts skips ────────────────────────────────────────────────────

@test "--skip-hosts skips /etc/hosts modification" {
  SKIP_HOSTS="true"

  run add_hosts_entry "$FAKE_HOSTS"
  assert_success
  assert_output --partial "Skipping"

  # Domain should not be in the hosts file
  run grep "${ZOT_DOMAIN}" "$FAKE_HOSTS"
  assert_failure
}
