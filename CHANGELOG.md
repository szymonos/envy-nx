# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [1.2.0] - 2026-04-28

### Added

- `check-zsh-compat` pre-commit hook validating bash_cfg scripts for zsh compatibility
- `nx setup [flags...]` command to run `nix/setup.sh` from anywhere, with auto-clone when repo is missing; shows repo path and branch in a prominent banner
- `nx self update [--force]` command to update the source repository (git pull or force-reset)
- `nx self path` command to print the recorded source repository path
- Install record (`install.json`) now includes `repo_path` and `repo_url` fields for repository tracking
- `nx version` now displays the source repository path
- Tab completions for `setup` (with all setup.sh flags) and `self` subcommands (bash + zsh)
- Zsh tab completions for `nx` command (`completions.zsh` using `compdef` API)
- PowerShell tab completions for `setup` and `self` subcommands
- Bats tests for `_nx_read_install_field`, `_nx_self_sync`, `nx self`, `nx setup`, and `install_record` repo fields
- Bats tests for `_io_pwsh_nop`/`_pwsh_nop` wrapper path resolution, `LD_LIBRARY_PATH` clearing, and `share/powershell` PATH cleanup
- Pester tests for PowerShell `nx` argument completer
- VS Code Server PATH setup: `setup_vscode_server_env` writes nix PATH entries to `~/.vscode-server/server-env-setup` so extensions (e.g. PowerShell) find nix-installed tools without a login shell

### Changed

- Renamed `.assets/config/bash_cfg/` to `.assets/config/shell_cfg/` with extension convention (`.sh` shared, `.bash` bash-only, `.zsh` zsh-only)
- Durable shell config path changed from `~/.config/bash/` to `~/.config/shell/`
- Bash completions for `nx` extracted from `aliases_nix.sh` into standalone `completions.bash`
- `check-zsh-compat` hook: add guard-aware rules for numeric array subscripts, `BASH_SOURCE`, bash completion API; support `# zsh-ok` inline suppression
- `check_changelog` hook: enforce `### Added` / `### Changed` / `### Fixed` section order within each release
- Extracted VS Code Server helpers (`setup_vscode_certs`, `setup_vscode_server_env`) from `certs.sh` into new `vscode.sh`
- PowerShell profile regions now use `$HOME`-relative paths instead of absolute resolved paths
- Removed redundant `local-path` profile region (already handled by `profile_base.ps1` sourced via `nix:base`)
- Makefile: `lint`/`lint-diff`/`lint-all` accept `HOOK=id` to run a single hook; moved `prek install` to dedicated `hooks-install` target; added `hooks` (list IDs) and `hooks-remove` targets

### Fixed

- Zsh compatibility: replace numeric array indexing in `sysinfo` function with `read` to avoid 0-based/1-based mismatch
- `LD_LIBRARY_PATH` glibc conflicts when running `nix/setup.sh` from pwsh: unset at script entry, clear inside all `pwsh -nop` invocations via `_pwsh_nop`/`_io_pwsh_nop` wrappers (pwsh .NET runtime re-injects it at startup), and clear in interactive PowerShell profile
- `_pwsh_nop`/`_io_pwsh_nop` wrappers: use full `~/.nix-profile/bin/pwsh` path instead of bare `pwsh` to avoid resolving to the unwrapped `share/powershell/pwsh` binary (no `LD_LIBRARY_PATH` setup, crashes with missing libicu); strip `share/powershell` from PATH at `nix/setup.sh` entry
- `nix:uv` profile region: use full nix path for `uvx` completion to avoid command-not-found during profile load
- WSL git config: source nix profile in StringBuilder so `git` is in PATH on bare distros (e.g. Debian)
- `setup_gh_repos.sh`: source nix profile fallback chain for nix-installed `git`; fix unbound `cloned` variable under `set -u`
- Zsh compatibility: use `function` keyword in bash_cfg function definitions to prevent alias expansion conflicts

## [1.1.0] - 2026-04-26

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
- `check_changelog` hook now validates heading structure: `## [Unreleased]` must be first, tagged headings must use pure semver without `v` prefix, dates must be valid and in reverse chronological order

### Fixed

- Redundant ps-modules re-clone removed from `linux_setup.sh` (repo is guaranteed to exist after `nix/setup.sh` completes)
- `Write-Warning` output captured into `$cloned` variable in `setup_common.sh` suppressed via `-WarningAction SilentlyContinue`
- `install_record.sh` now sources the nix profile if `jq` is not in PATH, fixing broken `install.json` (missing scopes/mode/version) when called from non-login shells (e.g. `wsl_setup.ps1` `clean` block)
- `Get-LogLine` in `do-common` fixed to use its own `$LogContext` parameter instead of leaking `$ctx` from caller scope
- SSH key title in `gh.sh` restored to `uname -n` format (hostname only)
- `install_record.sh` version detection on WSL: `wsl_setup.ps1` now resolves version on the Windows host and passes it via `_IR_VERSION`, avoiding `safe.directory` and PATH issues inside `bash -c`

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
- `nx doctor` health checks (10 checks including version-skew detection, `--json` output)
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
