# 레지스트리 마이그레이션 가이드 (Harbor → zot)

다른 레지스트리(Harbor 등)의 이미지를 zot으로 옮기는 방법을 설명합니다. `migrate.sh` 사용법과 함께, **이미지 주소를 그대로 유지**하는 무중단 전환 절차를 다룹니다.

> 실측 검증 결과는 [`harbor-to-zot-test-report.md`](./harbor-to-zot-test-report.md) 참고.

---

## 1. 핵심 개념: `mv`로는 안 된다

Harbor와 zot은 **디스크 저장 포맷이 다릅니다.** 디렉터리를 그냥 복사/이동해도 zot이 인식하지 못합니다.

| | Harbor (docker/distribution) | zot (OCI Image Layout) |
|---|---|---|
| blob | `.../v2/blobs/sha256/<xx>/<digest>/data` | `<repo>/blobs/sha256/<digest>` |
| 매니페스트/태그 | `.../v2/repositories/<repo>/_manifests`, `_layers/...link` | `<repo>/index.json` |
| 메타 | — | `<repo>/oci-layout` |

- blob의 **실제 바이트(sha256 콘텐츠)는 동일**하지만, 디렉터리 트리·매니페스트 인덱싱·태그 관리 방식이 달라 `mv`/`rsync`로 옮긴 데이터는 호환되지 않습니다.
- 따라서 **레지스트리 API(distribution-spec)를 통한 이미지 단위 복사**가 정답입니다. blob 콘텐츠가 같아 전송은 빠릅니다.

> 참고: **zot → zot**는 동일 OCI layout이라 `rootDir`를 통째로 `rsync`해도 됩니다. Harbor ↔ zot 간에는 불가.

---

## 2. 주소(repository 경로)는 그대로 유지된다

레지스트리 "주소"는 디스크 데이터가 아니라 **API 엔드포인트(호스트명:포트) + repository 경로**일 뿐입니다. zot도 동일한 distribution-spec API(`/v2/...`)를 구현하므로 주소를 그대로 유지할 수 있습니다.

| 항목 | 유지 방법 |
|------|-----------|
| repository 경로 (`project/app:tag`) | 마이그레이션 시 **경로 보존 복사** (migrate.sh가 처리) |
| 호스트명/포트 (`cr.makina.rocks`) | DNS/`/etc/hosts`/프록시를 zot으로 전환, **같은 호스트명 인증서 재사용** |

→ 두 가지가 맞으면 클라이언트(`docker pull cr.makina.rocks/project/app:tag`)는 **주소 문자열을 한 글자도 바꾸지 않고** zot으로 전환됩니다.

---

## 3. 사전 준비

| 요구 | 설명 |
|------|------|
| `skopeo` | 이미지 복사 도구. 폐쇄망은 OS ISO의 AppStream에서 설치 (아래 참고) |
| `jq`, `curl` | catalog/tags API 파싱 |
| source 읽기 권한 | Harbor에서 이미지를 **pull** 하려면 자격증명 필요 (robot 계정 등) — 계정 자체를 이전하는 건 아님 |
| dest 쓰기 권한 | zot에 인증을 걸었다면 push 자격증명 필요 (기본 zot은 익명 허용) |

### 폐쇄망에서 skopeo 설치 (RHEL 예시)

```bash
mount -o loop,ro /root/rhel-9.3-x86_64-dvd.iso /cdrom1
# /etc/yum.repos.d/local.repo 가 /cdrom1/{BaseOS,AppStream} 를 가리키도록 설정
dnf -y --disablerepo=* --enablerepo=local_BaseOS,local_AppStream install skopeo
skopeo --version
```

---

## 4. `migrate.sh` 사용법

```
Usage: migrate.sh [OPTIONS]

전략:
  --strategy skopeo       태그 단위 skopeo copy (기본, 권장 — 경로 정확 보존)
  --strategy filesystem   OCI 저장소 직접 rsync (zot→zot 전용)
  --strategy oras         oras 복사 (referrers/서명 보존)

필수:
  --dest REGISTRY         대상 레지스트리 (예: zot.example.com)

주요 옵션:
  --source REGISTRY       원본 레지스트리 (예: harbor.example.com)
  --src-creds USER:PASS   원본 자격증명 (Harbor 로그인)
  --dest-creds USER:PASS  대상 자격증명
  --source-ca PATH        원본 CA 인증서
  --insecure              src/dest TLS 검증 생략 (자체서명/HTTP 테스트용)
  --dry-run               실행 없이 미리보기
```

### Harbor → zot (인증 + 경로 보존)

```bash
./migrate.sh --strategy skopeo \
  --source harbor.example.com --src-creds 'robot$puller:TOKEN' \
  --dest   zot.example.com    --dest-creds 'admin:zotpass'
```

- 먼저 `--dry-run`으로 대상 repo 목록과 실행 명령을 확인하는 것을 권장.
- Harbor가 자체서명 CA면 `--source-ca /path/ca.crt` 추가 (또는 테스트 한정 `--insecure`).
- Harbor의 사설(private) 프로젝트는 `_catalog`/pull에 **읽기 자격증명 필수** → `--src-creds`.

### 동작 원리

1. `https://<source>/v2/_catalog` 를 **인증 + 페이지네이션**(Link 헤더 추적)으로 순회해 전체 repository 목록 수집.
2. repo별 `tags/list` 조회.
3. 각 태그를 `skopeo copy --all docker://<src>/<repo>:<tag> docker://<dest>/<repo>:<tag>` 로 복사 — **dest 경로를 완전 지정**하여 `project/app:tag`가 정확히 보존됨.

> ⚠️ `skopeo sync`는 단일 repo 소스에서 basename만 dest에 붙여 경로가 깨질 수 있어(`testproj/alpine` → `alpine` 또는 `testproj/alpine/alpine`), 본 스크립트는 **태그 단위 `skopeo copy`** 를 사용합니다.

---

## 5. 무중단 컷오버 (동일 주소 전환)

```
1. zot을 임시 주소/포트로 신규 설치
2. migrate.sh 로 전체 이미지를 경로 보존하며 복사
3. 신규 push 차단(또는 read-only) 후 마지막 증분 복사
4. DNS/hosts/프록시를 같은 호스트명 → zot 으로 전환 (인증서 재사용)
5. 검증 후 Harbor 폐기
```

검증 예시:

```bash
# catalog 일치
curl -sk https://<host>/v2/_catalog

# 콘텐츠 동일성(digest 비교)
skopeo inspect docker://<host>/project/app:tag | jq -r .Digest

# 동일 주소 pull
docker pull <host>/project/app:tag
```

---

## 6. 주의사항 / 비이전 항목

- **계정/권한 미이전**: Harbor의 robot 계정·프로젝트 RBAC·replication 정책은 옮겨지지 않습니다(이미지 콘텐츠만 이전). zot에서는 `htpasswd`/OIDC/OPA로 별도 구성.
- **Harbor UI/포털 기능 상실**: zot은 minimal registry. UI가 필요하면 `zui` 확장 별도 사용.
- **push 경로 규칙 차이**: Harbor는 project 선생성 필요, zot은 push 시 경로 자동 생성(더 단순).
- **자체서명 운영 적용**: 운영에서는 `--insecure` 대신 `--source-ca`로 CA 검증 사용.

---

## 7. 빠른 트러블슈팅

| 증상 | 원인/조치 |
|------|-----------|
| `_catalog` 401 | Harbor private → `--src-creds` 필요 |
| `_catalog` 결과 일부 누락 | 대량 레지스트리 페이지네이션 — 본 스크립트는 Link 헤더로 자동 순회 |
| dest에 경로가 `repo/repo` 로 중첩 | 구버전 `skopeo sync` 사용 시 — 현재 스크립트는 `skopeo copy`로 해결됨 |
| `x509: certificate signed by unknown authority` | `--source-ca` 지정 또는 (테스트) `--insecure` |
| `skopeo: command not found` | OS ISO AppStream에서 설치(§3) 또는 패키지 설치 |
