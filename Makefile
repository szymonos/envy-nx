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

.PHONY: test test-unit test-nix test-upgrade-walk
test: test-unit test-nix ## Run all tests (unit + Docker smoke)

test-unit: ## Run bats + Pester unit tests in parallel (fast, no Docker)
	@printf "\n\033[95;1m== Running unit tests ==\033[0m\n\n"
	@# Bats: parallelize across files via xargs -P. bats's native -j requires
	@# GNU parallel which isn't bootstrapped by this repo. Capped at 4 workers
	@# - tests do lots of mktemp/io and disks thrash above that.
	@# Shell glob (not `find -maxdepth`) for portability: `-maxdepth` is a
	@# GNU extension that BSD find on stock macOS lacks. The bats dir is
	@# flat (no subdirs to recurse into), so the glob is sufficient.
	@printf '%s\0' tests/bats/*.bats | xargs -0 -P 4 -n 1 bats
	@# Pester: file-level parallelism via ForEach-Object -Parallel inside a
	@# single pwsh session (avoids paying ~3s pwsh startup per file). The
	@# helper script is also reusable from CI / hooks / dev shell.
	@pwsh -nop -File tests/hooks/pester_parallel.ps1

test-nix: ## Run Docker smoke test for nix path
	@printf "\n\033[95;1m== Testing nix path (nix/setup.sh) ==\033[0m\n\n"
	@$(ENSURE_ROOT_CERT) && \
		docker build --no-cache \
			-f .assets/docker/Dockerfile.test-nix \
			--output type=image,name=lss-test-nix,unpack=false . \
		&& printf "\n\033[32;1m>> Nix test PASSED\033[0m\n\n" \
		&& docker rmi lss-test-nix >/dev/null 2>&1; \
		$(CLEANUP_ROOT_CERT)

test-upgrade-walk: ## Cross-version upgrade walk in Docker (slow, ~20+ min). WALK_FLOOR / WALK_VERSIONS / TARGET_REF env vars supported.
	@printf "\n\033[95;1m== Cross-version upgrade walk (Docker) ==\033[0m\n\n"
	@$(ENSURE_ROOT_CERT) && \
		docker build --platform=linux/amd64 \
			-f .assets/docker/Dockerfile.upgrade-walk \
			-t lss-upgrade-walk .assets/certs/ \
		&& docker run --rm --platform=linux/amd64 \
			-v "$$(pwd):/src:ro" \
			-v "$$(pwd)/.github/scripts/upgrade_walk.sh:/walk.sh:ro" \
			-e SRC_REPO=/src \
			-e WORK_REPO=/home/ubuntu/work \
			-e TARGET_REF="$${TARGET_REF:-$$(git rev-parse HEAD)}" \
			-e WALK_VERSIONS="$$WALK_VERSIONS" \
			-e WALK_FLOOR="$${WALK_FLOOR:-v1.5.0}" \
			-e TARGET_SCOPES="$${TARGET_SCOPES:---shell --unattended}" \
			lss-upgrade-walk /walk.sh; \
		rc=$$?; \
		$(CLEANUP_ROOT_CERT); \
		exit $$rc

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
release: ## Tag HEAD and push to origin to trigger the release workflow
	@set -e; \
	current_branch=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$current_branch" != "main" ]; then \
		printf '\e[31;1mReleases must be cut from main (currently on `%s`).\e[0m\n' "$$current_branch" >&2; \
		printf '\e[31;1mSwitch with: git switch main && git pull --ff-only\e[0m\n' >&2; \
		exit 1; \
	fi; \
	if [ -n "$$(git status --porcelain)" ]; then \
		printf '\e[31;1mWorktree is dirty. Commit or stash changes first.\e[0m\n' >&2; exit 1; \
	fi; \
	printf '\e[96mFetching origin/main to verify sync...\e[0m\n'; \
	git fetch --quiet origin main; \
	if [ "$$(git rev-parse HEAD)" != "$$(git rev-parse origin/main)" ]; then \
		printf '\e[31;1mLocal main differs from origin/main. Pull or push first so the tag points at a published commit.\e[0m\n' >&2; \
		exit 1; \
	fi; \
	if [ -n "$(VERSION)" ]; then \
		ver="$(VERSION)"; \
		printf '\e[96mUsing VERSION override: \e[1mv%s\e[0m\n' "$$ver"; \
	else \
		ver=$$(awk '/^## \[[0-9]+\.[0-9]+\.[0-9]+\]/{gsub(/[][]/,"",$$2); print $$2; exit}' CHANGELOG.md); \
		[ -n "$$ver" ] || { printf '\e[31;1mNo released version in CHANGELOG.md (expected `## [X.Y.Z] - YYYY-MM-DD`).\e[0m\n' >&2; exit 1; }; \
		printf '\e[96mDetected version from CHANGELOG.md: \e[1mv%s\e[0m\n' "$$ver"; \
	fi; \
	if git rev-parse "v$$ver" >/dev/null 2>&1; then \
		printf '\e[31;1mTag v%s already exists locally. Did you forget to add a new release section to CHANGELOG.md?\e[0m\n' "$$ver" >&2; \
		printf '\e[31;1mOverride with: make release VERSION=X.Y.Z\e[0m\n' >&2; \
		exit 1; \
	fi; \
	if git ls-remote --exit-code --tags origin "refs/tags/v$$ver" >/dev/null 2>&1; then \
		printf '\e[31;1mTag v%s already exists on origin. Build would succeed but `git push origin v%s` would fail after the artifact is built.\e[0m\n' "$$ver" "$$ver" >&2; \
		printf '\e[31;1mPick a new version (override: make release VERSION=X.Y.Z) or delete the remote tag if it was published in error.\e[0m\n' >&2; \
		exit 1; \
	fi; \
	printf '\n\e[96mTag v%s at HEAD and push to origin?\e[0m [y/N] ' "$$ver"; \
	read -r reply; \
	case "$$reply" in \
	[yY]|[yY][eE][sS]) \
		git tag -a "v$$ver" -m "Release v$$ver"; \
		git push origin "v$$ver"; \
		printf '\e[32mPushed v%s. Watch release.yml at: https://github.com/szymonos/envy-nx/actions\e[0m\n' "$$ver"; \
		;; \
	*) \
		printf '\e[33mSkipped tag + push. Run manually when ready:\e[0m\n'; \
		printf '  git tag -a "v%s" -m "Release v%s"\n' "$$ver" "$$ver"; \
		printf '  git push origin "v%s"\n' "$$ver"; \
		;; \
	esac
