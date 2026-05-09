---
description: Cross-shell feature parity - bash/zsh changes need a pwsh equivalent (and vice versa) when they touch user-shell behavior
globs: .assets/lib/nx_profile.sh, .assets/config/shell_cfg/**, .assets/config/pwsh_cfg/**, nix/lib/phases/profiles.sh
---

# Cross-shell feature parity

This project supports **bash, zsh, and PowerShell as first-class user shells**. A feature delivered in only some of them is a regression - users move between shells in the same week and expect parity. This rule activates when you touch shell-init or profile-rendering code; it exists to prevent the v1.6.3 incident shape (a fix landed for bash/zsh and silently skipped pwsh).

## When you change one side, check the other

Identify the paired-file location and decide whether it needs the same change. The mapping is not always 1:1 - pwsh consolidates more, so one bash/zsh file may map to a section of one pwsh file:

| bash/zsh                                             | pwsh                                                                | What it covers                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------- |
| `.assets/lib/nx_profile.sh` (`_nx_render_nix_block`) | `.assets/config/pwsh_cfg/_aliases_nix.ps1` (`#region nix:*` blocks) | nix-managed profile region: PATH, env vars, fnm self-heal |
| `.assets/config/shell_cfg/aliases_git.sh`            | `.assets/config/pwsh_cfg/_aliases_common.ps1` (git section)         | git aliases                                               |
| `.assets/config/shell_cfg/aliases_kubectl.sh`        | `.assets/config/pwsh_cfg/_aliases_common.ps1` (kubectl section)     | kubectl aliases                                           |
| `.assets/config/shell_cfg/aliases_nix.sh`            | `.assets/config/pwsh_cfg/_aliases_nix.ps1`                          | nix navigation aliases                                    |
| `.assets/config/shell_cfg/functions.sh`              | `.assets/config/pwsh_cfg/_aliases_common.ps1`                       | shell utility functions                                   |
| `nix/lib/phases/profiles.sh`                         | (orchestration only - invokes both renderers)                       | profile-rendering phase (both sides)                      |

## Three outcomes for any cross-shell change

1. **Mirror it.** Most cases. The pwsh equivalent gets the same behavior, adapted to PowerShell idioms - OTBS braces, `$env:VAR` (not `$VAR`), approved verbs, PascalCase parameters.
2. **Document the asymmetry inline.** Some features only apply to one shell environment. Example from v1.6.3 - the bash/zsh `XDG_RUNTIME_DIR` self-heal in `nx_profile.sh` WAS mirrored to `_aliases_nix.ps1`, but with an outer guard: `if ($env:XDG_RUNTIME_DIR -and -not (Test-Path ...))`. On native Windows pwsh that env var is unset, so the inner block correctly never runs and `id -u` (Linux-only) is never called. **The asymmetry is the design; it must be documented in a comment so the next reader doesn't "fix" it by removing the guard or making the pwsh side fire unconditionally.**
3. **Skip with reasoning.** The change is genuinely shell-specific (e.g., bash `compdef` completion, zsh `KEYTIMEOUT`). No pwsh equivalent is needed; no action. State this explicitly in the PR description so reviewers don't assume an omission.

If you're not sure which case applies, ask the user before submitting.

## The v1.6.3 incident - why this rule exists

A bug fix lands for bash and zsh because both render from the same `_nx_render_nix_block` generator in `nx_profile.sh`. The pwsh equivalent uses a different code path (`_NxProfileRegenerate` in `_aliases_nix.ps1`) and is silently omitted from the fix. The PR ships, the regression persists on Windows pwsh, and the next user to hit it has to re-debug.

When fixing a shell-init bug, explicitly walk: bash ✓, zsh ✓, pwsh ✓. If pwsh doesn't need it, say why in the commit message.

## Out of scope for this rule

- **WSL host-side scripts under `wsl/*.ps1`** - those run on the Windows host before any user shell is alive. Different concern, covered by the `wsl-orchestration` review shard.
- **Generated completion files (`completions.bash`, `completions.zsh`)** - auto-generated from `nx_surface.json`; pwsh has its own completer mechanism (`NxCompleter.Tests.ps1`) that's separately tested. Don't hand-edit the generated artifacts.
- **Tests, CI, pre-commit hooks** - covered by their own shards.

## Periodic safety net

Even with this rule active, the per-PR cycle can miss things. The [`config-templates`](../../design/reviews/charters/config-templates.md) and [`nx-cli`](../../design/reviews/charters/nx-cli.md) review charters list cross-shell parity as a criterion their periodic review pass checks for. This rule is the first line of defense; the charters are the second.
