# Testing Guide

Testing focuses on **integration tests** that exercise the scripts end-to-end
against live registries on a real host. (The mocked BATS unit-test suite has
been removed.)

## Prerequisites

The integration tests run the real tools, so the host needs:

- `docker` (or another supported runtime)
- `skopeo`, `jq`, `curl`, `openssl`, `rsync`
- Image pull access (or pre-loaded images for air-gapped hosts)

## Running Tests

```bash
# Host migration integration test (default target)
make test

# Run it directly
tests/integration/test_host_migration.sh

# Override ports / workdir
SRC_PORT=5002 DST_PORT=5003 tests/integration/test_host_migration.sh
```

### Host migration integration test

`tests/integration/test_host_migration.sh` validates `migrate.sh` end-to-end
against two live zot registries on the host (host registry → host zot, the
same-registry assumption stand-in for host Harbor → host zot). It needs
`docker` + `skopeo`/`jq`/`curl`/`openssl`/`rsync` and image pull access.

See [migration-test-guide.md](migration-test-guide.md) for the full method,
expected output, and troubleshooting, and
[harbor-to-zot-test-report.md](harbor-to-zot-test-report.md) for a recorded
real-Harbor validation run.

## Test Structure

```
tests/
└── integration/                # Integration test suite
    ├── Dockerfile.test          # Docker-in-Docker test container
    ├── run_integration.sh       # Integration test runner
    ├── test_full_install.sh     # Full installation test
    ├── test_filesystem_migration.sh # Filesystem migration test
    └── test_host_migration.sh   # Host registry -> host zot migration (skopeo + filesystem)
```
