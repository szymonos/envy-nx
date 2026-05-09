# Charter - `wsl-orchestration` shard (Windows-host PowerShell)

This shard runs on the Windows host **before any WSL distro exists**. It bootstraps the entire stack from PowerShell on the Windows side. Critically, **there is no CI coverage for real WSL2 boots** - only mocked Pester tests. Review effectively replaces integration testing here, so reviewer rigor matters more than for shards backed by CI. The recurring failure modes: encoding (CRLF, UTF-16, BOM surprises crossing the WSL boundary), path translation (`\\wsl$\...` vs `/mnt/c/...`), and distro lifecycle (idle-shutdown after ~8 seconds, race conditions with `wsl --shutdown`).

## Scope

| File                       | Role                                                               |
| -------------------------- | ------------------------------------------------------------------ |
| `wsl/wsl_install.ps1`      | Install WSL2 distribution (admin required)                         |
| `wsl/wsl_setup.ps1`        | WSL distro provisioning orchestrator (PowerShell 7.3+)             |
| `wsl/wsl_systemd.ps1`      | Enable/configure systemd in WSL distro                             |
| `wsl/wsl_certs_add.ps1`    | Add certificates to WSL distro (extracts from Windows trust store) |
| `wsl/wsl_files_copy.ps1`   | Copy files into WSL distro                                         |
| `wsl/wsl_distro_move.ps1`  | Move/copy and optionally rename a WSL2 distro                      |
| `wsl/wsl_flags_manage.ps1` | Manage WSL distro behavior flags (wslconfig settings)              |
| `wsl/wsl_restart.ps1`      | Restart WSL service (admin required)                               |
| `wsl/wsl_network_fix.ps1`  | Fix WSL network connectivity issues                                |
| `wsl/wsl_win_path.ps1`     | Manage appending Windows paths in PowerShell profile               |
| `wsl/wsl_wslg.ps1`         | Enable/configure WSL graphics (WSLg)                               |
| `wsl/pwsh_setup.ps1`       | PowerShell setup on the Windows host (PowerShell 5.1 compat)       |

**Out of scope:** the Linux-side scripts that get called inside the WSL distro after provisioning (those are `system-installers` / `orchestration` shards); the cert-extraction logic specifics (→ `certs` shard).

## What "good" looks like

- **Admin requirement is enforced via principal check**, not assumed: `if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { ... }`. Don't rely on the user reading the SYNOPSIS.
- **File copies across the WSL boundary handle UTF-8 without BOM.** Linux shells reject UTF-8-BOM at the start of a script with a cryptic error. PowerShell's default `Out-File` adds BOM - explicit `-Encoding utf8NoBOM` (PS 6+) or `[System.IO.File]::WriteAllText` is required.
- **Path translation uses `wsl wslpath -a`**, not string substitution. `\\wsl$\<distro>\path` ↔ `/path` translation has too many edge cases (drive letters, UNC vs DOS paths) to do by hand.
- **Long-running operations cope with idle-shutdown.** Either keep the distro alive (heartbeat command, or wrap in a single `wsl -- bash -c "..."` invocation) or accept restart cost. Don't assume the distro that was running 30 seconds ago is still running.
- **`$Script:` variables for cross-distro-loop state** are documented and used consistently per [`.claude/CLAUDE.md`](../../../.claude/CLAUDE.md). The pattern (e.g., `$Script:rel_*` for cached release versions) keeps the loop body clean.
- **`wsl.exe` is invoked via full path or via PATH lookup with fallback** - don't assume it's on PATH (it's not, in some constrained contexts).
- **Pester tests cover orchestration logic with realistic mocked distro state** - `WslSetupPhases.Tests.ps1` is the precedent for synthesizing distro-state hashtables and testing phase functions in isolation.
- **Output is parseable.** PS scripts that produce structured output use `[PSCustomObject]` (not formatted strings) so callers can pipe.
- **Functions follow `Verb-Noun` PascalCase with approved verbs**, parameters PascalCase, locals camelCase, OTBS brace style - per [`.claude/CLAUDE.md` → PowerShell Style](../../../.claude/CLAUDE.md).
- **Public functions have `.SYNOPSIS`, `.PARAMETER`, `.EXAMPLE`** comment-based help.

## What NOT to flag

- **PowerShell verbosity (the language).** It's the only choice for Windows-host orchestration that has to run on stock Windows. Suggestions to "rewrite this in Python" are out of scope (Python isn't guaranteed to be on a fresh Windows host).
- **OTBS brace style; PascalCase functions; approved verbs.** These are project conventions per CLAUDE.md. Flag *violations*, not the conventions.
- **Mocked Pester tests as a substitute for real WSL boot tests.** Per [`docs/index.md` → Limitations](../../../docs/index.md), this is a known gap. Don't re-flag it as a finding.
- **`$Script:`-scoped variables for cross-distro state in the loop bodies.** Existing pattern, intentional.
- **Repeated `wsl --shutdown` calls in some flows.** Necessary for clean state when WSL config changes need a restart to take effect.
- **`pwsh_setup.ps1` using PowerShell 5.1-compatible syntax.** It runs on the host's stock PowerShell, which on Windows 10/11 is 5.1. PS 7-only syntax in this file is a regression.
- **Anything already in [`design/reviews/accepted.md`](../accepted.md).**

## Severity rubric

| Level    | Definition                                                                                                                         | Examples                                                                                                                           |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| critical | A script destructively mutates Windows state without confirmation; UTF-16 / BOM corruption that bricks the target distro's shell.  | `wsl_distro_move.ps1` deletes the source distro before the copy is verified; a script writes a `.sh` with BOM that breaks shebang. |
| high     | Admin check missing on script that needs admin; encoding wrong on cross-boundary file copy; PS 7-only syntax in `pwsh_setup.ps1`.  | `wsl_install.ps1` runs without admin and silently fails partway; `wsl_files_copy.ps1` copies a `.sh` with default `Out-File` BOM.  |
| medium   | Path translation done by string substitution; missing approved-verb function; `$Script:` state leaks across distros; missing help. | `"\\wsl$\$distro\$path" -replace '\\','/'` instead of `wsl wslpath -a`; `Do-Setup` (not an approved verb).                         |
| low      | Comment rot, missing `.EXAMPLE`, parameter named camelCase instead of PascalCase, `$Script:` var without a brief reason comment.   | `# TODO: handle WSL1 - never going to`; public function with no `.PARAMETER` for one of its params.                                |

## Categories

| Category        | Use for                                                                         |
| --------------- | ------------------------------------------------------------------------------- |
| correctness     | A script does the wrong thing on some Windows version, distro, or pre-state.    |
| security        | Admin escalation surprise; weakened TLS; unvalidated input passed to `wsl.exe`. |
| maintainability | Convention violation (style, scoping, naming); cross-distro state leakage.      |
| testability     | Phase function can't be unit-tested via the synthetic distro hashtable pattern. |
| docs            | Missing `.SYNOPSIS`/`.PARAMETER`/`.EXAMPLE`; runnable-examples block stale.     |

## References

- [`.claude/CLAUDE.md` → PowerShell Style](../../../.claude/CLAUDE.md) - OTBS, indent, approved verbs, `$Script:` pattern
- [`docs/index.md` → Limitations](../../../docs/index.md) - explicit "WSL not e2e-tested in CI" disclosure
- `tests/pester/WslSetupPhases.Tests.ps1` - the canonical pattern for synthesizing distro state in tests
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes for this shard

## Charter version

- v1 (2026-05-09) - initial draft. Expect refinement after the first `/review wsl-orchestration` cycle, especially around encoding-edge-case examples surfaced from real fixes.
