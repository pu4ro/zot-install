# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
