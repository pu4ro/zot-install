# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Explicit runtime selection via `--runtime` / `CONTAINER_RUNTIME` with backend validation and fallback
- `harbor-to-zot-replace.sh` — air-gap-safe Harbor→zot full replacement with
  deploy/migrate/verify/cutover phases, path preservation, and resumable copy
  (skips tags whose raw-manifest digest already matches); never touches
  `containerd` `certs.d`, the system CA, or Harbor
- `tune-registry-kernel.sh` — one-shot, reversible kernel/network tuning
  (socket buffers, `tcp_mtu_probing`, keepalive, conntrack headroom) to mitigate
  registry connection drops on large pushes
- Docs: Harbor→zot replacement guide, registry-disconnect + kernel-tuning note,
  and a real-host (`192.168.135.81`) migration test report

### Removed

- Entire in-repo test suite (`tests/`), including the mocked BATS unit tests,
  the Docker-in-Docker integration tests, and the CI matrix. Validation is now
  performed against real air-gapped hosts and recorded under `docs/` as test
  reports.

## [1.0.0] - 2026-06-22

### Added

- Cross-OS Zot registry installation (Ubuntu/Debian, RHEL/CentOS/Rocky, SLES, macOS)
- Cross-runtime support (docker, nerdctl/containerd, podman)
- Automatic TLS certificate generation with SAN
- OCI Helm chart push/pull support
- Air-gapped deployment with offline image loading
- Registry migration with 3 strategies: skopeo sync, filesystem (rsync), oras
- Client node trust setup script (system CA, containerd certs.d, Docker certs)
- Makefile command interface for all operations
- Environment variable configuration via .env file
- BATS unit test suite (88 tests across 15 test files)
- Host registry -> host zot migration integration test (`tests/integration/test_host_migration.sh`)
- GitHub Actions CI pipeline (unit tests, integration tests, multi-OS matrix)
- Integration test suite with Docker-in-Docker
