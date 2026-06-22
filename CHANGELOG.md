# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-06-22

### Added

- Cross-OS Zot registry installation (Ubuntu/Debian, RHEL/CentOS/Rocky, SLES, macOS)
- Cross-runtime support (docker, nerdctl/containerd, podman)
- Explicit runtime selection via `--runtime` / `CONTAINER_RUNTIME` with backend validation and fallback
- Automatic TLS certificate generation with SAN
- OCI Helm chart push/pull support
- Air-gapped deployment with offline image loading
- Registry migration with 3 strategies: skopeo sync, filesystem (rsync), oras
- Client node trust setup script (system CA, containerd certs.d, Docker certs)
- Makefile command interface for all operations
- Environment variable configuration via .env file

### Removed

- Entire in-repo test suite (`tests/`), including the mocked BATS unit tests,
  the Docker-in-Docker integration tests, and the CI matrix. Validation is now
  performed against real air-gapped hosts and recorded under `docs/` as test
  reports.
