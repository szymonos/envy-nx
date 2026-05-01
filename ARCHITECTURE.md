# Architecture

Single source of truth for an agent or contributor working on this codebase. Read this before making cross-cutting changes. End-user docs live in `docs/`; this file is the implementation reference.

## 1. At a glance

```text
envy-nx/
├── nix/                      Primary entry point + flake declarations
│   ├── setup.sh              ~110-line orchestrator (sources phase libs)
│   ├── lib/
│   │   ├── io.sh             Logging + side-effect wrappers (_io_*)
│   │   └── phases/           bootstrap, platform, scopes, nix_profile,
│   │                         configure, profiles, post_install, summary
│   ├── scopes/*.nix          Per-scope package lists (one file per scope)
│   ├── configure/*.sh        Per-scope post-install hooks
│   ├── flake.nix             buildEnv flake (reads ~/.config/nix-env/config.nix)
│   └── uninstall.sh          Self-contained removal
├── .assets/
│   ├── lib/                  Shared bash libraries (sourced everywhere)
│   │   ├── nx.sh             nx CLI entry (helpers + family sourcing + dispatch)
│   │   ├── nx_pkg.sh         install/remove/upgrade/list/prune/gc/rollback/search
│   │   ├── nx_scope.sh       scope/overlay/pin
│   │   ├── nx_profile.sh     managed-block rendering + profile verb
│   │   ├── nx_lifecycle.sh   setup/self/doctor/version/help
│   │   ├── nx_doctor.sh      Health-check registry
│   │   ├── nx_surface.json   Manifest: nx verbs/subverbs/flags/completers
│   │   ├── scopes.{json,sh}  Scope catalog + resolver
│   │   ├── profile_block.sh  Managed-block insert/remove/upsert
│   │   ├── helpers.sh        download_file, gh_login_user, install_atomic
│   │   ├── certs.sh          CA bundle + MITM probe
│   │   ├── install_record.sh ~/.config/dev-env/install.json writer
│   │   └── setup_log.sh      Log file lifecycle
│   ├── config/
│   │   ├── shell_cfg/        Sourced into bash/zsh interactive shells
│   │   │   ├── aliases_*.sh  nix/git/kubectl aliases
│   │   │   ├── functions.sh  cert_intercept, fixcertpy, ...
│   │   │   └── completions.{bash,zsh}    GENERATED from nx_surface.json
│   │   ├── pwsh_cfg/         PowerShell profile + nx wrapper (proxies to bash;
│   │   │                     handles `nx profile *` natively)
│   │   ├── omp_cfg/          oh-my-posh themes
│   │   └── starship_cfg/     starship prompt config
│   ├── provision/install_*.sh    Root-required system installers (Linux)
│   ├── setup/setup_*.{sh,zsh,ps1}    User-level post-install setup
│   ├── check/*.sh            One-off diagnostic scripts
│   └── scripts/linux_setup.sh    Linux system prep + nix delegation
├── wsl/wsl_setup.ps1         Windows-host orchestrator for WSL distros
├── modules/                  Vendored PowerShell modules (do-*, psm-windows, ...)
├── tests/
│   ├── bats/*.bats           Bash unit tests (bats-core)
│   ├── pester/*.Tests.ps1    PowerShell unit tests (Pester)
│   └── hooks/*.py            Pre-commit hook scripts + completion generator
├── docs/                     End-user documentation (mkdocs)
├── ARCHITECTURE.md           This file (agent reference)
├── CONTRIBUTING.md           Workflow guide (links here for constraints)
├── CHANGELOG.md              Keep-a-Changelog format, gated by hook
└── Makefile                  Primary contributor interface (lint/test/release)
```

### First-run flow (`nix/setup.sh`)

```text
phase_bootstrap_*       repo refresh, root guard, paths, nix detect/install,
                        jq bootstrap, arg parsing
phase_platform_*        OS detect, overlay discovery, pre-setup hooks
phase_scopes_*          load existing config.nix, apply --remove,
                        resolve deps, write config.nix
phase_nix_profile_*     flake update (if --upgrade), nix profile add/upgrade,
                        MITM probe + CA bundle build
phase_configure_*       gh auth, git config, dispatch nix/configure/*.sh
phase_profiles_*        bash/zsh/PowerShell profile setup
phase_post_install_*    setup_common.sh + nix garbage collection
phase_summary_*         mode detect + final output
EXIT trap               install_record.sh writes install.json
```

## 2. The bootstrapper model

The tool provisions; it does not run continuously. One `nix/setup.sh` invocation produces a self-contained environment in `~/.config/nix-env/` and exits. After that, the repo clone is **disposable**: `nx upgrade`, `nx scope`, `nx install`, `nx doctor`, and `nix/uninstall.sh` all operate on `~/.config/nix-env/` without needing the source repo.

Implications for any change you make:

- Anything sourced from `~/.config/nix-env/` (e.g. `nx.sh`, the four `nx_<family>.sh` files, `nx_doctor.sh`, `profile_block.sh`) must be **copied into `~/.config/nix-env/` during setup** and must be **callable standalone** - they cannot rely on repo-relative paths at runtime.
- File copies into `~/.config/nix-env/` and `~/.config/shell/` use `install_atomic` (temp file + same-filesystem rename). A plain `cp` would race against any concurrent shell sourcing the file. See `_install_cfg_file` in `nix/configure/profiles.sh` and the install loop in `nix/lib/phases/bootstrap.sh:phase_bootstrap_sync_env_dir`. `flake.nix` and `scopes/*.nix` stay on plain `cp` because nix tooling, not the user's shell, reads them.
- Durable state lives in `~/.config/nix-env/` (env), `~/.config/shell/` (rc-sourced), `~/.config/powershell/` (PS profile), `~/.config/certs/` (CA bundles), `~/.config/dev-env/` (`install.json`). Removing the repo never touches these.

## 3. Subsystems

### 3a. Setup orchestration (`nix/setup.sh` + `nix/lib/phases/`)

`nix/setup.sh` is a slim orchestrator (~110 lines). All logic lives in phase libraries; the orchestrator only sequences them.

| Phase file                       | Responsibility                                                                 |
| -------------------------------- | ------------------------------------------------------------------------------ |
| `nix/lib/io.sh`                  | Output helpers + side-effect wrappers (`_io_nix`, `_io_curl_probe`, `_io_run`) |
| `nix/lib/phases/bootstrap.sh`    | Repo auto-refresh, root guard, paths, nix detect/install, jq bootstrap, args   |
| `nix/lib/phases/platform.sh`     | OS detection, overlay discovery, pre/post-setup hook runners                   |
| `nix/lib/phases/scopes.sh`       | Load/merge scopes, resolve deps, write `config.nix`, apply removes             |
| `nix/lib/phases/nix_profile.sh`  | Flake update, `nix profile add/upgrade`, MITM probe                            |
| `nix/lib/phases/configure.sh`    | gh/git/per-scope `configure/*.sh` dispatch (via `_io_run`)                     |
| `nix/lib/phases/profiles.sh`     | bash/zsh/pwsh profile setup (delegates block rendering to `nx.sh`)             |
| `nix/lib/phases/post_install.sh` | `setup_common.sh` + nix GC                                                     |
| `nix/lib/phases/summary.sh`      | Mode detection + final output                                                  |

**Wrapper boundary.** Phase functions call `_io_nix`, `_io_curl_probe`, `_io_run` instead of raw commands. Tests redefine these to capture calls without executing them. `_io_run` provides try/catch semantics: stdout streams normally, stderr is captured to a temp file and only surfaced on failure (terminal + log). Configure scripts (`nix/configure/*.sh`) are themselves invoked via `_io_run`, so their internal `gh`/`git`/`curl` commands are already wrapped at the call site - adding `_io_*` *inside* configure scripts gives no test benefit.

**Configure dispatch table** (in `phase_configure_per_scope`):

| Configure script                | Trigger condition     | Notes                                                     |
| ------------------------------- | --------------------- | --------------------------------------------------------- |
| `nix/configure/gh.sh`           | always                | GitHub CLI auth (skipped when `--unattended`)             |
| `nix/configure/git.sh`          | always                | git user.name / user.email (skipped when unattended)      |
| `nix/configure/docker.sh`       | scope: docker         | Group + daemon socket setup                               |
| `nix/configure/conda.sh`        | scope: conda          | Sources `functions.sh`, runs miniforge installer          |
| `nix/configure/conda_remove.sh` | scope: conda --remove | Reverses conda init, deletes ~/miniforge3                 |
| `nix/configure/az.sh`           | scope: az             | Calls `install_azurecli_uv.sh`                            |
| `nix/configure/terraform.sh`    | scope: terraform      | tfswitch -> ~/.local/bin/terraform                        |
| `nix/configure/omp.sh`          | scope: oh_my_posh     | Reads `.assets/config/omp_cfg/`                           |
| `nix/configure/starship.sh`     | scope: starship       | Reads `.assets/config/starship_cfg/`                      |
| `nix/configure/profiles.sh`     | always                | Copies `shell_cfg/`; certs; delegates blocks to `nx`      |
| `nix/configure/profiles.zsh`    | scope: zsh            | Copies zsh configs; installs zsh plugins                  |
| `nix/configure/profiles.ps1`    | scope: pwsh           | Copies pwsh_cfg/; delegates regions to `_aliases_nix.ps1` |

**Post-install dispatch** (in `post_install.sh`):

| Script                                 | Condition       | Purpose                          |
| -------------------------------------- | --------------- | -------------------------------- |
| `.assets/setup/setup_common.sh`        | always          | Copilot, zsh plugins, PS modules |
| `.assets/provision/install_copilot.sh` | called by above | GitHub Copilot CLI               |
| `.assets/setup/setup_profile_user.zsh` | scope: zsh      | Zsh profile setup                |
| `.assets/setup/setup_profile_user.ps1` | pwsh available  | certs + local PATH               |

**Variable naming convention** (cross-phase globals):

| Prefix      | Scope                   | Example                  | Set by                |
| ----------- | ----------------------- | ------------------------ | --------------------- |
| `_IR_*`     | Install record exports  | `_IR_SCOPES`, `_IR_MODE` | `setup.sh` `_on_exit` |
| `_ir_*`     | Install record state    | `_ir_phase`, `_ir_error` | Phase files           |
| `_io_*`     | Side-effect wrappers    | `_io_nix`, `_io_run`     | `io.sh`               |
| `phase_*`   | Public phase functions  | `phase_bootstrap_*`      | Phase files           |
| `_<name>_*` | Phase-private helpers   | `_scope_set`             | Phase files           |
| UPPERCASE   | Constants / env exports | `ENV_DIR`, `CONFIG_NIX`  | `bootstrap.sh`        |

**Repo auto-refresh.** `phase_bootstrap_refresh_repo` runs first, mirrors `Update-GitRepository` from `wsl/wsl_setup.ps1`. Cheap pre-check via `git ls-remote --heads`; full `git fetch` only when the remote tip differs. On a successful update, exits 0 with `repository updated to <upstream> - run the script again`. **Skips silently** when: `--skip-repo-update` flag, dirty working tree, divergent HEAD, no upstream tracking, not a git work tree (tarball install). `--unattended` no longer gates the refresh - `--skip-repo-update` is the explicit opt-out for "test my edits before committing." `wsl_setup.ps1` passes `--skip-repo-update` because it already runs its own `Update-GitRepository`.

### 3b. Scopes (`.assets/lib/scopes.{json,sh}`, `nix/scopes/*.nix`)

A scope is a name (e.g. `python`, `k8s_dev`) declared in `.assets/lib/scopes.json` and backed by a `nix/scopes/<name>.nix` package list and an optional `nix/configure/<name>.sh` post-install script. Users opt in via `setup.sh --<scope>` flags; the resolved set is persisted in `~/.config/nix-env/config.nix` and re-read on every run.

`scopes.json` is the single source of truth - consumed by three runtimes natively: bash via `jq`, PowerShell via `ConvertFrom-Json`, Python via `json`.

**Scope catalog:**

| Scope        | Nix packages                                              | Configure hook | Notes                                                            |
| ------------ | --------------------------------------------------------- | -------------- | ---------------------------------------------------------------- |
| `shell`      | bats, fd, fzf, eza, bat, nmap, ripgrep, shellcheck, ...   | -              | Common CLI utilities                                             |
| `zsh`        | zsh-autosuggestions, zsh-syntax-highlighting, completions | `profiles.zsh` | Linux: dropped if zsh missing or system-installed (plugins only) |
| `pwsh`       | powershell                                                | `profiles.ps1` | Triggers `.NET`-shadow PATH cleanup at the top of `setup.sh`     |
| `python`     | uv, prek, python3                                         | -              | Python interpreters managed by uv, not nix                       |
| `nodejs`     | nodejs                                                    | -              | -                                                                |
| `bun`        | bun                                                       | -              | Alternative JS runtime                                           |
| `az`         | azure-storage-azcopy                                      | `az.sh`        | azure-cli installed via uv (calls `install_azurecli_uv.sh`)      |
| `gcloud`     | google-cloud-sdk                                          | -              | -                                                                |
| `k8s_base`   | kubectl, kubelogin, k9s, kubecolor, kubectx               | -              | -                                                                |
| `k8s_dev`    | helm, flux, argo-rollouts, kustomize, trivy, kyverno, ... | -              | -                                                                |
| `k8s_ext`    | minikube, k3d, kind                                       | -              | Local cluster tools                                              |
| `terraform`  | tfswitch, tflint                                          | `terraform.sh` | terraform binary installed via tfswitch to `~/.local/bin`        |
| `docker`     | (empty)                                                   | `docker.sh`    | Empty scope - root install via `install_docker.sh`               |
| `distrobox`  | (empty)                                                   | -              | Empty scope - installed traditionally                            |
| `conda`      | (empty)                                                   | `conda.sh`     | Empty scope - miniforge installer                                |
| `oh_my_posh` | oh-my-posh                                                | `omp.sh`       | Mutually exclusive with `starship`                               |
| `starship`   | starship                                                  | `starship.sh`  | Mutually exclusive with `oh_my_posh`                             |
| `rice`       | btop, cmatrix, cowsay, fastfetch                          | -              | Eye-candy / fun tools                                            |

Plus two implicit scopes merged outside the user-selectable set:

- `base.nix` - always installed (cacert, coreutils, git, gh, openssl, vim, etc.). Not user-selectable.
- `base_init.nix` - bootstrap-only (jq, curl). Included only when `cfg.isInit = true` (no system jq/curl). See *Bootstrap dependency* under §5.

**Scope file format.** Each `nix/scopes/<name>.nix`:

```nix
# Short description
# bins: <space-separated binary names>
{ pkgs }: with pkgs; [
  <package1>
  <package2>
]
```

The `# bins:` comment is the **single source of truth** for `nx doctor`'s `scope_binaries` check. Every scope file must have one (enforced by `validate_scopes.py`); empty-scope files still need it because the binary may be provided by an installer script rather than nix.

**Empty-scope pattern.** `docker`, `conda`, `distrobox` are intentionally `{ pkgs }: [ ]`. The scope still exists so users opt in via `--docker` etc. - it triggers the matching `configure/<name>.sh`, is recorded in `config.nix`, counts toward `nx scope` and `nx doctor`. **Removal hooks** are dispatched by `phase_scopes_apply_removes` when a scope is removed via `--remove` (currently only `conda` has `conda_remove.sh`).

**Dependency resolution** (`scopes.json:dependency_rules`, single-pass - chains work because each trigger lists transitive deps explicitly):

| Trigger      | Adds                            |
| ------------ | ------------------------------- |
| `az`         | `python` (azure-cli via uv)     |
| `k8s_dev`    | `k8s_base`                      |
| `k8s_ext`    | `docker`, `k8s_base`, `k8s_dev` |
| `pwsh`       | `shell`                         |
| `zsh`        | `shell`                         |
| `oh_my_posh` | `shell`                         |
| `starship`   | `shell`                         |

Implemented in `resolve_scope_deps` (`.assets/lib/scopes.sh`). `--omp-theme <theme>` and `--starship-theme <theme>` also add their respective scope implicitly.

**Install order.** `scopes.json:install_order` defines the order configure hooks and shell-block rendering see scopes. `docker` precedes `k8s_*`; `python` precedes `az`; prompt engines precede shells. Overlay/local scopes not in `install_order` are appended last (`sort_scopes` in `scopes.sh`).

**Mutual exclusivity** (prompt engines). `phase_scopes_enforce_prompt_exclusivity`: both themes -> error; `--omp-theme` -> drop `starship`; `--starship-theme` -> drop `oh_my_posh`.

**Auto-detection** (no flags + no `config.nix`): probes for installed tools and adds matching scopes - `oh-my-posh` -> `oh_my_posh`, `docker` -> `docker`, `~/.local/bin/uv` or `~/.nix-profile/bin/uv` -> `python`, `conda` -> `conda`. Makes upgrade-only re-runs non-destructive.

**System-prefer (Linux zsh).** On Linux the `zsh` nix scope ships only *plugins*, not the `zsh` binary (expected from system pkg manager). `phase_scopes_skip_system_prefer`: system zsh found -> nix scope dropped (plugins still installed); zsh missing -> scope dropped with warning. macOS keeps the scope as-is.

**`flake.nix` integration.** Reads `config.nix` (`{ isInit, allowUnfree, scopes }`) and concatenates: (1) `base.nix` always, (2) `base_init.nix` if `cfg.isInit`, (3) each `scopes/${scope}.nix` for `scope` in `cfg.scopes` (silently skipped if missing - supports overlays), (4) `packages.nix` (managed by `nx install`/`nx remove`). All four feed `pkgs.buildEnv { name = "dev-env"; paths = ...; }`. Supported systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`.

### 3c. nx CLI (`.assets/lib/nx*.sh`)

`nx.sh` is the entry point: ~211 lines containing shared helpers (notably `_nx_find_lib`, which uses `BASH_SOURCE` in bash and falls back to `$HOME/.config/nix-env` in zsh) + family file sourcing + the main dispatcher. Verb implementations live in four sibling family files split by domain:

| Family file       | Verbs                                                                                                           |
| ----------------- | --------------------------------------------------------------------------------------------------------------- |
| `nx_pkg.sh`       | `search`, `install`, `remove`, `upgrade`, `list`, `prune`, `gc`, `rollback`                                     |
| `nx_scope.sh`     | `scope`, `overlay`, `pin`                                                                                       |
| `nx_profile.sh`   | `profile` verb + `_nx_render_env_block` / `_nx_render_nix_block` (also called from `nix/configure/profiles.sh`) |
| `nx_lifecycle.sh` | `setup`, `self`, `doctor`, `version`, `help`                                                                    |

`nx.sh` is sourced into the user's interactive shell lazily via the `nx()` wrapper in `.assets/config/shell_cfg/aliases_nix.sh`. **All five files** (`nx.sh` + the four family files) are subject to zsh-compat constraints (§7).

**`nx_doctor.sh` registry.** Each check is a `_check_<name>` function returning `pass|warn|fail<TAB><detail>` (or empty for skip). A single `_run_check` runner iterates the `CHECKS` list. The `shell_profile` check audits only the invoking shell - not every shell that happens to exist on PATH. The shell is resolved by `_invoking_rc()` in this order: `NX_INVOKING_SHELL` env var (set by the `nx` shell wrapper from `$BASH_VERSION`/`$ZSH_VERSION`) → in-script `$ZSH_VERSION` (only set if invoked as `zsh nx_doctor.sh`) → `basename $SHELL` (the user's login shell - handles direct `bash nx_doctor.sh` invocations) → bash. By default only FAILs produce a non-zero exit; `--strict` treats warnings as failures too (used in CI).

**`_nx_find_lib` resolution.** Looks for sibling library files (`profile_block.sh`, family files when sourced standalone). Order: `NX_LIB_DIR` env var override → `BASH_SOURCE`-derived script directory (bash) → `$HOME/.config/nix-env` (zsh fallback, where `BASH_SOURCE[0]` is empty). `NX_LIB_DIR` lets `tests/bats/test_nx_zsh.bats` point at the source repo's `.assets/lib/` instead of copying files into the test's mock ENV_DIR.

**Doctor checks:**

| Check                | Pass                                                                                                                                     | Fail/Warn                        |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `nix_available`      | `nix` in PATH                                                                                                                            | FAIL: nix not found              |
| `flake_lock`         | `flake.lock` exists, nixpkgs node valid                                                                                                  | FAIL: missing; WARN: unreadable  |
| `env_dir_files`      | `flake.nix`, `nx.sh`, `nx_{pkg,scope,profile,lifecycle,doctor}.sh`, `profile_block.sh`, `config.nix` all present in `~/.config/nix-env/` | FAIL: lists missing files        |
| `install_record`     | `install.json` exists, status=success                                                                                                    | WARN: missing or last run failed |
| `scope_binaries`     | All `# bins:` binaries from scope files found                                                                                            | WARN: lists missing binaries     |
| `shell_profile`      | Exactly 1 managed block in the **invoking shell's** rc file (bash → `.bashrc`, zsh → `.zshrc`)                                           | FAIL: zero or duplicates         |
| `shell_config_files` | Every `~/.config/shell/<file>` referenced by the rc resolves on disk                                                                     | FAIL: lists missing files        |
| `cert_bundle`        | Custom CA bundle + VS Code env OK                                                                                                        | FAIL: bundle or env missing      |
| `vscode_server_env`  | `~/.vscode-server/server-env-setup` includes nix PATH (if `~/.nix-profile/bin` exists)                                                   | WARN: nix PATH missing           |
| `nix_profile`        | `nix-env` in `nix profile list`                                                                                                          | FAIL: not found                  |
| `nix_profile_link`   | `~/.nix-profile` is a symlink resolving to a live target                                                                                 | FAIL: missing or dangling        |
| `overlay_dir`        | `NIX_ENV_OVERLAY_DIR` readable (if set)                                                                                                  | FAIL: not a readable directory   |
| `version_skew`       | Installed version matches latest GitHub release (if `gh` available)                                                                      | WARN: installed version is older |

**PowerShell `nx` wrapper.** `.assets/config/pwsh_cfg/_aliases_nix.ps1` defines a PS `nx` function that proxies almost every verb to `bash $ENV_DIR/nx.sh "$@"`. The single exception is `nx profile *`, handled natively because **the bash and PS profile dispatchers operate on structurally different files** (`~/.bashrc`/`~/.zshrc` with `# >>> nix-env managed >>>` blocks vs `$PROFILE.CurrentUserAllHosts` with `#region nix:* ... #endregion` regions). The `$PROFILE` path is resolved by the .NET runtime per host and cannot be derived from bash; the region syntax is PowerShell-specific. This is **symmetric implementation, not duplicated logic** - but the user-facing subverb surface must stay in sync (enforced by `check-nx-profile-parity`, see §3d).

### 3d. Manifest-driven completions and help (`.assets/lib/nx_surface.json` + `tests/hooks/gen_nx_completions.py`)

The user-facing surface of `nx` (verbs, subverbs, aliases, flags, dynamic completer references, summaries) is declared once in `.assets/lib/nx_surface.json`. Four artifacts are **generated** from it:

| Generated artifact                                        | Generator                           | Replacement scope                                       |
| --------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------- |
| `.assets/config/shell_cfg/completions.bash`               | `tests/hooks/gen_nx_completions.py` | full file                                               |
| `.assets/config/shell_cfg/completions.zsh`                | same                                | full file                                               |
| `.assets/config/pwsh_cfg/_aliases_nix.ps1`                | same                                | only `#region nx-completer ... #endregion` block        |
| `.assets/lib/nx_lifecycle.sh` (`_nx_lifecycle_help` body) | same                                | between `# >>> nx-help generated >>>` / `# <<< ... <<<` |

Adding a verb, subverb, or flag is a **one-file edit** to `nx_surface.json` followed by `python3 -m tests.hooks.gen_nx_completions`. Before this manifest existed, every flag addition was a four-file change (parser in `nx.sh` + bash/zsh/pwsh completers); verb summaries lived twice (heredoc in `nx_lifecycle.sh` + manifest `summary` field).

**Schema** (intentionally narrow):

- `verbs[]` - top-level commands (`name`, `summary`, optional `aliases`, `subverbs`, `args`, `flags`, `help_args`).
- `subverbs[]` - same shape as a verb, no further nesting (current `nx` has no depth-3 verbs).
- `args[]` - positional shape: `name`, `required`, `variadic`, optional `completer` reference.
- `flags[]` - `long`, optional `short`, `summary`, optional `takes_value` + `value_completer`.
- `help_args` - optional override for the `nx help` args column. Used by `setup` to render `[flags...]` since its primary surface is passthrough flags, not positional args.
- `completers{}` - registry of named dynamic completers (`installed_packages`, `all_scopes`, `theme_omp`, `theme_starship`). Implementation lives in the generator as per-shell snippets so shell-native idioms (zsh `(@f)`, bash `compgen -W`, PS `Where-Object`) stay readable.

**Drift defenders** (pre-commit hooks):

- `check-nx-completions` (`tests/hooks/check_nx_completions.py`) imports the generator's `emit_*` functions and diffs against the committed completer files **and** the `nx-help generated` region in `nx_lifecycle.sh`. Fails with `Regenerate with: python3 -m tests.hooks.gen_nx_completions`. Triggers on changes to the manifest, any generated file, or the generator/checker scripts.
- `check-nx-profile-parity` (`tests/hooks/check_nx_profile_parity.py`) parses the PowerShell `switch ($subCmd)` block in `_aliases_nix.ps1` and asserts the subverbs match `nx_surface.json`'s `profile.subverbs`.
- `check-nx-dispatch-parity` (`tests/hooks/check_nx_dispatch_parity.py`) parses `nx_main`'s `case "$cmd" in` block in `nx.sh` and asserts every verb (and alias) matches `nx_surface.json`. Closes the third drift loop: completers, PS profile dispatcher, and the bash dispatcher itself all stay in sync.

This is the third instance of "single JSON manifest consumed by bash/PowerShell/Python" in the repo, joining `scopes.json` and `flake.lock`. See *Bootstrap dependency* under §5 for why JSON.

### 3e. Managed-block pattern

Shell profile injection (`~/.bashrc`, `~/.zshrc`, PowerShell `$PROFILE`) uses a **managed block** pattern instead of `grep -q && echo >>` append. This gives idempotent, fully-regenerated, removable config injection.

**Bash/Zsh** - `nx_profile.sh` renders blocks; `profile_block.sh` provides `manage_block` (insert/upsert/remove). Two blocks per rc file:

- `nix-env managed` - nix-specific (PATH, nix aliases, completions, prompt init). Removed by `nix/uninstall.sh`.
- `managed env` - generic env (local PATH, cert env vars, generic aliases/functions). Survives uninstall.

Block rendering lives in `nx_profile.sh` (`_nx_render_env_block`, `_nx_render_nix_block`). The `nix/configure/profiles.sh` / `.zsh` scripts handle provisioning (file copy, CA certs, zsh plugins) then delegate block management to `nx profile regenerate`. This means `nx profile regenerate` works standalone after the repo is removed.

Alias files are routed to the correct block by install source:

- `functions.sh` - always in `managed env` (purely generic).
- `aliases_git.sh` - `nix-env managed` if git is from nix (`~/.nix-profile/bin/git` exists), else `managed env`.
- `aliases_kubectl.sh` - same logic for kubectl.
- `aliases_nix.sh` - always `nix-env managed` (nix-specific by definition).

```bash
# >>> nix-env managed >>>
# :path
. $HOME/.nix-profile/etc/profile.d/nix.sh
export PATH="$HOME/.nix-profile/bin:$PATH"
export NIX_SSL_CERT_FILE="$HOME/.config/certs/ca-bundle.crt"
# :aliases
. "$HOME/.config/shell/aliases_nix.sh"
# :oh-my-posh
[ -x "$HOME/.nix-profile/bin/oh-my-posh" ] && eval "$(oh-my-posh init bash ...)"
# <<< nix-env managed <<<

# >>> managed env >>>
# :local path
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# :certs
export NODE_EXTRA_CA_CERTS="$HOME/.config/certs/ca-custom.crt"
# <<< managed env <<<
```

**PowerShell** - `_aliases_nix.ps1` provides `_NxProfileRegenerate` + region helpers. Nix-managed regions use the `nix:` prefix (`#region nix:base`, `#region nix:path`, `#region nix:certs`). Generic regions (certs, conda, make completer) use unprefixed names and are written by `setup_profile_user.ps1`. The uninstaller only removes `nix:`-prefixed regions.

Properties:

- Block content is **fully regenerated** each run, not appended.
- `manage_block upsert` / `Update-ProfileRegion` replaces old content atomically.
- `manage_block remove` / `nx profile uninstall` cleanly removes the block.
- `nx profile doctor` detects duplicate blocks and legacy (pre-managed-block) lines.
- `nix/uninstall.sh` removes only nix-specific blocks/regions, preserving generic config.

### 3f. Diagnostics (`nx doctor`)

See the table in §3c. Implementation is `.assets/lib/nx_doctor.sh`, copied to `~/.config/nix-env/nx_doctor.sh` during setup so it remains available after the repo is removed. By default only FAILs cause non-zero exit; `--strict` treats warnings as failures too (used in CI).

**Adding a check** is a §6 recipe: write `_check_<name>`, append `<name>` to `CHECKS`, document in §3c table.

### 3g. Certificate handling (`.assets/lib/certs.sh`, `nix/lib/phases/nix_profile.sh:phase_nix_profile_mitm_probe`)

Many enterprise environments use MITM TLS inspection proxies. Three ways tools break:

1. **Nix-installed binaries** are built against nix's own OpenSSL with an isolated Mozilla CA bundle. They do not consult the macOS Keychain or Linux system CA store. A proxy cert trusted by the OS is invisible.
2. **Python tools** (pip, requests, azure-cli) use `certifi`, vendored per-virtualenv.
3. **Node.js tools** use Node's built-in CA bundle by default, separate from the system store.

Detection runs during setup (`phase_nix_profile_mitm_probe`): probes a TLS endpoint (default `https://www.google.com`, override with `NIX_ENV_TLS_PROBE_URL`). On failure, runs `cert_intercept` to extract intermediate + root certs from the TLS chain, deduplicates, appends to `~/.config/certs/ca-custom.crt`. Then `build_ca_bundle` merges with nix CAs into `~/.config/certs/ca-bundle.crt`.

**Env vars exported by the `managed env` block:**

| Variable                             | Used by              | Points to       | Why                                                |
| ------------------------------------ | -------------------- | --------------- | -------------------------------------------------- |
| `NIX_SSL_CERT_FILE`                  | All nix-built tools  | `ca-bundle.crt` | Nix tools ignore OS store; need full bundle        |
| `NODE_EXTRA_CA_CERTS`                | Node.js, npm         | `ca-custom.crt` | Node trusts system CAs; only needs proxy additions |
| `REQUESTS_CA_BUNDLE`                 | Python requests, pip | `ca-bundle.crt` | Python replaces (not extends) its store            |
| `SSL_CERT_FILE`                      | OpenSSL-based tools  | `ca-bundle.crt` | Same replacement behavior                          |
| `UV_SYSTEM_CERTS`                    | uv, uvx              | n/a (flag)      | Tells uv to use platform native certificate store  |
| `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` | Google Cloud CLI     | `ca-bundle.crt` | gcloud has its own cert configuration              |

**VS Code Server** does not source `~/.bashrc`, so shell-profile env vars are invisible to extensions. Fix: `~/.vscode-server/server-env-setup` - written by `setup_vscode_certs` and `setup_vscode_server_env` in `.assets/lib/vscode.sh`. Both create the directory if absent (handles the bootstrap problem where setup runs before the first VS Code session).

**Shell functions** (defined in `.assets/config/shell_cfg/functions.sh`):

- `cert_intercept [host...]` - extract certs from TLS chains, append to `ca-custom.crt`. Default host is `$NIX_ENV_TLS_PROBE_URL`.
- `fixcertpy [path]` - patch certifi bundles with custom certs (each Python virtualenv has its own copy).

## 4. Package layering

Packages assemble bottom-up into a single `buildEnv` profile entry. No layer can shadow another.

| Layer | What           | Source                      | Managed by                  |
| ----- | -------------- | --------------------------- | --------------------------- |
| 1     | Base           | `nix/scopes/base.nix`       | Always installed            |
| 2     | Repo scopes    | `nix/scopes/<name>.nix`     | `setup.sh --<scope>` flags  |
| 3     | Overlay scopes | `local_*.nix` in scopes dir | `nx scope add`, overlay dir |
| 4     | Extra packages | `packages.nix`              | `nx install` / `nx remove`  |

All four merge into a single `nix profile upgrade` - one atomic operation, one rollback point. Layers 3 and 4 are user/team customization; layers 1-2 are repo-controlled.

## 5. Critical "do not break" decisions

These choices are load-bearing - changing one cascades. Each entry is a *constraint*, not a preference.

**Bash 3.2 + BSD sed compatibility (nix-path files).** macOS ships bash 3.2 and Apple will not update it (GPLv3). The setup script must run on stock macOS - bootstrapping cannot require something a user might not have. Linux-only files (`.assets/scripts/`, `.assets/check/`, `.assets/provision/` except `install_copilot.sh`, WSL scripts) may use bash 5+ features. See §7 for the full constraint list. Enforced by `check-bash32`.

**Zsh sourcing constraints (shell-sourced files).** `.assets/config/shell_cfg/*.sh`, `.assets/lib/nx.sh`, the four `nx_<family>.sh` files, and `.assets/lib/profile_block.sh` get sourced into the user's interactive shell on macOS (bash and zsh) and Linux. They must work under both. See §7. Enforced by `check-zsh-compat`.

**`set -eo pipefail` without `-u` (nix-path files).** Bash 3.2 treats `arr=()` as unset when `-u` is active, so `${#arr[@]}` on an empty array errors. The counter-variable workaround was actively harmful to readability. ShellCheck (pre-commit) catches uninitialized refs at lint time - a stronger guard than runtime `-u`. Linux-only scripts may use `set -euo pipefail`.

**Bootstrap dependency (jq via base_init.nix).** `scopes.json` is the single source of truth, parsed natively by bash (jq), PowerShell (`ConvertFrom-Json`), and Python (`json`). On bare macOS bash 3.2 has no JSON parser, so jq must be bootstrapped before scope resolution. Mechanism: `base_init.nix` (jq, curl) + `isInit` flag in `config.nix` + conditional inclusion in `flake.nix` + ~13 lines in `setup.sh`. Runs once per machine, then `isInit` flips to false. Vendoring jq (per-arch) and pure-bash JSON parsing were considered and rejected.

**No repo-level `flake.lock`.** Per-user lock in `~/.config/nix-env/flake.lock` gives run-to-run reproducibility on one machine; explicit `nx pin` covers fleet pinning. `nixpkgs-unstable` is the input - Hydra-validated rolling release, not raw `main`. `setup.sh` does **not** implicitly run `nix flake update` on scope-only changes; the upgrade path is explicit (`--upgrade` or `nx upgrade`).

**Atomic file install for runtime files.** Files copied into `~/.config/nix-env/` and `~/.config/shell/` use `install_atomic` (temp file + same-filesystem rename). A plain `cp` races against any concurrent shell sourcing the file → cryptic `command not found` / `syntax error` errors. `flake.nix` and `scopes/*.nix` stay on plain `cp` (read by nix tooling, not the user's shell).

**Symmetric (not duplicated) profile dispatchers.** Bash and PowerShell `nx profile` operate on structurally different files (rc with sentinel blocks vs `$PROFILE` with `#region`). Implementations must stay independent; surface stays in sync via `check-nx-profile-parity`. **Do not** try to "deduplicate" by shelling PS to bash - `$PROFILE` resolution and region syntax are PS-specific.

**Manifest-driven completions.** Adding/changing a verb, subverb, or flag goes through `nx_surface.json`. Hand-editing `completions.bash`, `completions.zsh`, or the `#region nx-completer` block in `_aliases_nix.ps1` will be reverted by the next `gen_nx_completions` run and rejected by `check-nx-completions`.

**Wrapper boundary at the phase level.** Side-effect wrappers (`_io_nix`, `_io_curl_probe`, `_io_run`) are called from `nix/lib/phases/*.sh`. Configure scripts (`nix/configure/*.sh`) are themselves invoked via `_io_run`, so their internal commands are already wrapped. Adding `_io_*` *inside* configure scripts would force tests to stub at two levels for no gain.

**Default unfree = false.** `allowUnfree` is opt-in via `--allow-unfree` (sticky in `config.nix`). Avoids silent license-compliance exposure, binary cache misses, and reproducibility gaps. Terraform (the most common unfree request) is handled outside the nix store via tfswitch -> `~/.local/bin`.

## 6. How to add X - recipes

Follow these exact steps. They are built from real change sets.

### 6.1. Add a new scope

1. Create `nix/scopes/<name>.nix` with a `# bins:` comment and a `{ pkgs }: with pkgs; [ ... ]` body.
2. Add `<name>` to `.assets/lib/scopes.json` - `valid_scopes` and `install_order` (and `dependency_rules` if it pulls in others).
3. Add a `--<name>` case to `phase_bootstrap_parse_args` in `nix/lib/phases/bootstrap.sh`.
4. If post-install configuration is needed: add `nix/configure/<name>.sh` and a `case` entry in `phase_configure_per_scope` in `nix/lib/phases/configure.sh`.
5. If the scope needs a removal hook: add `nix/configure/<name>_remove.sh` and a case in `phase_scopes_apply_removes`.
6. Add a CHANGELOG entry under `## [Unreleased]`.
7. Run `make lint` (triggers `validate-scopes` + `bats-tests`).

### 6.2. Add a new phase function

1. Add the function to the appropriate file in `nix/lib/phases/`. Use `phase_<phase>_<verb>` naming.
2. Document globals in the header comment (`# Reads:` / `# Writes:`).
3. Call it from `nix/setup.sh` at the right point in the phase sequence.
4. Use `_io_*` wrappers for any external commands (`nix`, `curl`, script invocations).
5. Add bats tests that stub `_io_*` and verify behavior. Define stubs **after** sourcing `io.sh`.

### 6.3. Add a new nx verb (in an existing family)

1. Edit `.assets/lib/nx_surface.json` - add the verb (or subverb) under the appropriate parent. Include `name`, `summary`, optional `aliases`, `subverbs`, `args`, `flags`.
2. Implement the verb in the matching family file (`nx_pkg.sh`, `nx_scope.sh`, `nx_profile.sh`, or `nx_lifecycle.sh`). Use `function name() {` (zsh-compat).
3. Wire the dispatcher in `.assets/lib/nx.sh`'s `nx_main` if the verb is top-level - every manifest verb name and alias must have a matching `case` arm, otherwise `check-nx-dispatch-parity` will fail.
4. Regenerate completers and `nx help`: `python3 -m tests.hooks.gen_nx_completions` (also rewrites the `_nx_lifecycle_help` body from the manifest).
5. If the verb is `nx profile *`: also add the case to PowerShell `_aliases_nix.ps1`'s `switch ($subCmd)` block, otherwise `check-nx-profile-parity` will fail.
6. Add bats tests in `tests/bats/test_nx_*.bats` (and Pester tests under `tests/pester/` for any PS-side change).
7. Update the user-facing summary in `docs/nx.md`.
8. Add a CHANGELOG entry.
9. Run `make lint` (triggers `check-nx-completions`, `check-nx-profile-parity`, `check-nx-dispatch-parity`, `bats-tests`).

### 6.4. Add a new nx family file

Rare - only when an existing family becomes too large or a new domain emerges.

1. Create `.assets/lib/nx_<family>.sh`. No shebang (sourced library). Every function definition uses `function name() {` (zsh-compat). Use private `_nx_<family>_*` names.
2. Add `nx_<family>.sh` to the loop in `nx.sh` that sources family files.
3. Add `nx_<family>.sh` to the install list in `nix/lib/phases/bootstrap.sh:phase_bootstrap_sync_env_dir` (the `install_atomic` loop). Verify the file ends up in `~/.config/nix-env/`.
4. Add the file to the `env_dir_files` doctor check in `nx_doctor.sh`.
5. Update `tests/bats/test_nx_zsh.bats` setup to copy the new family file into `$ENV_DIR` (so `_nx_find_lib`'s zsh fallback resolves it).
6. Update §1 directory tree, §3c family table, and §13 runtime layout in this file.
7. Run `make lint` and `make test-unit`.

### 6.5. Add a new doctor check

1. Implement `_check_<name>` in `.assets/lib/nx_doctor.sh`. Return one of: empty (skip), `pass`, `warn<TAB><detail>`, `fail<TAB><detail>`.
2. Append `<name>` to the `CHECKS` list at the bottom of the file.
3. Add a row to the doctor table in §3c of this file (and `docs/nx.md` if user-facing).
4. Add bats tests in `tests/bats/test_nx_doctor.bats` covering pass + at least one fail/warn path.
5. Run `make lint`.

### 6.6. Add a new flag (no behavior change to surface schema)

If the flag belongs to an existing verb in `nx_surface.json`:

1. Add the flag to the verb's `flags[]` in `nx_surface.json`. Set `takes_value` / `value_completer` if it consumes an argument with dynamic completion.
2. Implement the flag in the verb function (in the matching `nx_<family>.sh` file).
3. Regenerate completers: `python3 -m tests.hooks.gen_nx_completions`.
4. If the flag is for `setup`, also add the case to `phase_bootstrap_parse_args` in `nix/lib/phases/bootstrap.sh`.
5. Run `make lint`.

### 6.7. Add a new pre-commit hook

1. Add the script under `tests/hooks/<name>.py`. Use `python3 -m tests.hooks.<name>` invocation style.
2. Register in `.pre-commit-config.yaml` under the local repo. Set `files:` to a regex (file scope is the regex, not a shell glob).
3. Add the hook ID + description to §8 of this file (and `docs/standards.md` if user-facing).
4. Run `make lint-all HOOK=<id>` to verify the hook over the whole tree.
5. Add the hook to CHANGELOG under `## [Unreleased]`.

### 6.8. Add a new completer

For a dynamic value completer (e.g. listing installed packages, scope names):

1. Add the completer name to `completers{}` in `nx_surface.json`.
2. Add the per-shell snippet (bash, zsh, pwsh) to the `COMPLETER_SNIPPETS` constant in `tests/hooks/gen_nx_completions.py`. Each snippet emits the candidate list using shell-native idioms.
3. Reference the completer from the relevant flag's `value_completer` or arg's `completer` in `nx_surface.json`.
4. Regenerate completers: `python3 -m tests.hooks.gen_nx_completions`.
5. Run `make lint`.

## 7. Constraints reference

### 7.1. File scope (which bash version, which set flags)

| Files matching                                                                                                                                                                                                                                                                          | Bash version | `set` flags         |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ------------------- |
| `nix/**/*.sh`, `.assets/lib/{scopes,profile_block,nx,nx_pkg,nx_scope,nx_profile,nx_lifecycle,nx_doctor,helpers,certs,install_record,setup_log,vscode}.sh`, `.assets/config/shell_cfg/{aliases_*,functions}.sh`, `.assets/setup/setup_common.sh`, `.assets/provision/install_copilot.sh` | 3.2          | `set -eo pipefail`  |
| `.assets/provision/*.sh` (except `install_copilot.sh`), `.assets/scripts/*.sh`, `.assets/check/*.sh`, `.assets/fix/*.sh`                                                                                                                                                                | 5.x (Linux)  | `set -euo pipefail` |

The bash 3.2 file scope is the regex in `.pre-commit-config.yaml`'s `check-bash32` block (not a shell glob).

### 7.2. Bash 3.2 / BSD constraints (nix-path files)

Avoid:

- `mapfile` / `readarray` - use `while IFS= read -r line; do arr+=("$line"); done < <(...)`
- `declare -A` (associative arrays) - use space-delimited strings + helpers (`scope_has`, `scope_add`, `scope_del` in `scopes.sh`)
- `${var,,}` / `${var^^}` (case modification) - use `tr '[:upper:]' '[:lower:]'`
- `declare -n` (namerefs) - pass variable name as string
- Negative array index `${arr[-1]}` - use `${arr[$((${#arr[@]}-1))]}`
- `sed \s` - use `[[:space:]]`
- `sed` BRE `\+` or alternation - use `sed -E` with bare `+` or alternation
- `sed -i ''` (BSD in-place) - write to temp file + `mv`
- `sed -r` - use `sed -E`
- `grep -P` (PCRE) - use `grep -E` or `sed`
- `grep \S` / `\w` / `\d` - use `[^[:space:]]` / `[a-zA-Z0-9_]` / `[0-9]`

Enforced by `check-bash32` (`tests/hooks/check_bash32.py`).

### 7.3. Zsh sourcing constraints (shell-sourced files)

Files in scope: `.assets/config/shell_cfg/*.sh`, `.assets/lib/nx.sh`, the four `nx_<family>.sh` files, `.assets/lib/profile_block.sh`. Constraints:

- **Bare function defs** (`name() {`) - use `function name() {`. Zsh expands aliases at parse time, so a function whose name matches an alias breaks under zsh.
- **Numeric array subscripts** (`${arr[0]}`) - zsh arrays are 1-based. Avoid indexed arrays or guard with `[ -n "$BASH_VERSION" ]`.
- **For-loops over unquoted globs** (`for f in "$dir"/*.ext`) - zsh's `nomatch` aborts the command on no-match. Use `find ... | while IFS= read -r f` instead.
- **Bash-only builtins/vars** (`BASH_SOURCE`, `BASH_REMATCH`, `compgen`, `complete -F`/`-W`, `COMP_WORDS`, `COMP_CWORD`, `COMPREPLY`) - guard with `[ -n "$BASH_VERSION" ]` or fall back when in zsh.

**Auto-detected safe forms** (no `# zsh-ok` marker needed):

- `BASH_SOURCE` access with default-value form `${BASH_SOURCE[N]:-...}`
- `BASH_SOURCE` on the same line as a `||` fallback
- `BASH_SOURCE` inside an equality test `[ "${BASH_SOURCE[0]}" = "..." ]`
- Any code inside an `if [ -n "${BASH_SOURCE[0]:-}" ]; then ... fi` guard block
- Pattern matches inside single-quoted string literals (e.g. `printf 'complete -W "..."'`)

Inline suppression (`# zsh-ok` appended to a line) is the rare escape hatch. Enforced by `check-zsh-compat` (`tests/hooks/check_zsh_compat.py`).

### 7.4. Sourced libraries vs executable scripts

Sourced library files (e.g. `nix/lib/io.sh`, `nix/lib/phases/*.sh`, `.assets/lib/*.sh`) must **not** have a shebang and must **not** be executable. Loaded via `source`.

Executable scripts must have `#!/usr/bin/env bash` and be `chmod +x`. Enforced by `check-executables-have-shebangs` and `check-shebang-scripts-are-executable`.

### 7.5. Runnable examples block

Every executable `.sh` and `.zsh` script must have a `: '...'` block immediately after the shebang. Lets the user run any example with the IDE "run current line" shortcut.

```bash
#!/usr/bin/env bash
: '
# run as current user
.assets/setup/setup_foo.sh
# run with a specific option
.assets/setup/setup_foo.sh --option value
'
set -euo pipefail
```

Rules: use `# comment` lines to describe what the next example does; the following line must be the bare runnable command (no `Usage:` / `Example:` prefix); never put prose with embedded single quotes inside the block (single quotes cannot be escaped inside `'...'`). Run `make egsave` to regenerate example scripts from these blocks.

### 7.6. Bash style

- Shebang: `#!/usr/bin/env bash`
- Indent: **2 spaces**; line length: **120** chars
- Command substitution: `$(...)`, never backticks
- Functions: `snake_case`; private: `_prefixed`. Prefer `local` for function-scoped vars.
- Variables: `snake_case` locals, `UPPERCASE` constants/env
- Color codes: `\e[31;1m` red/error, `\e[32m` green, `\e[92m` bright green, `\e[96m` cyan/info

### 7.7. PowerShell style

- Indent: **4 spaces**; brace style: **OTBS** (opening `{` on same line, closing `}` on own line)
- Functions: `Verb-Noun` PascalCase (approved verbs only); use parameter splatting for >3 parameters
- Parameters: `PascalCase`; locals: `camelCase`
- Public functions require comment-based help (`.SYNOPSIS`, `.PARAMETER`, `.EXAMPLE`)
- For conditional/loop with multiple conditions, all conditions and the opening `{` on the same line
- `wsl_setup.ps1` uses `$Script:rel_*` variables to cache release versions across distro loops

### 7.8. ShellCheck global excludes

`SC1090` (non-constant source), `SC2139` (expand at define time), `SC2148` (missing shebang on sourced files), `SC2155` (declare and assign separately), `SC2174` (mkdir mode).

## 8. Pre-commit hooks

Configured in `.pre-commit-config.yaml`, run via `prek` (not `pre-commit`).

### Local hooks (`tests/hooks/`)

| Hook                       | Script                        | What it checks                                                                                                                        |
| -------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `gremlins-check`           | `gremlins.py`                 | Unwanted Unicode (zero-width spaces, smart quotes); auto-fixes common substitutions                                                   |
| `validate-docs-words`      | `validate_docs_words.py`      | `project-words.txt` contains only words that appear in docs (removes stale entries automatically)                                     |
| `align-tables`             | `align_tables.py`             | Auto-aligns markdown tables on save                                                                                                   |
| `validate-scopes`          | `validate_scopes.py`          | `scopes.json` and `nix/scopes/*.nix` consistent; every scope has `# bins:`                                                            |
| `check-bash32`             | `check_bash32.py`             | Nix-path `.sh` files avoid bash 4+ constructs                                                                                         |
| `check-zsh-compat`         | `check_zsh_compat.py`         | Shell-sourced files work under zsh                                                                                                    |
| `check-changelog`          | `check_changelog.py`          | Runtime file changes require CHANGELOG entry under `[Unreleased]` (bypass via `skip-changelog` label)                                 |
| `check-nx-completions`     | `check_nx_completions.py`     | Generated completers + `_nx_lifecycle_help` body match `nx_surface.json` (regenerate via `python3 -m tests.hooks.gen_nx_completions`) |
| `check-nx-profile-parity`  | `check_nx_profile_parity.py`  | PowerShell `nx profile` subverbs match `nx_surface.json`                                                                              |
| `check-nx-dispatch-parity` | `check_nx_dispatch_parity.py` | Bash `nx_main` case arms (verbs + aliases) match `nx_surface.json`                                                                    |
| `bats-tests`               | `run_bats.py`                 | Runs bats unit tests when relevant files change (parses `source` directives to map files to tests)                                    |
| `pester-tests`             | `run_pester.py`               | Runs Pester unit tests when relevant files change                                                                                     |

### External hooks

| Hook                                   | What it checks                             |
| -------------------------------------- | ------------------------------------------ |
| `check-executables-have-shebangs`      | Executable files have a shebang line       |
| `check-shebang-scripts-are-executable` | Files with shebangs are `chmod +x`         |
| `end-of-file-fixer`                    | Files end with exactly one newline         |
| `mixed-line-ending`                    | No mixed LF/CRLF                           |
| `trailing-whitespace`                  | No trailing whitespace (except `.md`)      |
| `ruff-check` / `ruff-format`           | Python lint + format (`tests/` only)       |
| `markdownlint-cli2`                    | Markdown lint                              |
| `cspell`                               | Spell checking on docs and commit messages |
| `shellcheck`                           | Shell static analysis (severity: warning+) |

## 9. Testing

### 9.1. Unit tests - bats (`tests/bats/*.bats`)

Phase functions are tested by sourcing them directly and overriding `_io_*` wrappers from `nix/lib/io.sh`:

```bash
setup() {
  source "$REPO_ROOT/nix/lib/io.sh"
  source "$REPO_ROOT/nix/lib/phases/nix_profile.sh"
  source "$REPO_ROOT/.assets/lib/scopes.sh"

  # override side effects AFTER sourcing
  _io_nix() { echo "nix $*" >>"$BATS_TEST_TMPDIR/nix.log"; }
  _io_run() { echo "run $*" >>"$BATS_TEST_TMPDIR/run.log"; }
}

@test "nix_profile: apply runs profile add and upgrade" {
  phase_nix_profile_apply
  grep -q 'nix profile add' "$BATS_TEST_TMPDIR/nix.log"
  grep -q 'nix profile upgrade nix-env' "$BATS_TEST_TMPDIR/nix.log"
}
```

The `_io_*` convention: phases call `_io_nix`, `_io_nix_eval`, `_io_curl_probe`, `_io_run` instead of raw commands. Tests redefine these to capture calls. Define stubs **after** sourcing `io.sh` (sourcing redefines defaults).

### 9.2. Unit tests - Pester (`tests/pester/*.Tests.ps1`)

```powershell
$pesterCfg = @{
    Run    = @{ Path = 'tests/pester/'; Exit = $true }
    Output = @{ Verbosity = 'Detailed' }
}
Invoke-Pester -Configuration @pesterCfg
```

### 9.3. Runtime zsh smoke (`tests/bats/test_nx_zsh.bats`)

12 tests verify `nx.sh` and family files actually source and dispatch correctly under zsh (catches issues `check-zsh-compat` cannot - e.g. the 1.3.1 glob-nomatch trip). Skipped when zsh is not installed. Test setup copies lib files into `$ENV_DIR` because `_nx_find_lib`'s zsh fallback looks there (BASH_SOURCE is empty in zsh).

### 9.4. Smoke tests (Docker)

`make test-nix` builds a throwaway Docker image, runs a full nix provisioning pass, verifies key binaries on PATH, validates `install.json`, and exercises the uninstaller. Slower than unit tests; catches integration issues mocking cannot.

### 9.5. Coverage targets

Coverage is **not** measured as a percentage (bash makes line coverage misleading). Targets instead:

- Every phase function has at least one bats test that stubs side effects and asserts behavior.
- Every nx verb has at least one bats test (`test_nx_*.bats`).
- Every doctor check has pass + at least one fail/warn test.
- Every PS-side change to WSL orchestration has a Pester test that mocks `wsl.exe`.

## 10. CI scenarios

GitHub Actions workflows under `.github/workflows/` encode validated deployment targets. Each matrix entry is a real install scenario; passing the job is the compatibility guarantee for that scenario.

| Workflow          | Runner / Matrix            | Scenario it validates                                                                          |
| ----------------- | -------------------------- | ---------------------------------------------------------------------------------------------- |
| `test_linux.yml`  | `ubuntu-slim`, `daemon`    | Multi-user Nix install (WSL, bare-metal Linux, managed macOS via equivalent path)              |
| `test_linux.yml`  | `ubuntu-slim`, `no-daemon` | Single-user rootless Nix install. Covers Coder / devcontainer (no systemd, no root at runtime) |
| `test_macos.yml`  | `macos-15` (default), `26` | Apple Silicon macOS via Determinate installer. Validates bash 3.2 + BSD sed constraints        |
| `repo_checks.yml` | pre-commit hooks           | `check_bash32`, `check_zsh_compat`, `validate_scopes`, ShellCheck, lint                        |
| `release.yml`     | Full test matrix           | Build tarball + SBOM + sign + publish (triggers on `v*` tags)                                  |

**Test-per-run assertions** (both integration workflows):

- `setup.sh` completes with requested scope flags. Label-triggered runs use a fast smoke test (`--shell` plus a prompt theme); `workflow_dispatch` defaults to the full scope set (`--shell --python --pwsh --k8s-dev --terraform` plus a prompt engine) with an input override for custom scopes.
- Core binaries (`git`, `gh`, `jq`, `curl`, `openssl`) resolve on PATH.
- Scope-specific binaries resolve (mapped from scope flags).
- `nx doctor --strict` passes (warnings and failures both break the build).
- `# >>> nix-env managed >>>` block exists in `~/.bashrc` exactly once.
- Second `setup.sh` invocation produces exactly one managed block (idempotency).
- `install.json` written with `status = "success"`.
- `bats tests/bats/test_nix_setup.bats` passes.
- `nix/uninstall.sh --env-only` removes nix-env state, preserves generic `managed env` block, leaves `/nix/store` intact.

**Triggers:** manual (`workflow_dispatch` with scope override), PR label (`test:integration`), or push to an already-labeled PR.

**WSL end-to-end testing (intentionally omitted).** GitHub-hosted Windows runners only support WSL1 (no nested virtualization for WSL2), which lacks systemd and behaves differently from production WSL2. A self-hosted Windows runner with WSL2 would work but cannot be ephemeral, making maintenance cost disproportionate. The orchestration logic is validated by Pester unit tests (`tests/pester/WslSetup.Tests.ps1`) that mock `wsl.exe`.

## 11. CHANGELOG and SemVer

This project follows [Keep a Changelog](https://keepachangelog.com) format and [Semantic Versioning](https://semver.org/).

| Bump  | When                                                                 |
| ----- | -------------------------------------------------------------------- |
| MAJOR | Breaking `config.nix` layout, removed `nx` subcommand, removed scope |
| MINOR | New scope, new `nx` subcommand, new flag                             |
| PATCH | Bug fix, internal refactor, dependency bump, doc change              |

**Discipline.** Every PR that changes runtime files (`nix/`, `.assets/`, `wsl/`) must add an entry under `## [Unreleased]` in `CHANGELOG.md`. Enforced by `check-changelog`. Bypass via the `skip-changelog` PR label for doc-only or test-only changes.

**Cutting a release:**

1. Ensure all changes have CHANGELOG entries under `## [Unreleased]`.
2. Run `make release` - builds the tarball, prints the tag/push commands.
3. Review tarball contents, then run the printed commands.
4. The `release.yml` workflow runs the full test matrix, generates SBOM, signs artifacts, and publishes the GitHub Release.

## 12. File reference

### 12.1. nix-path (bash 3.2 + BSD compatible required)

| File                                                                                  | Role                                                               |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `nix/setup.sh`                                                                        | Main entry point (slim orchestrator, sources phase libraries)      |
| `nix/lib/io.sh`                                                                       | Structured logging + side-effect wrappers (tests override)         |
| `nix/lib/phases/bootstrap.sh`                                                         | Repo auto-refresh, root guard, paths, nix detect/install, jq, args |
| `nix/lib/phases/platform.sh`                                                          | OS detection, overlay discovery, hook runner                       |
| `nix/lib/phases/scopes.sh`                                                            | Load/merge scopes, resolve deps, write config.nix                  |
| `nix/lib/phases/nix_profile.sh`                                                       | Flake update, nix profile upgrade, MITM probe                      |
| `nix/lib/phases/configure.sh`                                                         | gh/git/per-scope configure dispatch                                |
| `nix/lib/phases/profiles.sh`                                                          | bash/zsh/PowerShell shell profile setup                            |
| `nix/lib/phases/post_install.sh`                                                      | Common post-install + nix garbage collection                       |
| `nix/lib/phases/summary.sh`                                                           | Mode detection + final status output                               |
| `nix/configure/{gh,git,docker,conda,az,terraform,omp,starship,profiles}.{sh,zsh,ps1}` | Per-scope post-install hooks                                       |
| `nix/configure/conda_remove.sh`                                                       | Removal hook for conda scope                                       |
| `nix/uninstall.sh`                                                                    | Removes nix-env environment, optionally Nix itself                 |
| `.assets/lib/scopes.{json,sh}`                                                        | Scope catalog (json) + helpers (sh)                                |
| `.assets/lib/nx_surface.json`                                                         | nx CLI verb/flag/subverb manifest                                  |
| `.assets/lib/install_record.sh`                                                       | Install provenance writer                                          |
| `.assets/lib/setup_log.sh`                                                            | Log file lifecycle                                                 |
| `.assets/lib/helpers.sh`                                                              | `download_file`, `gh_login_user`, `install_atomic`                 |
| `.assets/lib/profile_block.sh`                                                        | Managed-block library (sourced by profiles.sh/.zsh, nx)            |
| `.assets/lib/env_block.sh`                                                            | Generic env block (sourced by setup_profile_user; legacy)          |
| `.assets/lib/certs.sh`                                                                | CA bundle builder + VS Code Server cert setup                      |
| `.assets/lib/vscode.sh`                                                               | VS Code Server env helpers                                         |
| `.assets/lib/nx.sh`                                                                   | nx CLI entry point: helpers + family sourcing + dispatcher         |
| `.assets/lib/nx_pkg.sh`                                                               | nx verbs: search/install/remove/upgrade/list/prune/gc/rollback     |
| `.assets/lib/nx_scope.sh`                                                             | nx verbs: scope/overlay/pin                                        |
| `.assets/lib/nx_profile.sh`                                                           | nx profile verb + managed-block rendering                          |
| `.assets/lib/nx_lifecycle.sh`                                                         | nx verbs: setup/self/doctor/version/help                           |
| `.assets/lib/nx_doctor.sh`                                                            | Health-check registry (`nx doctor`)                                |
| `.assets/config/shell_cfg/aliases_{nix,git,kubectl}.sh`                               | Shell aliases (sourced into managed blocks)                        |
| `.assets/config/shell_cfg/functions.sh`                                               | Shared shell functions (cert_intercept, fixcertpy)                 |
| `.assets/config/shell_cfg/completions.{bash,zsh}`                                     | Tab completions for nx (**generated** from `nx_surface.json`)      |
| `.assets/setup/setup_common.sh`                                                       | Post-install setup (called via `nix/setup.sh`)                     |
| `.assets/setup/setup_profile_user.ps1`                                                | PowerShell user profile (certs, local-path, etc.)                  |
| `.assets/provision/install_copilot.sh`                                                | Post-install: GitHub Copilot CLI                                   |

### 12.2. linux-only (bash 4+ OK)

| File / Pattern                         | Role                                                                                          |
| -------------------------------------- | --------------------------------------------------------------------------------------------- |
| `.assets/scripts/linux_setup.sh`       | Linux system prep + nix delegation                                                            |
| `.assets/provision/install_*.sh`       | System-scope installers (base, nix, docker, podman, distrobox, zsh, gh, azurecli_uv, copilot) |
| `.assets/provision/upgrade_system.sh`  | System upgrade                                                                                |
| `.assets/setup/setup_profile_user.zsh` | User zsh profile setup                                                                        |
| `.assets/setup/setup_*.sh`             | Other setup scripts                                                                           |
| `.assets/check/*.sh`                   | System checks                                                                                 |
| `.assets/fix/*.sh`                     | One-off fixes                                                                                 |

### 12.3. powershell

| File / Pattern                             | Role                                                                                                                                |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `wsl/*.ps1`                                | WSL management (Windows host)                                                                                                       |
| `.assets/config/pwsh_cfg/_aliases_nix.ps1` | PowerShell aliases + nx (bash proxy + native PS profile mgmt); `#region nx-completer` block is **generated** from `nx_surface.json` |
| `.assets/config/pwsh_cfg/profile_nix.ps1`  | Base profile template                                                                                                               |
| `.assets/scripts/module_manage.ps1`        | Vendored module clone/update management                                                                                             |
| `modules/InstallUtils/`                    | Install utility module (repo cloning)                                                                                               |
| `modules/SetupUtils/`                      | Setup utility module (scopes, WSL config)                                                                                           |
| `modules/do-*/`                            | Vendored: common / Linux / Azure functions                                                                                          |
| `modules/psm-windows/`                     | Vendored: Windows-specific functions                                                                                                |
| `modules/aliases-{git,kubectl}/`           | Vendored: aliases + completers                                                                                                      |

### 12.4. nix declarations

| File / Pattern     | Role                                                                 |
| ------------------ | -------------------------------------------------------------------- |
| `nix/flake.nix`    | buildEnv flake (reads `config.nix`, merges base + scopes + packages) |
| `nix/scopes/*.nix` | 20 package list files (18 user-selectable scopes + base + base_init) |

### 12.5. tests

| File / Pattern                 | Role                                                          |
| ------------------------------ | ------------------------------------------------------------- |
| `tests/bats/*.bats`            | bats-core unit tests (incl. `test_nx_zsh.bats` runtime smoke) |
| `tests/pester/*.Tests.ps1`     | Pester unit tests                                             |
| `tests/hooks/*.py`             | Pre-commit hook scripts + `gen_nx_completions.py`             |
| `.github/workflows/test_*.yml` | Integration tests (see §10)                                   |

## 13. Runtime layout (durable state)

### 13.1. User-scope nix env (`~/.config/nix-env/`)

Persists after the repo is removed.

| Runtime file         | Source                                    | Created by                        |
| -------------------- | ----------------------------------------- | --------------------------------- |
| `flake.nix`          | `nix/flake.nix`                           | `nix/setup.sh`                    |
| `scopes/*.nix`       | `nix/scopes/*.nix`                        | `nix/setup.sh`                    |
| `config.nix`         | generated                                 | `nix/setup.sh` or `nx scope`      |
| `packages.nix`       | generated                                 | `nx install` / `nx remove`        |
| `omp/theme.omp.json` | `.assets/config/omp_cfg/`                 | `nix/configure/omp.sh`            |
| `profile_base.ps1`   | `.assets/config/pwsh_cfg/profile_nix.ps1` | `nix/configure/profiles.ps1`      |
| `nx.sh`              | `.assets/lib/nx.sh`                       | `nix/setup.sh` (`install_atomic`) |
| `nx_pkg.sh`          | `.assets/lib/nx_pkg.sh`                   | `nix/setup.sh` (`install_atomic`) |
| `nx_scope.sh`        | `.assets/lib/nx_scope.sh`                 | `nix/setup.sh` (`install_atomic`) |
| `nx_profile.sh`      | `.assets/lib/nx_profile.sh`               | `nix/setup.sh` (`install_atomic`) |
| `nx_lifecycle.sh`    | `.assets/lib/nx_lifecycle.sh`             | `nix/setup.sh` (`install_atomic`) |
| `nx_doctor.sh`       | `.assets/lib/nx_doctor.sh`                | `nix/setup.sh` (`install_atomic`) |
| `profile_block.sh`   | `.assets/lib/profile_block.sh`            | `nix/setup.sh` (`install_atomic`) |
| `pinned_rev`         | optional                                  | `nx pin set <rev>`                |

### 13.2. Hook directories (`~/.config/nix-env/hooks/`)

Not created automatically. `*.sh` files sourced in lexical order.

| Directory       | When                    | Variables available                                                         |
| --------------- | ----------------------- | --------------------------------------------------------------------------- |
| `pre-setup.d/`  | Before scope resolution | `NIX_ENV_VERSION`, `NIX_ENV_PLATFORM`, `ENV_DIR`, `NIX_ENV_PHASE=pre-setup` |
| `post-setup.d/` | After profile config    | All above + `NIX_ENV_SCOPES`, `NIX_ENV_PHASE=post-setup`                    |

### 13.3. Overlay directory (`~/.config/nix-env/local/` or `$NIX_ENV_OVERLAY_DIR`)

Discovery order: `$NIX_ENV_OVERLAY_DIR` (if set and exists), then `~/.config/nix-env/local/`. Not created automatically.

| Path           | Purpose                                           |
| -------------- | ------------------------------------------------- |
| `scopes/*.nix` | Extra nix packages (copied as `local_*.nix`)      |
| `shell_cfg/*`  | Extra shell config (copied to `~/.config/shell/`) |
| `hooks/*.d/`   | Hook scripts (see 13.2)                           |

### 13.4. Shell config (`~/.config/shell/`)

Sourced by `~/.bashrc` and `~/.zshrc` on all platforms including macOS.

| Runtime file         | Source                                        |
| -------------------- | --------------------------------------------- |
| `aliases_nix.sh`     | `.assets/config/shell_cfg/aliases_nix.sh`     |
| `aliases_git.sh`     | `.assets/config/shell_cfg/aliases_git.sh`     |
| `aliases_kubectl.sh` | `.assets/config/shell_cfg/aliases_kubectl.sh` |
| `functions.sh`       | `.assets/config/shell_cfg/functions.sh`       |
| `completions.bash`   | `.assets/config/shell_cfg/completions.bash`   |
| `completions.zsh`    | `.assets/config/shell_cfg/completions.zsh`    |

Extension convention: `.sh` (shared), `.bash` (bash-only), `.zsh` (zsh-only).

### 13.5. PowerShell config (`~/.config/powershell/`)

| Runtime file               | Source                                     |
| -------------------------- | ------------------------------------------ |
| `Scripts/_aliases_nix.ps1` | `.assets/config/pwsh_cfg/_aliases_nix.ps1` |

### 13.6. Provenance (`~/.config/dev-env/install.json`)

Written on every setup run (success or failure) by an EXIT trap (bash) or `clean` block (PowerShell).

| `entry_point` | Meaning                                         |
| ------------- | ----------------------------------------------- |
| `nix`         | `nix/setup.sh` run directly                     |
| `linux`       | `linux_setup.sh` (system prep + nix delegation) |
| `wsl/nix`     | `wsl_setup.ps1` using nix path                  |

### 13.7. Certificates (`~/.config/certs/`)

| Runtime file    | Created by                      | Purpose                          |
| --------------- | ------------------------------- | -------------------------------- |
| `ca-custom.crt` | `cert_intercept` (functions.sh) | Intercepted proxy certs only     |
| `ca-bundle.crt` | `build_ca_bundle` (certs.sh)    | Full CA bundle (system + custom) |

### 13.8. Environment variables exported by setup

| Variable                | Set by     | When                             | Purpose                                        |
| ----------------------- | ---------- | -------------------------------- | ---------------------------------------------- |
| `NIX_ENV_VERSION`       | `setup.sh` | After script root resolution     | Tool version (git tag / `VERSION` / `unknown`) |
| `NIX_ENV_SCOPES`        | `setup.sh` | After scope resolution           | Space-separated resolved scopes                |
| `NIX_ENV_PHASE`         | `setup.sh` | Before hook dispatch             | `pre-setup` or `post-setup`                    |
| `NIX_SSL_CERT_FILE`     | profiles   | Shell startup (if bundle exists) | Merged CA bundle for nix-built tools           |
| `NIX_ENV_TLS_PROBE_URL` | `certs.sh` | On source                        | TLS probe URL for MITM detection               |

`NIX_ENV_VERSION` uses a three-step fallback: `git describe --tags --dirty`, then a `VERSION` file (present in release tarballs), then `"unknown"`.

### 13.9. Environment variables read by the `nx` CLI (consumer-side)

These are read, not set, by `nx*.sh`. Useful for tests, dev iteration, and overriding default behavior.

| Variable              | Read by                | Purpose                                                                                                                                                                                                                             |
| --------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NX_LIB_DIR`          | `_nx_find_lib`         | Override library lookup path (highest priority); used by `test_nx_zsh.bats` to point at the source repo without copying files                                                                                                       |
| `NX_INVOKING_SHELL`   | `nx_doctor.sh`         | Shell name (`bash`/`zsh`) the `nx` wrapper detected from `$BASH_VERSION`/`$ZSH_VERSION`; routes the `shell_profile` check to the right rc file. Falls back to `$ZSH_VERSION` then `basename $SHELL` when unset (direct invocations) |
| `NIX_ENV_OVERLAY_DIR` | `nx_scope.sh`, `nx.sh` | Overlay directory location override (default: `~/.config/nix-env/local/`)                                                                                                                                                           |

## 14. Cross-links

| For                                                   | See                     |
| ----------------------------------------------------- | ----------------------- |
| Why specific design choices were made                 | `docs/decisions.md`     |
| End-user `nx` CLI guide                               | `docs/nx.md`            |
| Customization (overlay, hooks, scopes, pin)           | `docs/customization.md` |
| Corporate proxy / cert handling (operational details) | `docs/proxy.md`         |
| End-user architecture overview (mermaid diagrams)     | `docs/architecture.md`  |
| Quality / testing summary                             | `docs/standards.md`     |
| Release process detail                                | `docs/releasing.md`     |
| Workflow (how to develop on this repo)                | `CONTRIBUTING.md`       |
| Versioning policy                                     | §11 of this file        |
