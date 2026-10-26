# Review rules

What counts as a defect in this repo and what never to report. Copilot code review,
`/second-opinion` and Claude Code Review all read this file; `REVIEW.md` links to it.

## Project

Cross-platform developer-environment provisioner: Bash, PowerShell 7.4+ and Nix. Entry points are
`nix/setup.sh` (macOS, Linux, Coder, user-scope), `.assets/scripts/linux_setup.sh` (Linux system prep,
root) and `wsl/wsl_setup.ps1` (Windows host). After setup the repo clone is disposable: runtime state
lives in `~/.config/nix-env/` and is managed by the `nx` CLI.

Load-bearing constraints (`ARCHITECTURE.md` §5 and §7 hold the full list):

- **bash, zsh and PowerShell are all first-class user shells.** A fix to one usually needs a matching fix
  in the others.
- Nix-path scripts (`nix/`, `.assets/lib/`, `.assets/config/shell_cfg/`) run on stock macOS bash 3.2 with
  BSD `sed`/`grep`. Linux-only scripts (`.assets/scripts/`, `.assets/check/`, `.assets/provision/`,
  `wsl/`) may use bash 5.
- Files sourced into the user's shell (`.assets/config/shell_cfg/*.sh`, `.assets/lib/nx*.sh`,
  `.assets/lib/profile_block.sh`) must work under both bash and zsh, and inherit the user's aliases.

## What counts as a defect here

- **Important** - wrong behaviour, a security hole, a stated requirement not met,
  or a rule in this file or `CLAUDE.md` broken. Only these block a merge.
- **Nit** - style, naming, clarity. Report at most five per review.
- **Evidence** - a claim about behaviour cites the `file:line` it rests on, not an
  inference from a name.
- **Out of scope** - hardening against a case that cannot happen here: extra
  validation of a trusted internal source, a new abstraction layer, defensive code
  or tests for an input that cannot occur. Bugs the change did not introduce are
  out of scope too; mention one once, as a follow-up.

## Focus areas (ordered by importance)

1. **Correctness** - logic errors, missed edge cases, race conditions, a runtime file installed without
   `install_atomic`, user data deleted before its replacement is in place.
2. **Cross-shell parity** - a fix landed for bash/zsh and silently skipped for pwsh, or the reverse.
   Paired locations:
   - `.assets/lib/nx_profile.sh` (`_nx_render_nix_block`, `_nx_render_env_block`) ↔
     `.assets/config/pwsh_cfg/_aliases_nix.ps1` (`#region nix:*` blocks, `_NxProfileRegenerate`)
   - `.assets/config/shell_cfg/aliases_nix.sh` and `functions.sh` ↔ `.assets/config/pwsh_cfg/_aliases_nix.ps1`
   - `.assets/config/shell_cfg/aliases_git.sh` ↔ `modules/aliases-git/`
   - `.assets/config/shell_cfg/aliases_kubectl.sh` ↔ `modules/aliases-kubectl/` (repo extras such as
     `ktog` in `_aliases_nix.ps1`)

   A deliberate asymmetry must carry an inline comment saying why; a missing one is the defect.
3. **Managed shell-rc blocks** - PATH and env sections must run in every shell; completion and prompt
   sections must be gated on `[[ $- == *i* ]]`. `nix/uninstall.sh` removes only `nix:managed` blocks and
   `nix:`-prefixed pwsh regions; anything generic belongs in `env:managed` or an unprefixed region.
4. **Bash 3.2 and zsh compatibility** beyond what `check-bash32` and `check-zsh-compat` catch - for
   example a 0-based array subscript or a bash-only builtin reached through an unguarded path.
5. **Error handling** -
   - Bash: an unchecked exit code after a critical external command.
   - PowerShell: missing `$ErrorActionPreference = 'Stop'` in `begin`; unchecked `$LASTEXITCODE` after
     `wsl.exe` or another native binary.
6. **Invocation helpers** - pwsh called from bash without `_io_pwsh_nop`; side-effect wrappers
   (`_io_nix`, `_io_run`) added inside `nix/configure/*.sh`, which already run under `_io_run`.

## Premium review triggers

- `.assets/lib/certs.sh`
- `nix/lib/phases/nix_profile.sh`
- `wsl/wsl_certs_add.ps1`
- `.assets/provision/*`
- `.assets/scripts/linux_setup.sh`
- `.assets/scripts/nopasswd_*.sh`
- `.assets/lib/profile_block.sh`
- `nix/uninstall.sh`

## Do not report

### Enforced by tooling

Pre-commit hooks (`prek`): shellcheck, shfmt, ruff, markdownlint, cspell, check-bash32,
check-zsh-compat, check-no-aliased-builtins (bare `mv`/`cp`), check-no-tty-read, check-distro-case-arm,
check-curl-tls, check-nx-generated, check-executables-have-shebangs, check-shebang-scripts-are-executable,
validate-scopes, check-changelog, check-arch-drift, check-skills, gremlins,
bats and Pester tests. CI runs Linux and macOS integration tests, the all-scopes env build and the
cross-version upgrade walk.

### Vendored or generated

- `modules/aliases-git/`, `modules/aliases-kubectl/`, `modules/do-*/`, `modules/psm-windows/` - vendored
  from upstream `ps-modules`; fix upstream, not here.
- `.assets/config/shell_cfg/completions.{bash,zsh}` and every other artifact
  `tests/hooks/gen_nx_completions.py` writes from `.assets/lib/nx_surface.json`.
- `uv.lock`.

### Author decisions

- **`set -eo pipefail` without `-u`** in nix-path scripts - bash 3.2 treats an empty array as unset under
  `-u`; shellcheck covers uninitialized refs. (`ARCHITECTURE.md` §5)
- **BSD `sed`/`grep` syntax** (`sed -E`, `[[:space:]]`, no `-P`) in nix-path scripts - macOS compat.
- **Temp file + rename** (`install_atomic`) is not redundant - a plain `cp` races a shell sourcing the file.
- **No repo `flake.lock`** - `nix/nixpkgs_rev.json` pins the validated revision instead. (decision 0011)
- **Managed-block markers are the idempotency mechanism** (`# >>> nix:managed >>>`,
  `# >>> env:managed >>>`, pwsh `#region nix:*`); content is fully regenerated each run, so do not suggest
  idempotency checks inside a block. (decision 0003)
- **Bash and PowerShell `nx profile` dispatchers stay independent** - do not suggest shelling pwsh out to
  bash to deduplicate them.
- **No per-call `LD_LIBRARY_PATH` clears around pwsh** - `flake.nix:patchPwsh` fixes the package.
  (decision 0014)
- **`Write-Host`** in PowerShell is intentional - it bypasses the pipeline for coloured console output.
- **OTBS braces in PowerShell** are the project convention.
- **pwsh aliases in `_aliases_nix.ps1` are not gated on a TTY** like the bash ones - agents run bash, and a
  pwsh profile is never in their shell snapshot. (`ARCHITECTURE.md` §7.10)
- **A PowerShell `clean {}` block is enough to remove temp files** - it runs on Ctrl-C and on uncaught
  exceptions. (certs standing review, 2026-05-13)
- **`.assets/fix/*.sh` are execution-only** - source-safety is not part of their contract.
  (certs standing review, 2026-05-13)
- **`runs-on: ubuntu-slim`** is a valid GitHub-hosted runner, used deliberately for light jobs.
- **PowerShell `-in` with a scalar right-hand side** is a one-element collection, not a substring test:
  `'set' -in 'setup'` is `$false`. The single-name verb completers rely on it.
- **`release-auto` and `/review` state and inputs are the agent's own** - `.release/` and the review skill's
  scratch directory are script-owned, git-ignored state, and `release.py` / `review.py` file arguments come from
  the agent running it. Symlink or alias planting under either directory and empty, directory or non-UTF-8 file
  arguments are not findings. (#117, #122)
- **A symlink, hard link or directory planted at a path a repo script owns** - the temp file beside
  `design/reviews/history.md`, `design/reviews/shards.json`, the findings JSON the review agents write - is not a
  finding; nothing but the scripts and their agents writes there. (#122)
- **Commands in a SKILL.md written `scripts/<name>`** resolve against the skill's own directory, where the agent
  runs them - not a missing repo-root path. (#122)
- **"a REVIEW.md rule" in `release-auto`** names the rule, not a write target. Only an instruction to edit the rules
  must name `.github/copilot-instructions.md`. (#121)
