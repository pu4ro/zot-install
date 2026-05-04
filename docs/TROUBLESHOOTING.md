# Troubleshooting Guide

Common issues and solutions when using the Zot Registry Installer. Error entries reference specific script locations for debugging.

### "No supported container runtime found"

**Script:** `install.sh` (line ~94)  
**Cause:** None of docker, nerdctl, or podman are installed or available in PATH.  
**Solution:**
- Install one of: Docker (`apt install docker.io`), nerdctl with containerd, or podman
- Verify with `docker --version`, `nerdctl --version`, or `podman --version`

### "Cannot auto-detect IP"

**Script:** `install.sh` (line ~111)  
**Cause:** IP detection failed. Happens when no external network interface is configured or `hostname -I` / `ip route` don't return a usable IP.  
**Solution:**
- Specify IP explicitly: `sudo ./install.sh --ip 192.168.1.100`
- Or set `ZOT_IP` in `.env`

### "This script must be run as root"

**Script:** `install.sh` (line ~254), `client-setup.sh` (line ~129)  
**Cause:** Script requires root privileges for certificate installation, /etc/hosts modification, and container operations.  
**Solution:**
- Run with sudo: `sudo ./install.sh ...`
- Or run as root user

### "Air-gapped mode requires --image-tar" / "Image tar not found"

**Script:** `install.sh` (lines ~260-261)  
**Cause:** Air-gapped mode (`--airgap`) was specified but either `--image-tar` was not provided or the specified tar file doesn't exist.  
**Solution:**
- Generate the image tar on an internet-connected host: `make save-image`
- Transfer `zot-image.tar` to the air-gapped host
- Run: `sudo ./install.sh --airgap --image-tar ./zot-image.tar --ip <IP>`

### "No server.crt found" / "No server.key found"

**Script:** `install.sh` (lines ~285-286)  
**Cause:** `--skip-certs` was used but no existing TLS certificates were found in the certificate directory.  
**Solution:**
- Either remove `--skip-certs` to auto-generate certificates
- Or place existing `server.crt` and `server.key` in the cert directory (default: `/data/cert/`)
- Regenerate certificates only: `make certs`

### "Zot container already exists"

**Script:** `install.sh` (line ~391)  
**Cause:** A container named `zot` already exists from a previous installation.  
**Solution:**
- Use `--force` flag to overwrite: `sudo ./install.sh --force --ip <IP>`
- Or uninstall first: `make uninstall`
- Check current status: `make status`

### "Zot may not be ready yet" (startup timeout)

**Script:** `install.sh` (line ~432)  
**Cause:** The container started but the health check didn't succeed within 30 seconds. This is a warning, not a fatal error.  
**Solution:**
- Check container logs: `make logs`
- Verify the container is running: `make status`
- Common causes: port conflict, TLS configuration error, insufficient disk space

### "'X' is required but not found" (missing migration tools)

**Script:** `migrate.sh` (line ~64)  
**Cause:** A required external tool for the chosen migration strategy is not installed.  
**Solution:**
- skopeo strategy: install `skopeo` and `jq`
- zot-sync strategy: install `helm` and `kubectl`
- filesystem strategy: install `rsync`
- oras strategy: install `oras` and `jq`

### "--dest is required" / "--dest-storage is required"

**Script:** `migrate.sh` (lines ~73, ~311, ~343)  
**Cause:** Migration destination was not specified. Each strategy requires either `--dest` (registry URL) or `--dest-storage` (local path).  
**Solution:**
- For skopeo/zot-sync/oras: `./migrate.sh --strategy <name> --dest harbor.example.com`
- For filesystem: `./migrate.sh --strategy filesystem --dest-storage /mnt/k8s-pv/zot`
- Or set `DEST_REGISTRY` / `DEST_STORAGE` in `.env`

### "Source storage not found"

**Script:** `migrate.sh` (line ~312)  
**Cause:** The filesystem strategy requires access to the source OCI storage directory, which doesn't exist at the specified path.  
**Solution:**
- Verify the source storage path (default: `/data/zot`)
- Specify correct path: `--source-storage /path/to/zot/storage`
- Ensure the Zot registry has been installed and has stored data

### "No repositories found" (catalog issues)

**Script:** `migrate.sh` (lines ~84, ~354)  
**Cause:** The registry catalog API returned empty results or is unreachable.  
**Solution:**
- Verify source registry is running: `make status`
- Check connectivity: `curl -sk https://cr.makina.rocks/v2/_catalog`
- Ensure images have been pushed to the registry before migrating

### "--ip is required" / "--ca is required"

**Script:** `client-setup.sh` (lines ~130-131)  
**Cause:** Required parameters for client trust setup were not provided.  
**Solution:**
- Copy the CA certificate from the Zot server: `scp root@<ZOT_IP>:/data/cert/ca.crt ./ca.crt`
- Run: `sudo ./client-setup.sh --ip <ZOT_IP> --ca ./ca.crt`

### Port conflict (443 already in use)

**(Common symptom -- not a specific script error)**  
**Cause:** Another service (nginx, Apache, etc.) is already listening on port 443.  
**Solution:**
- Check what's using the port: `ss -tlnp | grep :443`
- Use a different port: `sudo ./install.sh --port 8443 --ip <IP>`
- Or stop the conflicting service

### TLS certificate SAN mismatch

**(Common symptom -- not a specific script error)**  
**Cause:** The IP address used when generating certificates doesn't match the actual server IP, or the client is connecting via an IP/hostname not included in the certificate SAN.  
**Solution:**
- Regenerate certificates with the correct IP: `sudo ./install.sh --certs-only --ip <CORRECT_IP>`
- Verify certificate SAN: `openssl x509 -in /data/cert/server.crt -text -noout | grep -A1 "Subject Alternative"`
- Run client setup again after fixing: `sudo ./client-setup.sh --ip <IP> --ca /data/cert/ca.crt`

---

**Note:** Line numbers are approximate and may shift as the codebase evolves. Use function names and error messages to locate the relevant code.
