# Testing Guide

## Prerequisites

Install BATS (Bash Automated Testing System) and its helper libraries:

```bash
# Install bats-core
git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats
sudo ln -s /tmp/bats/bin/bats /usr/local/bin/bats

# Install support libraries
git clone --depth 1 https://github.com/bats-core/bats-support.git /opt/bats-support
git clone --depth 1 https://github.com/bats-core/bats-assert.git /opt/bats-assert
```

## Running Tests

```bash
# Run all tests
make test

# Run all tests directly
bats tests/

# Run a specific test directory
bats tests/install/

# Run a specific test file
bats tests/install/test_tls_generation.bats
```

## Test Structure

```
tests/
├── install/                    # install.sh tests (6 files)
│   ├── test_airgap.bats       # Air-gapped mode validation
│   ├── test_arg_parsing.bats  # CLI argument parsing
│   ├── test_client_trust.bats # Client trust configuration
│   ├── test_hosts_file.bats   # /etc/hosts management
│   ├── test_os_detection.bats # OS and runtime detection
│   └── test_tls_generation.bats # TLS certificate generation
├── migrate/                    # migrate.sh tests (7 files)
│   ├── test_arg_parsing.bats  # CLI argument parsing
│   ├── test_dry_run.bats      # Dry run mode
│   ├── test_filesystem.bats   # Filesystem strategy
│   ├── test_oras.bats         # ORAS strategy
│   ├── test_skopeo.bats       # Skopeo strategy
│   ├── test_strategy_validation.bats # Strategy validation
│   └── test_zot_sync.bats    # Zot sync strategy
├── client_setup/               # client-setup.sh tests (2 files)
│   ├── test_arg_parsing.bats  # CLI argument parsing
│   └── test_trust_setup.bats  # Trust configuration
├── makefile/                   # Makefile tests (1 file)
│   └── test_makefile_targets.bats # Makefile target validation
├── integration/                # Integration test suite
│   ├── Dockerfile.test        # Docker-in-Docker test container
│   ├── run_integration.sh     # Integration test runner
│   ├── test_full_install.sh   # Full installation test
│   └── test_filesystem_migration.sh # Filesystem migration test
└── test_helper/                # Shared test utilities
    ├── common.bash            # Common setup/teardown, source helpers
    └── mocks.bash             # Mock functions for external commands
```

## Test Helpers

**`test_helper/common.bash`** provides:
- `setup_common()` / `teardown_common()` -- create/cleanup temp directories
- `source_functions()` -- source a script with main guard (functions become available without running main)
- `source_functions_lax()` -- same but with `set +eu` for testing failure paths
- `mock_command()` / `mock_command_log()` -- create mock executables in temp PATH
- `mock_calls()` -- retrieve logged calls to a mocked command
- `fake_os_release()` -- create fake /etc/os-release for OS detection tests
- `create_env_file()` -- create .env files for testing .env loading

**`test_helper/mocks.bash`** provides pre-built mock setups:
- `setup_install_mocks()` -- mocks for openssl, curl, container runtimes
- `setup_migrate_mocks()` -- mocks for skopeo, oras, rsync, helm, kubectl
- `setup_runtime_mocks <runtime>` -- mock a specific container runtime
- `setup_ip_mocks <ip>` -- mock IP detection commands
- And many more specialized mock functions

## CI Pipeline

The CI pipeline is defined in `tests/ci/matrix.yml` and runs on GitHub Actions with 3 tiers:

**Tier 1: Unit Tests** (runs on every push/PR)
- Runs `bats tests/` on Ubuntu 22.04 and 24.04
- Fast feedback, catches most regressions

**Tier 2: Integration Tests** (runs after unit tests pass)
- Docker-in-Docker full installation and operation tests
- Only runs on PRs to main

**Tier 3: Multi-OS Matrix** (runs after unit tests pass)
- Tests on Ubuntu 22.04, Ubuntu 24.04, Debian 12, Rocky Linux 9
- Verifies cross-OS compatibility for TLS generation and OS detection

## Writing New Tests

1. **Determine the test directory**: Match the script being tested (install/ for install.sh, etc.)
2. **Create a new `.bats` file** with a descriptive name
3. **Required boilerplate**:
   ```bash
   #!/usr/bin/env bats

   load '/opt/bats-support/load'
   load '/opt/bats-assert/load'
   load '../test_helper/common'
   load '../test_helper/mocks'

   setup() {
     setup_common
     source_functions_lax install.sh   # or migrate.sh, client-setup.sh
   }

   teardown() {
     teardown_common
   }
   ```
4. **Write tests** using `@test` blocks with `run`, `assert_success`, `assert_failure`, `assert_output`
5. **Use mocks** instead of real external commands -- never call real docker/openssl/etc. in unit tests
6. **Run your tests**: `bats tests/your_directory/your_test.bats`
