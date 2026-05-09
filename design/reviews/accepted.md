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
