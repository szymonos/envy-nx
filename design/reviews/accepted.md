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
