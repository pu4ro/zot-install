#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "=== Building test image ==="
docker build -f tests/integration/Dockerfile.test -t zot-test .

echo "=== Running unit tests ==="
docker run --rm zot-test bats tests/install/ tests/migrate/ tests/client_setup/ tests/makefile/

echo "=== All tests passed ==="
