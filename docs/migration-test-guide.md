# 마이그레이션 테스트 가이드 (host registry → host zot)

`migrate.sh`가 **호스트에서 호스트로** 레지스트리 데이터를 옮기는 동작을 end-to-end로 검증하는 방법을 설명합니다. 원래 목적은 **host Harbor → host zot** 전환 검증이며, 본 가이드는 그 절차를 재현 가능한 자동 테스트로 정리한 것입니다.

> 실 Harbor로 수행한 1회성 검증 기록은 [`harbor-to-zot-test-report.md`](./harbor-to-zot-test-report.md) 참고.

---

## 1. 전제: "레지스트리가 같다"는 가정

`migrate.sh`의 skopeo 전략이 실제로 사용하는 인터페이스는 **OCI distribution-spec**(`/v2/_catalog`, manifest/blob 엔드포인트)와 **`skopeo copy`** 뿐입니다. Harbor의 `/v2/` 역시 내부에 내장된 distribution registry가 처리하므로, 이 경로에서는 Harbor와 zot의 동작이 동일합니다.

따라서 본 테스트는 **source/destination을 모두 zot**으로 두고 진행합니다. "레지스트리가 같다"는 가정 하에서 마이그레이션 로직(카탈로그 순회 · 경로 보존 복사 · 콘텐츠 동일성)을 그대로 검증할 수 있으며, Harbor 이미지를 받을 수 없는 폐쇄망/오프라인 환경에서도 재현됩니다.

| | 원래 시나리오 | 본 테스트 |
|---|---|---|
| source | host Harbor (`/v2/` = 내장 registry) | host zot |
| destination | host zot | host zot |
| 마이그레이션 경로 | `_catalog` + `skopeo copy` | 동일 |
| 검증 포인트 | 경로 보존 · digest 동일 · pull | 동일 |

실 Harbor source에 적용할 때의 차이는 §6 참고.

---

## 2. 사전 요구사항

- `docker` (데몬 기동 상태)
- `skopeo`, `jq`, `curl`, `openssl`, `rsync`
- seed 이미지(alpine/busybox)와 zot 이미지를 pull 할 수 있는 네트워크 (오프라인이면 §7 참고)

```bash
for t in docker skopeo jq curl openssl rsync; do command -v "$t" || echo "missing: $t"; done
docker info >/dev/null && echo "docker daemon UP"
```

---

## 3. 실행 방식

이전에는 저장소에 자동화 스크립트(`tests/integration/test_host_migration.sh`)가 포함되어 있었으나, 현재는 **실 호스트에서 수동 절차로 검증**합니다. 아래 §4의 단계를 순서대로 수행하고, 결과는 `docs/*-test-report.md`로 기록합니다.

---

## 4. 테스트가 수행하는 단계 (내부 동작)

| 단계 | 내용 |
|------|------|
| 1 | 작업 디렉터리 + 자체서명 인증서 생성 (SAN: `DNS:localhost`, `IP:127.0.0.1`). CA는 **`ca.crt`만 있는 전용 디렉터리**에 따로 둠 (이유는 §7) |
| 2 | source zot(`:5000`), destination zot(`:5001`)을 **HTTPS**로 기동 후 `/v2/` 헬스체크 |
| 3 | source에 **중첩 경로** 이미지 시드 — `testproj/alpine:{1.0,2.0}`, `testproj/busybox:1.0` (docker 데몬 변경 없이 `skopeo copy`로 push) |
| 4 | `migrate.sh --strategy skopeo`를 **실제 TLS 신뢰**(`--source-ca`/`--dest-ca`)로 실행 |
| 5 | source/dest `_catalog` 비교 — **경로 보존** 확인 |
| 6 | 태그별 manifest **digest 동일성** 비교 (콘텐츠 정합성) |
| 7 | destination에서 **실제 pull**(blob 전체 fetch) |
| 8 | `--strategy filesystem`로 OCI layout을 rsync 후 **바이트 동일성**(`diff -r`) 확인 (zot→zot) |

> 시드를 `skopeo copy`로 처리하는 이유: 자체서명 레지스트리에 `docker push` 하려면 docker 데몬의 insecure-registry 설정/재시작이 필요합니다. 호스트가 K8s 노드 등인 경우 데몬 재시작은 위험하므로, 데몬을 건드리지 않는 skopeo push를 사용합니다.

---

## 5. 실제 실행 결과 (2026-06-22)

환경: skopeo 1.13.3, docker 29.5.3, jq 1.7, openssl 3.0.13, zot 이미지 `ghcr.io/project-zot/zot@sha256:48b0c11c…0a3cc0`.

```
== 4. Run migrate.sh --strategy skopeo (real TLS trust via CA) ==
[INFO]  Found 2 repositories to migrate
[INFO]  [1/2] Copying testproj/alpine (2 tags)...
[INFO]  [2/2] Copying testproj/busybox (1 tags)...
[INFO]  Migration complete: 2/2 repos, 3 tags copied, 0 failed

== 5. Verify catalog parity (path preservation) ==
  src: ["testproj/alpine","testproj/busybox"]
  dst: ["testproj/alpine","testproj/busybox"]
[ OK ] catalog matches (nested paths preserved)

== 6. Verify per-tag manifest digest parity (content identity) ==
[ OK ] testproj/alpine:1.0   sha256:b58899f0…c2171  [MATCH]
[ OK ] testproj/alpine:2.0   sha256:c64c687c…83b5e  [MATCH]
[ OK ] testproj/busybox:1.0  sha256:b7f3d86d…9e29f  [MATCH]

== 7. Verify real pull from destination (full blob fetch) ==
[ OK ] pulled testproj/alpine:1.0 from destination

== 8. Verify filesystem strategy (zot -> zot, rsync of OCI layout) ==
[ OK ] filesystem rsync produced identical OCI layout

ALL CHECKS PASSED
```

| 검증 항목 | 결과 |
|------|------|
| skopeo 마이그레이션 (3 tags / 2 repos) | ✅ 3/3 copied, 0 failed |
| repository 경로 보존 (`testproj/...`) | ✅ catalog 완전 일치 |
| 콘텐츠 digest 동일성 | ✅ 3/3 MATCH |
| destination 실제 pull | ✅ 성공 |
| filesystem 전략 OCI layout 동일성 | ✅ `diff -r` 일치 |

---

## 6. 실 Harbor source에 적용할 때의 차이

본 테스트의 source를 실제 Harbor로 바꾸면 다음만 달라집니다(전략 로직은 동일).

```bash
./migrate.sh --strategy skopeo \
  --source harbor.example.com --src-creds 'robot$puller:TOKEN' \
  --dest   zot.example.com    --dest-creds 'admin:zotpass' \
  --source-ca /path/to/harbor-ca.crt
```

- **인증**: Harbor private 프로젝트는 `_catalog`/pull에 읽기 자격증명 필요 → `--src-creds` (robot 계정 권장). 계정 자체는 이전 대상이 아님.
- **TLS**: 운영 환경은 `--source-ca`로 Harbor CA 검증. 테스트/자체서명 한정으로만 `--insecure` 사용.
- **동일 주소 컷오버**: zot을 임시 포트로 띄워 복사 → DNS/`/etc/hosts`/프록시를 같은 호스트명으로 zot에 전환(인증서 재사용) → Harbor 폐기. 자세한 절차는 [`migration-guide.md`](./migration-guide.md) §5.

---

## 7. 트러블슈팅

| 증상 | 원인/조치 |
|------|-----------|
| zot 기동 실패: `couldn't initialize inotify: too many open files` | 호스트 inotify 인스턴스 한도 소진(예: kind/다수 컨테이너). `sudo sysctl -w fs.inotify.max_user_instances=1024` (런타임 한정, 영구 적용은 `/etc/sysctl.d/`) |
| skopeo: `missing client certificate server.cert for key server.key` | `--cert-dir`(=`--source-ca`의 디렉터리)에 `*.key`가 있으면 skopeo가 **클라이언트 인증서 쌍**으로 오인. CA는 `ca.crt`만 담긴 **전용 디렉터리**에 둘 것 |
| `Bind for 0.0.0.0:5000 failed` | 포트 충돌 → `SRC_PORT`/`DST_PORT` 변경 |
| seed pull 실패 | 오프라인 환경. 사내 미러를 `SEED` 소스로 바꾸거나, zot 이미지·seed 이미지를 미리 `docker load` |
| `x509: certificate signed by unknown authority` | source/dest CA를 `--source-ca`/`--dest-ca`로 지정(또는 테스트 한정 `--insecure`) |

---

## 8. 정리

스크립트는 컨테이너를 자동 제거하지만, 작업 디렉터리는 남습니다:

```bash
docker rm -f mig-src mig-dst 2>/dev/null || true
rm -rf /tmp/zot-mig-test
```
