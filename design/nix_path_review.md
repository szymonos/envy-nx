# Nix Path Architectural Review

**Scope:** `nix/setup.sh`, flake architecture, scope system, and integration strategy for enterprise distribution.
**Last updated:** April 2026

---

## Executive Summary

**Verdict: Strong engineering. Distribution and air-gapped support are the remaining gaps.**

Code quality is **9/10** - above-average for ops tooling with proper error handling,
test coverage, explicit design trade-offs in `ARCHITECTURE.md`, deliberate multi-language
schema design (`scopes.json` consumed natively by bash/PowerShell/Python), and a slim
phase-based orchestrator (`nix/setup.sh` ~120 lines sourcing `nix/lib/phases/`) that
isolates side effects behind testable `_io_*` stubs.

Enterprise fit is **8/10**. Coder validated (no-daemon CI matrix), macOS validated
(Determinate installer workflow), `--unattended` mode, configurable TLS probe URL,
`pinned_rev` mechanism with `nx pin set`, overlay hooks for fleet distribution, legacy
system-scope layer fully removed. Remaining gaps: release tarball distribution,
air-gapped installation support, fleet guidance documentation.

---

## Strengths

### Architecture & Documentation

- **`ARCHITECTURE.md` is exceptional.** File ownership classified by runtime constraint
  (bash 3.2, bash 4+, nix-only), call tree documented, runtime paths cataloged, design
  trade-offs with rejected alternatives.
- **Clean layering.** Orchestration (`setup.sh`) -> declarative packages (`flake.nix`) ->
  scope lists (`.nix` files) -> tool-specific setup (`configure/*.sh`).
- **Idempotent managed-block pattern** (`profile_block.sh`) with `uninstall.sh` that
  actually works. Timestamped backups on every write.
- **JSON shared schema** (`scopes.json`) consumed natively by bash/PowerShell/Python.

### Operations & Observability

- **Provenance via EXIT trap** (`install_record.sh`) writes structured `install.json`
  with entry point, scopes, phase, status, and `allow_unfree`.
- **`nx doctor`**: 8 health checks with FAIL/WARN distinction, `--json` output.
  `# bins:` comments as single source of truth, validated by `validate_scopes.py`.
- **Extension points**: `NIX_ENV_OVERLAY_DIR`, `pre-setup.d/`/`post-setup.d/` hooks,
  `pinned_rev` for fleet cohort pinning, `nx overlay` CLI.

### Quality & Discipline

- **Bash 3.2 enforced via pre-commit** (`check_bash32.py`). Rare discipline.
- **Test coverage**: 13 bats test files, 9 Pester suites, Linux CI (daemon + no-daemon),
  macOS CI (Determinate installer, Sequoia + Tahoe).
- **Slim orchestrator**: `setup.sh` ~120 lines, phases independently sourceable by bats,
  side effects behind `_io_*` stubs in `nix/lib/io.sh`.
- **System-prefer scope handling**: pwsh and zsh scopes auto-skipped on Linux when
  system binaries exist; re-sorts after removals to keep `config.nix` consistent.

### Enterprise Readiness

- **MITM proxy handling** with configurable `NIX_ENV_TLS_PROBE_URL`, auto-detection,
  tool-specific env vars (`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, etc.).
- **`--unattended` mode** for MDM/Ansible/CI.
- **`--allow-unfree`** as a persisted, sticky config option (default false).
- **Version identity** (`NIX_ENV_VERSION` from git tags -> VERSION file -> short SHA).
- **Rollback**: `nx rollback` (nix profiles) + managed-block backups + `uninstall.sh`
  with `--dry-run` and `--env-only` modes.
- **Legacy layer fully removed**: nix is the only installation path; `wsl_setup.ps1`
  nix-only (no `-Nix` switch).

---

## Open Weaknesses

### 1. External GitHub fetches mid-install (HIGH)

Setup requires live GitHub access for non-nix components:

- `.assets/provision/install_copilot.sh` curls `https://gh.io/copilot-install`
- `.assets/setup/setup_common.sh` clones `szymonos/ps-modules` via `Invoke-GhRepoClone`

Air-gapped or heavily proxied environments will fail on these steps. The copilot install
is skipped in CI (`$CI` check) but not in production. ps-modules is not vendored or
pin-overridable.

**Recommendation:** Make both fetches conditional or skippable via `--unattended` or a
dedicated `--offline` flag. Vendor ps-modules or provide `NIX_ENV_PS_MODULES_REPO` override.
Document the air-gapped installation path.

### 2. No versioned release tarball (MEDIUM-HIGH)

Distribution model is git-clone-only. No `scripts/build_release.sh`, no
`.github/workflows/release.yml`. `docs/enterprise.md` acknowledges this gap.

**Recommendation:** Implement Phase 1 from `implementation_plan.md` -- build release
tarball with VERSION stamp, SHA256 checksums, optional minisign signing.

### 3. Fleet guidance documentation (MEDIUM)

The overlay mechanism and hook system exist but lack concrete examples:

- No example `post-setup.d/` hook for fleet telemetry reporting
- No example overlay hook for fleet-wide nixpkgs pinning
- No documented telemetry data contract

**Recommendation:** Add `docs/examples/` with reference hooks for fleet pinning
(`fleet-pin.sh`) and telemetry (`telemetry-report.sh`). Define the telemetry contract
(what fields, what endpoint shape).

### 4. WSL end-to-end testing gap (MEDIUM)

macOS and Linux have dedicated CI workflows with real `nix/setup.sh` runs. WSL is
simulated via the Linux no-daemon matrix job. True WSL testing (Windows host running
`wsl_setup.ps1`) requires a Windows CI runner.

This is documented as a scope boundary in `ARCHITECTURE.md` -- the Pester unit tests
cover `wsl_setup.ps1` orchestration logic, and the Linux CI covers everything that
runs inside WSL.

### 5. kubectl aliases size (LOW)

`.assets/config/shell_cfg/aliases_kubectl.sh` is 52 KB. Conditionally loaded only when
kubectl is in scope, so no runtime impact for non-k8s users. Signals "personal dotfiles
taste" more than "company baseline," but functionally harmless.

---

## Risks for Enterprise Distribution

### Risk 1: Nix Adoption (Highest Impact)

Strategic, not technical. Validate with InfoSec/Platform that Nix is acceptable and
`install.determinate.systems` is reachable. If rejected, pivot to `mise`, `devbox`,
or static tarballs.

### Risk 2: macOS MDM

Nix on managed macOS (Jamf/Kandji) needs special handling: SIP restrictions, Gatekeeper,
daemon vs single-user. Early PoC on your MDM required.

### Risk 3: Upstream Drift

`nixpkgs-unstable` default + post-install scripts calling `gh`, `git`, `az` CLIs. Any
upstream option change breaks configure scripts. Mitigated by `pinned_rev` mechanism
but not enforced.

---

## Resolved Items

All items below were identified in earlier reviews and have been fully addressed:

| Item                                     | Resolution                                                                |
| ---------------------------------------- | ------------------------------------------------------------------------- |
| `setup.sh` monolith (590 lines)          | Phase extraction to `nix/lib/phases/`, orchestrator ~120 lines            |
| Implicit `nix flake update` on every run | `--upgrade` flag, `should_update_flake()` gates updates                   |
| Hidden `sudo` in rootless script         | Removed; fails with diagnostic if nix store unreachable                   |
| No upgrade control / rollback            | `nx upgrade`, `nx rollback`, `nx pin set`, managed-block backups          |
| Profile injection not reversible         | Managed-block pattern + `nx profile uninstall` + timestamped backups      |
| No org config overlay                    | `NIX_ENV_OVERLAY_DIR`, scope copy with `local_` prefix, hook dirs         |
| No `nx doctor` diagnostics               | 8 health checks, `--json` output, `# bins:` validated by pre-commit       |
| Bash 3.2 rules not enforced              | `check_bash32.py` pre-commit hook on all nix-path files                   |
| No macOS or Linux CI                     | `test_macos.yml` (Sequoia + Tahoe), `test_linux.yml` (daemon + no-daemon) |
| Error handling inconsistent              | `                                                                         |
| Legacy path coexistence                  | Legacy layer fully removed; nix is the only path                          |
| No unattended mode                       | `--unattended` flag skips all interactive steps                           |
| TLS probe URL not configurable           | `NIX_ENV_TLS_PROBE_URL` with documented default rationale                 |
| nixpkgs pinning per-user only            | `pinned_rev` + `nx pin set` + overlay hooks for fleet distribution        |
| No Day 1 user documentation              | `docs/index.md` quickstart + README with platform-specific commands       |
| Base vs opinions tangled                 | All opinion scopes (oh-my-posh, starship, zsh, kubectl) optional          |
| Unfree packages always allowed           | `--allow-unfree` persisted in config.nix, default false                   |
| `sorted_scopes` desync after `scope_del` | `phase_scopes_skip_system_prefer` re-sorts after system-prefer removals   |

---

## What Must Not Change

- **Managed-block pattern.** Correct; don't revert to append-style.
- **EXIT trap for provenance.** Good observability.
- **Overlay skeleton + hook directories.** Right extension points.
- **`nx doctor` health checks.** FAIL/WARN + `# bins:` as source of truth.
- **Bash 3.2 discipline with pre-commit enforcement.** Rare and valuable.
- **System-prefer scope handling.** Auto-skip on Linux, nix provides on macOS.
