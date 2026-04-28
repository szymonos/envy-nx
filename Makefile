SHELL := /bin/bash

# Default target
.DEFAULT_GOAL := help

# MITM proxy support: use native TLS (OpenSSL) in prek to trust system CA certificates
export PREK_NATIVE_TLS := 1
# tell Node.js/npm to trust custom MITM proxy certificates (for prek-managed node hooks)
CA_CUSTOM := $(wildcard $(HOME)/.config/certs/ca-custom.crt)
ifdef CA_CUSTOM
export NODE_EXTRA_CA_CERTS := $(CA_CUSTOM)
endif
# root certificate interception
define ROOT_CERT_CMD
command -v openssl >/dev/null 2>&1 || { printf '\e[31;1mopenssl not found, aborting.\e[0m\n' >&2; exit 1; }; \
openssl s_client -showcerts -connect google.com:443 </dev/null 2>/dev/null \
	| awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ if(/BEGIN/){pem=""} pem=pem $$0 "\n" } END{printf "%s", pem}'
endef

define ENSURE_ROOT_CERT
set -e; \
ROOT_PEM=$$($(ROOT_CERT_CMD)); \
[ -n "$$ROOT_PEM" ] || { printf '\e[31;1mFailed to retrieve root certificate.\e[0m\n' >&2; exit 1; }; \
mkdir -p .assets/certs && printf '%s' "$$ROOT_PEM" >.assets/certs/ca-cert-root.crt
endef
CLEANUP_ROOT_CERT = rm -f .assets/certs/ca-cert-root.crt

.PHONY: help
help: ## Show this help message
	@printf 'Usage: make [target]\n\n'
	@printf "\033[1;97mAvailable targets:\033[0m"
	@awk 'BEGIN {FS = ":.*?## "} /^\.PHONY:/ {printf "\n"} /^[a-zA-Z_-]+:.*?## / {printf "  \033[1;94m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: install upgrade
install: ## Install pre-commit hooks
	@printf "📦 Installing all dependencies...\n\n"
	uv sync --all-extras --frozen
upgrade: ## Upgrade prek and hooks versions
	@printf "\n✅ All dependencies upgraded\n\n"
	uv sync --all-extras --upgrade --compile-bytecode
	uv run prek autoupdate

.PHONY: test test-unit test-nix
test: test-unit test-nix ## Run all tests (unit + Docker smoke)

test-unit: ## Run bats unit tests (fast, no Docker)
	@printf "\n\033[95;1m== Running unit tests ==\033[0m\n\n"
	@bats tests/bats/
	@pwsh -c '$$cfg = New-PesterConfiguration; $$cfg.Run.Path = "tests/pester/"; $$cfg.Run.Exit = $$true; $$cfg.Output.Verbosity = "Detailed"; Invoke-Pester -Configuration $$cfg'

test-nix: ## Run Docker smoke test for nix path
	@printf "\n\033[95;1m== Testing nix path (nix/setup.sh) ==\033[0m\n\n"
	@$(ENSURE_ROOT_CERT) && \
		docker build --no-cache \
			-f .assets/docker/Dockerfile.test-nix \
			--output type=image,name=lss-test-nix,unpack=false . \
		&& printf "\n\033[32;1m>> Nix test PASSED\033[0m\n\n" \
		&& docker rmi lss-test-nix >/dev/null 2>&1; \
		$(CLEANUP_ROOT_CERT)

.PHONY: mkdocs-serve
mkdocs-serve: ## Serve mkdocs documentation with live reload
	uv run --extra docs mkdocs serve --livereload

.PHONY: hooks hooks-install hooks-remove
hooks: ## List available pre-commit hook IDs
	@awk '/- id:/ {print "  " $$3}' .pre-commit-config.yaml | sort -u
hooks-install: ## Install pre-commit hooks
	uv run prek install --overwrite
hooks-remove: ## Remove pre-commit hooks
	uv run prek uninstall

.PHONY: hooks lint lint-diff lint-all
lint: ## Run pre-commit hooks for changed files (HOOK=id to run one hook)
	@printf "🧭 Running pre-commit hooks for changed files...\n\n"
	git add --all && uv run prek run $(HOOK)
lint-diff: ## Run pre-commit hooks for files changed in this diff (HOOK=id to run one hook)
	@printf "🧭 Running pre-commit hooks for files changed in this diff...\n\n"
	@if [ "$$(git branch --show-current)" = "main" ]; then \
		printf "⚠️  You are on the main branch. Skipping lint-diff.\n"; \
	else \
		git add --all && uv run prek run $(HOOK) --from-ref main --to-ref HEAD; \
	fi
lint-all: ## Run pre-commit hooks for all files (HOOK=id to run one hook)
	@printf "🧭 Running pre-commit hooks for all files...\n\n"
	uv run prek run $(HOOK) --all-files

.PHONY: egsave
egsave: ## Regenerate runnable-example scripts (requires pwsh)
	@command -v pwsh >/dev/null 2>&1 || { printf '\e[31;1mpwsh not found. Install PowerShell 7.4+ to use this target.\e[0m\n' >&2; exit 1; }
	@pwsh -nop .assets/scripts/scripts_egsave.ps1

.PHONY: release
release: ## Build release tarball and print tag commands
	@set -e; \
	if [ -n "$$(git status --porcelain)" ]; then \
		printf '\e[31;1mWorktree is dirty. Commit or stash changes first.\e[0m\n' >&2; exit 1; \
	fi; \
	printf 'Enter version (e.g. 1.0.0): '; read -r ver; \
	[ -n "$$ver" ] || { printf '\e[31;1mVersion required.\e[0m\n' >&2; exit 1; }; \
	VERSION="$$ver" .assets/tools/build_release.sh; \
	printf '\n\e[96mTo tag and push:\e[0m\n'; \
	printf '  git tag -a "v%s" -m "Release v%s"\n' "$$ver" "$$ver"; \
	printf '  git push origin "v%s"\n' "$$ver"
