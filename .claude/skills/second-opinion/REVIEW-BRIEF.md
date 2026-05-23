# Review brief - envy-nx

Curated context for a heterogeneous-model reviewer (`/second-opinion`).
You are reviewing a code diff. Read this brief first, then the diff, then any files needed for context.

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

## Output format

Produce a single markdown response with this structure:

```text
## Findings

### F-001 - <severity> - <file>:<line>
<one-paragraph description; reference the constraint being violated; be specific>

**Suggestion:** <concrete fix direction, NOT a patch>

### F-002 - <severity> - <file>:<line>
...
```

Severities:

- **`bug`** - correctness or security defect; the code is wrong.
- **`warning`** - likely issue, needs judgment; the code might be wrong under conditions you can't fully verify.
- **`nit`** - style or clarity; the code works but could be clearer.

If zero findings, output exactly: `No findings.`

## Bias-control rules

- Speculate carefully. If you suspect a bug but can't verify the call site, mark `warning` not `bug`.
- Don't pad with `nit` findings to look productive. Five `nit` items on a 200-line diff is fine; thirty is noise.
- If several findings share the same root cause, consolidate into one finding with multiple `<file>:<line>` references.
