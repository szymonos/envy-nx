# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `vim_setup.sh` script for configuring vim and setting it up as the default editor for git and gh on Linux (global or user-scoped)
- Structured logging system: `setup_log.sh` creates/rotates log file, `io.sh` provides `info`/`ok`/`warn`/`err` helpers that write colored output to terminal and plain-text markers to log file
- `_io_run` try/catch wrapper: captures stderr to temp file, shows on terminal and logs on failure, discards on success - preserves nix progress bar and tty detection
- `Get-GhReleaseLatest` in `wsl_setup.ps1` to resolve GitHub release versions from Windows host without `gh` CLI
- `module_manage.ps1` script for managing vendored PowerShell modules (clone/update from upstream repos)
- Vendored PowerShell modules: `do-common`, `do-linux`, `do-az`, `psm-windows`, `aliases-git`, `aliases-kubectl`

### Changed

- Moved pwsh from system-prefer tier to always-nix; deleted `install_pwsh.sh`, `setup_profile_AllUsers.ps1`
- Deleted `.assets/provision/source.sh`; replaced with `gh_helpers.sh` (`gh_download_file`, `gh_login_user`)
- Removed dead code: `enable_strict_mode`, `find_file`, `install_github_release_user`, `gh_release_latest` (zero callers)
- `do-common` ps-module is now always installed as CurrentUser on all platforms
- `setup_common.sh` pwsh setup now runs on all platforms including WSL (previously skipped in WSL)
- Removed duplicated functions from `InstallUtils` (`Invoke-CommandRetry`, `Join-Str`, `Test-IsAdmin`, `Update-SessionEnvironmentPath`) and `SetupUtils` (`ConvertFrom-PEM`, `ConvertTo-PEM`, `Get-Certificate`, `Show-LogContext`, `ConvertFrom-Cfg`, `ConvertTo-Cfg`, `Get-ArrayIndexMenu`, `Invoke-ExampleScriptSave`); WSL scripts now import `do-common`/`psm-windows` directly
- Back-ported `ConvertFrom-Cfg`/`ConvertTo-Cfg` improvements (header comment preservation, `IDictionary` param type) to `do-common`
- GitHub repo cloning (`gh.sh`) now prefers SSH over HTTPS when an SSH key is available
- `apt-get dist-upgrade` quieted with `-qq`/`-qqy` flags in `upgrade_system.sh`

### Fixed

- Redundant ps-modules re-clone removed from `linux_setup.sh` (repo is guaranteed to exist after `nix/setup.sh` completes)
- `Write-Warning` output captured into `$cloned` variable in `setup_common.sh` suppressed via `-WarningAction SilentlyContinue`
- `install_record.sh` now sources the nix profile if `jq` is not in PATH, fixing broken `install.json` (missing scopes/mode/version) when called from non-login shells (e.g. `wsl_setup.ps1` `clean` block)
- `Get-LogLine` in `do-common` fixed to use its own `$LogContext` parameter instead of leaking `$ctx` from caller scope
- SSH key title in `gh.sh` restored to `uname -n` format (hostname only)

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
