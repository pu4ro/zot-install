.PHONY: help install uninstall status logs restart enable disable \
       certs client migrate migrate-dry-run \
       save-image load-image airgap-bundle airgap-install \
       clean check test

SHELL := /bin/bash
MAKEFLAGS += --no-print-directory

# Load .env if present
ifneq (,$(wildcard ./.env))
  include .env
  export
endif

ZOT_DOMAIN   ?= cr.makina.rocks
ZOT_IP       ?=
ZOT_PORT     ?= 443
DATA_DIR     ?= /data
ZOT_IMAGE    ?= ghcr.io/project-zot/zot:latest
AIRGAP       ?= false
STRATEGY     ?= skopeo
DEST_REGISTRY ?=
BUNDLE_DIR   ?= ./airgap-bundle

# Detect runtime
RUNTIME := $(shell command -v nerdctl 2>/dev/null || command -v docker 2>/dev/null || command -v podman 2>/dev/null)

# ── Help ────────────────────────────────────────────────────────────────────
help: ## Show this help
	@echo ""
	@echo "  Zot Registry Installer"
	@echo "  ======================"
	@echo ""
	@echo "  Setup:"
	@echo "    cp .env.example .env    # then edit .env with your settings"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ── Core Commands ───────────────────────────────────────────────────────────
install: check ## Install zot registry
	@sudo ./install.sh

uninstall: ## Remove zot registry and data
	@sudo ./install.sh --uninstall

status: ## Show zot status (systemd unit if present, else container)
	@if systemctl cat zot.service >/dev/null 2>&1; then \
		systemctl --no-pager status zot.service || true; \
	else \
		$(RUNTIME) inspect zot --format '{{.State.Status}}' 2>/dev/null || echo "not running"; \
	fi
	@echo "---"
	@curl -sk https://$(ZOT_DOMAIN):$(ZOT_PORT)/v2/_catalog 2>/dev/null || echo "API unreachable"

logs: ## Show zot logs (journald if systemd-managed, else container)
	@if systemctl cat zot.service >/dev/null 2>&1; then \
		journalctl -u zot.service -f; \
	else \
		$(RUNTIME) logs -f zot; \
	fi

restart: ## Restart zot (via systemd if managed, else container)
	@if systemctl cat zot.service >/dev/null 2>&1; then \
		sudo systemctl restart zot.service; \
	else \
		$(RUNTIME) restart zot; \
	fi

enable: ## Enable zot to start on boot (systemd)
	@systemctl cat zot.service >/dev/null 2>&1 || { echo "zot.service not found (systemd-managed install required)"; exit 1; }
	@sudo systemctl enable --now zot.service

disable: ## Disable zot from starting on boot (systemd)
	@systemctl cat zot.service >/dev/null 2>&1 || { echo "zot.service not found (systemd-managed install required)"; exit 1; }
	@sudo systemctl disable zot.service

# ── TLS ─────────────────────────────────────────────────────────────────────
certs: ## Generate TLS certificates only
	@sudo ./install.sh --certs-only

# ── Client Setup ────────────────────────────────────────────────────────────
client: ## Setup client node trust (requires ZOT_IP)
	@test -n "$(ZOT_IP)" || (echo "ERROR: Set ZOT_IP in .env"; exit 1)
	@sudo ./client-setup.sh --ip $(ZOT_IP) --ca $(DATA_DIR)/cert/ca.crt --domain $(ZOT_DOMAIN) --port $(ZOT_PORT)

# ── Migration ───────────────────────────────────────────────────────────────
migrate: ## Migrate registry to destination (requires DEST_REGISTRY or DEST_STORAGE)
	@sudo ./migrate.sh --strategy $(STRATEGY) --dest $(DEST_REGISTRY)

migrate-dry-run: ## Preview migration without executing
	@sudo ./migrate.sh --strategy $(STRATEGY) --dest $(DEST_REGISTRY) --dry-run

# ── Air-Gapped ──────────────────────────────────────────────────────────────
save-image: ## Save zot container image to tar file
	@echo "Pulling and saving $(ZOT_IMAGE)..."
	@$(RUNTIME) pull $(ZOT_IMAGE)
	@$(RUNTIME) save -o zot-image.tar $(ZOT_IMAGE)
	@echo "Saved: zot-image.tar ($$(du -h zot-image.tar 2>/dev/null | cut -f1))"

load-image: ## Load zot image from tar file
	@test -f zot-image.tar || (echo "ERROR: zot-image.tar not found. Run 'make save-image' first"; exit 1)
	@$(RUNTIME) load -i zot-image.tar
	@echo "Image loaded"

airgap-bundle: save-image ## Create complete air-gapped bundle (tar.gz)
	@echo "Creating air-gapped bundle..."
	@mkdir -p $(BUNDLE_DIR)
	@cp install.sh migrate.sh client-setup.sh Makefile .env.example README.md $(BUNDLE_DIR)/
	@cp zot-image.tar $(BUNDLE_DIR)/
	@tar czf zot-airgap-bundle.tar.gz -C $(BUNDLE_DIR) .
	@rm -rf $(BUNDLE_DIR)
	@echo ""
	@echo "Bundle created: zot-airgap-bundle.tar.gz ($$(du -h zot-airgap-bundle.tar.gz | cut -f1))"
	@echo ""
	@echo "Transfer to air-gapped host and run:"
	@echo "  tar xzf zot-airgap-bundle.tar.gz -C ./zot-install"
	@echo "  cd zot-install"
	@echo "  cp .env.example .env && vi .env"
	@echo "  make airgap-install"

airgap-install: ## Install in air-gapped mode using local image tar
	@test -f zot-image.tar || (echo "ERROR: zot-image.tar not found"; exit 1)
	@sudo ./install.sh --airgap --image-tar ./zot-image.tar

# ── Testing ─────────────────────────────────────────────────────────────────
test: ## Validation is performed on real air-gapped hosts; see docs/ test reports
	@echo "No in-repo test suite. Migration is validated on real air-gapped hosts."
	@echo "See docs/ for recorded test reports (e.g. harbor-to-zot-test-report.md)."

# ── Utilities ───────────────────────────────────────────────────────────────
check: ## Validate environment and prerequisites
	@echo "Checking prerequisites..."
	@echo -n "  Container runtime: "; command -v nerdctl || command -v docker || command -v podman || echo "NOT FOUND"
	@echo -n "  openssl: "; command -v openssl || echo "NOT FOUND"
	@echo -n "  curl: "; command -v curl || echo "NOT FOUND"
	@echo -n "  jq: "; command -v jq || echo "NOT FOUND"
	@test -f .env && echo "  .env: found" || echo "  .env: NOT FOUND (copy from .env.example)"
	@test -n "$(ZOT_IP)" && echo "  ZOT_IP: $(ZOT_IP)" || echo "  ZOT_IP: NOT SET (required)"
	@echo "  ZOT_DOMAIN: $(ZOT_DOMAIN)"
	@echo "  ZOT_PORT: $(ZOT_PORT)"
	@echo "  AIRGAP: $(AIRGAP)"

clean: ## Remove generated files (image tar, bundles)
	@rm -f zot-image.tar zot-airgap-bundle.tar.gz
	@rm -rf $(BUNDLE_DIR)
	@echo "Cleaned"
