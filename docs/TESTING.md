# Testing Guide

This project no longer ships an in-repo automated test suite. Migration and
installation are validated directly on **real (often air-gapped) hosts**, and
each validation run is recorded as a Markdown report under `docs/`.

## Why real-host validation

The scripts orchestrate `docker`/`containerd`, `skopeo`, TLS trust, and
`/etc/hosts` against live registries. The behaviours that matter most —
same-address cutover, repository-path preservation, air-gapped image loading,
and pre-existing `containerd` `certs.d` trust — can only be proven against a
real host with real images, so that is where testing happens.

## Running a validation

1. Stand up (or reuse) the source registry and images on the target host.
2. Install zot with `install.sh` (use `--airgap --image-tar` on air-gapped
   hosts).
3. Run `migrate.sh` with the appropriate strategy and credentials.
4. Compare catalogs and manifest digests between source and destination.
5. Perform the same-address cutover and confirm clients pull unchanged.
6. Record the steps, commands, and results in a new `docs/*-test-report.md`.

## Recorded reports

- [harbor-to-zot-test-report.md](harbor-to-zot-test-report.md) — Harbor → zot
  migration validated on a real host (`192.168.135.95`).
- [migration-guide.md](migration-guide.md) / [migration-test-guide.md](migration-test-guide.md)
  — reproducible method, expected output, and troubleshooting.

Additional reports are added here as new environments are validated.
