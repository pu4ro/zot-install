# Zot Registry Installer

> 한국어 문서: [README.ko.md](README.ko.md)

Automated OCI registry (Zot) deployment tool for Runway 2.0. Use as a standalone registry, with optional migration to another permanent registry.

## Features

- Container image push/pull
- OCI Helm chart push/pull
- Automatic TLS certificate generation
- Cross-OS: Ubuntu/Debian, RHEL/CentOS/Rocky, SLES, macOS
- Cross-runtime: docker, nerdctl (containerd), podman
- systemd-managed service (`zot.service`): auto-restart and survives reboot
- Air-gapped environment support
- Registry migration (3 strategies)

## Quick Start

```bash
# 1. Configure environment
cp .env.example .env
vi .env                # ZOT_IP is required

# 2. Pre-flight check
make check

# 3. Install
make install

# 4. Verify
make status
```

## Commands (Makefile)

| Command | Description |
|---|---|
| `make help` | List all available commands |
| `make install` | Install Zot registry |
| `make uninstall` | Remove Zot registry |
| `make status` | Show service/container status and catalog |
| `make logs` | Follow logs (journald if systemd-managed) |
| `make restart` | Restart the registry (via systemd if managed) |
| `make enable` | Enable the service to start on boot (systemd) |
| `make disable` | Disable the service from starting on boot (systemd) |
| `make client` | Configure TLS trust on client nodes |
| `make migrate` | Migrate to a destination registry |
| `make migrate-dry-run` | Preview migration (dry run) |
| `make save-image` | Save Zot image to a tar archive |
| `make airgap-bundle` | Create a full air-gapped bundle |
| `make airgap-install` | Install in air-gapped mode |
| `make check` | Validate environment prerequisites |
| `make clean` | Remove generated files |

## Service Management (systemd)

On Linux hosts, the installer registers a systemd unit (`zot.service`) that owns
the container lifecycle. It is enabled on boot and uses `Restart=always`, so the
registry comes back automatically after a crash or reboot.

What the installer configures to guarantee reboot survival:

- Enables the container runtime daemon on boot (`docker.service` / `containerd.service`; podman is daemonless).
- `Requires=`/`After=` the runtime daemon so the container only starts once it is ready.
- `RequiresMountsFor=` the data and cert directories, avoiding a race when they live on a separate or network mount.
- `WantedBy=multi-user.target` + `systemctl enable zot.service`.

Manage it directly with systemd:

```bash
systemctl status zot          # current state
systemctl restart zot         # restart
systemctl stop zot            # stop (won't auto-restart until started again)
journalctl -u zot -f          # follow logs
```

On hosts without systemd (e.g. macOS), the installer falls back to the runtime's
own `--restart=always` policy.

## Configuration (.env)

```bash
cp .env.example .env
```

Key variables:

| Variable | Default | Description |
|---|---|---|
| `ZOT_IP` | (required) | Server IP address |
| `ZOT_DOMAIN` | `cr.makina.rocks` | Registry domain |
| `ZOT_PORT` | `443` | Host port |
| `DATA_DIR` | `/data` | Data directory |
| `ZOT_IMAGE` | `ghcr.io/project-zot/zot:latest` | Container image |
| `AIRGAP` | `false` | Air-gapped mode |
| `ZOT_IMAGE_TAR` | - | Path to image tar for air-gapped use |

For the full list of variables, see [.env.example](.env.example).

## Air-Gapped Deployment

### Bundle Creation (on internet-connected host)

```bash
# Download image and package the bundle
make airgap-bundle
# -> produces zot-airgap-bundle.tar.gz
```

### Installation (on air-gapped host)

```bash
# 1. Transfer the bundle and extract it
tar xzf zot-airgap-bundle.tar.gz -C ./zot-install
cd zot-install

# 2. Configure environment
cp .env.example .env
vi .env    # Set ZOT_IP and AIRGAP=true

# 3. Install
make airgap-install
```

### Manual Installation (without bundle)

```bash
# Save the image on an internet-connected host
nerdctl pull ghcr.io/project-zot/zot:latest
nerdctl save -o zot-image.tar ghcr.io/project-zot/zot:latest

# Transfer to the air-gapped host, then run
sudo ./install.sh --airgap --image-tar ./zot-image.tar --ip 192.168.135.121
```

## Client Node Setup

Configure each worker node to trust the registry:

```bash
# Copy ca.crt from the Zot server to the client
scp root@<ZOT_IP>:/data/cert/ca.crt ./ca.crt

# Run on the client node
sudo ./client-setup.sh --ip <ZOT_IP> --ca ./ca.crt
```

The setup script handles:
- `/etc/hosts` entry registration
- OS-level system CA trust addition
- containerd `certs.d` configuration
- Docker `certs.d` configuration (if Docker is present)

## Usage Examples

### Container Image Push/Pull

```bash
# Tag & Push
nerdctl tag myapp:v1 cr.makina.rocks/myorg/myapp:v1
nerdctl push cr.makina.rocks/myorg/myapp:v1

# Pull
nerdctl pull cr.makina.rocks/myorg/myapp:v1
```

### Helm Chart Push/Pull (OCI)

```bash
# Push
helm push mychart-1.0.0.tgz oci://cr.makina.rocks/charts

# Pull
helm pull oci://cr.makina.rocks/charts/mychart --version 1.0.0
```

### Web UI

Open `https://<ZOT_IP>` in your browser.

## Registry Migration

Migrate from this registry to another permanent registry:

### Strategy 1: skopeo sync (recommended)

Bulk-copies all images and Helm charts.

```bash
# Set in .env
DEST_REGISTRY=harbor.example.com
STRATEGY=skopeo

# Preview
make migrate-dry-run

# Execute
make migrate
```

### Strategy 2: filesystem (fastest)

Directly rsyncs the OCI storage directory. Zot-to-Zot only.

```bash
./migrate.sh --strategy filesystem --dest-storage /mnt/data/zot
```

### Strategy 3: oras (preserves signatures/SBOM)

Preserves the full referrer chain, including Cosign signatures and SBOMs.

```bash
DEST_REGISTRY=harbor.example.com
STRATEGY=oras

make migrate
```

### Strategy Comparison

| Strategy | Speed | Referrer Preservation | External Tools |
|---|---|---|---|
| skopeo | Fast | No | skopeo |
| filesystem | Fastest | Yes | rsync |
| oras | Medium | Yes | oras |

## Directory Structure

```
zot-install/
├── .env.example          # Configuration template
├── .env                  # Local config (git-ignored)
├── .gitignore
├── CHANGELOG.md          # Release history
├── CONTRIBUTING.md       # Contributor guide
├── LICENSE               # Apache 2.0
├── Makefile              # Command entry points
├── README.md             # This document (English)
├── README.ko.md          # Korean documentation
├── install.sh            # Main installer script
├── migrate.sh            # Registry migration script
├── client-setup.sh       # Client node trust setup
├── docs/                 # Extended documentation
│   ├── ARCHITECTURE.md   # System architecture & flow diagrams
│   ├── TESTING.md        # Test suite documentation
│   └── TROUBLESHOOTING.md # Common issues & solutions
└── tests/                # BATS test suite
    ├── ci/
    │   └── matrix.yml    # GitHub Actions CI config
    ├── install/          # install.sh tests
    ├── migrate/          # migrate.sh tests
    ├── client_setup/     # client-setup.sh tests
    ├── makefile/         # Makefile target tests
    ├── integration/      # Integration test suite
    └── test_helper/      # Shared test utilities
```

## License

This project is licensed under the Apache License 2.0 -- see the [LICENSE](LICENSE) file for details.

## References

- [Zot Official Documentation](https://zotregistry.dev/)
- [Zot Sync/Mirroring](https://zotregistry.dev/v2.1.15/articles/mirroring/)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)
- [Architecture](docs/ARCHITECTURE.md)
- [Testing Guide](docs/TESTING.md)
- [Migration Test Guide (host registry → host zot)](docs/migration-test-guide.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
