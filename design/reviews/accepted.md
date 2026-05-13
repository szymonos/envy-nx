# Accepted decisions

Conscious decisions made during `/review act` triage. The reviewer subagent **must consult this file before flagging** and skip anything already accepted here. Without this ledger, every periodic review re-discovers the same trade-offs.

Two decision types live here:

- **Defer** - the finding is real, but we've decided not to fix it (e.g., breaking change, low ROI, intentional trade-off). Should re-evaluate when the rationale's `Re-evaluate when:` trigger fires.
- **Dispute** - the reviewer was wrong about this being a problem (e.g., misread the constraint, the "issue" is actually intentional). Should not be flagged again under any circumstances.

## Format

```markdown
## A-NNN: [Short title]

- **Date:** YYYY-MM-DD
- **Shard:** <shard-name>
- **Decision:** defer | dispute
- **Original finding:** [one-line summary; severity, file:line if useful]
- **Rationale:** [why this isn't worth fixing - link to docs/decisions.md, ARCHITECTURE.md, or context that informed the call]
- **Re-evaluate when:** [optional - the trigger that would change the answer; omit for `dispute`]
```

`A-NNN` is monotonic across all shards (not per-shard) so IDs are globally unique. Increment from the highest existing ID.

## Entries

<!-- Entries accumulate below as `/review act` triage produces defer/dispute decisions. Newest at the bottom. -->

## A-001: Defer `_check_version_skew` timeout-logic deduplication

- **Date:** 2026-05-09
- **Shard:** nx-cli
- **Decision:** defer
- **Original finding:** F-014 (low/maintainability, `.assets/lib/nx_doctor.sh:474`) - the `timeout 5 gh ...` fragment in `_check_version_skew` duplicates `_with_timeout` from `helpers.sh:220-230`.
- **Rationale:** Bundle with FU-003's architectural decision. The right shape of the fix depends on whether `nx_doctor.sh` may source `helpers.sh` (which would contradict the standalone-after-install property documented in ARCHITECTURE.md §5) or whether `nx_profile regenerate --dry-run` becomes the bridge. Fixing F-014 in isolation now risks doing the work twice.
- **Re-evaluate when:** FU-003 (`managed_block_drift` doctor check) is resolved and the doctor-vs-helpers coupling question has an answer.
- **Resolved 2026-05-10:** FU-003 implemented as `nx profile regenerate --dry-run` (preserving the standalone-after-install property by shelling out rather than sourcing `helpers.sh`). The new `_check_managed_block_drift` shares the same timeout pattern, so F-014 landed as a small `_dr_timeout_cmd` helper with two callers in `nx_doctor.sh` - `_check_version_skew` and `_check_managed_block_drift`.

## A-002: Defer pwsh `setup_profile_user.ps1` cert blocks pending F-003

- **Date:** 2026-05-13
- **Shard:** certs
- **Decision:** defer
- **Original finding:** F-004 (medium/maintainability, `.assets/setup/setup_profile_user.ps1:211`) - cert env vars written to `$PROFILE.CurrentUserAllHosts` in non-managed `#region certs` / `#region ca-bundle` / `#region gcloud-certs` blocks gated only on a substring `Select-String 'NODE_EXTRA_CA_CERTS'` check; the existing region is left stale once a tool is added later or the bundle path changes.
- **Rationale:** F-003 will be applied. Once the regenerable `nix:certs` region in `_aliases_nix.ps1` carries the same exports under the same conditions as the bash/zsh `_nx_render_env_block`, the static blocks in `setup_profile_user.ps1` may become redundant. Fixing F-004 in isolation now risks doing the work twice.
- **Re-evaluate when:** F-003 fix has landed and the `nix:certs` region has been audited for parity with the bash/zsh cert exports - at that point either drop the static blocks or commit to managed-region conversion.

## A-003: Dispute WSL temp-folder-in-repo-root concern

- **Date:** 2026-05-13
- **Shard:** certs
- **Decision:** dispute
- **Original finding:** F-006 (medium/correctness, `wsl/wsl_certs_add.ps1:109`) - `New-Item` for the random-named temp folder runs in `begin {}` against the script's current working directory (the repo root), so a crash between line 109 and the `clean {}` block on line 181 would leave a folder of intercepted PEM certs in the git-tracked working tree.
- **Rationale:** PowerShell's `clean {}` block always runs on Ctrl-C and on uncaught exceptions (this is the language guarantee that distinguishes `clean` from `end`), so the temp folder is removed; the leak scenario is theoretical, not reachable in practice.

## A-004: Dispute azcli venv-leak source-safety concern

- **Date:** 2026-05-13
- **Shard:** certs
- **Decision:** dispute
- **Original finding:** F-011 (low/correctness, `.assets/fix/fix_azcli_certs.sh:27`) - `source "$AZ_VENV"` activates the user's azure-cli venv inside the running script and never deactivates, leaking `VIRTUAL_ENV`/PATH/`pip` into the caller's shell if the script is sourced rather than executed.
- **Rationale:** `.assets/fix/*.sh` are designed and documented for direct execution only (shebang + `set -euo pipefail`); `make fix-certs` and other callers always invoke them as subprocesses, never `source`. Source-safety is not part of the script's contract, and adding subshell wrappers for a non-supported invocation pattern adds friction for the supported one.
