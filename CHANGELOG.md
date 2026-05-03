# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [1.5.1] - 2026-05-03

Polish release on top of 1.5.0. Adds a `-WebDownload` switch to `wsl/wsl_setup.ps1` for environments where the Microsoft Store distro download is slow or blocked, aligns the two repo-owned PowerShell modules with the kebab-case naming used by every other module (`SetupUtils` → `utils-setup`, `InstallUtils` → `utils-install`), simplifies `.assets/scripts/modules_update.ps1` to a whole-directory copy from the upstream `ps-modules` checkout instead of cherry-picking individual functions, and fixes a `$input` automatic-variable collision in `tests/pester/ConvertCfg.Tests.ps1` that masked test intent.

### Added

- `wsl/wsl_setup.ps1`: new `-WebDownload` switch that appends `--web-download` to every `wsl.exe --install` invocation. Bypasses the Microsoft Store as the distro source - useful when the Store download stalls (common on slow or restricted networks) or when the Store is disabled by policy. Wired into all four install code paths (no-launch install, interactive setup, admin-mode service install, post-elevation install). Existing behavior preserved when the switch is absent.

### Changed

- **PowerShell module rename**: `modules/SetupUtils` → `modules/utils-setup` and `modules/InstallUtils` → `modules/utils-install`, including the manifest filenames (`utils-setup.psd1`, `utils-install.psd1`) and module GUIDs unchanged. Aligns the two repo-owned modules with the kebab-case convention used by `do-common`, `do-az`, `do-linux`, `psm-windows`, `aliases-git`, `aliases-kubectl` (every other module under `modules/`). All 11 callers updated in one pass: `wsl/*.ps1` scripts, `.assets/lib/scopes.sh` comment, `tests/pester/{Scopes,WslSetup}.Tests.ps1`, `.assets/scripts/modules_update.ps1`, `ARCHITECTURE.md`, `design/phase_1_self_contained.md`. Anyone importing these modules directly by old name (`Import-Module SetupUtils`) needs to update the import path.
- `.assets/scripts/modules_update.ps1`: replaced the per-function cherry-pick logic with a whole-module directory copy from `../ps-modules/modules/<name>` to `./modules/<name>`. The previous design imported each function from ps-modules and rebuilt consolidated `Functions/<group>.ps1` files inline (~50 lines of nested hashtable + string-builder per module). The new approach (`Remove-Item -Recurse -Force` + `Copy-Item -Recurse`) preserves the source layout exactly, so updates from upstream don't drift on file structure. Scope reduced to the 6 externally-sourced modules (`aliases-git`, `aliases-kubectl`, `do-az`, `do-common`, `do-linux`, `psm-windows`); the two repo-owned modules (`utils-install`, `utils-setup`) are not touched by this script since they're maintained in this repo.

### Fixed

- `tests/pester/ConvertCfg.Tests.ps1`: renamed every `$input` local to `$cfgInput`. `$input` is a PowerShell automatic variable (the pipeline input enumerator); using it as a `It`-block local shadowed the automatic and caused subtle test-behavior surprises depending on whether the `It` block ran via direct invocation or pipelined. Behavior of `ConvertFrom-Cfg`/`ConvertTo-Cfg` unchanged - this is purely a test-hygiene fix.

## [1.5.0] - 2026-05-02

`nx doctor` evolves from diagnostic into actionable: every failing or warning check now prints a `Fix:` hint, full output is mirrored to `~/.config/dev-env/doctor.log`, a `nix` version floor catches the most common cryptic-flake-error class, and a new `scope_bins_in_profile` check distinguishes "binary on PATH" from "binary actually provided by nix." Setup gains crash-proof provenance via incremental `install.json` flushes plus an `exec`-instead-of-exit auto-refresh - one invocation completes in one go, and the on-disk record reflects where the script died if it ever does. The MITM probe now distinguishes cert failure from network/DNS failure before mutating `ca-custom.crt`. The `nx_surface.json` manifest extends from completers/help into dispatchers and lib-file lists - 9 generated artifacts across 5 files, with 4 parity hooks collapsed into one `check-nx-generated` hook (~600 fewer lines of regex). Managed-block markers renamed to `nix:managed` / `env:managed` to match the PowerShell `nix:*` convention, with silent auto-migration. `make release` becomes one interactive command (auto-detect version, build, prompt to tag + push). Test infrastructure: bats and Pester suites now run in parallel via the same helpers `make test-unit` uses, integration workflows exercise the full suite per run, and a new `check-no-tty-read` hook prevents the silent-hang pattern from re-entering the codebase.

### Added

- `nx doctor`: each failing or warning check now prints a `Fix: <command-or-pointer>` hint indented under the check line, so the common remediation (`nx self sync`, `nx profile regenerate`, `nx upgrade`, re-run `nix/setup.sh`, etc.) is visible without re-deriving it from the failure message. All 13 checks have a remediation populated; absence is allowed (the new 3rd tab field on the `_check_<name>` return contract is optional and back-compat). Combined-failure cases (e.g. `cert_bundle` when both the bundle and VS Code env are missing) join remediation strings with ` && ` so the rendered Fix is valid shell, not broken syntax. Remediations referencing the install path lead with the durable URL (`https://nixos.org/download`) since `nx doctor` is meant to work from `~/.config/nix-env/` after the source repo is gone.
- `nx doctor`: writes a plain-text diagnostic log to `~/.config/dev-env/doctor.log` on every non-`--json` run (overwritten per run, atomic via temp + rename). Header carries date, host, invoking shell, and resolved `ENV_DIR`/`DEV_ENV_DIR`; body mirrors the terminal output without ANSI codes. The path is printed at the end of the summary only when failures or warnings exist - clean runs stay silent. Designed to be a shareable artifact when asking for help.
- `nx doctor --json`: each check entry in `.checks[]` now includes a `remediation` field (empty string for `pass`, populated for `warn`/`fail` when the check supplies one). Existing consumers reading `name`/`status`/`detail` are unaffected.
- `nx doctor`: `nix_available` check now also enforces a nix version floor of 2.18 (the flake-stability era used by current nixpkgs-unstable). Older nix produces cryptic flake errors; the check now FAILs with a clear remediation pointing at the official Nix install URL. Parses the trailing X.Y[.Z] from `nix --version`, which correctly handles both vanilla `nix (Nix) 2.18.1` and Determinate's `nix (Determinate Nix 3.6.5) 2.34.1` format.
- `nx doctor`: new `scope_bins_in_profile` behavior check - for each scope's `# bins:`, asserts the binary lives under `~/.nix-profile/bin/` specifically, not just somewhere on `$PATH`. Catches the case where a binary is present from a system install or another tool but nix never actually provided it (silently broken scope; `nx upgrade`/uninstall would leave the user with a binary they can't manage). Skipped when `~/.nix-profile/bin` is absent. Complements the looser `scope_binaries` check, which stays as a `WARN` for "PATH-resolvable" while the new check is a `FAIL` for "actually nix-managed." Scopes whose `# bins:` value starts with `(` (e.g. `(external-installer)`) are treated as opt-out sentinels: `conda.nix` uses this since miniforge installs to `~/miniforge3/bin/`, not the nix profile.
- `install_record.sh`: new `_ir_flush <status> [error]` helper for incremental writes. `nix/setup.sh` now calls it at every `_ir_phase` boundary so `~/.config/dev-env/install.json` reflects the *currently-running* phase even when the script is killed via SIGKILL/OOM and the EXIT trap never fires. The previous design only wrote at EXIT, losing provenance for exactly the failure modes where it's most useful. `installed_at` is captured once per run and reused across all flushes (cached in `_IR_INSTALLED_AT`), so it represents "when did this install start" rather than "when was the record last touched."
- `install_record.sh`: new `bash_version` field (`BASH_VERSINFO[0].BASH_VERSINFO[1]`) in both jq and fallback paths, surfaced by `nx version` as a `Bash:` line. Distinguishes Apple's frozen 3.2 from modern bash 5+ at a glance; useful for triaging "is this a bash 3.2 path failure?" without asking.
- `nix/setup.sh`: `phase_bootstrap_refresh_repo` now `exec`s the new `setup.sh` after a successful repo refresh instead of exiting and asking the user to re-run. The user invocation completes in one go - no more "did anything happen?" surprise. `NX_REEXECED=1` is exported as a loop guard so the post-exec invocation skips the refresh phase entirely. `exec` failures fall through to `set -e`, so the EXIT trap still records the failure.
- `phase_nix_profile_mitm_probe`: distinguish cert failure from network/DNS failure before triggering `cert_intercept`. The probe now runs a second `curl -k` (insecure) probe on first failure: if the bypass probe succeeds, the original failure was cert-related and `cert_intercept` is the right remedy; if the bypass probe also fails, the network is the problem and skipping interception prevents `ca-custom.crt` from being polluted with unrelated bytes. New `_io_curl_probe_insecure` wrapper in `nix/lib/io.sh` lets bats tests stub the bypass probe.
- `_io_step "<label>"` helper added to `.assets/lib/helpers.sh` for structured configure-script failure reporting. Configure scripts call `_io_step` before each non-trivial action; on failure, `_io_run` (in `nix/lib/io.sh`) extracts the LAST step marker from captured stderr and prepends `failed at step: <label>` to the error output. Users hitting a configure failure now see *which* part of the script died, not just the raw error stream. Markers are silent on success (existing `_io_run` behavior already discards captured stderr on success). `nix/configure/conda.sh` is instrumented as the demonstration; other configure scripts can adopt incrementally.
- Parallel test execution: `make test-unit` (and the `bats-tests` / `pester-tests` pre-commit hooks) now run files in parallel - bats via `xargs -P 4`, Pester via `ForEach-Object -Parallel` inside a single `pwsh` session (avoids paying ~3s startup per file). Helpers: `tests/hooks/run_bats.py` for the changed-file bats hook, `tests/hooks/run_pester.py` for the changed-file Pester hook, and `tests/hooks/pester_parallel.ps1` for full-suite parallel runs (used by `make test-unit` and the integration workflows). Both Pester helpers wrap each runspace in try/catch with a separate `$errBag` so a worker that crashes before `Invoke-Pester` returns a result is surfaced as a failure instead of silently passing. Local timeouts use `timeout`/`gtimeout` with auto-detection so the helpers work on stock macOS without coreutils.
- `tests/bats/diagnose.sh`: hang-diagnosis helper that runs each bats file with a per-file 30s budget and tags the output `PASS|FAIL(N)|HANG` so you can identify which file wedges a `make lint-all HOOK=bats-tests` run. Strips env vars known to cause hangs (proxy, GH_TOKEN, NIX_ENV_TLS_PROBE_URL) before running.
- `check-no-tty-read` pre-commit hook (`tests/hooks/check_no_tty_read.py`): forbids `read ... </dev/tty` in `.assets/`, `nix/`, `wsl/`, `modules/` without a `# tty-ok` self-attestation marker on the same line. The `read </dev/tty` pattern silently hangs in interactive shells (it bypasses stdin redirects and reads from the *session's* controlling tty), passes silently in CI/headless contexts (no controlling tty -> `open` fails -> fallback fires), so authors mistake it as safe. Hook prevents the trap from re-entering the codebase. Reference call sites with the `[ -t 0 ]` guard pattern: `nix/configure/conda_remove.sh` and `.assets/lib/nx_lifecycle.sh:_nx_self_dispatch`.
- `tests/bats/test_nx_doctor.bats`: ~250 lines of new coverage for Fix hint rendering (pass / warn / fail paths), the `doctor.log` write (header, ANSI stripping, path-printed-only-on-fail/warn, JSON skip), JSON `remediation` field, version-floor parsing edge cases (Determinate's wrapper format, missing version, below floor), `cert_bundle` combined-failure remediation, and the `(external-installer)` sentinel skip. `tests/bats/test_install_record.bats`: 7 new tests covering `bash_version` (jq + fallback), `_ir_flush` defaults / explicit status / `_ir_skip` no-op, and `installed_at` stability across multiple flushes + final write.

### Changed

- **Manifest-driven generation extended to dispatchers and lib-file lists** (Block D, item #1). `tests/hooks/gen_nx_completions.py` now emits 4 additional artifacts from `nx_surface.json`: `nx_main`'s `case "$cmd" in` body in `.assets/lib/nx.sh`, the `switch ($subCmd)` arms in PowerShell's `nx profile` dispatcher in `_aliases_nix.ps1`, and the `for X in <files>; do` lib-file lists in 3 sync/audit sites (`bootstrap.sh:phase_bootstrap_sync_env_dir`, `nx_lifecycle.sh:_nx_self_sync`, `nx_doctor.sh:_check_env_dir_files`). Total: 9 generated regions across 5 files, all derived from one manifest. Adding a verb is now manifest + regenerate; adding a family file is `family` field + regenerate. The four `check-nx-{completions,profile-parity,dispatch-parity,lib-files-parity}` hooks are collapsed into one `check-nx-generated` hook that diffs every region against the generator's expected output - generation is strictly more powerful than parsing-and-diffing, so the same correctness guarantee with one mental model and ~600 fewer lines of regex.
- `nx_surface.json`: every verb now declares its `family` (`pkg`, `scope`, `profile`, `lifecycle`). Used by the generator to derive bash handler names (`_nx_<family>_<verb>` for non-subverb verbs) and to compute the family-file list emitted to all 3 sync/audit sites. Old hand-authored handler names that didn't match the convention have been renamed for consistency: `_nx_lifecycle_self` → `_nx_self_dispatch` (matches `_nx_scope_dispatch`, `_nx_profile_dispatch`, etc. - all subverb-routing verbs use the `_dispatch` suffix).
- `_aliases_nix.ps1`: extracted the inline `'uninstall' { ... }` switch arm body (~30 lines of profile cleanup logic) into a `_NxProfileUninstall` function placed alongside the other `_NxProfile*` helpers. The `nx profile` dispatcher is now pure routing - precondition for generating the switch arms from the manifest. Behavior unchanged.
- `nx_main` case arms now drop dead `"$@"` forwarding for verbs that take no args/flags/subverbs (`upgrade`, `rollback`, `prune`, `gc`, `version`, `help`, `list`). Functions never read `$@` so this was always a no-op; the generator omits it to make the dispatcher match function intent.
- **Managed-block marker rename** (Block D, item #11). The two bash/zsh managed blocks have been renamed to match the `nix:*` convention already used by the PowerShell regions: `# >>> nix-env managed >>>` → `# >>> nix:managed >>>` (nix-specific block) and `# >>> managed env >>>` → `# >>> env:managed >>>` (generic env block). The previous names differed only in word order and were a routine source of typos / confusion. **Existing users are auto-migrated** silently on their next `nx profile regenerate` (or `nx upgrade` / `nx setup`, which call regenerate internally): `_nx_profile_regenerate` strips legacy-named blocks before writing new-named ones, so users transitioning from <= 1.4.x never end up with duplicates. `nx doctor`'s `shell_profile` check accepts both names as a valid managed block (no false-positive failures during the transition window). `nix/uninstall.sh` removes both names. The legacy-marker handling lives in code marked `# MIGRATION:` and is safe to drop in a subsequent major release after the install base has had time to migrate (cleanup plan: `design/marker_rename_cleanup.md`). PowerShell regions were already `nix:*` prefixed - no PS-side changes.
- `make release`: end-to-end release flow with one interactive confirmation. Auto-detects the version from the latest `## [X.Y.Z] - YYYY-MM-DD` heading in `CHANGELOG.md` (override with `make release VERSION=X.Y.Z` for hotfix builds). Enforces four preconditions: branch must be `main` (no accidentally tagging from a feature branch), worktree must be clean, local `HEAD` must match `origin/main` after a `git fetch` (so the tag always points at a published commit), and `vX.Y.Z` must not already exist locally *or* on origin (catches the "forgot to add a new release section" mistake before the tarball is built). After the tarball builds, prompts `Tag vX.Y.Z at HEAD and push to origin? [y/N]`: `y` runs `git tag -a` + `git push origin vX.Y.Z` (triggers `release.yml`); anything else prints the manual commands as an escape hatch (lets you inspect the tarball first). One target replaces the previous "build + print + manually tag + manually push" four-step dance.
- `docs/decisions.md`: added `### Why nix gc runs in post-install by default` section capturing the WSL VHD ratchet + maintainer-trust assumption that motivates GC-on-every-setup. Closes a documentation gap that left an intentional architectural choice looking like a reliability oversight to external reviewers. Cross-linked from ARCHITECTURE.md §3a post-install dispatch table.
- `docs/decisions.md`: clarified the Nix vs Homebrew comparison row for "Reproducible pins" - distinguishes per-user `flake.lock` (per-machine reproducibility) from `nx pin set <rev>` (cross-machine/team reproducibility). The previous wording conflated the two.
- Integration workflows (`test_linux.yml`, `test_macos.yml`): label-trigger and matrix defaults expanded to `--shell --pwsh --k8s-base --conda` + prompt engine so conda's external installer + the Pester runtime are exercised on every PR. Bats coverage expanded from one file to the full suite (parallel via `xargs -P 4`); Pester runs the full suite via the same helper `make test-unit` uses (with `Install-Module Pester` step on Linux runners that don't preinstall it). Uninstaller verification adds conda cleanup checks (`~/miniforge3` + `# >>> conda initialize >>>` block both removed). macOS workflow pins every step shell to `/bin/bash` so the bash 3.2 compatibility constraint is genuinely tested, not bypassed by brewed bash 5 on PATH.

### Fixed

- `Invoke-GhRepoClone` (`modules/utils-install/Functions/git.ps1`): guard the SSH probe with `Get-Command ssh -ErrorAction SilentlyContinue`. On Windows PowerShell hosts where OpenSSH is not on PATH (relevant when `wsl/wsl_setup.ps1` runs on a stock Windows host), the bare `ssh -T git@github.com` call previously threw under `$ErrorActionPreference = 'Stop'` and aborted the clone before HTTPS fallback could engage. Now resolves cleanly to HTTPS when `ssh` is unavailable.
- `git_resolve_branch` (`.assets/config/shell_cfg/aliases_git.sh`): rewrite `(|el|elop|elopment)` regex to `(el|elop|elopment)?`. BSD grep on macOS silently fails to match the empty-alternative form, so `git_resolve_branch ""` / `git_resolve_branch "d"` returned the literal regex pattern instead of resolving to `dev`/`development`. Same pattern lurked in the `gbda` alias - fixed too. Caught by the integration workflow's full bats suite on macos-15.
- macOS portability: `Makefile` `test-unit` target uses a shell glob instead of `find -maxdepth` (GNU extension); `tests/hooks/run_bats.py`, `tests/bats/diagnose.sh`, and `nx_doctor.sh`'s `_check_version_skew` now detect `timeout` vs `gtimeout` instead of hard-requiring GNU coreutils. All four were silently broken on stock macOS - the timeout fallback meant no-coreutils macOS users got `command not found` (`Makefile`, `diagnose.sh`) or silently skipped checks (`run_bats.py`, `nx_doctor.sh`).
- `_aliases_nix.ps1`: dropped two unused locals (`$baseProfileDst`, `$nixBinUvx`) in `_NxProfileRegenerate`. PSScriptAnalyzer flagged them as `PSUseDeclaredVarsMoreThanAssignments` - they were vestigial from earlier iterations where the path was used in code that has since been inlined into the region literal. Behavior unchanged.

## [1.4.0] - 2026-05-01

This release introduces the **manifest-driven nx CLI surface** - `.assets/lib/nx_surface.json` is the single source of truth for verbs, subverbs, aliases, flags, completer references, and `nx help` text. Adding a verb or flag is a one-file edit, regenerated into bash/zsh/PowerShell completers and the `nx help` body via one Python script. Four pre-commit parity hooks defend the surface against drift in any direction (completer files, PS `nx profile` dispatcher, bash `nx_main` dispatcher, lib-file installer/audit lists). Other highlights: `nix/setup.sh` auto-refreshes the source repo at start (with `--skip-repo-update` opt-out), `nx doctor` adds three new checks closing silent-failure gaps, the monolithic `nx.sh` is split into four verb-family files, and `nx_doctor.sh` is refactored into a registry pattern.

### Added

- `nix/setup.sh`: auto-refresh the source repo from upstream at start (`phase_bootstrap_refresh_repo` in `nix/lib/phases/bootstrap.sh`), mirroring `wsl/wsl_setup.ps1`'s `Update-GitRepository`. Uses the same cheap `ls-remote` pre-check (no fetch when remote tip already matches the local tracking ref). On a successful update, the script exits 0 with `repository updated to <upstream> - run the script again`. Skips silently when the working tree has uncommitted changes or HEAD has diverged from upstream (protects feature-branch dev work), when not in a git work tree (tarball install), when `git` is unavailable, or when no upstream tracking branch is configured (e.g. detached HEAD on CI).
- `nix/setup.sh --skip-repo-update`: opt-out flag for the auto-refresh, intended for repo-developer iteration ("test my uncommitted changes to setup.sh") and for callers that already refreshed the repo themselves. Wired into bash/zsh/PowerShell completers for `nx setup`. `wsl/wsl_setup.ps1` now passes it to `nix/setup.sh` since it already runs `Update-GitRepository` at script start.
- `.assets/lib/nx_surface.json`: declarative manifest for the `nx` CLI surface (verbs, subverbs, aliases, flags, dynamic completer references, summaries). Single source of truth for the completion generator, `nx help` generator, and the four parity hooks below.
- `tests/hooks/gen_nx_completions.py`: generator that emits bash/zsh/PowerShell tab completers AND the `_nx_lifecycle_help` body from `nx_surface.json`. Adding a verb or flag is a one-file edit (the manifest) instead of a four-file edit (parser + 3 completers). Side effects vs. the previous hand-written completers: zsh now offers `nx doctor` flags (`--strict`, `--json`) and `nx overlay` subverbs (`list`, `status`) which were previously missing; bash and zsh both now complete subverb aliases (e.g. `rm` for `scope remove`); bash groups subverbs sharing a completer into one elif (4 lines instead of 12 for `scope show|edit|remove|rm`).
- `nx help` text is now generated from `nx_surface.json`. The `_nx_lifecycle_help` body is wrapped with `# >>> nx-help generated >>>` / `# <<< nx-help generated <<<` markers and replaced in-place by the generator. Verb summaries, args representations (`<query>`, `<packages...>`, `[flags...]`), and the `(nx <verb> help)` hint for verbs with subverbs all derive from the manifest. Eliminates the verb-summary duplication (previously both heredoc and manifest had their own copies). Adds optional `help_args` schema field (used by `setup` to render `[flags...]` since its primary surface is passthrough flags, not positional args).
- `nx install` accepts `add` as an alias and `nx list` accepts `ls` - both were silently honored by the bash dispatcher but never declared in `nx_surface.json`, so completers and `nx help` never suggested them. Now in the manifest, surfaced everywhere.
- `check-nx-completions` pre-commit hook (`tests/hooks/check_nx_completions.py`): asserts the committed completer files **and** the `_nx_lifecycle_help` body match what the generator would emit from `nx_surface.json`. Catches drift in either direction - hand-editing a completer/help block, or editing the manifest without regenerating. Triggers on changes to the manifest, any generated artifact, or the generator/checker scripts.
- `check-nx-profile-parity` pre-commit hook (`tests/hooks/check_nx_profile_parity.py`): asserts the bash and PowerShell `nx profile` dispatchers expose the same subverbs. The two dispatchers are intentionally independent (they manage structurally different files - bash/zsh rc with `# >>> nix-env managed >>>` blocks vs PowerShell `$PROFILE` with `#region nix:* ... #endregion` regions) but their user-facing surface must stay in sync. Caught real drift on first run: PS dispatcher had no explicit `'help'` case (fell through to `default`); fixed by extracting the help text into `_NxProfileHelp` and dispatching both `'help'` and `default` to it, matching bash's `help | *)` pattern.
- `check-nx-dispatch-parity` pre-commit hook (`tests/hooks/check_nx_dispatch_parity.py`): asserts every verb (and alias) in `nx_main`'s `case "$cmd" in` block matches `nx_surface.json` and vice versa. Caught the `add`/`ls` alias drift on first run.
- `check-nx-lib-files-parity` pre-commit hook (`tests/hooks/check_nx_lib_files_parity.py`): asserts the 7 nx lib files (`nx.sh`, `nx_pkg.sh`, `nx_scope.sh`, `nx_profile.sh`, `nx_lifecycle.sh`, `nx_doctor.sh`, `profile_block.sh`) appear in all three places that install or audit `~/.config/nix-env/`: `phase_bootstrap_sync_env_dir` (bootstrap.sh), `_nx_self_sync` (nx_lifecycle.sh), and `_check_env_dir_files` (nx_doctor.sh). Adding a family file previously required touching 3 places with nothing to enforce sync; this hook closes the drift loop. Doctor's check legitimately includes `flake.nix` and `config.nix` as auxiliaries - the hook subtracts those before comparing.
- `nx doctor`: three new checks closing gaps where broken installs were silently fine until something else hit them. `env_dir_files` verifies that `~/.config/nix-env/{flake.nix,nx.sh,nx_doctor.sh,profile_block.sh,config.nix}` are all present (a sync that failed mid-run or a manually deleted file would otherwise surface as opaque `nx` / `nix profile upgrade` errors). `shell_config_files` parses the managed block in the invoking shell's rc and verifies every `~/.config/shell/<file>` it references exists on disk (catches the case where `aliases_nix.sh` is missing - that one's sourced unguarded and spams the terminal on every shell start). `nix_profile_link` verifies `~/.nix-profile` is a live symlink (a dangling target breaks every nix-built binary even though `nix profile list` still shows `nix-env`).
- `tests/bats/test_nx_zsh.bats`: 12 runtime-zsh smoke tests covering the documented zsh trip-points (sourcing, family-file load, `compdef`/`compinit` guard in `completions.zsh`, glob-nomatch on empty overlay dir, `_nx_find_lib` BASH_SOURCE fallback) and one entry-point per family dispatcher (pkg/scope/profile/lifecycle). Bats itself runs under bash; each test invokes `zsh -c "source nx.sh && nx_main ..."` so any zsh parse/expansion issue breaks the test. Skipped when zsh isn't installed (keeps non-zsh dev machines happy; CI always runs them since zsh is on `ubuntu-slim` and `macos-15` by default). Complements the static `check-zsh-compat` hook - the static check catches known patterns at edit time, the runtime tests catch whatever zsh actually chokes on.
- `NX_LIB_DIR` env var: explicit override for `_nx_find_lib`'s lookup path, takes precedence over BASH_SOURCE-based auto-discovery and the zsh `$HOME/.config/nix-env` fallback. Lets `tests/bats/test_nx_zsh.bats` point at the source repo's `.assets/lib/` instead of copying 7 files into the test's mock ENV_DIR per test. The fallback test still exercises the zsh `BASH_SOURCE`-empty path because `marker.sh` isn't in `NX_LIB_DIR`.

### Changed

- `nx.sh`: split from a single 1300-line file into a 200-line entry point plus four verb-family files (`nx_pkg.sh`, `nx_scope.sh`, `nx_profile.sh`, `nx_lifecycle.sh`) sourced at startup. `nx.sh` keeps the shared helpers (`_nx_read_pkgs`, `_nx_apply`, `_nx_scopes`, `_nx_find_lib`, etc.) and a flat dispatcher that routes each verb to `_nx_<family>_<verb>`. Behavior-preserving: all 156 nx bats tests pass unchanged. The four family files use the same `install_atomic` sync as `nx.sh` (concurrent shells may source them mid-write); `_nx_self_sync` and `phase_bootstrap_sync_env_dir` were updated to copy them too. `check-zsh-compat` hook scope extended to cover the new files. Doctor's `env_dir_files` check now also verifies the four family files are present (their absence breaks `nx`).
- `nx_doctor.sh`: refactored from 13 inline `if/then/_check` blocks into a registry pattern. Each check is now a self-contained `_check_<name>` function returning `pass|warn|fail<TAB><detail>` (or empty for skip); a single `_run_check` runner iterates the `CHECKS` list and parses the result. Adding a check is now a 10-line function plus a one-line registration. JSON schema and check ordering are byte-identical to before; all 24 bats tests pass unchanged.
- `check-zsh-compat` hook: smarter BASH_SOURCE detection - no longer requires `# zsh-ok` markers for the four legitimate patterns: default-value form `${BASH_SOURCE[N]:-...}`, `||` fallback on the same line, equality test `[ "${BASH_SOURCE[0]}" = "..." ]`, and code inside an `if [ -n "${BASH_SOURCE[0]:-}" ]` guard block. Also masks single-quoted string literals before applying rules so emitted text like `printf 'complete -W "..."'` doesn't trip the bash-completion-API rules. The numeric-subscript rule now exempts BASH_SOURCE accesses that pass the same safety checks. Removed all 5 `# zsh-ok` markers (3 in `nx.sh`, 1 in `nx_profile.sh`, 1 in `aliases_nix.sh`) - they're now redundant. Inline suppression remains as an escape hatch for genuinely-unusual cases. Verified with regression tests: hook still flags 9/9 deliberate violations, skips 6/6 safe-form patterns.
- `Update-GitRepository` (`modules/utils-install/Functions/git.ps1`): added a `git ls-remote --heads` pre-check that skips the always-on `git fetch --tags --prune --prune-tags --force` when the remote tip already matches the local tracking ref. Cuts several seconds off `wsl/wsl_setup.ps1`'s startup repo-freshness check on lower-end systems with slow disks (fetch always rewrites `FETCH_HEAD`/packed-refs even on a no-op). Upstream resolution is now a single `rev-parse --abbrev-ref --symbolic-full-name @{upstream}` call (replaces the `git remote` + `git branch --show-current` pair) and the post-fetch HEAD/upstream comparison is collapsed into one `rev-parse HEAD upstream`. The 0/1/2 return contract, retry loop, and `--prune-tags --force` semantics on the fetch path are unchanged.

### Fixed

- `nx doctor` `shell_profile` check: now audits only the rc file of the **invoking shell** instead of always checking both `~/.bashrc` and `~/.zshrc`. `nx.sh` (sourced into the user's interactive shell) detects bash vs zsh from `$BASH_VERSION`/`$ZSH_VERSION` and passes it to `nx_doctor.sh` via `NX_INVOKING_SHELL`. Removes the false positive where a legacy `.zshrc` (e.g. left over from a previously-installed zsh) failed `nx doctor` from a bash session. Pwsh continues to own its own check via `nx profile doctor` (in `_aliases_nix.ps1`) - same self-only contract, consistent across all three shells.
- `nx_doctor.sh` `_invoking_rc()` fallback chain: when `NX_INVOKING_SHELL` isn't set (direct invocation: `bash .assets/lib/nx_doctor.sh`, bats tests without the env var, etc.), the function now falls back to in-script `$ZSH_VERSION` (handles `zsh nx_doctor.sh`) then to `basename $SHELL` (the user's login shell - covers `bash nx_doctor.sh` from a zsh terminal where the script-side $BASH_VERSION would otherwise pick the wrong rc). Final fallback remains bash. New bats test pins the `$SHELL` fallback. The wrapper-set `NX_INVOKING_SHELL` is unchanged - this only affects direct invocations.

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
- Removed duplicated functions from `utils-install` (`Invoke-CommandRetry`, `Join-Str`, `Test-IsAdmin`, `Update-SessionEnvironmentPath`) and `utils-setup` (`ConvertFrom-PEM`, `ConvertTo-PEM`, `Get-Certificate`, `Show-LogContext`, `ConvertFrom-Cfg`, `ConvertTo-Cfg`, `Get-ArrayIndexMenu`, `Invoke-ExampleScriptSave`); WSL scripts now import `do-common`/`psm-windows` directly
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
