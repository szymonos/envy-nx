---
name: address-pr-review
description: State-aware GitHub Copilot PR review handler. Detects review state (not triggered / in progress / has unresolved threads / clean), triggers Copilot via `gh pr edit --add-reviewer` when needed, polls until completion, classifies fresh unresolved comments as fix/resolve-only/skip, applies fixes, resolves threads via GraphQL, and pushes. Only exits when no thread is left unresolved at all, outdated ones included - triage works off the fresh review (matching HEAD SHA), but finishing runs a separate completeness check. Use when the user types `/address-pr-review`, asks to address PR comments, wants to clear review findings, or says "check the PR review." Disabled for auto-invocation.
disable-model-invocation: true
---

# Address PR review

State-aware Copilot PR review handler. Detects the current review state, drives toward "fresh review clean," and processes only fresh unresolved threads. Works with any reviewer that posts inline PR comments; Copilot is the default trigger target.

## When to use

- `/address-pr-review` - drive current branch's PR review to a clean state
- `/address-pr-review 37` - same, for a specific PR number
- "address the PR review comments" / "check the PR review" / "clear the review" - same as `/address-pr-review`

## Prerequisites

- `gh` CLI installed and authenticated.
- Copilot enabled on the repository.

**Important:** always trigger Copilot via `pr_review.py trigger`, never via ad-hoc `gh pr edit --add-reviewer` invocations or raw GraphQL mutations from the agent. `pr_review.py trigger` wraps `gh pr edit --add-reviewer copilot-pull-request-reviewer` with the right reviewer login, idempotency handling, and uniform error reporting; one-off calls drift in subtle ways (wrong login alias, no idempotency, no JSON output for the skill's state machine to consume). If `trigger` fails, surface the error to the user - Copilot may need to be enabled in repo settings.

## Review states

The skill operates as a state machine. Four states are possible:

| State | Fresh review exists? | Copilot requested? | Unresolved fresh threads? | Action                          |
| ----- | -------------------- | ------------------ | ------------------------- | ------------------------------- |
| **A** | No                   | No                 | N/A                       | Trigger + wait                  |
| **B** | No                   | Yes (in progress)  | N/A                       | Wait                            |
| **C** | Yes                  | No                 | Yes                       | **Process**                     |
| **D** | Yes                  | No                 | No                        | **Run `unresolved`**, then exit |

"Fresh review" = a Copilot review whose `commit.oid` matches the PR's current `headRefOid`. A review from a prior push is **stale** and ignored - the skill triggers a new one.

"Fresh threads" = threads with `isResolved: false` AND `isOutdated: false`. The four states are about **triage** - which comments still describe the current code - so they deliberately exclude outdated ones.

**State D means "nothing left to triage", not "nothing left open".** A force-push moves the head SHA and flips every thread anchored to the old diff to `isOutdated`, which drops it out of `state` entirely. Before calling a PR done, run the separate completeness check in Phase 2.

## Workflow

### Phase 1 - detect state

```bash
.claude/skills/address-pr-review/scripts/pr_review.py state --pr <N>
```

Returns JSON with `state`, `headSha`, `freshReviewSha`, `copilotRequested`, and `unresolvedFreshThreads` (fresh only - the finish-time check is `unresolved`, in Phase 2). Exit code: `0`=D, `1`=C, `2`=B, `3`=A.

If no PR is found on the current branch (or `--pr` is invalid), the script exits with a clear error. Surface it to the user and stop.

### Phase 2 - drive to State D

Branch on the state from Phase 1:

- **State A** (not triggered): run `pr_review.py trigger --pr <N>` to request Copilot. Then `pr_review.py wait --pr <N>` to poll until the review completes. The `wait` subcommand returns when the state resolves to C or D. Continue from that state.
- **State B** (in progress): skip trigger, go straight to `pr_review.py wait --pr <N>`. Same continuation.
- **State C** (unresolved fresh threads): proceed to Phase 3.
- **State D**: no unresolved *fresh* threads. Do not announce the PR clean yet - run the completeness check below first.

#### The completeness check

```bash
.claude/skills/address-pr-review/scripts/pr_review.py unresolved --pr <N>
```

Lists **every** unresolved thread, outdated or not, and exits 1 while any remain. `state` cannot see the outdated ones, so a comment nobody actioned goes invisible exactly when you are deciding you are done - and it stays open on the PR, where it still counts against "Require conversation resolution before merging".

Outdated means the diff moved under the comment, not that the point is moot. Triage each one the same way as Phase 3, then `resolve` it. Only announce the review clean once this exits 0.

`wait` polls every 30 seconds, up to 8 min total. On timeout (exit 4), surface to the user - Copilot may be queued or the service may be slow. Don't loop the wait; let the user decide whether to retry.

### Phase 3 - process unresolved fresh threads (State C only)

The `state` JSON already contains `unresolvedFreshThreads` with `{id, path, line, author, body}` for each. Present them as a summary table:

```text
## PR #37 - N unresolved fresh threads

| # | File:Line | Author | Summary |
|---|-----------|--------|---------|
| 1 | src/main.py:9 | copilot | Missing error handling on API call |
| 2 | docs/index.md:109 | copilot | Stale reference count |
```

**Known false positives** - auto-resolve without reading the file:

- Comments flagging `ubuntu-slim` as an invalid or non-standard GitHub runner (e.g., "runs-on: ubuntu-slim is likely to fail"). `ubuntu-slim` is a valid GitHub-hosted runner that this repo uses intentionally.

For each remaining thread, read the comment body + the referenced file at the specified line. Classify:

- **`fix`** - the comment identifies a real issue (bug, missing code, inconsistency, stale reference). Read the referenced file, formulate a fix using Claude's knowledge of the codebase (not a copy-paste of the suggestion), apply via Edit.
- **`resolve-only`** - the comment is already addressed by a prior fix in this session, or the issue genuinely doesn't apply (e.g., stale on a specific line but the file changed elsewhere). Resolve silently.
- **`skip`** - the comment is a suggestion, design question, or judgment call that needs human input.

Resolve `fix` and `resolve-only` threads via:

```bash
.claude/skills/address-pr-review/scripts/pr_review.py resolve <thread-id>
```

After processing all `fix` and `resolve-only` items:

- If any `skip` items remain: present them to the user via `AskUserQuestion`. For each, offer three options: "Fix it" (Claude fixes now), "Resolve without fix" (intentional choice), "Leave open" (for later / human reviewer to decide). Act on user's choices.
- Report: "N fixed, M resolved (stale/intentional), K surfaced to user."

### Phase 4 - commit and push

**Only runs in standalone mode** - when the skill is invoked directly, not as part of a larger workflow. The caller decides commit topology; the skill's job is to surface fixes and resolve threads.

When invoked by a caller that manages its own commit flow (e.g., a consolidation skill that re-cuts commits), the caller should pass context indicating Phase 4 should be skipped. Without that context, Phase 4 runs by default.

If any files were edited in Phase 3:

1. Run `make lint` to validate.
2. Stage the changed files explicitly (never `git add -A`).
3. Commit: `git commit -m "fix: address PR review comments"`
4. Push: `git push`

The push will trigger a new Copilot review automatically. The skill is **one-shot** - it does not re-invoke itself after pushing. The user decides whether to re-run.

If no files were edited (all threads were `resolve-only` or `skip` → leave-open), skip the commit - just report the resolution results.

## Anti-patterns

- **Finishing on `state` alone.** `state` filters to threads that describe the current code, which is right for triage and wrong for deciding you are done. A check that filters by freshness cannot also serve as the completeness check - run `unresolved` before you call a PR clean.
- **Treating "outdated" as "handled".** `isOutdated: true` means the diff moved under the comment, not that anyone read it. Don't assume the fresh review re-raises it: Copilot is not obliged to repeat a finding, and an unresolved outdated thread still blocks merge under conversation-resolution rules.
- **Skipping a thread because its review is stale.** Thread selection is not SHA-scoped - `state` and `unresolved` both return threads from *any* prior review. A finding does not stop being true because a newer commit landed; triage it on its merits.
- **Resolving `skip` items silently.** The human might want to act on them - a "consider X" suggestion might actually be a good idea. Surface, don't suppress.
- **Posting reply comments before resolving.** Silent resolve is the design choice - keeps the PR history clean. The fix is visible in the diff; the resolution is visible in the thread state.
- **Looping `wait` on timeout.** If `wait` exits 4 (timeout), don't immediately re-call it. Surface to the user; Copilot may be queued or rate-limited.
- **Copying the reviewer's suggested fix verbatim.** The reviewer (Copilot or human) suggests direction; Claude writes the actual fix using its knowledge of the codebase's patterns and accepted decisions.
- **Resolving threads for human reviewers' comments without checking.** The skill processes ALL unresolved fresh threads regardless of author. If a human reviewer left a comment expecting a human reply, resolving silently would be rude. Classify these as `skip` unless the fix is unambiguous.

## Example invocations

- `/address-pr-review` - address comments on current branch's PR
- `/address-pr-review 37` - address comments on PR #37
- "Check the PR review and fix what you can" - same as `/address-pr-review`
