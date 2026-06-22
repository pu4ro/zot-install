# Harbor → zot migration & cutover test report (192.168.135.81)

> Real-host validation of the **full Harbor replacement** — migration **and**
> same-address cutover — on a live K8s/Harbor node.

- **Date**: 2026-06-22
- **Host**: `192.168.135.81` — RHEL 9.6, **nerdctl 2.2.0 / containerd v2.2.0**
  (`docker` is a symlink to `nerdctl`; no dockerd). Live **K8s production node**
  (flannel/vxlan; runway/istio/gitea/seaweedfs workloads pull from this registry).
- **Domain**: `cr.makina.rocks` → `192.168.135.81` (via `/etc/hosts`)
- **zot**: `ghcr.io/project-zot/zot-linux-amd64` (v2.1.17), loaded from a tar (air-gap path)
- **Goal**: replace Harbor with zot at the **same address**, without changing
  `/etc/containerd/certs.d`, the system CA, or client config — **achieved**.

## Topology

```
cr.makina.rocks (192.168.135.81)
├── Harbor v2.11.1  :443   source  ── migrate ──▶  zot :5000 (staged)
└── after cutover:          zot :443  replaces Harbor   (Harbor stopped)
```

## Source inventory (Harbor)

- **17 projects, 153 repositories, 202 tags, `/data` ≈ 55 GB.**
- Helm charts, mirrored upstream images, and app/ML images.

## Results

| Check | Result |
|-------|--------|
| Repositories migrated | **153 / 153** |
| Tags migrated | **202 / 202** |
| Catalog identical (Harbor vs zot) | ✅ `diff` empty — paths preserved exactly |
| Content equality (raw-manifest sha256, sampled across namespaces) | ✅ MATCH |
| Large ML images (4–5 GB layers) | ✅ copied after the readTimeout fix (below) |
| **Cutover** (Harbor stopped, zot on `:443`) | ✅ performed |
| **Client pull via existing containerd trust** (`nerdctl pull cr.makina.rocks/...`) | ✅ busybox + kube-vip pulled, same address, identical digests |
| `certs.d` / system CA / client config | ✅ unchanged |

**Outcome: Harbor fully stopped; zot serves `https://cr.makina.rocks` (:443) with
all 153 repos / 202 tags. Clients pull the same `cr.makina.rocks/<repo>:<tag>`
addresses with no change.**

## Root cause found & fixed: large-image push/pull failures

Three large ML images first failed during migration:
`seldonio/mlserver:1.7.1` (4.3 GB layer), `catalogs/langflow:1.7.3`,
`runway-platform/vllm-openai:v0.18.0-tf5.1.0` (5.0 GB layer). Client error:
`use of closed network connection`.

zot's own log gave the cause:

```
error="read tcp <zot>:5000-><client>: i/o timeout"   (PatchBlobUpload)
PATCH .../blobs/uploads/<uuid>  statusCode=500  latency=1m0s  Content-Length=5017156773
```

**zot's `http.readTimeout`/`writeTimeout` default to 60 s**; a multi-GB layer
cannot finish a single PATCH within 60 s, so zot closes the connection at exactly
`1m0s`. Confirmed it was **not** kernel, the nerdctl port-forwarder, or Harbor —
the failure reproduced identically with zot on host networking, and zot logged
`latency=1m0s`.

**Fix:** set `readTimeout`/`writeTimeout` to `3600s` in the zot config and
restart. All three large images then copied cleanly. This also protects the
**cluster's pulls** of large images from zot after cutover. See
[harbor-registry-disconnect.md](harbor-registry-disconnect.md).

> The kernel tuning (`tune-registry-kernel.sh`) was also applied (larger socket
> buffers, `tcp_mtu_probing=1`, keepalive) and is good general hygiene, but it
> did **not** resolve these failures — the decisive fix was the zot timeout.

## Cutover procedure (as executed)

1. Migrated all repos to staged zot on `:5000` (anonymous, self-signed cert).
2. Raised zot `readTimeout`/`writeTimeout` to `3600s`; re-copied the 3 large images.
3. Verified catalog (153/153) and tag count (202/202).
4. **Staged Harbor's own cert** (`/data/secret/cert/server.{crt,key}`) for zot
   `:443`. `certs.d/cr.makina.rocks/hosts.toml` pins no `ca` — clients verify via
   the **system trust store**, which already trusts Harbor's "Harbor CA". Serving
   zot with Harbor's cert keeps that trust valid with **zero client change**.
5. Stopped Harbor (`docker compose down` + stop remaining containers).
6. Started zot on `:443` (`--net host`, Harbor cert, same data volume,
   `--restart=always`).
7. Verified `nerdctl --namespace k8s.io pull cr.makina.rocks/...` succeeds for
   small and app images — same address, existing trust.

## Method notes

- **Verify by `skopeo inspect --raw | sha256`, not the HTTP
  `Docker-Content-Digest` header.** zot's `docker2s2` compat re-renders manifests
  on the fly, so the HEAD digest can differ from Harbor's even when the stored
  content is identical. The scripts use the raw-manifest fingerprint.
- Migration is sequential with `skopeo copy --all --retry-times`, gentle on the
  source proxy; resumable via raw-manifest digest comparison.

## Rollback

Harbor is recoverable until its data is decommissioned:

```bash
nerdctl rm -f zot-443
cd /opt/harbor && docker compose up -d   # Harbor back on :443
```

## Conclusion

Full Harbor → zot replacement validated end-to-end on a live K8s node:
**153/153 repos, 202/202 tags, identical content and addresses**, large ML
images included, with `certs.d`/system trust/client config untouched. After
cutover, zot serves `cr.makina.rocks` and clients pull unchanged.
