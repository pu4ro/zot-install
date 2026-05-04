#!/usr/bin/env bats
# Tests for migrate.sh zot-sync strategy

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
  DEPLOY_K8S=false
  NAMESPACE="zot-registry"
  HELM_VALUES=""

  touch "$SOURCE_CA"
}

teardown() {
  teardown_common
}

# ── Config.json generated with sync extension ────────────────────────────

@test "zot-sync: generates config.json with sync extension" {
  run migrate_zot_sync
  [ "$status" -eq 0 ]

  local config="/tmp/zot-k8s-config/config.json"
  [ -f "$config" ]

  run cat "$config"
  [[ "$output" == *'"sync"'* ]]
  [[ "$output" == *'"enable": true'* ]]
  [[ "$output" == *"source.example.com"* ]]
  [[ "$output" == *'"prefix": "**"'* ]]
}

# ── Helm values.yaml generated with correct ingress host ─────────────────

@test "zot-sync: generates helm-values.yaml with correct ingress host" {
  run migrate_zot_sync
  [ "$status" -eq 0 ]

  local values="/tmp/zot-k8s-config/helm-values.yaml"
  [ -f "$values" ]

  run cat "$values"
  [[ "$output" == *"host: dest.example.com"* ]]
  [[ "$output" == *"- dest.example.com"* ]]
  [[ "$output" == *"secretName: zot-tls"* ]]
}

# ── --deploy-k8s --dry-run outputs DRY RUN markers ──────────────────────

@test "zot-sync: --deploy-k8s --dry-run outputs DRY RUN markers" {
  setup_k8s_mocks

  DRY_RUN=true
  DEPLOY_K8S=true

  run migrate_zot_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY RUN]"* ]]
  [[ "$output" == *"kubectl"* ]] || [[ "$output" == *"helm"* ]]
}

# ── config.json contains correct storage settings ────────────────────────

@test "zot-sync: config.json has storage and http settings" {
  run migrate_zot_sync
  [ "$status" -eq 0 ]

  local config="/tmp/zot-k8s-config/config.json"
  run cat "$config"
  [[ "$output" == *'"rootDirectory": "/var/lib/registry"'* ]]
  [[ "$output" == *'"port": "5000"'* ]]
  [[ "$output" == *'"distSpecVersion": "1.1.0"'* ]]
}
