# Architecture

This document describes the high-level architecture and component relationships of the Zot Registry Installer.

## Component Overview

| Component | File | Purpose |
|-----------|------|---------|
| Installer | `install.sh` | Detects OS/runtime, generates TLS certs, deploys Zot container |
| Migrator | `migrate.sh` | Migrates registry data to a destination registry (3 strategies) |
| Client Setup | `client-setup.sh` | Configures client nodes to trust the registry |
| Makefile | `Makefile` | User-facing command interface for all operations |
| Configuration | `.env` / `.env.example` | Environment variable configuration |

## Configuration Hierarchy

Configuration values are resolved in this order (later sources override earlier ones):

```
Defaults (hardcoded) → .env file → CLI arguments
```

Each script loads `.env` if present using bash's `set -a` / `set +a` pattern to source all variables, then parses CLI arguments that override any `.env` values.

### Default Values

**install.sh defaults:**
- `ZOT_DOMAIN`: `cr.makina.rocks`
- `ZOT_PORT`: `443`
- `ZOT_INTERNAL_PORT`: `5000`
- `DATA_DIR`: `/data`
- `CERT_DIR`: `${DATA_DIR}/cert`
- `ZOT_STORAGE`: `${DATA_DIR}/zot`
- `ZOT_IMAGE`: `ghcr.io/project-zot/zot:latest`

**migrate.sh defaults:**
- `SOURCE_REGISTRY`: `cr.makina.rocks`
- `STRATEGY`: `skopeo`
- `SOURCE_STORAGE`: `/data/zot`
- `SOURCE_CA`: `/data/cert/ca.crt`

**client-setup.sh defaults:**
- `ZOT_DOMAIN`: `cr.makina.rocks`
- `ZOT_PORT`: `443`

## Install Flow

```
make install
    │
    ▼
install.sh --ip <IP>
    │
    ├─ 1. Load .env (if present)
    ├─ 2. Parse CLI arguments (override .env)
    ├─ 3. Check root privileges
    ├─ 4. Detect OS (Ubuntu/Debian, RHEL/CentOS, SLES, macOS)
    ├─ 5. Detect container runtime (nerdctl > docker > podman)
    ├─ 6. Detect/validate IP address
    ├─ 7. Generate TLS certificates (CA + server cert with SAN)
    │     └─ SAN includes: domain name, IP address, localhost
    ├─ 8. Update /etc/hosts (unless --skip-hosts)
    ├─ 9. Load image from tar (if --airgap --image-tar)
    │     └─ Or pull image from registry (online mode)
    ├─ 10. Generate Zot JSON config
    ├─ 11. Start Zot container
    │      └─ Mounts: certs, storage, config
    ├─ 12. Configure OS-level CA trust
    ├─ 13. Configure runtime-specific certs (containerd/Docker)
    └─ 14. Health check (curl /v2/_catalog)
```

### OS Detection

The installer uses `/etc/os-release` to identify the operating system and distribution. Supported families:

- Ubuntu/Debian (ID: ubuntu, debian)
- RHEL/CentOS/Rocky (ID: rhel, centos, rocky, alma, fedora)
- SLES/openSUSE (ID: sles, opensuse)
- macOS (detected via `uname -s`)

### Container Runtime Priority

The installer searches for runtimes in this order:

1. **nerdctl** - Preferred (containerd-native)
2. **docker** - If available and daemon is running
3. **podman** - Fallback option

### TLS Certificate Generation

The installer generates a self-signed CA and server certificate with the following SAN (Subject Alternative Names):

- Registry domain name (e.g., `cr.makina.rocks`)
- Server IP address
- `localhost` and `127.0.0.1`

Certificates are stored in `${CERT_DIR}`:
- `ca.crt` - Root CA certificate
- `ca.key` - Root CA private key
- `server.crt` - Server certificate (public)
- `server.key` - Server certificate (private)

### Zot Configuration

The installer generates a JSON configuration file at `${ZOT_STORAGE}/config.json` with:

- Storage backend: OCI directory layout
- HTTPS with TLS certificates
- Catalog API enabled

### Container Startup

The Zot container is started with:

- Port mapping: `${ZOT_PORT}` (host) → `${ZOT_INTERNAL_PORT}` (container, default 5000)
- Volume mounts:
  - `${CERT_DIR}` → `/etc/zot/certs` (TLS certificates)
  - `${ZOT_STORAGE}` → `/data` (OCI storage)
  - Config file → `/etc/zot/config.json`
- Named container: `zot` (for easy identification)

### OS-Level CA Trust

After starting the container, the installer configures the host OS to trust the self-signed CA:

- **Ubuntu/Debian**: Copies CA to `/usr/local/share/ca-certificates/` + runs `update-ca-certificates`
- **RHEL/CentOS**: Copies CA to `/etc/pki/ca-trust/source/anchors/` + runs `update-ca-trust`
- **SLES**: Copies CA to `/usr/share/pki/trust/anchors/` + runs `update-ca-certificates`
- **macOS**: Imports CA into system keychain via `security add-trusted-cert`

### Runtime-Specific Configuration

#### containerd (nerdctl)

Creates `/etc/containerd/certs.d/<domain>:<port>/hosts.toml` with:

- Server address and capabilities
- Path to CA certificate
- Restarts containerd service if running

#### Docker

Creates `/etc/docker/certs.d/<domain>:<port>/ca.crt` with the CA certificate.

## Migration Flow

Migration supports three strategies for moving data from this Zot registry to a permanent destination:

```
make migrate
    │
    ▼
migrate.sh --strategy <STRATEGY> --dest <REGISTRY>
    │
    ├─ 1. Load .env, parse CLI arguments
    ├─ 2. Validate strategy and required tools
    ├─ 3. Select strategy:
    │
    ├── skopeo ──────── skopeo sync --src docker (all repos from catalog)
    ├── filesystem ──── rsync OCI storage directory to destination
    └── oras ────────── oras copy per-repo (preserves referrers/signatures)
    
    └─ 4. Verify migration (curl destination catalog)
```

### Strategy: skopeo

Uses OCI Image spec-compliant tool to bulk copy all images and artifacts.

**Requirements:**
- `skopeo`
- `jq` (for parsing catalog)
- Network access to source and destination

**Process:**
1. Fetches repository catalog from source registry (`/v2/_catalog`)
2. Iterates through each repository
3. Calls `skopeo sync` for each repository with:
   - Source TLS certificate (if present)
   - Destination TLS certificate (if present)
   - Retry logic for transient failures
4. Continues on failure for remaining repositories

**Best for:** Large registries with many repositories, simple image-only migration.

### Strategy: filesystem

Direct copy of OCI storage directory to destination using `rsync`.

**Requirements:**
- `rsync`
- Local or network-accessible destination path
- Appropriate filesystem permissions

**Process:**
1. Validates source storage directory exists
2. Creates destination directory
3. Runs `rsync -avH` to preserve:
   - All file attributes
   - Hard links (important for OCI blob deduplication)
4. Logs size information

**Flags used:**
- `-a` - Archive mode (preserves permissions, timestamps, etc.)
- `-v` - Verbose
- `-H` - Hard links
- `--progress` - Progress indicator

**Best for:** Migrating to a persistent volume or storage path on the same host or network share.

### Strategy: oras

Uses OCI Artifact specification-aware tool to copy images and referrers (signatures, attestations).

**Requirements:**
- `oras`
- `jq` (for parsing catalog)
- Network access to source and destination

**Process:**
1. Fetches repository catalog from source registry
2. Iterates through each repository
3. Calls `oras copy` for each image with:
   - All layers and manifests
   - Referrers (signatures, SBOMs, attestations)
   - Source and destination credentials
4. Continues on failure for remaining repositories

**Best for:** Migration scenarios requiring artifact referrers and signatures to be preserved.

## Client Setup Flow

The `client-setup.sh` script configures a client node to securely access the Zot registry by installing certificates and configuring container runtimes.

```
client-setup.sh --ip <ZOT_IP> --ca <CA_PATH>
    │
    ├─ 1. Load .env, parse CLI arguments
    ├─ 2. Check root privileges
    ├─ 3. Detect OS
    ├─ 4. Add registry to /etc/hosts
    ├─ 5. Install CA certificate (OS-specific):
    │     ├─ Ubuntu/Debian: /usr/local/share/ca-certificates/ + update-ca-certificates
    │     ├─ RHEL/CentOS: /etc/pki/ca-trust/source/anchors/ + update-ca-trust
    │     ├─ SLES: /usr/share/pki/trust/anchors/ + update-ca-certificates
    │     └─ macOS: security add-trusted-cert (system keychain)
    ├─ 6. Configure containerd certs.d (if containerd present)
    │     └─ /etc/containerd/certs.d/<domain>:<port>/hosts.toml
    └─ 7. Configure Docker certs (if Docker present)
          └─ /etc/docker/certs.d/<domain>:<port>/ca.crt
```

**Requirements:**
- Root privileges (sudo)
- CA certificate file from the Zot registry host
- Container runtime installed (containerd, Docker, or both)

**Processing:**

1. **Load configuration:** Reads `.env` file if present, allowing pre-configuration of ZOT_DOMAIN and ZOT_PORT
2. **Parse arguments:** CLI arguments override `.env` values
3. **Validation:** Ensures ZOT_IP is provided and CA certificate file exists
4. **OS detection:** Uses `/etc/os-release` (or `uname` for macOS) to determine CA installation method
5. **Hosts file:** Adds DNS entry to `/etc/hosts` if not already present
6. **System CA:** Installs CA certificate in OS-specific trust store
7. **containerd configuration:** If containerd is available, creates `/etc/containerd/certs.d/` configuration
8. **Docker configuration:** If Docker is available, creates `/etc/docker/certs.d/` configuration

## Air-Gapped Deployment Flow

For environments without internet access, the installer supports bundled offline deployment:

```
Internet-connected host              Air-gapped host
─────────────────────                ─────────────────
                                     
make save-image                      
  └─ Pull + save zot image           
     to zot-image.tar                
                                     
make airgap-bundle                   
  └─ Bundle: scripts +               
     image tar + configs             
     → zot-airgap-bundle.tar.gz      
            │                        
            │  (USB/SCP transfer)    
            ▼                        
                                     tar xzf zot-airgap-bundle.tar.gz
                                       └─ cp .env.example .env
                                       └─ vi .env
                                       └─ make airgap-install
                                            └─ install.sh --airgap
                                               --image-tar ./zot-image.tar
                                               └─ <runtime> load -i zot-image.tar
                                               └─ (normal install flow)
```

### Bundle Creation (make airgap-bundle)

1. Executes `make save-image`:
   - Pulls the Zot image from registry
   - Saves image to `zot-image.tar` using container runtime
   - Image size is logged
2. Creates bundle directory
3. Copies all necessary files:
   - Installation scripts: `install.sh`, `migrate.sh`, `client-setup.sh`
   - Makefile
   - Configuration template: `.env.example`
   - Documentation: `README.md`
   - Container image: `zot-image.tar`
4. Compresses to `zot-airgap-bundle.tar.gz`
5. Cleans up temporary directory
6. Displays transfer and installation instructions

### Air-Gapped Install (make airgap-install)

1. Verifies `zot-image.tar` exists
2. Calls `install.sh --airgap --image-tar ./zot-image.tar`
3. The installer:
   - Skips any online checks
   - Loads image from tar: `<runtime> load -i zot-image.tar`
   - Proceeds with normal installation flow
   - Does not attempt to pull from registry

### Environment Variables for Air-Gapped Mode

- `AIRGAP=true` - Enables air-gapped mode in scripts
- `ZOT_IMAGE_TAR=<path>` - Path to saved image tar file

## Script Testability

All three main scripts use a main guard pattern that allows them to be sourced for testing without automatically executing:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

This pattern enables:

- **Unit testing frameworks** (e.g., BATS) to source the script and call individual functions
- **Function testing** without triggering the main execution flow
- **Isolation** of function dependencies for mocking and stubbing

### Testing Implications

- Functions are defined at file load time and remain available
- The `main()` function can be tested with specific arguments
- Helper functions (e.g., `detect_os()`, `check_tool()`) can be called directly
- Shellcheck and linting tools work correctly with this pattern

See the test suite for examples in `tests/install/`, `tests/migrate/`, and `tests/client_setup/`.

## Error Handling

All scripts use `set -euo pipefail` for robust error handling:

- `-e` - Exit immediately on error (non-zero exit status)
- `-u` - Treat undefined variables as errors
- `-o pipefail` - Fail if any command in a pipe fails

Error messages are printed to stderr using the `error()` function:

```bash
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
```

This ensures clear error reporting and immediate termination on critical failures.

## Logging and Output

All scripts use consistent color-coded logging:

- `[INFO]` (green) - Informational messages
- `[WARN]` (yellow) - Warning messages (non-fatal)
- `[ERROR]` (red) - Error messages (fatal)
- `══════` (blue) - Section headers (for major steps)

## File Structure

```
zot-install/
├── .env.example          # Configuration template
├── .env                  # Local config (git-ignored)
├── .gitignore
├── CHANGELOG.md          # Release history
├── CONTRIBUTING.md       # Contributor guide
├── LICENSE               # Apache 2.0
├── Makefile              # Command entry points
├── README.md             # English documentation
├── README.ko.md          # Korean documentation
├── install.sh            # Main installer script
├── migrate.sh            # Registry migration script
├── client-setup.sh       # Client node trust setup
├── docs/                 # Extended documentation
│   ├── ARCHITECTURE.md   # This file
│   ├── TESTING.md        # Test suite documentation
│   └── TROUBLESHOOTING.md # Common issues & solutions
└── tests/                # BATS test suite
    ├── ci/
    │   └── matrix.yml    # GitHub Actions CI config
    ├── install/          # install.sh tests (6 files)
    ├── migrate/          # migrate.sh tests (7 files)
    ├── client_setup/     # client-setup.sh tests (2 files)
    ├── makefile/         # Makefile target tests (1 file)
    ├── integration/      # Integration test suite
    └── test_helper/      # Shared test utilities
```

## Key Dependencies

### Required Tools

- `bash` (4.0+) - Script interpreter
- `openssl` - TLS certificate generation
- `curl` - Health checks and API calls
- A container runtime: `docker`, `nerdctl`, or `podman`

### Optional Tools

By strategy:
- **skopeo** - For image copying
- **rsync** - For filesystem-based migration
- **oras** - For artifact-aware migration
- **jq** - For JSON parsing (catalog queries)

## Design Principles

1. **Cross-platform compatibility** - Works across Linux distributions and macOS
2. **Container runtime agnostic** - Supports docker, nerdctl, podman
3. **Configuration-driven** - All values configurable via .env or CLI
4. **Idempotent operations** - Safe to run multiple times
5. **Clear error reporting** - Fail fast with informative messages
6. **Testable design** - Scripts structured to allow unit testing
7. **Minimal dependencies** - Uses standard tools; optional tools for advanced features
8. **Offline capability** - Supports air-gapped environments
