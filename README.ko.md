> **English documentation: [README.md](README.md)**

# Zot Registry Installer

Runway 2.0 배포를 위한 OCI 레지스트리(Zot) 자동 설치 도구.
standalone registry로 사용하고, 필요 시 다른 영구 registry로 마이그레이션.

## 기능

- Container image push/pull
- OCI Helm chart push/pull
- TLS 자동 생성
- Cross-OS: Ubuntu/Debian, RHEL/CentOS/Rocky, SLES, macOS
- Cross-runtime: docker, nerdctl (containerd), podman
- systemd 서비스 관리(`zot.service`): 자동 재시작 + 재부팅 후 자동 기동
- Air-gapped 환경 지원
- 레지스트리 마이그레이션 (3가지 전략)

## Quick Start

```bash
# 1. 환경 설정
cp .env.example .env
vi .env                # ZOT_IP 필수 입력

# 2. 사전 체크
make check

# 3. 설치
make install

# 4. 확인
make status
```

## 명령어 (Makefile)

| 명령어 | 설명 |
|---|---|
| `make help` | 전체 명령어 목록 |
| `make install` | Zot 레지스트리 설치 |
| `make uninstall` | 제거 |
| `make status` | 서비스/컨테이너 상태 + catalog 조회 |
| `make logs` | 로그 확인 (systemd 관리 시 journald) |
| `make restart` | 재시작 (systemd 관리 시 systemctl 사용) |
| `make enable` | 부팅 자동시작 활성화 (systemd) |
| `make disable` | 부팅 자동시작 비활성화 (systemd) |
| `make client` | 클라이언트 노드 TLS 신뢰 설정 |
| `make migrate` | 목적지 레지스트리로 마이그레이션 |
| `make migrate-dry-run` | 마이그레이션 미리보기 |
| `make save-image` | Zot 이미지를 tar로 저장 |
| `make airgap-bundle` | Air-gapped 전체 번들 생성 |
| `make airgap-install` | Air-gapped 모드 설치 |
| `make check` | 환경 검증 |
| `make clean` | 생성 파일 정리 |

## 서비스 관리 (systemd)

Linux 호스트에서는 설치 시 컨테이너 라이프사이클을 관리하는 systemd 유닛
(`zot.service`)을 등록합니다. 부팅 시 자동 기동(enable)되며 `Restart=always`로
설정되어, 크래시나 재부팅 후에도 레지스트리가 자동으로 다시 올라옵니다.

재부팅 생존을 보장하기 위해 설치 스크립트가 설정하는 항목:

- 컨테이너 런타임 데몬 부팅 자동시작 enable (`docker.service` / `containerd.service`, podman은 데몬리스라 제외)
- `Requires=`/`After=`로 런타임 데몬 기동 후에만 컨테이너 시작
- 데이터/인증서 디렉터리에 대한 `RequiresMountsFor=` — 별도/네트워크 마운트 레이스 방지
- `WantedBy=multi-user.target` + `systemctl enable zot.service`

systemd로 직접 관리:

```bash
systemctl status zot          # 상태 확인
systemctl restart zot         # 재시작
systemctl stop zot            # 중지 (다시 start 전까지 자동 재시작 안 함)
journalctl -u zot -f          # 로그 확인
```

systemd가 없는 호스트(예: macOS)에서는 런타임 자체의 `--restart=always`
정책으로 폴백합니다.

## 환경 설정 (.env)

```bash
cp .env.example .env
```

주요 변수:

| 변수 | 기본값 | 설명 |
|---|---|---|
| `ZOT_IP` | (필수) | 서버 IP 주소 |
| `ZOT_DOMAIN` | `cr.makina.rocks` | 레지스트리 도메인 |
| `ZOT_PORT` | `443` | 호스트 포트 |
| `DATA_DIR` | `/data` | 데이터 디렉토리 |
| `ZOT_IMAGE` | `ghcr.io/project-zot/zot:latest` | 컨테이너 이미지 |
| `AIRGAP` | `false` | Air-gapped 모드 |
| `ZOT_IMAGE_TAR` | - | Air-gapped용 이미지 tar 경로 |

전체 변수 목록은 [.env.example](.env.example) 참조.

## Air-Gapped 환경

### 번들 생성 (인터넷 가능한 호스트에서)

```bash
# 이미지 다운로드 + 번들 패키징
make airgap-bundle
# -> zot-airgap-bundle.tar.gz 생성
```

### 설치 (Air-gapped 호스트에서)

```bash
# 1. 번들 전송 후 압축 해제
tar xzf zot-airgap-bundle.tar.gz -C ./zot-install
cd zot-install

# 2. 환경 설정
cp .env.example .env
vi .env    # ZOT_IP, AIRGAP=true 설정

# 3. 설치
make airgap-install
```

### 수동 설치 (번들 없이)

```bash
# 인터넷 호스트에서 이미지 저장
nerdctl pull ghcr.io/project-zot/zot:latest
nerdctl save -o zot-image.tar ghcr.io/project-zot/zot:latest

# Air-gapped 호스트로 전송 후
sudo ./install.sh --airgap --image-tar ./zot-image.tar --ip 192.168.135.121
```

## 클라이언트 노드 설정

각 워커 노드에서 레지스트리를 신뢰하도록 설정:

```bash
# Zot 서버에서 ca.crt를 클라이언트로 복사
scp root@<ZOT_IP>:/data/cert/ca.crt ./ca.crt

# 클라이언트에서 실행
sudo ./client-setup.sh --ip <ZOT_IP> --ca ./ca.crt
```

설정 항목:
- `/etc/hosts` 등록
- OS별 시스템 CA 신뢰 추가
- containerd `certs.d` 설정
- Docker `certs.d` 설정 (있는 경우)

## 사용 예시

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

브라우저에서 `https://<ZOT_IP>` 접속.

## 레지스트리 마이그레이션

이 레지스트리에서 다른 영구 레지스트리로 마이그레이션:

### 전략 1: skopeo sync (권장)

모든 이미지와 Helm chart를 일괄 복사.

```bash
# .env에 설정
DEST_REGISTRY=harbor.example.com
STRATEGY=skopeo

# 미리보기
make migrate-dry-run

# 실행
make migrate
```

### 전략 2: filesystem (가장 빠름)

OCI 스토리지 디렉토리를 직접 rsync. Zot -> Zot 전용.

```bash
./migrate.sh --strategy filesystem --dest-storage /mnt/data/zot
```

### 전략 3: oras (서명/SBOM 보존)

Cosign 서명, SBOM 등 referrer 체인까지 보존.

```bash
DEST_REGISTRY=harbor.example.com
STRATEGY=oras

make migrate
```

### 전략 비교

| 전략 | 속도 | referrer 보존 | 외부 도구 |
|---|---|---|---|
| skopeo | 빠름 | X | skopeo |
| filesystem | 가장 빠름 | O | rsync |
| oras | 보통 | O | oras |

## 디렉토리 구조

```
zot-install/
├── .env.example          # 환경 변수 템플릿
├── .env                  # 환경 변수 (git-ignored)
├── .gitignore
├── CHANGELOG.md          # 변경 이력
├── CONTRIBUTING.md       # 기여 가이드
├── LICENSE               # Apache 2.0 라이선스
├── Makefile              # Make 명령어
├── README.md             # 영어 문서
├── README.ko.md          # 이 문서 (한국어)
├── install.sh            # 메인 설치 스크립트
├── migrate.sh            # 레지스트리 마이그레이션 스크립트
├── client-setup.sh       # 클라이언트 노드 설정 스크립트
├── docs/                 # 상세 문서
│   ├── ARCHITECTURE.md   # 시스템 아키텍처
│   ├── TESTING.md        # 테스트 가이드
│   └── TROUBLESHOOTING.md # 문제 해결 가이드
└── tests/                # 테스트 스위트
    └── integration/      # 통합 테스트 (실 호스트 마이그레이션)
```

## 참고

- [Zot 공식 문서](https://zotregistry.dev/)
- [Zot Sync/Mirroring](https://zotregistry.dev/v2.1.15/articles/mirroring/)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)
- [Architecture](docs/ARCHITECTURE.md)
- [Testing Guide](docs/TESTING.md)
- [마이그레이션 테스트 가이드 (host registry → host zot)](docs/migration-test-guide.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
