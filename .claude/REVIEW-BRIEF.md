# Review brief

Project context for `/second-opinion`. The skill supplies the output format and bias-control rules.

## Project

Cross-platform system provisioner. Bash 5+, PowerShell 7.4+, Nix.
Three first-class user shells: **bash, zsh, PowerShell** - a fix to one usually requires a matching fix in the others.
Platforms: macOS, Linux, WSL (Windows host), Coder / containers.

## Focus areas (ordered by importance)

1. **Correctness** - logic errors, missed edge cases, off-by-one, race conditions, atomicity violations on file install.
2. **Cross-shell parity** - a fix landed for bash/zsh that's silently skipped for pwsh (or vice versa). Paired files to cross-check:
   - `.assets/lib/nx_profile.sh` (`_nx_render_nix_block`) ↔ `.assets/config/pwsh_cfg/_aliases_nix.ps1` (`#region nix:*` blocks)
   - `.assets/config/shell_cfg/aliases_git.sh` ↔ `.assets/config/pwsh_cfg/_aliases_common.ps1` (git section)
   - `.assets/config/shell_cfg/aliases_kubectl.sh` ↔ `.assets/config/pwsh_cfg/_aliases_common.ps1` (kubectl section)
   - `.assets/config/shell_cfg/functions.sh` ↔ `.assets/config/pwsh_cfg/_aliases_common.ps1`
3. **Bash 3.2 compatibility (macOS)** - scripts under `nix/`, `.assets/lib/`, `.assets/config/shell_cfg/` must avoid:
   - `mapfile`, `declare -A`, `${var,,}` (lowercase expansion), `declare -n` (namerefs), negative array indices.
   - GNU sed/grep extensions: `-P`, `-r` (use `-E`), `\s`, `\w`.
   - Linux-only scripts (`.assets/scripts/`, `.assets/check/`, `.assets/provision/`, `wsl/`) may use bash 5 freely.
4. **Error handling** -
   - Bash: missing `set -eo pipefail`; unchecked exit code after a critical external command.
   - PowerShell: missing `$ErrorActionPreference = 'Stop'` in `begin` block; unchecked `$LASTEXITCODE` after `wsl.exe` or native binaries; missing `Show-LogContext` for structured errors.

## Premium review triggers

A diff that touches any of these paths is reviewed by the premium model
(`scripts/review_brief.py run` picks it). They handle TLS trust, run as root, write the user's
shell rc files, or delete user files - review them with extra care.

- `.assets/lib/certs.sh`
- `nix/lib/phases/nix_profile.sh`
- `.assets/provision/*`
- `.assets/scripts/linux_setup.sh`
- `.assets/lib/profile_block.sh`
- `nix/uninstall.sh`

## Known patterns - do NOT flag

These are deliberate. Flagging them is noise - they're documented project decisions:

- **`set -eo pipefail` without `-u`** in bash scripts is intentional. `-u` (nounset) breaks shell-init files that source optional vars.
- **BSD `sed`/`grep` syntax** in nix-path scripts (`sed -En` not `sed -rn`; no `\s`/`\w`/`-P`) is intentional for macOS compat.
- **Atomic file install** (write to temp + rename) is intentional, not redundant - prevents partial reads during concurrent execution.
- **`Write-Host`** in PowerShell is intentional - bypasses the pipeline for colored console output.
- **No `flake.lock` checked in** is intentional - rolling channels.
- **Managed shell-rc blocks** with marker comments (`# >>> nx-managed >>>` / `# <<< nx-managed <<<`) are by design; do not suggest idempotency checks inside them - the markers ARE the idempotency mechanism.
- **`# no-learning` token** in commit messages is a deliberate opt-out for the `check-learning-trailer` hook on trivial refactors.
- **OTBS brace style in PowerShell** (opening `{` on same line as statement, even for `if`/`foreach`) is the project convention.
