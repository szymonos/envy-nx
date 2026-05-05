# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## OpenWolf

@.wolf/OPENWOLF.md

This project uses OpenWolf for context management. Read and follow .wolf/OPENWOLF.md every session. Check .wolf/cerebrum.md before generating code. Check .wolf/anatomy.md before reading files.

## Project Overview

Universal, cross-platform system configuration and developer environment setup. Installs and configures base system tools (ripgrep, eza, bat, fzf), development toolchains (Python/uv, Node.js/Bun, shell scripting), shell prompt customization (oh-my-posh), and common aliases across shells.

**Platforms:**

- **macOS** - via `nix/setup.sh` (primary path)
- **Linux** (Debian/Ubuntu, Fedora/RHEL, OpenSUSE; Arch/Alpine have reduced support) - via `nix/setup.sh` or `linux_setup.sh`
- **WSL** (Windows Subsystem for Linux) - via `wsl/wsl_setup.ps1` on the Windows host
- **Coder / rootless environments** - `nix/setup.sh` works without root access

**Languages**: Bash 5.0+ (`.sh`), PowerShell 7.4+ (`.ps1`)

## Bash Portability

Scripts in the **Nix setup path** (`nix/setup.sh`, `.assets/lib/scopes.sh`, `.assets/config/shell_cfg/`) must be compatible with **bash 3.2** (macOS system default). This means:

- **No `mapfile`/`readarray`** - use `while IFS= read -r line; do arr+=("$line"); done < <(...)` instead
- **No `declare -A`** (associative arrays) - use space-delimited strings with helper functions (`scope_has`, `scope_add`, `scope_del` in `scopes.sh`)
- **No `${var,,}`/`${var^^}`** (case modification) - use `tr '[:upper:]' '[:lower:]'` instead
- **No `declare -n`** (namerefs), **no negative array indices** (`${arr[-1]}`)

Linux-only scripts (`.assets/scripts/linux_setup.sh`, `.assets/check/`, `.assets/provision/`, WSL scripts) may use bash 4+ features since they run on Linux where bash 5.x is standard.

## Setup Paths

### Primary: Nix (`nix/setup.sh`)

The preferred path for all platforms. Uses a Nix buildEnv flake for **user-scope, rootless, idempotent** package management. Nix itself must be pre-installed once (requires root); everything after runs as the user.

- Durable config lives in `~/.config/nix-env/` - persists after the repo is removed
- Run without scope flags to upgrade existing packages; add flags to install new scopes
- Scope definitions: `nix/scopes/*.nix`; flake: `nix/flake.nix`
- Post-install configuration scripts: `nix/configure/`

```bash
nix/setup.sh                                        # upgrade existing
nix/setup.sh --shell --python --pwsh --oh-my-posh  # install scopes
nix/setup.sh --all                                  # install everything
nix/setup.sh --help                                 # list all scopes/options
```

### Linux system prep (`linux_setup.sh`)

System-wide preparation for bare-metal Linux: base packages (ca-certificates etc.), system upgrade, nix bootstrap, then delegates to `nix/setup.sh` for user-scope packages.

### WSL: Windows host orchestration (`wsl/wsl_setup.ps1`)

Runs on the Windows host; creates/configures WSL distros and calls the Nix path inside WSL. System-scope packages (docker, pwsh, nix bootstrap) are installed directly before delegating to `nix/setup.sh`.

## Architecture

`ARCHITECTURE.md` is the single source of truth for file classification, call tree, constraints, runtime layout, pre-commit hooks, and step-by-step recipes. **Read it first** when the task touches any of:

- Adding/modifying a scope, `nx` verb, family file, doctor check, flag, completer, or pre-commit hook → use the recipes in §6
- Anything under `nix/lib/phases/`, `nix/configure/`, or the `phase_*` orchestration → §3a
- Files sourced into the user's shell (`.assets/config/shell_cfg/*`, `.assets/lib/nx*.sh`, `.assets/lib/profile_block.sh`) → zsh-compat rules in §7.3
- Managed shell-rc blocks or PowerShell `#region nix:*` regions → §3e
- `nx_surface.json` or any of the generated completer files → §3d (regenerate via `python3 -m tests.hooks.gen_nx_completions`)
- A pre-commit hook fires that you don't recognize → §8 explains each one
- A constraint feels arbitrary (`set -eo pipefail` without `-u`, no `flake.lock` in repo, atomic file install, symmetric bash/PS dispatchers) → §5 documents the load-bearing decisions

Skip reading it for typo fixes, doc-only edits, and conversational questions.

**Scope system**: users select feature sets (e.g., `shell`, `python`, `k8s_base`, `pwsh`). Scope logic and dependency resolution are in `.assets/lib/scopes.sh`; canonical definitions in `.assets/lib/scopes.json`. The Nix path uses the same scope names with package lists in `nix/scopes/*.nix`.

**Key shared files:**

- `.assets/lib/scopes.sh` - scope parsing, dependency resolution, `resolve_scope_deps` / `sort_scopes`
- `.assets/lib/helpers.sh` - shared helpers (`download_file`, `gh_login_user`)
- `.assets/setup/setup_common.sh` - post-install setup (copilot, zsh plugins, PS modules)

**Testing**: Unit tests in `tests/bats/` (bats-core) and `tests/pester/` (Pester) cover phase functions and WSL orchestration logic. Docker-based smoke tests in `.assets/docker/` run a full provisioning pass and verify key binaries exist in `$PATH`.

## Key Entry Points

- `nix/setup.sh` - primary entry point (all platforms, user-scope, no root after Nix install)
- `wsl/wsl_setup.ps1` - WSL orchestration, runs on Windows host
- `.assets/scripts/linux_setup.sh` - Linux system prep + nix delegation (requires root)
- `.assets/provision/install_*.sh` - system-scope tool installers (docker, pwsh, nix bootstrap)
- `.assets/setup/setup_*.sh` - user-level configuration scripts

## Common Commands

**IMPORTANT**: Always run `make lint` before every commit and fix any failures.

```bash
make lint                  # Run pre-commit hooks on changed files (use before committing)
make lint-all              # Run all pre-commit hooks on all files (slow)
make test-unit             # Run bats + Pester unit tests (fast, no Docker) - agent-runnable
make test-nix              # Docker smoke test for nix path - USER ONLY, do not run automatically
make test                  # Wraps test-unit + test-nix - USER ONLY (pulls in Docker)
make hooks                 # List available hook IDs (use with HOOK=<id>)
make help                  # List all available make targets
```

**Agent guardrail - Docker smoke tests:** never invoke `make test-nix` or `make test` from an agent
session. Both pull a Docker image and run a full `nix/setup.sh` provisioning pass; they take
several minutes and the user runs them on demand before merging. Agent-side verification stops at
`make lint` + `make test-unit` (or a scoped `bats tests/bats/<file>.bats`).

All `lint*` targets accept `HOOK=<id>` to run a single hook (e.g. `make lint-all HOOK=check-zsh-compat`) - seconds instead of minutes when verifying one hook's scope or rule changes across the whole tree. Run `make hooks` first to discover the available IDs.

**Tooling notes:**

- When cspell fails on a new word, add it to `project-words.txt` (sorted alphabetically) - that's the project dictionary
- Pre-commit runner is `prek` (not `pre-commit`)
- Use `pwsh` for PowerShell 7.4+ (not `powershell`)
- Use `gh` CLI for GitHub operations

## Global Renames and Pattern Changes

Before fixing a pattern globally, run `rg <pattern> .` or `git grep <pattern>` first to find **all** occurrences - don't start editing until the full scope is known. For bulk renames across multiple files, use `sed -i` instead of editing files one by one. Verify with another grep afterwards.

## Bash Style (`.sh`)

- Shebang: `#!/usr/bin/env bash`
- Indentation: **2 spaces**; line length: **120 chars max**
- Error handling: `set -euo pipefail`
- Command substitution: `$(...)`, never backticks
- Functions: `snake_case`, private: `_prefixed`; prefer `local` for function-scoped variables
- Variables: `snake_case` locals, `UPPERCASE` constants/env
- Color output: `\e[31;1m` red/error, `\e[32m` green, `\e[92m` bright green, `\e[96m` cyan/info

### Runnable examples block

Every executable `.sh` and `.zsh` script must have a `: '...'` block immediately after the shebang with copy-pasteable examples. See `CONTRIBUTING.md` "Runnable examples block" for the format and rules.

### Common Bash Patterns

```bash
# Distro detection
SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"

# Root check
if [ $EUID -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi
```

## PowerShell Style (`.ps1`)

- Indentation: **4 spaces**
- Brace style: **OTBS** - opening `{` on same line as statement, closing `}` on its own line, block body always on separate lines
- Functions: `Verb-Noun` PascalCase (approved verbs only); use parameter splatting for >3 parameters
- Parameters: `PascalCase`; local variables: `camelCase`
- Public functions require comment-based help: `.SYNOPSIS`, `.PARAMETER`, `.EXAMPLE`
- `wsl_setup.ps1` uses `$Script:rel_*` variables to cache release versions across distro loops
- For conditional/loop statements with multiple conditions, all conditions and the opening `{` must be on the same line
