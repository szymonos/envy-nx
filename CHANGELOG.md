# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `nix/setup.sh`: auto-refresh the source repo from upstream at start (`phase_bootstrap_refresh_repo` in `nix/lib/phases/bootstrap.sh`), mirroring `wsl/wsl_setup.ps1`'s `Update-GitRepository`. Uses the same cheap `ls-remote` pre-check (no fetch when remote tip already matches the local tracking ref). On a successful update, the script exits 0 with `repository updated to <upstream> - run the script again`. Skips silently when the working tree has uncommitted changes or HEAD has diverged from upstream (protects feature-branch dev work), when not in a git work tree (tarball install), when `git` is unavailable, or when no upstream tracking branch is configured (e.g. detached HEAD on CI).
- `nix/setup.sh --skip-repo-update`: opt-out flag for the auto-refresh, intended for repo-developer iteration ("test my uncommitted changes to setup.sh") and for callers that already refreshed the repo themselves. Wired into bash/zsh/PowerShell completers for `nx setup`. `wsl/wsl_setup.ps1` now passes it to `nix/setup.sh` since it already runs `Update-GitRepository` at script start.

### Changed

- `Update-GitRepository` (`modules/InstallUtils/Functions/git.ps1`): added a `git ls-remote --heads` pre-check that skips the always-on `git fetch --tags --prune --prune-tags --force` when the remote tip already matches the local tracking ref. Cuts several seconds off `wsl/wsl_setup.ps1`'s startup repo-freshness check on lower-end systems with slow disks (fetch always rewrites `FETCH_HEAD`/packed-refs even on a no-op). Upstream resolution is now a single `rev-parse --abbrev-ref --symbolic-full-name @{upstream}` call (replaces the `git remote` + `git branch --show-current` pair) and the post-fetch HEAD/upstream comparison is collapsed into one `rev-parse HEAD upstream`. The 0/1/2 return contract, retry loop, and `--prune-tags --force` semantics on the fetch path are unchanged.

### Fixed

- `nx doctor` `shell_profile` check: now audits only the rc file of the **invoking shell** instead of always checking both `~/.bashrc` and `~/.zshrc`. `nx.sh` (sourced into the user's interactive shell) detects bash vs zsh from `$BASH_VERSION`/`$ZSH_VERSION` and passes it to `nx_doctor.sh` via `NX_INVOKING_SHELL`. Removes the false positive where a legacy `.zshrc` (e.g. left over from a previously-installed zsh) failed `nx doctor` from a bash session. Pwsh continues to own its own check via `nx profile doctor` (in `_aliases_nix.ps1`) - same self-only contract, consistent across all three shells.

## [1.3.1] - 2026-04-30

### Added

- `check-zsh-compat` hook: new rule flagging for-loops over unquoted globs (the pattern that bit `nx scope tree` on macOS), and broader file scope - now also lints `.assets/lib/nx.sh` and `.assets/lib/profile_block.sh`, both sourced into the user's interactive shell via the `nx()` wrapper. The hook is now scope-agnostic; file selection lives entirely in `.pre-commit-config.yaml`.
- `install_atomic` helper in `.assets/lib/helpers.sh`: copy a file via temp-file + same-filesystem rename so concurrent readers never see a partial file. Sourced from `nix/setup.sh` (used by `phase_bootstrap_sync_env_dir`) and from `nix/configure/profiles.{sh,zsh}` (used by `_install_cfg_file`).

### Changed

- `.assets/lib/nx.sh` and `.assets/lib/profile_block.sh`: convert all bare `name() {` function definitions to `function name() {` to match zsh-safe style enforced for shell-sourced scripts. The few legitimate bash-isms (`BASH_SOURCE`-with-fallback in `_nx_find_lib`, the file-end exec guard, and the `complete -W` literal that's emitted text rather than a runtime call) are marked with inline `# zsh-ok` suppressions.
- CI workflows: consolidated the `test:linux` and `test:macos` PR labels into a single `test:integration` label that triggers both Linux and macOS integration runs (`test_linux.yml`, `test_macos.yml`, plus the docs that referenced the old labels).

### Fixed

- `completions.zsh`: guard `compdef` with `autoload -Uz compinit; compinit -i` when the completion system has not been initialized yet. macOS' default zsh setup does not run `compinit`, which caused `command not found: compdef` on first source. The guard is a no-op when `compinit` has already run elsewhere (e.g. via Oh My Zsh).
- `nx.sh`, `functions.sh`: replace bash-idiomatic `for f in "$dir"/*.ext` loops with `find` piped into `while read`. zsh's default `nomatch` option aborts the command on unmatched globs (`nx_main:217: no matches found: .../local_*.nix`) instead of leaving the literal pattern for the `[ -f "$f" ]` guard to filter; `find` sidesteps both shells' glob behavior with no shell-option side effects on the user's interactive shell. Affects `nx scope list`, `nx scope tree`, `nx overlay`, the pwsh cache cleanup in `_nx_clear_pwsh_cache`, and the cert-bundle helper in `functions.sh` whenever the target dir contains no matching files (typical on a fresh macOS setup with no overlay scopes).
- Race condition during `nix/setup.sh` rerun where the first invocation after a finished setup printed `~/.config/nix-env/nx.sh: line N: Garbage: command not found` (or similar text from inside the `cat <<'EOF' ... EOF` help heredoc), `EOF: command not found`, then a syntax error near `;;`. Cause: `cp` used in `phase_bootstrap_sync_env_dir` and `_install_cfg_file` truncates the destination and writes in chunks; if the user's shell sources the file mid-write (e.g. via the `nx()` wrapper in another terminal, bash completion, or the post-setup "Restart your terminal" call-out itself), it reads a half-written file - heredoc body without its opening `<<'EOF'` line, so the body lines get parsed as shell commands. Replaced with `install_atomic` (temp-file + same-filesystem rename, atomic on POSIX). Empirically verified: 5 partial-read failures in 200 concurrent `cp` writes vs. 0 failures with `install_atomic`.
- `docs/releasing.md`: tarball download example now points at GitHub's `releases/latest/download/envy-nx.tar.gz` redirect instead of a hard-coded `v1.2.0` URL that drifted with every release.

## [1.3.0] - 2026-04-30

### Added

- `scop/pre-commit-shfmt` hook for formatting bash scripts with `shfmt`.
- `docs/nx.md`: comprehensive user guide for the `nx` CLI - command surface table, tab-completion coverage (bash/zsh/PowerShell), per-functionality chapters (package management, scopes, lifecycle, maintenance). Wired into `mkdocs.yml` nav.

### Changed

- extended `k8s_dev` scope with crane and kyverno cli.
- moved `.assets/provision/gh_helpers.sh` to `.assets/lib/helpers.sh` so it can be sourced from the nix path (used by `nix/configure/conda.sh` for `download_file`); added `helpers` to the `check-bash32` hook regex.
- `nix/configure/az.sh`: pass `--fix_certify true` on macOS too (was Linux-only) - keychain-intercepted certs now land in `~/.config/certs/ca-custom.crt`, so the same patch path applies cross-platform; safe no-op when no custom bundle exists.
- `nx setup`: removed the interactive clone-path prompt. Primary path is `install.json:repo_path` when it points to a valid envy-nx checkout (respects forks / non-canonical clones); falls back to canonical `~/source/repos/szymonos/envy-nx` when the recorded path is unset or stale, cloning on demand. Stale-fallback case prints a one-line notice.

### Fixed

- `validate_docs_words` hook: tokenize raw content first for cspell.
- added `python3` to the `python` scope to offer a common Python interpreter for VSCode and other tools.
- formatted all bash scripts with `shfmt` pre-commit hook.
- `nix/configure/conda.sh`: wrap `fixcertpy` in `conda activate base` / `conda deactivate` so the cert patch lands on conda's own certifi (was previously running against whichever pip was on PATH and silently no-op for conda).
- pwsh `nix:path` region: append both `~/.local/share/powershell/Scripts` and `~/.local/share/powershell/Modules` to `$env:PATH`. Scripts is needed so `Install-PSResource -Type Script` outputs are invocable as commands. Modules is needed to silence PSResourceGet's `ScriptPATHWarning` - a noisy WARNING that fires on every install on Linux because the check (incorrectly) probes the Modules dir, not Scripts. System pwsh provides both via `/etc/profile.d/`, nix-installed pwsh does not. Verified end-to-end with `Install-PSResource pester -Reinstall`.
- `nx gc` and `nx upgrade`: clear stale pwsh module-analysis cache (`~/.cache/powershell/ModuleAnalysisCache-*`, `StartupProfileData-*`) - both reference module paths that go stale after a nix store GC or pwsh upgrade, causing `Install-PSResource` to fail with `Could not find a part of the path .../Modules/PSReadLine/<version>/PSReadLine.format.ps1xml`. Cache regenerates on next pwsh launch.
- `nix/setup.sh --remove conda`: now also cleans up the on-disk miniforge install via the new `nix/configure/conda_remove.sh` hook (lists user envs first, prompts for confirmation, runs `conda init --reverse` to clean shell rc, then deletes `~/miniforge3`). Skips the prompt under `--unattended`. Previously `--remove conda` only updated `config.nix` and left the install on disk - asymmetric with the install path.

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
