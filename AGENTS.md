# AGENTS.md

Project context for any AI coding agent working in this repository.

## Project Overview

Universal, cross-platform system configuration and developer environment setup. Installs and configures base system tools (ripgrep, eza, bat, fzf), development toolchains (Python/uv, Node.js/Bun, shell scripting), shell prompt customization (oh-my-posh), and common aliases across shells.

**Platforms:** macOS (`nix/setup.sh`), Linux (`nix/setup.sh` or `linux_setup.sh`), WSL (`wsl/wsl_setup.ps1` on Windows host), Coder/containers (`nix/setup.sh` rootless).

**Languages**: Bash 5.0+ (`.sh`), PowerShell 7.4+ (`.ps1`)

## Compound knowledge

Three knowledge layers beyond this file. Read on demand, not upfront:

| Layer                                            | When to read                                         | What it answers         |
| ------------------------------------------------ | ---------------------------------------------------- | ----------------------- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md)             | Modifying phases, scopes, nx CLI, hooks, constraints | How things connect      |
| [`design/decisions/`](design/decisions/INDEX.md) | Questioning why the project uses approach A over B   | Why things are this way |
| [`design/lessons.md`](design/lessons.md)         | Fixing bugs in shell-init, caching, profiles         | What went wrong before  |

## Architecture

`ARCHITECTURE.md` is the single source of truth for file classification, call tree, constraints, runtime layout, pre-commit hooks, and step-by-step recipes. **Read it first** when the task touches any of:

- Adding/modifying a scope, `nx` verb, family file, doctor check, flag, completer, or pre-commit hook -> use the recipes in section 6
- Anything under `nix/lib/phases/`, `nix/configure/`, or the `phase_*` orchestration -> section 3a
- Files sourced into the user's shell (`.assets/config/shell_cfg/*`, `.assets/lib/nx*.sh`, `.assets/lib/profile_block.sh`) -> zsh-compat rules in section 7.3
- Managed shell-rc blocks or PowerShell `#region nix:*` regions -> section 3e
- `nx_surface.json` or any of the generated completer files -> section 3d (regenerate via `python3 -m tests.hooks.gen_nx_completions`)
- A pre-commit hook fires that you don't recognize -> section 8 explains each one
- A constraint feels arbitrary (`set -eo pipefail` without `-u`, no `flake.lock` in repo, atomic file install) -> section 5

Skip reading it for typo fixes, doc-only edits, and conversational questions.

**Scope system**: users select feature sets (e.g., `shell`, `python`, `k8s_base`, `pwsh`). Scope logic and dependency resolution are in `.assets/lib/scopes.sh`; canonical definitions in `.assets/lib/scopes.json`. The Nix path uses the same scope names with package lists in `nix/scopes/*.nix`.

## Key Entry Points

- `nix/setup.sh` - primary entry point (all platforms, user-scope, no root after Nix install)
- `wsl/wsl_setup.ps1` - WSL orchestration from Windows host; creates distros, delegates to `nix/setup.sh`
- `.assets/scripts/linux_setup.sh` - Linux system prep + nix delegation (requires root)
- `.assets/provision/install_*.sh` - system-scope tool installers (docker, pwsh, nix bootstrap)
- `.assets/setup/setup_*.sh` - user-level configuration scripts

```bash
nix/setup.sh --shell --python --pwsh   # install scopes
nix/setup.sh                            # upgrade existing
```

## Common Commands

**IMPORTANT**: Always run `make lint` before every commit and fix any failures.

```bash
make lint                  # Run pre-commit hooks on changed files (use before committing)
make lint-all              # Run all pre-commit hooks on all files (slow)
make test-unit             # Run bats + Pester unit tests (fast, no Docker) - agent-runnable
make hooks                 # List available hook IDs (use with HOOK=<id>)
make help                  # List all available make targets
```

**Agent guardrail:** never invoke `make test-nix` or `make test` from an agent session. Both pull Docker images and run full provisioning passes. Agent-side verification stops at `make lint` + `make test-unit`.

All `lint*` targets accept `HOOK=<id>` to run a single hook - seconds instead of minutes when verifying one hook's scope.

**Tooling:** cspell dictionary is `project-words.txt`. Pre-commit runner is `prek` (not `pre-commit`). Use `pwsh` for PowerShell 7.4+. Use `gh` CLI for GitHub operations.

## Global Renames and Pattern Changes

Before fixing a pattern globally, run `rg <pattern> .` or `git grep <pattern>` first to find **all** occurrences - don't start editing until the full scope is known. For bulk renames across multiple files, use `sed -i` instead of editing files one by one. Verify with another grep afterwards.

## Cross-shell parity

bash, zsh, and PowerShell are all first-class user shells. When editing shell-init, profile-rendering, or alias files, check both sides - the [`.claude/rules/cross-shell-parity.md`](.claude/rules/cross-shell-parity.md) rule activates with the paired-file map and the canonical asymmetry example (the v1.6.3 fnm incident).
