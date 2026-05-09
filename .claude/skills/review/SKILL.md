---
name: review
description: Run a periodic chunked code review against one shard of the repo. Use /review <shard> to start a review, /review next to rotate to the oldest-reviewed shard, /review act <findings-path> to triage findings and apply fixes, /review status to see what's pending. Spawns the reviewer/fixer/verifier subagents from .claude/agents/.
disable-model-invocation: true
---

# Chunked agentic-review skill

Orchestrates the periodic code-review cycle for envy-nx. Background and rationale: [`docs/decisions.md` → "Process decisions"](../../../docs/decisions.md). Framework artifacts: [`design/reviews/README.md`](../../../design/reviews/README.md).

This skill is **never auto-invoked** (`disable-model-invocation: true`). It runs only when the user explicitly types `/review` followed by a verb or shard name.

## Argument dispatch

This skill is invoked as `/review <args>`. It is the only skill in the namespace; there is no separate `/review-act` or `/review-status` skill (Claude Code resolves slash commands to skill names, and a hyphenated form like `/review-act` would look up a skill named `review-act` which does not exist).

Dispatch rule on first arg:

- `act <findings-path>` → triage and act (see "Triage and act" below)
- `next` → rotate to the oldest-reviewed shard and review it
- `status` → print the rotation table
- `<shard-name>` (any other value) → run a review on that shard
- (no args) → print the rotation table (same as `status`) plus a one-line usage hint

Reserved verbs (`act`, `next`, `status`) take precedence over shard-name resolution. **Do not add a shard named `act`, `next`, or `status`** to `shards.json` - there is no automated check for this collision (would need a dedicated hook), so the gate is this dispatch table. If the shard list grows past a single maintainer, add a `check_shards.py` hook that rejects reserved names.

## Commands

### `/review <shard>` - review one shard

1. Read `design/reviews/shards.json`. Look up the entry where `name == <shard>`. If not found, list available shard names and stop.
2. Verify the charter file at `<entry>.charter` exists. If missing, instruct the user to write the charter first (see `design/reviews/README.md` → "Adding a new shard") and stop.
3. Compute today's date in `YYYY-MM-DD` form and the current `git rev-parse HEAD` for the findings header.
4. Compute `sha256` of the charter file - pass it to the reviewer so it lands in the findings JSON (lets a stale findings file be detected when the charter has since changed).
5. Spawn the **reviewer** subagent (`.claude/agents/reviewer.md`) with this prompt:

   ```text
   Review shard: <shard>
   Charter: <charter-path>
   Charter sha: <charter-sha>
   File globs: <comma-separated globs from shards.json>
   Output path: .wolf/reviews/<date>-<shard>.json
   Git sha: <head-sha>
   Reviewed at: <iso-8601-utc>

   Load the charter and the accepted-decisions ledger (design/reviews/accepted.md), then walk the files matched by the globs. Emit findings as specified in the charter's severity rubric and category list. Write the JSON to the output path. Report back: total finding count, breakdown by severity, output path.
   ```

6. After the reviewer returns: update `.wolf/reviews/state.json` (create if missing) with the new last-run timestamp for this shard.
7. Print a one-line summary to the user: `Reviewed <shard>: <N> findings (<critical>/<high>/<medium>/<low>). See <output-path>. Run /review act <output-path> to triage.`

### `/review next` - rotate to oldest shard

1. Read `.wolf/reviews/state.json` (treat missing or unlisted shards as "never reviewed" → infinite age).
2. From `shards.json`, pick the shard with the oldest `last_run` (or never-run, breaking ties by `blast_radius` desc).
3. Run `/review <picked-shard>`.

### `/review act <findings-path>` - triage and act

1. Read the findings JSON at `<findings-path>`. Validate `charter_sha` against the current charter file's sha - if mismatched, warn the user the findings are stale and ask whether to proceed anyway or re-run review first.
2. For each finding, ask the user via `AskUserQuestion`:

   ```text
   F-XXX [<severity>/<category>] <file>:<line>
   <finding>
   Suggestion: <suggestion>

   apply | defer | dispute?
   ```

   - On **defer**: prompt for a one-line rationale and a `Re-evaluate when:` trigger (optional). Append a new entry to `design/reviews/accepted.md` (next monotonic `A-NNN` ID).
   - On **dispute**: prompt for a one-line rationale (why this isn't actually a problem). Append to `accepted.md` as `Decision: dispute` (no `Re-evaluate when:`).
   - On **apply**: keep in the apply-set for the fixer.
3. After triage:
   - If apply-set is empty: report "no findings marked for fix; defers/disputes recorded in accepted.md" and stop.
   - Otherwise: spawn the **fixer** subagent (`.claude/agents/fixer.md`) with the apply-set and findings path. Wait for it to return.
4. After the fixer returns successfully: spawn the **verifier** subagent (`.claude/agents/verifier.md`) with the findings path and the diff range (`git diff <base>...HEAD`). Report the verifier's per-finding verdicts to the user.
5. The user is responsible for opening the PR (the fixer prepares the branch and commit; the human pushes and opens the PR after reviewing the verifier's verdicts).

### `/review status` - show review cadence

1. Read `.wolf/reviews/state.json`. For each shard in `shards.json`, print a row:

   ```text
   <shard>  <last-run-date or "never">  <days-since>  <finding-count-last-run>
   ```

2. Sort by `days-since` descending - oldest first. Highlight shards that have never been reviewed.

## Findings JSON schema

The reviewer writes, the fixer reads. Both must conform.

```json
{
  "shard": "<shard-name>",
  "charter_path": "design/reviews/charters/<shard>.md",
  "charter_sha": "<sha256-of-charter-at-review-time>",
  "reviewed_at": "<iso-8601-utc>",
  "git_sha": "<git-rev-parse-HEAD-at-review-time>",
  "findings": [
    {
      "id": "F-001",
      "file": "<repo-relative-path>",
      "line": 87,
      "severity": "critical | high | medium | low",
      "category": "correctness | security | maintainability | testability | docs",
      "finding": "<1-3 sentence description of the issue>",
      "suggestion": "<concrete fix direction, NOT a patch - the fixer subagent decides the patch>"
    }
  ]
}
```

The `charter_sha` field is load-bearing: when `/review act` runs against a stale findings file (charter changed between review and act), it warns the user before triage rather than acting on outdated criteria.

## Triage state

`/review act` augments each finding in-memory with a `triage` field (`apply | defer | dispute`) and a `triage_rationale` field. This in-memory state is passed to the fixer; nothing is written back to the original findings JSON (it stays as the immutable record of what the reviewer saw).

## Rotation state

`.wolf/reviews/state.json`:

```json
{
  "shards": {
    "<shard-name>": {
      "last_run": "<iso-8601-utc>",
      "last_findings_path": ".wolf/reviews/<date>-<shard>.json",
      "last_finding_count": 12
    }
  }
}
```

Updated at the end of every `/review <shard>` run. Read by `/review next` and `/review status`. Per-clone - not synced via git.

## Safety constraints (enforced by agent frontmatter, documented here for the reader)

- **Reviewer cannot edit code.** `.claude/agents/reviewer.md` has `tools: Read, Grep, Glob, Bash` - no `Edit`/`Write`. This is intentional bias control: the reviewer cannot "pick easy issues" because it can't fix anything.
- **Verifier cannot edit code.** Same restriction. The verifier's job is to flag "fixed the symptom, not the cause" or "fix introduced an unrelated change". It escalates via report, never overrules.
- **Fixer cannot ignore the human.** The fixer only acts on findings the user marked `apply` during `/review act`. If a fix turns out to be wrong (test fails, unintended scope), it marks the finding `disputed (fix-broke-tests)` with the failing output captured, rather than silently dropping it.
- **Fixer hard DONE marker.** `make lint && make test-unit` must pass before the fixer reports completion. This is the deterministic verification per Anthropic's "give Claude a way to verify its work" guidance - not the agent's own judgment.

## Out of scope (intentionally not implemented)

- **Fan-out across all shards in one command.** Reviewing all 8 in parallel would consume context and produce a noisy combined inbox. Manual rotation via `/review next` is intentional.
- **Auto-trigger on cron.** WSL distros idle-shutdown after ~8s; cron is unreliable. Manual trigger also keeps the human in the loop on every cycle.
- **Persistent committed findings archive.** The fixer's PR description and `design/reviews/accepted.md` are the historical record. Raw findings JSON in `.wolf/reviews/` is forensic and ephemeral by design.
