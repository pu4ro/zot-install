# Contributing to Zot Registry Installer

Thank you for your interest in contributing to the Zot Registry Installer! This guide will help you get started with development, testing, and submitting contributions.

## Development Setup

### Clone the Repository

```bash
git clone https://github.com/project-zot/zot-install.git
cd zot-install
```

### Configure Environment Variables

Copy the example configuration and set required values:

```bash
cp .env.example .env
```

Edit `.env` and set at minimum:
- `ZOT_IP`: Your server's IP address (required)

Other common settings:
- `ZOT_DOMAIN`: Registry domain (default: `cr.makina.rocks`)
- `ZOT_PORT`: Host port (default: `443`)
- `DATA_DIR`: Data directory (default: `/data`)

### Install Prerequisites

Before contributing, ensure you have:

- **bash**: Shell scripting
- **openssl**: TLS certificate generation
- **curl**: HTTP requests
- **jq**: JSON processing
- **A container runtime**: One of:
  - docker
  - nerdctl (containerd)
  - podman

The installer auto-detects your container runtime.

## Running Tests

### Install BATS Test Framework

BATS (Bash Automated Testing System) is used for testing. Install it with the support and assertion libraries:

```bash
# Install BATS core
git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats
sudo ln -s /tmp/bats/bin/bats /usr/local/bin/bats

# Install helper libraries
git clone --depth 1 https://github.com/bats-core/bats-support.git /opt/bats-support
git clone --depth 1 https://github.com/bats-core/bats-assert.git /opt/bats-assert
```

### Run Tests

Execute all tests:

```bash
make test
```

Or run directly with BATS:

```bash
bats tests/
```

For detailed test documentation and writing new tests, see [docs/TESTING.md](docs/TESTING.md).

## Code Style Conventions

All scripts in this project follow these patterns for consistency:

### Script Header and Safety

Every script includes these lines at the top:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

This ensures:
- `set -e`: Exit on errors
- `set -u`: Fail on undefined variables
- `set -o pipefail`: Pipeline failures propagate

### Color Helper Functions

All scripts implement color output helpers for user feedback:

```bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
```

For scripts like `install.sh` and `migrate.sh`, also include:

```bash
step()  { echo -e "\n${BLUE}══════ $* ══════${NC}"; }
```

### Usage Function

Each script includes a `usage()` function showing syntax and examples:

```bash
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --option VALUE        Description (default: value)

Examples:
  ./script.sh --option value

EOF
  exit 1
}
```

### Main Function Guard

Wrap the main execution logic in a main() function, guarded so scripts can be sourced for testing:

```bash
main() {
  # Main execution code here
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

This allows tests to source the script without executing main.

### Code Quality

- Use ShellCheck for linting where possible
- Favor explicit variable declarations
- Quote all variable expansions: `"$var"` not `$var`
- Use command substitution syntax: `$(command)` not backticks

## Pull Request Process

We follow these conventions:

### Branch Naming

Use prefixes to categorize your work:

- `feature/`: New functionality (e.g., `feature/podman-rootless`)
- `fix/`: Bug fixes (e.g., `fix/cert-renewal-timeout`)
- `docs/`: Documentation updates (e.g., `docs/api-reference`)

Example: `git checkout -b feature/add-registry-export`

### PR Checklist

Before submitting a pull request, verify:

- **Tests pass**: Run `make test` and confirm all tests pass
- **Documentation updated**:
  - Update `README.md` for user-facing changes
  - Update `README.ko.md` for user-facing changes (if it exists)
  - Update relevant docs in `docs/` directory
- **No secrets committed**: Use `.gitignore` for sensitive files
- **Single logical change**: Each PR should address one feature or fix

### Creating a PR

Push your branch and create a PR on GitHub:

```bash
git push origin feature/your-feature-name
```

The PR title should follow the commit message format (see below).

## Commit Message Conventions

We follow these conventions:

### Format

```
type: short description
```

Keep the subject line under 72 characters.

### Types

Use one of these prefixes:

- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation updates
- `test`: Test additions or modifications
- `chore`: Build, dependency, or tooling changes

### Examples

```
feat: add podman rootless support
fix: correct TLS certificate validation timeout
docs: add migration troubleshooting guide
test: add BATS tests for certificate generation
chore: update base image to debian:12
```

### Full Commit Example

For commits with a body:

```
feat: add podman rootless support

- Detect rootless mode from container runtime
- Apply correct socket path and permissions
- Update documentation with rootless setup

Closes #42
```

## 한국어 요약

한국어로 기여하는 개발자를 위한 주요 정보:

- **개발 환경 설정**: `.env.example`을 `.env`로 복사한 후 `ZOT_IP` 필수 설정
- **테스트 실행**: `make test` 또는 `bats tests/`로 모든 테스트 실행 (자세한 내용은 docs/TESTING.md 참조)
- **PR 규칙**: 브랜치 이름에 `feature/`, `fix/`, `docs/` 접두사 사용, 테스트 통과 확인, README.md와 README.ko.md 업데이트 (사용자 대면 변경 시)
- **커밋 메시지**: `type: 설명` 형식 사용 (feat, fix, docs, test, chore 타입 중 선택, 제목 72자 이하)
- **코드 스타일**: 모든 스크립트는 `set -euo pipefail` 포함, 컬러 헬퍼 함수(`info()`, `warn()`, `error()`, `step()`) 사용, `main()` 함수를 `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`로 가드

---

Thank you for making the Zot Registry Installer better!
