# Harbor → zot full replacement (air-gapped, same-address)

Goal: **completely replace a Harbor registry with zot** while keeping the exact
same address, so every client (containerd/nerdctl, docker, helm, CI) keeps
pulling `cr.makina.rocks/<repo>:<tag>` with **no change** — same hostname, same
repository paths, same digests.

This guide covers two equivalent ways to do it:

- **A. Scripted** — `harbor-to-zot-replace.sh` (recommended; resumable).
- **B. Manual** — every command spelled out, for hosts where you want to drive
  each step yourself or adapt it.

Both are designed for the constraints of a **live, air-gapped, containerd/nerdctl
host**:

- **Never touches `/etc/containerd/certs.d`, the system CA store, or Harbor.**
  Client trust for the domain already exists in `certs.d`; cutover only stops
  Harbor and rebinds zot to `:443`, so that trust keeps working unchanged.
- **Air-gap friendly** — the zot image is carried in as a tar and `load`ed; no
  pull is needed on the target host.
- **Path-preserving** — each tag is copied to a fully-qualified destination ref,
  so nested namespaces (`charts/gitea/actions`) are reproduced exactly. A plain
  `skopeo sync` would flatten them.
- **Resumable** — a tag whose digest already matches on the destination is
  skipped, so a run interrupted by a Harbor disconnect can simply be re-run
  (see [harbor-registry-disconnect.md](harbor-registry-disconnect.md)).

## Topology

```
cr.makina.rocks (one host, e.g. 192.168.135.81)
├── Harbor   :443    (source, stays up during migration)
└── zot      :5000   (destination, staged)   ── cutover ──▶  zot :443  (replaces Harbor)
```

`/etc/hosts` already maps `cr.makina.rocks` to the host IP, and containerd
`certs.d/cr.makina.rocks/hosts.toml` already trusts that domain — neither is
modified.

## Prerequisites (on the host)

- A container runtime: `nerdctl` (+ containerd), `docker`, or `podman`.
- `skopeo`, `jq`, `curl`, `openssl`.
- The zot image as a tar for air-gap, e.g. `zot-image.tar`
  (`ghcr.io/project-zot/zot-linux-amd64:latest`). On a connected helper host:
  ```bash
  nerdctl pull ghcr.io/project-zot/zot-linux-amd64:latest
  nerdctl save -o zot-image.tar ghcr.io/project-zot/zot-linux-amd64:latest
  # transfer zot-image.tar to the air-gapped host
  ```
- Harbor read credentials (e.g. `admin:****`, or a read-only robot account).

---

## A. Scripted

```bash
# 1) Validate end-to-end WITHOUT touching production (no cutover):
#    deploy zot on :5000, migrate all repos, verify digests.
./harbor-to-zot-replace.sh --phase all \
    --domain cr.makina.rocks \
    --src-creds admin:Harbor12345 \
    --image-tar ./zot-image.tar

# 2) If any tag failed (e.g. a large image hit a disconnect), just re-run
#    migrate — it resumes and only retries what is missing:
./harbor-to-zot-replace.sh --phase migrate --src-creds admin:Harbor12345

# 3) During a maintenance window, perform the actual cutover:
#    stop Harbor, rebind zot to :443. Clients keep their existing trust.
./harbor-to-zot-replace.sh --phase cutover --yes
```

Phases can also be run one at a time: `--phase deploy`, `--phase migrate`,
`--phase verify`, `--phase cutover`. See `--help` for all options
(`--dest-port`, `--runtime`, `--work`, `--harbor-compose`, `--ip`, …).

---

## B. Manual (every step)

All paths below use a working dir `WORK=/root/zot-mig`. Adjust to taste.

### B.1 Prepare working dir and TLS

The cert is **local to the working dir only** — it is NOT installed into the
system CA store or `certs.d`. `skopeo` talks to the staged zot with TLS
verification disabled, so this self-signed cert is sufficient.

```bash
WORK=/root/zot-mig; CERTS=$WORK/certs; DATA=$WORK/data
DOMAIN=cr.makina.rocks; IP=192.168.135.81
mkdir -p "$CERTS" "$DATA"

openssl genrsa -out "$CERTS/ca.key" 4096
openssl req -x509 -new -nodes -key "$CERTS/ca.key" -sha256 -days 3650 \
  -out "$CERTS/ca.crt" -subj "/CN=${DOMAIN}-zot-ca"
openssl genrsa -out "$CERTS/server.key" 4096
openssl req -new -key "$CERTS/server.key" -out "$CERTS/server.csr" -subj "/CN=${DOMAIN}"
printf 'subjectAltName=@a\n[a]\nDNS.1=%s\nIP.1=%s\n' "$DOMAIN" "$IP" > "$CERTS/v3.ext"
openssl x509 -req -in "$CERTS/server.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" \
  -CAcreateserial -out "$CERTS/server.crt" -days 365 -sha256 -extfile "$CERTS/v3.ext"
```

### B.2 zot config (HTTPS :5000, anonymous, GC off during migration)

```bash
cat > "$WORK/config.json" <<'EOF'
{
  "distSpecVersion": "1.1.0",
  "storage": { "rootDirectory": "/var/lib/registry", "gc": false },
  "http": {
    "address": "0.0.0.0", "port": "5000",
    "compat": ["docker2s2"],
    "tls": { "cert": "/certs/server.crt", "key": "/certs/server.key" }
  },
  "log": { "level": "info" }
}
EOF
```

### B.3 Load the zot image (air-gap) and run the destination

```bash
# Air-gap: load from the tar you transferred in (no pull on this host).
nerdctl load -i "$WORK/zot-image.tar"

# Run zot on :5000 in the default namespace (separate from the k8s.io
# namespace used by the kubelet). Harbor on :443 is untouched.
nerdctl rm -f zot-mig 2>/dev/null || true
nerdctl run -d --name zot-mig --restart=no \
  -p 5000:5000 \
  -v "$WORK/config.json:/etc/zot/config.json:ro" \
  -v "$CERTS:/certs:ro" \
  -v "$DATA:/var/lib/registry" \
  ghcr.io/project-zot/zot-linux-amd64:latest serve /etc/zot/config.json

# readiness
curl -sk https://$DOMAIN:5000/v2/        # -> {} once ready
curl -sk https://$DOMAIN:5000/v2/_catalog # -> {"repositories":[]}
```

> Runtime note: on this host `docker` is a symlink to `nerdctl` and there is no
> dockerd. Use `nerdctl` (or `--runtime nerdctl`). On a docker host, substitute
> `docker` — the commands are identical.

### B.4 Migrate all repositories (path-preserving)

Use the repo's `migrate.sh` (skopeo strategy). It enumerates Harbor's
`_catalog` (auth + pagination aware) and copies **each tag** with a fully
qualified destination ref so paths are preserved exactly:

```bash
./migrate.sh --strategy skopeo \
  --source cr.makina.rocks --src-creds admin:Harbor12345 \
  --dest   cr.makina.rocks:5000 \
  --insecure
```

Equivalent single-tag command (what the loop runs):

```bash
skopeo copy --all --retry-times 5 \
  --src-creds admin:Harbor12345 --src-tls-verify=false --dest-tls-verify=false \
  docker://cr.makina.rocks/<repo>:<tag> \
  docker://cr.makina.rocks:5000/<repo>:<tag>
```

If a **large image drops the connection**, retry it (it is idempotent) — see
[harbor-registry-disconnect.md](harbor-registry-disconnect.md).

### B.5 Verify (catalog + per-tag digest)

```bash
# catalogs should match
curl -sk -u admin:Harbor12345 https://cr.makina.rocks/v2/_catalog?n=5000 \
  | jq -r '.repositories[]' | sort > /tmp/harbor.cat
curl -sk https://cr.makina.rocks:5000/v2/_catalog?n=5000 \
  | jq -r '.repositories[]' | sort > /tmp/zot.cat
diff /tmp/harbor.cat /tmp/zot.cat && echo "CATALOG MATCH"

# a tag's manifest digest must be identical on both
dig() { curl -skI -u "$2" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "https://$1/v2/$3/manifests/$4" | tr -d '\r' \
  | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'; }

dig cr.makina.rocks      admin:Harbor12345 charts/gitea/actions 0.0.1
dig cr.makina.rocks:5000 ""                charts/gitea/actions 0.0.1   # must be equal
```

### B.6 Cutover (maintenance window — DISRUPTIVE)

Stop Harbor so `:443` is free, then run zot on `:443` with the **same data and
the same cert**. Client trust in `certs.d` is unchanged, so pulls continue with
the same address.

```bash
# 1) stop Harbor (frees :443)
cd /opt/harbor && docker compose down

# 2) rebind zot to :443
sed 's/"port": "5000"/"port": "443"/' "$WORK/config.json" > "$WORK/config.443.json"
nerdctl rm -f zot-mig
nerdctl run -d --name zot-mig --restart=always \
  -p 443:443 \
  -v "$WORK/config.443.json:/etc/zot/config.json:ro" \
  -v "$CERTS:/certs:ro" \
  -v "$DATA:/var/lib/registry" \
  ghcr.io/project-zot/zot-linux-amd64:latest serve /etc/zot/config.json

# 3) confirm same-address service and pull
curl -sk https://cr.makina.rocks/v2/_catalog | jq '.repositories | length'
nerdctl pull cr.makina.rocks/charts/gitea/actions:0.0.1   # unchanged address
```

Only after a successful pull and a soak period should Harbor's data be
decommissioned.

---

## What is intentionally NOT changed

- `/etc/containerd/certs.d/**` — left exactly as-is (client trust for the domain
  and all mirrors).
- System CA trust store.
- `/etc/hosts`.
- Harbor configuration and data (until you choose to decommission it after
  cutover).

## Limitations

- `skopeo copy --all` reproduces images, indexes, and OCI artifacts (incl. Helm
  charts) by digest. Cosign/Notation **referrers** attached to a tag are not
  guaranteed to follow unless copied explicitly; migrate signatures separately
  if you rely on them.
- Harbor-specific metadata (projects, RBAC, robot accounts, retention/replication
  policies, vulnerability scan results) is **not** migrated — only the registry
  content (images/charts) is, which is what clients actually pull.
