# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Fixed

- `sort_scopes()` dropping overlay/local scopes when re-running `setup.sh`
- Orphaned overlay scope copies not cleaned up when source file is deleted

## [1.0.0] - 2026-04-25

### Added

- Nix-based cross-platform setup with scope system (`nix/setup.sh`)
- Declarative `nx` CLI for bash and PowerShell (`aliases_nix.sh`, `_aliases_nix.ps1`)
- `nx` standalone CLI extracted to `.assets/lib/nx.sh`
- Installation provenance record (`~/.config/dev-env/install.json`, viewed via `nx version`)
- Managed block pattern for shell profile injection (`manage_block`)
- Managed env block for cert env vars and local PATH (`env_block.sh`)
- Shared CA bundle builder and VS Code Server cert setup (`certs.sh`)
- Explicit upgrade semantics (`--upgrade` flag, `nx upgrade`)
- Scope dependency resolution and validation (`scopes.sh`, `scopes.json`)
- Scope-name completions for bash and PowerShell
- Oh-my-posh and starship prompt integration with mutual exclusivity
- Linux CI workflow (daemon + no-daemon + tarball matrix)
- macOS CI workflow (Determinate installer)
- Release pipeline with tarball builder, SBOM, cosign signing (`release.yml`)
- Uninstaller with env-only mode and `--dry-run` preview (`nix/uninstall.sh`)
- BATS and Pester unit testing with pre-commit hooks
- BSD sed lint enforcement in pre-commit hook (`check_bash32`)
- CHANGELOG enforcement pre-commit hook (`check_changelog`)
- `NIX_ENV_VERSION` and `NIX_ENV_SCOPES` environment variable exports
- `VERSION` file fallback for tarball installs (no `.git` directory)
- ARCHITECTURE.md with file classification, call tree, and design decisions
- Corporate proxy documentation (`docs/proxy.md`)
- mkdocs documentation site (architecture, enterprise readiness, quality standards, proxy, releasing, customization)
- `nx pin set <rev>`, `nx pin show`, `nx pin rm` for nixpkgs revision pinning
- `--allow-unfree` flag for enabling unfree packages in `config.nix`
- `nx doctor` health checks (9 checks including version-skew detection, `--json` output)
- `# bins:` comments in scope `.nix` files as single source of truth for expected binaries
- Pre-setup and post-setup hook directories (`~/.config/nix-env/hooks/`)
- Overlay directory for local customization (`~/.config/nix-env/local/` or `$NIX_ENV_OVERLAY_DIR`)
- `nx overlay list` and `nx overlay status` commands
- `nx scope add <name>` for creating custom overlay scopes
- SUPPORT.md with platform support matrix

### Changed

- Removed legacy system-scoped installation layer (50+ `install_*.sh` scripts replaced by Nix scopes)
- Removed Vagrant infrastructure (hyperv, libvirt, virtualbox)
- Moved `scripts_egsave.ps1` from repo root to `.assets/scripts/scripts_egsave.ps1`
- Moved `build_release.sh` from `scripts/` to `.assets/tools/`
- Release tarball now includes `.assets/scripts/` and `.assets/check/` directories
- Unified scope/overlay UX: stripped `local_` prefix from scope names, merged overlay subcommands

### Fixed

- BSD sed grouped-command violations across all nix-path scripts
- Bash 3.2 compatibility (no mapfile, no associative arrays, no namerefs)
- Uninstaller cleanup for env-only and full removal modes
- Probe-first CA bundle handling (only build bundle when MITM proxy detected)
- `_io_nix_eval` path interpolation hardened via `builtins.getEnv` (no injection surface)
