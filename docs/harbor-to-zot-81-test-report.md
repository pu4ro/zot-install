# Harbor → zot migration test report (192.168.135.81)

> Real-host validation of the full Harbor-replacement workflow. Scope agreed
> with the operator: **full replication to a staged zot, NO cutover.**

- **Date**: 2026-06-22
- **Host**: `192.168.135.81` — RHEL 9.6, **nerdctl 2.2.0 / containerd v2.2.0**
  (`docker` is a symlink to `nerdctl`; no dockerd). Live **K8s production node**
  (flannel/vxlan; runway/istio/gitea/seaweedfs workloads pull from this registry).
- **Domain**: `cr.makina.rocks` → `192.168.135.81` (via `/etc/hosts`)
- **Goal**: replace Harbor with zot at the **same address**, air-gap-friendly,
  **without changing** `/etc/containerd/certs.d`, the system CA, or Harbor.

## Topology under test

```
cr.makina.rocks (192.168.135.81)
├── Harbor v2.11.1   :443    source (kept running)
└── zot     latest   :5000   destination (staged, no cutover)
```

zot was stood up manually (not via `install.sh`, which would have rewritten
`certs.d`). It used a working-dir-local self-signed cert, anonymous access, and
the zot image **loaded from a tar** (air-gap path). See
[harbor-to-zot-replacement.md](harbor-to-zot-replacement.md) §B for the exact
commands.

## Source inventory (Harbor)

- **17 projects**, **153 repositories**, **199 tags**, `/data` ≈ **55 GB**.
- Mix of Helm charts (`charts/...`), mirrored upstream images
  (`docker-io/...`, `ghcr-io/...`, `quay-io/...`, `nvcr-io/...`), and app images
  (`runway-platform/...`, `cr-makina-rocks/...`).

## Procedure

1. Deployed zot on `:5000` (manual; certs.d / system CA / Harbor untouched).
2. Ran `migrate.sh --strategy skopeo --source cr.makina.rocks
   --src-creds admin:**** --dest cr.makina.rocks:5000 --insecure`.
3. Re-ran the resumable `harbor-to-zot-replace.sh --phase migrate` to retry
   failures.
4. Verified catalog equality and per-tag content equality.

## Results

| Check | Result |
|-------|--------|
| Repositories migrated | **153 / 153** |
| Catalog identical (Harbor vs zot) | ✅ `diff` empty — **paths preserved exactly** |
| Tags copied & verified | **196 / 199** |
| Content equality (sampled, raw-manifest sha256) | ✅ MATCH across namespaces (`charts/gitea/gitea`, `docker-io/library/busybox`, `cr-makina-rocks/kube-vip/kube-vip`) |
| Same-address path preservation | ✅ `cr.makina.rocks/<repo>` reproduced at `cr.makina.rocks:5000/<repo>` byte-for-byte |
| Cutover | ⏸️ not performed (out of scope) |
| `certs.d` / system CA / Harbor / `:443` | ✅ unchanged |

### 3 tags failed (large images)

```
cr-makina-rocks/external-hub/seldonio/mlserver:1.7.1
cr-makina-rocks/runway-applications/catalogs/langflow:1.7.3
runway-platform/vllm-openai:v0.18.0-tf5.1.0
```

All three fail the **same way**, on a large blob upload to the destination:

```
level=fatal msg="writing blob: Patch \"https://cr.makina.rocks:5000/v2/.../blobs/uploads/<uuid>\":
                 use of closed network connection"
```

This is the **registry-disconnect-on-large-push** class
([harbor-registry-disconnect.md](harbor-registry-disconnect.md)). Here it
surfaces on the **destination (zot via the nerdctl published port)** when a
multi-GB layer is streamed. Small/medium images (196 tags) copied cleanly. The
copy is idempotent and resumable, so these recover once the transport limit is
addressed (kernel tuning and/or proxy/host-networking).

**Remedies (each is an environment change — pending operator approval):**
- Apply `tune-registry-kernel.sh` (larger socket buffers, `tcp_mtu_probing=1`
  for the vxlan overlay, keepalive, `tcp_slow_start_after_idle=0`).
- Run the staged zot on **host networking** to bypass the nerdctl userspace port
  forwarder for multi-GB uploads.
- Retry the three tags individually (`skopeo copy --all --retry-times 5 ...`).

## Method notes

- **Verify by `skopeo inspect --raw | sha256`, not the HTTP
  `Docker-Content-Digest` header.** zot's `docker2s2` compat re-renders
  manifests on the fly, so the HEAD digest can differ from Harbor's even when
  the stored content is identical. The raw manifest bytes match after
  `skopeo copy --all`. (An earlier resume pass over-copied 113 tags because it
  trusted the HEAD digest; the scripts now use the raw-manifest fingerprint.)
- Migration is **sequential with `--retry-times`**, which is gentler on the
  source proxy than parallel pushes.

## Artifacts on the host

```
/root/zot-mig/
├── certs/            # working-dir-local self-signed cert (NOT in any trust store)
├── config.json       # zot :5000 config
├── data/             # zot storage (~27 GB migrated so far)
├── zot-image.tar     # air-gap image artifact
├── migrate.sh        # repo migration engine
├── harbor-to-zot-replace.sh
├── migrate.log / resume.log
```

## Conclusion

The path-preserving, air-gap-safe, `certs.d`-non-invasive migration works on a
live K8s/Harbor node: **153/153 repositories and 196/199 tags replicated with
identical content and identical addresses**, Harbor and client trust untouched.
The remaining 3 are very large images blocked by a transport-layer disconnect on
upload — recoverable via the documented kernel/proxy tuning and a resumable
re-run, then the cutover phase can take zot to `:443`.
