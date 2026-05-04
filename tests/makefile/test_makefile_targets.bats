#!/usr/bin/env bats
load '/opt/bats-support/load'
load '/opt/bats-assert/load'
load '../test_helper/common'

setup() { setup_common; }
teardown() { teardown_common; }

@test "make help exits 0 and shows header" {
  run make -C "${PROJECT_DIR}" help
  assert_success
  assert_output --partial "Zot Registry Installer"
}

@test "make help lists all targets" {
  run make -C "${PROJECT_DIR}" help
  assert_success
  for target in install uninstall status logs restart certs client migrate save-image airgap-bundle airgap-install check clean test; do
    assert_output --partial "$target"
  done
}

@test "make check shows prerequisites" {
  run make -C "${PROJECT_DIR}" check
  assert_success
  assert_output --partial "Container runtime"
  assert_output --partial "openssl"
  assert_output --partial "curl"
  assert_output --partial "jq"
}

@test "make clean removes generated files" {
  touch "${PROJECT_DIR}/zot-image.tar"
  run make -C "${PROJECT_DIR}" clean
  assert_success
  [ ! -f "${PROJECT_DIR}/zot-image.tar" ]
}
