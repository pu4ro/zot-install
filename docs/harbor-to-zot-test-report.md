# Harbor → zot 마이그레이션 테스트 결과

- **테스트 일시**: 2026-06-22
- **대상 호스트**: `192.168.135.95` (RHEL 9.3, Docker 20.10.16, GPU K8s 컨트롤플레인 노드)
- **레지스트리 주소**: `cr.makina.rocks` (→ `/etc/hosts`에 `192.168.135.95`로 매핑)
- **테스트 목적**: Harbor에 적재된 이미지를 **동일한 repository 주소를 유지**한 채 zot으로 이전(계정/robot 계정 등은 제외, 순수 이미지만)
- **사용 스크립트**: 이 저장소의 `migrate.sh` (`--strategy skopeo`)

## 결론 (요약)

| 항목 | 결과 |
|------|------|
| Harbor 신규 설치 (`cr.makina.rocks`, HTTPS 443) | ✅ 성공 |
| zot 신규 설치 (동일 인증서) | ✅ 성공 |
| 이미지 마이그레이션 (3 tags / 2 repos) | ✅ 3/3 copied, 0 failed |
| **repository 경로 정확 보존** (`testproj/alpine` 등) | ✅ Harbor와 catalog 완전 일치 |
| 콘텐츠 동일성 (manifest digest 비교) | ✅ 3/3 MATCH |
| **동일 주소 컷오버** (`cr.makina.rocks/...` → zot) | ✅ 동일 주소·동일 digest로 서비스 |
| 실제 pull (blob 전체 fetch) | ✅ 성공 |

> **핵심**: 마이그레이션 후 클라이언트는 이미지 주소 문자열을 **한 글자도 바꾸지 않고**(`cr.makina.rocks/testproj/alpine:1.0`) zot에서 그대로 pull 할 수 있음을 실측으로 확인.

## 테스트 환경 제약 및 대응

| 제약 | 대응 |
|------|------|
| 인터넷 dnf 레포 없음 → `skopeo` 미설치 | **RHEL 9.3 DVD ISO**(`/root/rhel-9.3-x86_64-dvd.iso`)를 `/cdrom1`에 마운트해 `local_BaseOS/local_AppStream` 레포에서 `skopeo 1.13.3` **정식 설치** (초기 검증은 `quay.io/skopeo/stable` 컨테이너 래퍼로 진행했으나 이후 네이티브 바이너리로 교체·재검증) |
| `docker compose` 미설치 (Harbor 전제조건) | compose v2.27 플러그인 바이너리를 `/usr/libexec/docker/cli-plugins/`에 설치 |
| 호스트가 K8s 컨트롤플레인 → **docker 데몬 재시작 금지** | seed/마이그레이션을 모두 컨테이너 skopeo로 처리, `daemon.json` 미변경 |
| 자체서명 인증서 | 인증서 SAN에 `DNS:cr.makina.rocks` 포함 발급, skopeo는 `--insecure` 사용 |

## 테스트 구성

```
cr.makina.rocks (192.168.135.95)
├── Harbor  v2.14.4   https :443  (source)   admin / Harbor12345
└── zot     latest    https :5000 (dest)     익명 (no auth)
         └─ 컷오버 후 :443 로 재바인딩
```

시드 이미지 (Harbor `testproj` 프로젝트, public):

| repository | tags |
|------------|------|
| `testproj/alpine` | `1.0`, `2.0` |
| `testproj/busybox` | `1.0` |

## 실행 절차

1. 사전요소: compose 플러그인, 컨테이너 skopeo 래퍼, 자체서명 인증서(SAN `cr.makina.rocks`)
2. `/etc/hosts`에 `192.168.135.95 cr.makina.rocks` 등록
3. Harbor 신규 설치(online installer) → `hostname: cr.makina.rocks`, https `443`
4. Harbor에 테스트 이미지 seed (skopeo copy, public 이미지 → Harbor)
5. zot 신규 설치(컨테이너, 동일 인증서)
6. `migrate.sh --strategy skopeo --source cr.makina.rocks --src-creds admin:Harbor12345 --dest cr.makina.rocks:5000 --insecure`
7. catalog/digest 비교 검증
8. 컷오버: Harbor 정지 → zot을 `:443`으로 재바인딩 → 동일 주소 검증

## 마이그레이션 명령

```bash
SOURCE_CA=/root/mig-test/certs/ca.crt ./migrate.sh --strategy skopeo \
  --source cr.makina.rocks --src-creds admin:Harbor12345 \
  --dest   cr.makina.rocks:5000 \
  --insecure
```

출력:

```
[INFO]  Found 2 repositories to migrate
[INFO]  [1/2] Copying testproj/alpine (2 tags)...
[INFO]  [2/2] Copying testproj/busybox (1 tags)...
[INFO]  Migration complete: 2/2 repos, 3 tags copied, 0 failed
```

## 검증 결과

### 1) catalog 완전 일치 (경로 보존)

```
Harbor: {"repositories":["testproj/alpine","testproj/busybox"]}
zot   : {"repositories":["testproj/alpine","testproj/busybox"]}
```

태그도 일치: `testproj/alpine` → `1.0, 2.0`, `testproj/busybox` → `1.0`

### 2) 콘텐츠 digest 동일성

```
testproj/alpine:1.0    harbor=sha256:6baf43584bcb  zot=sha256:6baf43584bcb  [MATCH]
testproj/alpine:2.0    harbor=sha256:de0eb0b3f2a4  zot=sha256:de0eb0b3f2a4  [MATCH]
testproj/busybox:1.0   harbor=sha256:73aaf090f3d8  zot=sha256:73aaf090f3d8  [MATCH]
```

### 3) 동일 주소 컷오버

Harbor 정지 후 zot을 `:443`으로 재바인딩. **포트 없는 동일 주소**로 검증:

```
who serves cr.makina.rocks/v2/  -> {"repositories":["testproj/alpine","testproj/busybox"]}   (zot)
Harbor@443 digest = sha256:6baf43584bcb...   (컷오버 전)
zot@443    digest = sha256:6baf43584bcb...   (컷오버 후)
RESULT: SAME ADDRESS + SAME DIGEST -> OK
PULL from cr.makina.rocks (zot) OK
```

→ 클라이언트는 `docker pull cr.makina.rocks/testproj/alpine:1.0`를 **그대로** 사용 가능.

## 테스트 중 발견·수정한 버그 (중요)

테스트가 `migrate.sh`의 **경로 보존 버그 2건**을 실측으로 잡아냄:

1. **이중 중첩**: 초기 구현은 `skopeo sync SRC/repo DEST/repo` 형태였는데, `skopeo sync`가 dest에 소스 repo의 basename을 자동으로 덧붙여 `testproj/alpine` → `testproj/alpine/alpine`로 저장됨.
2. **네임스페이스 소실**: dest를 레지스트리 루트로만 주면(`skopeo sync SRC/repo DEST`) basename만 보존되어 `testproj/alpine` → `alpine`으로 prefix가 사라짐.

**해결**: `skopeo sync` 대신 **태그 단위 `skopeo copy`에 dest 경로를 완전 지정**하도록 `migrate_skopeo()`를 재작성 →
`docker://SRC/${repo}:${tag}` → `docker://DEST/${repo}:${tag}`로 경로가 **정확히** 보존됨.

### `migrate.sh` 이번 변경 사항

- `--src-creds USER:PASS`, `--dest-creds USER:PASS` 추가 (Harbor 등 인증 필요한 source 대응)
- `--insecure` 추가 (자체서명/HTTP 테스트 레지스트리용 `--src/--dest-tls-verify=false`)
- `fetch_catalog()` 추가 — `_catalog` **인증 + 페이지네이션**(Link 헤더 추적) 처리
- skopeo 전략을 **태그 단위 `skopeo copy`(경로 완전 보존)** 로 재작성
- oras 전략에도 자격증명/`--insecure` 옵션 연결

## 재현/운영 메모

- 운영 환경(실 인증서) 적용 시 `--insecure` 제거하고 `--source-ca`(Harbor CA)만 지정.
- 사설 Harbor는 read 권한 robot 계정으로 `--src-creds 'robot$puller:TOKEN'` 사용 권장(계정 자체는 이전 대상 아님).
- `skopeo`는 RHEL 9.3 DVD ISO의 AppStream에서 정식 설치(1.13.3). 네트워크 dnf 레포가 없는 폐쇄망에서는 동일 방식 권장:
  ```bash
  mount -o loop,ro /root/rhel-9.3-x86_64-dvd.iso /cdrom1
  dnf -y --disablerepo=* --enablerepo=local_BaseOS,local_AppStream install skopeo
  ```
- 네이티브 skopeo는 호스트에서 직접 실행되므로 `/etc/hosts`의 `cr.makina.rocks` 항목으로 호스트명이 그대로 해석됨(컨테이너 래퍼/`--add-host` 불필요).
- 네이티브 skopeo(1.13.3)로 migrate.sh end-to-end 재검증 완료: `testproj/alpine{1.0,2.0}` + `testproj/busybox:1.0` 3/3 copied, catalog/경로 일치.
- 테스트 리소스 위치(호스트): `/root/mig-test/` (Harbor: `/root/mig-test/harbor`, zot data: `/root/mig-test/zot/data`, 인증서: `/root/mig-test/certs`)
