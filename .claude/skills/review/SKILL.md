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

- `act <findings-path>` → triage and act (see the section below); spawns fixer + verifier
- `fix <finding-id>` → re-run the fixer on a single finding with revised guidance, after a verifier flag (auto-loads the active findings JSON from `state.json`)
- `next` → rotate to the oldest-reviewed shard and review it
- `status` → print the rotation table
- `<shard-name>` (any other value) → run a review on that shard
- (no args) → print the rotation table (same as `status`) plus a one-line usage hint

Reserved verbs (`act`, `fix`, `next`, `status`) take precedence over shard-name resolution. **Do not add a shard named `act`, `fix`, `next`, or `status`** to `shards.json` - there is no automated check for this collision (would need a dedicated hook), so the gate is this dispatch table. If the shard list grows past a single maintainer, add a `check_shards.py` hook that rejects reserved names.

## Commands

### `/review <shard>` - review one shard

1. Read `design/reviews/shards.json`. Look up the entry where `name == <shard>`. If not found, list available shard names and stop.
2. Verify the charter file at `<entry>.charter` exists. If missing, instruct the user to write the charter first (see `design/reviews/README.md` → "Adding a new shard") and stop.
3. Compute today's date in `YYYY-MM-DD` form and the current `git rev-parse HEAD` for the findings header.
4. Compute `sha256` of the charter file - pass it to the reviewer so it lands in the findings JSON (lets a stale findings file be detected when the charter has since changed).
5. **Load open followups for this shard.** If `.wolf/follow-ups/<shard>.json` exists, read entries with `status: open`. These are candidate findings from prior cycles. Pass the list (with `id`, `description`, `source_cycle`, `source_shard`) to the reviewer in the spawn prompt.
6. Spawn the **reviewer** subagent (`.claude/agents/reviewer.md`) with this prompt:

   ```text
   Review shard: <shard>
   Charter: <charter-path>
   Charter sha: <charter-sha>
   File globs: <comma-separated globs from shards.json>
   Output path: .wolf/reviews/<date>-<shard>.json
   Git sha: <head-sha>
   Reviewed at: <iso-8601-utc>
   Open followups: <list of {id, description, source_cycle} or empty>

   Load the charter, the accepted-decisions ledger (design/reviews/accepted.md), and the followups list above. Walk the files matched by the globs. Emit findings as specified in the charter's severity rubric. For each open followup, decide whether to re-emit as a finding (prefix `[FU-NNN]` in the finding field) or skip it for this cycle (it stays open). Append today's date to each considered FU's `considered_in_cycles` in `.wolf/follow-ups/<shard>.json`. Write findings to the output path. Report back: total finding count, severity breakdown, output path, and which FU-NNNs were re-emitted vs skipped.
   ```

7. After the reviewer returns: update `.wolf/reviews/state.json` (create if missing) with the new last-run timestamp for this shard.
8. Print a one-line summary to the user: `Reviewed <shard>: <N> findings (<critical>/<high>/<medium>/<low>). See <output-path>. Run /review act <output-path> to triage.`

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

   For each decision, write `triage_decision` (and `triage_rationale` for defer/dispute) back to the corresponding finding in the findings JSON via `jq` and atomic temp-file + rename. See "Append-only invariant" under the Findings JSON schema below.

   **If the finding's text starts with `[FU-NNN]`** (i.e., the reviewer re-emitted a followup as this finding): in addition to the findings JSON write, also update `.wolf/follow-ups/<shard>.json` to close the corresponding FU. Set `status: closed`, `closed_at: <iso-date>`, `closed_via: triage-applied` (or `triage-deferred` / `triage-disputed`).
3. After triage:
   - If apply-set is empty: report "no findings marked for fix; defers/disputes recorded in accepted.md" and stop.
   - Otherwise: spawn the **fixer** subagent (`.claude/agents/fixer.md`) with the apply-set and findings path. The fixer writes `fixer_outcome` and `fixer_commit` per finding back to the JSON. Wait for it to return.
4. **Persist the fixer's followups output.** The fixer's report includes a structured `followups` array - things it noticed but didn't act on (per the minimum-scope rule). For each entry, append to `.wolf/follow-ups/<suggested_home_shard>.json` (creating the file if absent). Each new entry gets the next shard-local `FU-NNN` id, plus initial fields: `status: open`, `source_cycle: <today>`, `source_shard: <current shard>`, `source_findings_path: <findings path>`, `considered_in_cycles: []`. Multiple entries with different home shards land in different files.
5. Spawn the **verifier** subagent (`.claude/agents/verifier.md`) with the findings path and the diff range (`git diff <base>...HEAD`). The verifier writes `verifier_verdict` and `verifier_note` per finding back to the findings JSON, AND checks open followups for this shard against the diff (auto-closing any that the diff incidentally resolves). Report the verifier's per-finding verdicts and any followup auto-closures to the user.
6. The user is responsible for opening the PR (the fixer prepares the branch and commit; the human pushes and opens the PR after reviewing the verifier's verdicts).

### `/review fix <finding-id>` - re-run the fixer on one finding with revised guidance

For when the verifier flagged a fix as `symptom-only`, `regression-risk`, `over-corrected`, or `not-applied`. Targets a single finding by ID; auto-loads the active findings JSON from `state.json` so no path argument is needed.

1. **Locate the active findings JSON.** Read `.wolf/reviews/state.json`; pick the `last_findings_path` of the most recently active shard. If multiple shards have a finding with this ID (rare - IDs are file-local, not global), ask the user which shard.
2. **Validate the charter sha.** If the findings JSON's `charter_sha` doesn't match the current charter sha, warn the user the findings are stale and ask whether to proceed.
3. **Locate the finding by `<finding-id>`.** If not found in the active JSON, list available IDs and stop. If the finding's existing `verifier_verdict` is `confirmed`, warn the user that re-fixing isn't normally needed and ask whether to proceed.
4. **Display the finding's current state** in the user's terminal (so they don't have to recall it):
   - The original `finding` and `suggestion` text (immutable from the reviewer)
   - The most recent `verifier_verdict` and `verifier_note` (if present)
   - The `fixer_commit` SHA (if present) so the user can `git show <sha>` to inspect the prior fix
   - The current `retry_count` (0 means this is the first retry)
5. **Prompt for revised guidance** via `AskUserQuestion`: free-text, one paragraph describing what the previous fix missed and what the new fix should address. Empty guidance means "try again with the same finding text"; usually you'll want concrete direction informed by the verifier's prior note.
6. **Spawn the fixer subagent** with: the finding's full payload, the verifier's prior verdict + note, and the user's revised guidance. The fixer follows its usual protocol: minimum-scope edit, gate on `make lint && make test-unit`, one commit. Commit message suffixed `[F-NNN, retry-N]` (where N is the new `retry_count`) so the original commit stays distinguishable in `git log`.
7. **Fixer writes back** the new `fixer_outcome`, `fixer_commit`, and incremented `retry_count` to the findings JSON for this finding.
8. **Spawn the verifier subagent** on the new diff range. The verifier overwrites the prior `verifier_verdict` and `verifier_note` for this finding with the new ones (this is the one author-may-overwrite-own-field exception to the append-only invariant).
9. **Report the new verdict** to the user. If still flagged, the user can `/review fix F-NNN` again with further-revised guidance, push the branch as-is and address the remainder manually, or demote the finding to `accepted.md`.

`/review fix` is **targeted** (single finding, no batch) and **context-discovering** (no path arg). It is NOT a redo of `/review act` - the original triage decisions stand; only the fixer phase re-runs for the one finding you named. To retry multiple findings, run `/review fix F-NNN` once per finding.

### `/review status` - show review cadence

1. Read `.wolf/reviews/state.json`. For each shard in `shards.json`, print a row:

   ```text
   <shard>  <last-run-date or "never">  <days-since>  <finding-count-last-run>
   ```

2. Sort by `days-since` descending - oldest first. Highlight shards that have never been reviewed.

## Findings JSON schema

The reviewer writes initial findings; subsequent agents and commands ADD fields as the cycle progresses. The original reviewer fields are never modified after initial write - this preserves the forensic record of what the reviewer originally said.

```json
{
  "shard": "<shard-name>",
  "charter_path": "design/reviews/charters/<shard>.md",
  "charter_sha": "<sha256-of-charter-at-review-time>",
  "reviewed_at": "<iso-8601-utc>",
  "git_sha": "<git-rev-parse-HEAD-at-review-time>",
  "findings": [
    {
      // Set by reviewer - IMMUTABLE after this point:
      "id": "F-001",
      "file": "<repo-relative-path>",
      "line": 87,
      "severity": "critical | high | medium | low",
      "category": "correctness | security | maintainability | testability | docs",
      "finding": "<1-3 sentence description of the issue>",
      "suggestion": "<concrete fix direction, NOT a patch>",

      // Added by /review act triage:
      "triage_decision": "apply | defer | dispute",
      "triage_rationale": "<one-line - present for defer/dispute>",

      // Added by fixer (initial run during /review act, or retries via /review fix):
      "fixer_outcome": "applied | failed | skipped",
      "fixer_commit": "<sha - present if outcome is applied>",
      "fixer_failure_reason": "<captured output - present if outcome is failed>",
      "retry_count": 0,

      // Added by verifier:
      "verifier_verdict": "confirmed | symptom-only | regression-risk | scope-creep | not-applied | over-corrected",
      "verifier_note": "<explanation - present for non-confirmed verdicts>"
    }
  ]
}
```

**Append-only invariant.** The original reviewer fields (`id`, `file`, `line`, `severity`, `category`, `finding`, `suggestion`) are never modified after the reviewer writes them. Cycle agents only ADD new fields, or update fields they themselves previously added (e.g., the verifier overwrites its own `verifier_verdict` on a `/review fix` re-verify; the fixer increments its own `retry_count`). If the reviewer's findings turn out to be wrong (wrong file path, wrong severity), run `/review <shard>` again to produce a fresh findings JSON - never edit the immutable fields in place.

Practical consequence: the findings JSON is a self-contained record of one cycle. A reader of one file can reconstruct what the reviewer found, what the human decided, what the fixer did, and what the verifier concluded - useful for cross-session continuity, post-mortems, and `/review fix` UX.

The `charter_sha` field is load-bearing: when `/review act` or `/review fix` runs against a findings JSON whose charter has since changed, it warns the user before proceeding rather than acting on outdated criteria.

## Triage state

`/review act` writes each finding's `triage_decision` (and `triage_rationale` for defer/dispute) to the findings JSON via `jq` per the schema above. The original reviewer fields stay immutable; only new fields accumulate. This means a partially-completed cycle can be picked up by a different session or even a different machine: anyone reading the findings JSON sees exactly which findings have been triaged and which haven't.

## Followups JSON schema

The fixer often notices things during a cycle that don't fit the current finding's minimum-scope rule but warrant consideration eventually. The framework persists these as **followups** so they aren't lost between cycles.

`.wolf/follow-ups/<home-shard>.json` (per-machine ephemeral, gitignored - same lifetime as findings JSON):

```json
{
  "shard": "<home-shard-name>",
  "entries": [
    {
      "id": "FU-001",
      "source_cycle": "<iso-date - when the fixer noticed it>",
      "source_shard": "<shard the fixer was working on when it noticed>",
      "source_findings_path": ".wolf/reviews/<date>-<source-shard>.json",
      "description": "<one sentence describing what to consider>",
      "source_finding_ids": ["F-002", "F-007"],
      "status": "open | closed",
      "considered_in_cycles": ["<iso-date>", ...],
      "closed_at": "<iso-date or null>",
      "closed_via": "triage-applied | triage-deferred | triage-disputed | verifier-auto-resolved | manual",
      "verifier_verdict": "auto-resolved-by-diff | partially-resolved-by-diff | null",
      "verifier_note": "<sentence with commit SHA, or null>"
    }
  ]
}
```

**Lifecycle.** A followup is created `open` by the fixer (via `/review act` step 4). It can transition to `closed` via four paths:

- **Triage closure** (most common): on the next `/review <home-shard>` cycle, the reviewer re-emits the FU as a finding (with `[FU-NNN]` prefix). When the human triages that finding (apply / defer / dispute), `/review act` closes the FU with `closed_via: triage-<decision>`.
- **Verifier auto-close**: on any `/review act` for this shard, the verifier checks open FUs against the fixer's diff. If a fix incidentally resolved a FU's concern, the verifier closes it with `closed_via: verifier-auto-resolved`. Independent bias control - the fixer focuses on its own finding and won't notice incidental followup resolution; the verifier reads the diff cold.
- **Reviewer skip** (no closure): if the reviewer chooses NOT to re-emit a FU (still applicable but not worth flagging right now), the FU stays open. Its `considered_in_cycles` array grows so the human can spot stale FUs that have been considered many times without action - candidates for manual pruning.
- **Manual closure**: human edits the JSON to set `status: closed`, `closed_via: manual`. Recovery path for verifier errors and stale FUs.

**Cross-shard followups.** The fixer may notice things outside its current shard (e.g., a WSL refactor noticed during a test-quality fix). The followup goes to the file named after the **suggested home shard**, so the next reviewer for that shard picks it up - not the source shard. Cross-shard observations would otherwise be orphaned.

**Persistence trade-off.** The followups file is gitignored (under `.wolf/`), so it lives only on the machine where reviews run. Load-bearing followups (those that absolutely must survive a machine wipe) should be promoted to durable artifacts at triage time: a PR, a GitHub issue, or a charter v2 entry. The followups file is the "remember next time" inbox, not the archive.

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
