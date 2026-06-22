# Harbor: registry connection drops on many / large pushes

> Separate issue note, referenced from the Harbor → zot replacement procedure.

## Symptom

When pushing **many images** in a row, or a **single large image** (many/large
layers), the registry connection is dropped mid-upload and the copy fails with
errors such as:

```
level=fatal msg="writing blob: Patch \"https://cr.makina.rocks:5000/v2/<repo>/blobs/uploads/<uuid>\":
                 use of closed network connection"
```

Other equivalent forms seen in the wild:

- `unexpected EOF`
- `broken pipe` / `connection reset by peer`
- `received unexpected HTTP status: 502 Bad Gateway` (nginx in front of Harbor)
- `received unexpected HTTP status: 413 Request Entity Too Large`

The push that fails is almost always in the **blob `PATCH` upload** phase (the
streaming of a layer), not in the manifest write.

## Observed during the .81 migration

While migrating Harbor → zot (153 repositories, ~55 GB), the large ML image
`cr-makina-rocks/external-hub/seldonio/mlserver:1.7.1` failed once with:

```
writing blob: Patch ".../blobs/uploads/<uuid>": use of closed network connection
```

The surrounding small images copied fine; only the large-layer image tripped
the drop — consistent with a size/time-based limit rather than a hard outage.

## Why it happens

The registry sits behind a reverse proxy (Harbor ships an `nginx` front-end;
many zot deployments add one too). The drop is almost always one of:

| Cause | Where | Effect |
|-------|-------|--------|
| `client_max_body_size` too small | nginx | large layer rejected (413) |
| `proxy_read_timeout` / `proxy_send_timeout` too short | nginx | long upload of a big layer times out → connection closed |
| Keep-alive / idle timeout hit during a slow blob | nginx / registry | "use of closed network connection" |
| Backend (registry/registryctl) restart or OOM under load | Harbor core | 502 / reset |
| Concurrent uploads exhausting workers | proxy | resets under burst |

The key point: it is a **transport / proxy limit**, not data corruption. A
retried upload of the *same* blob succeeds, which is why retry and resume work.

## Mitigations

### 1. Tooling already retries and resumes

- The copy loop uses `skopeo copy --all --retry-times N`, so transient drops
  are retried automatically per tag.
- `harbor-to-zot-replace.sh --phase migrate` is **resumable**: before copying a
  tag it compares source and destination manifest digests and **skips tags that
  already match**. Re-running the phase therefore only re-attempts the tags that
  failed — just run it again until `0 failed`:

  ```bash
  ./harbor-to-zot-replace.sh --phase migrate --src-creds admin:****   # re-run as needed
  ```

### 2. Sequential, not parallel

Copy one tag at a time (this is what the scripts do). Parallel pushes multiply
the chance of hitting proxy worker / keep-alive limits.

### 3. Raise the proxy limits on Harbor (source side)

If failures persist for large images, increase the limits on Harbor's nginx.
Edit Harbor's nginx config (`common/config/nginx/nginx.conf` in the Harbor
install dir, or the templated `harbor.yml` → re-run `prepare`) and bump:

```nginx
client_max_body_size 0;        # 0 = unlimited (or e.g. 8192m)
proxy_read_timeout   900;
proxy_send_timeout   900;
proxy_request_buffering off;   # stream large uploads instead of buffering
```

Then reload only the proxy container so the running registry is untouched:

```bash
cd /opt/harbor && docker compose restart proxy
```

> Changing Harbor config is an **environment change** — do it in a maintenance
> window and only if retries/resume are not enough.

### 4. Re-pull the failed images and retry individually

```bash
skopeo copy --all --retry-times 5 \
  --src-creds admin:**** --src-tls-verify=false --dest-tls-verify=false \
  docker://cr.makina.rocks/<repo>:<tag> \
  docker://cr.makina.rocks:5000/<repo>:<tag>
```

## OS / kernel tuning (sysctl)

The disconnect is a transport limit, so beyond the proxy config it can also be
mitigated at the **kernel/network layer**. The values below are grounded in what
was actually measured on the `.81` host (RHEL 9.6, K8s node with flannel/vxlan);
adjust to your hardware.

> Applying any of these is an **environment change**. Stage them in a sysctl
> drop-in, apply in a maintenance window, and roll back by removing the file and
> re-running `sysctl --system`.

### Measured baseline on .81 (the gaps)

| Parameter | Observed | Recommended | Why it matters here |
|-----------|----------|-------------|---------------------|
| `net.core.rmem_max` / `wmem_max` | **212992 (208 KB)** | `16777216` (16 MB) | default is far too small for large layer uploads → stalls/resets under load |
| `net.ipv4.tcp_rmem` / `tcp_wmem` | default | `4096 87380 16777216` / `4096 65536 16777216` | lets TCP autoscale windows for big blobs |
| `net.ipv4.tcp_slow_start_after_idle` | **1** | `0` | between layers the connection idles; `1` collapses the window and the next big PUT/PATCH stalls |
| `net.ipv4.tcp_keepalive_time` | **7200 (2 h)** | `600` | a half-dead proxy/peer isn't noticed for 2 h; 10 min keeps long uploads alive and fails fast |
| `net.ipv4.tcp_keepalive_intvl` / `_probes` | 75 / 9 | `30` / `5` | quicker, tighter liveness probing during slow uploads |
| `net.ipv4.tcp_mtu_probing` | **0** | `1` | **flannel/vxlan overlay** can blackhole large packets (PMTU); probing avoids the silent mid-transfer hang that surfaces as "use of closed network connection" |
| `net.ipv4.ip_local_port_range` | 32768–60999 | `1024 65000` | more ephemeral ports for bursty, many-image pushes |
| `net.core.somaxconn` | 32768 (OK) | keep ≥ 4096 | listen backlog for connection bursts |
| `net.core.netdev_max_backlog` | 16384 (OK) | keep / `16384` | NIC ingress queue under burst |
| conntrack `nf_conntrack_max` | 655360 (count ~4 k, OK) | keep; monitor | on a K8s node a full conntrack table drops packets → resets; headroom is fine now |
| `fs.file-max` | 2097152 (OK) | keep | system-wide fd ceiling |
| process `nofile` (ulimit -n) | **1024** | `1048576` | low per-process fd limit can starve the registry/proxy under many connections |

`tcp_slow_start_after_idle=1`, the 208 KB socket buffers, `tcp_mtu_probing=0`
on a vxlan overlay, and the 2 h keepalive are the four most likely contributors
on this host.

### Drop-in to apply (after approval)

```bash
cat > /etc/sysctl.d/99-registry-tuning.conf <<'EOF'
# Larger socket buffers for big image-layer transfers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# Don't collapse the congestion window between layers
net.ipv4.tcp_slow_start_after_idle = 0
# Keep long uploads alive; detect dead proxy/peer faster
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# Avoid PMTU blackholes over the flannel/vxlan overlay
net.ipv4.tcp_mtu_probing = 1
# More ephemeral ports for bursty pushes
net.ipv4.ip_local_port_range = 1024 65000
# Connection-burst headroom
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
# Conntrack headroom (K8s node) — raise only if count approaches max
net.netfilter.nf_conntrack_max = 1048576
EOF

sysctl --system          # apply
# rollback: rm /etc/sysctl.d/99-registry-tuning.conf && sysctl --system
```

Raise the per-process file-descriptor limit for the registry/proxy/runtime too
(systemd-managed services):

```bash
mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
systemctl daemon-reload && systemctl restart containerd   # maintenance window
```

### Monitor to confirm the cause/fix

```bash
# conntrack pressure (should stay well under nf_conntrack_max)
watch -n2 'cat /proc/sys/net/netfilter/nf_conntrack_count'
dmesg | grep -i 'nf_conntrack: table full'        # any hit => raise nf_conntrack_max

# listen-queue overflow and retransmits during a migration run
nstat -az | grep -E 'ListenOverflows|ListenDrops|RetransSegs|TCPSynRetrans'

# MTU blackhole smoke test across the overlay (should not hang)
ping -M do -s 1472 <peer-ip>
```

## Bottom line

The drop is a proxy/transport limit triggered by large or bursty uploads, not
data loss. Retry + digest-based resume recover it without manual bookkeeping;
raising Harbor's nginx timeouts/body-size removes the trigger for very large
images.
