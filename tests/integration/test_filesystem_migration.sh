#!/usr/bin/env bash
set -euo pipefail
SRC_DIR="/tmp/zot-migrate-src-$$"
DST_DIR="/tmp/zot-migrate-dst-$$"
cleanup() { rm -rf "${SRC_DIR}" "${DST_DIR}"; }
trap cleanup EXIT

mkdir -p "${SRC_DIR}/repos/test-image/blobs/sha256"
echo "fake-manifest" > "${SRC_DIR}/repos/test-image/blobs/sha256/abc123"

echo "=== Filesystem migration (dry-run) ==="
OUTPUT=$(./migrate.sh --strategy filesystem --source-storage "${SRC_DIR}" --dest-storage "${DST_DIR}" --dry-run 2>&1)
echo "${OUTPUT}" | grep -q "DRY RUN"
[ ! -d "${DST_DIR}" ]
echo "PASS: Dry-run did not copy files"

echo "=== Filesystem migration (real) ==="
./migrate.sh --strategy filesystem --source-storage "${SRC_DIR}" --dest-storage "${DST_DIR}"
[ -f "${DST_DIR}/repos/test-image/blobs/sha256/abc123" ]
echo "PASS: Files migrated successfully"

echo "=== ALL MIGRATION TESTS PASSED ==="
