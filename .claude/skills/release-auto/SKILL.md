---
name: release-auto
argument-hint: "VERSION [skip-review|claude-review|reopen]"
description: Orchestrator-driven release prep. A stateful Python driver runs the deterministic release spine headless - lint, extract, version bump, upgrade, commit-plan recut, lint-diff, force-push, PR upsert, both review layers, and the final integration-test run - and stops at a few batched gates where the agent supplies judgment (CHANGELOG prose, cspell classification, commit topology, version verdict, review triage). The agent triages review findings itself and asks the user only about intent, once, at the end. Use when the user types `/release-auto` with a target version, asks to cut a release the automated way, or wants the orchestrator-driven release. Disabled for auto-invocation.
disable-model-invocation: true
---

# Release-auto

Orchestrator-driven release prep for a feature/release branch. The driver,
`.claude/skills/release-auto/scripts/release.py`, owns every mechanical step;
the agent is a **decision oracle** called only at batched gates. Tagging is
**out of scope** - `make release` handles it post-merge.

## When to use

- `/release-auto 1.16.0` - cut 1.16.0 from the current branch
- `/release-auto 1.16.0 skip-review` - skip *both* review layers (urgent hotfix, Copilot offline, already reviewed)
- `/release-auto 1.16.0 claude-review` - add Claude's `/code-review` after second-opinion at the first gate (Claude Code only; elsewhere it is ignored with one stderr line)
- `/release-auto 1.16.0 reopen` - re-cut an already-pushed release with no new changes (fold committed coda follow-ups into clean per-group commits; commit them first); see `references/recovery.md`
- "minor ver" / "patch" - compute the version from `git describe --tags --abbrev=0`

**No version given: choose the bump by what a user of envy-nx gains, not by
CHANGELOG section names.** Minor means a new capability on their machine: a
scope, an `nx` verb or flag, a platform, a tool installed. Everything else is a
patch: fixes, refinements, and anything confined to contributor tooling (agent
skills, tests, CI, design docs), even when it is filed under `Added`. State the
bump and why before running `start`.

A word after the version is the `start` flag of the same name with `--` in
front: `skip-review` is `--skip-review`. Anything else is an ordinary request.

## Prerequisites

- A feature or `release/*` branch - never `main`/`master`/`develop` (the driver refuses). On `main`, create a branch first.
- `gh` authenticated; a git tag to scope against.

## Mental model

```text
start        ──► rebase, lint, bump, upgrade     ──► GATE phase1   (exit 10)
               (CHANGELOG, then second-opinion [+ /code-review]; fixes stay uncommitted)
resume       ──► cspell/changelog checks, recut  ──► GATE push     (exit 10)
resume       ──► force-push, PR upsert           ──► SPINE_COMPLETE (exit 0)
copilot-review ──► triage ──► only if it fixed something:
               second-opinion --fixes ──► recut + push   (the one round)
escalations  ──► one AskUserQuestion, at the end
push --done  ──► thread check, post decision log, wipe, label PR ──► integration
```

**Exit codes:** `0` done, `1` error (surface it, don't paper over), `2` usage,
`4` still waiting (re-run the same command), `10` `DECISION_NEEDED` gate.

**Invoke the driver bare - never pipe it.** A pipe reports the tail's status,
not the driver's 10 or 4. Run each verb on its own. If a printed gate payload
looks truncated, read the file its `full_context` names.

**Answer a gate with the `echo '{...}' |` form, never a heredoc** - a
worktree-isolated session refuses every heredoc command. A decision whose
values contain an apostrophe goes in a file: `--decision <path>`.

Every gate payload carries an `instructions` string - follow it; this file
covers only the judgment behind it.

## Workflow

### Step 1 - start

```bash
.claude/skills/release-auto/scripts/release.py start --version <X.Y.Z> [--skip-review] [--claude-review]
```

Exit 1 means stop: a failed `make lint`/`make upgrade` must be fixed first.
Leftover state from an earlier run is reported with the command that clears it.

`start` first rebases the branch onto the latest `origin/main`. When it cannot
(a merge commit on the branch, a conflict, uncommitted edits to files main also
changed, or a failed fetch), the branch stays put and the gate's `trunk` says
why; tell the user. `abort` does not undo the rebase: `trunk.from` is the
pre-rebase HEAD.

### Step 2 - the phase-1 gate

1. **Compose the CHANGELOG entry.** Splice `## [<X.Y.Z>] - <today>` into
   `CHANGELOG.md` from the payload's `extract` chunks - never Read the whole
   file. Follow **Bullet style** and **Section reclassification**. On a re-run
   (`is_rerun: true`) combine the existing block with `[Unreleased]` and
   **reclassify, don't just merge**.
2. **With `review` true in the payload, run second-opinion** once the CHANGELOG
   section is written - it is the stated intent, and the run reviews
   `<last-tag>` against the working tree, so the bump is in it:

   ```bash
   .claude/skills/release-auto/scripts/release.py second-opinion   # Bash timeout 600000
   ```

   Triage its findings by **Review triage** below. Fixes stay uncommitted
   edits for the plan to fold in. It runs once per release (`model_reasons`
   says which model and why); exit 3/4 output says it skipped. Each finding
   carries its `lens`, and lenses are not deduplicated, so merge findings that
   name the same defect. `failed` lists lenses that did not finish - their
   findings are missing.

   **With `audit_rules` true in the payload, keep the review rules current**,
   independent of `review`. The driver sets it only when `REVIEW.md` exists and
   `/bootstrap-review` is installed. Make every edit below in
   `.github/copilot-instructions.md`, the file `REVIEW.md` links to: write
   tools refuse to write through the link. Run the `review_md.py audit` command
   the payload gives before the commit plan and fix every finding as an uncommitted
   edit: update a rule whose file or function moved, delete one whose target is
   gone. Rerun until no `stale-path` or `stale-symbol` finding remains. Any
   other kind (`section`, `link`, `legacy`) means onboarding is unfinished: name
   it in one line, suggest `/bootstrap-review`, and carry on. Also replace a
   rule's `(<branch> branch)` citation with `(#<PR>)` once that branch's PR
   exists. The rules file only grows unless a run prunes it,
   and a stale rule teaches the reviewer a deleted file matters.

   **Pass the requirements ledger when the work has one.** A ledger is numbered
   rows each ending `-> Approach N`, `Out: <why>` or `Unsure: <question>`.
   Fetch it from wherever this environment keeps one, save it to a file and add
   `--requirements <file>`. Each pass then reports an `-> Approach` row the code
   leaves unimplemented, and stays quiet about work an `Out:` row excludes. The
   driver keeps the file, so the `--fixes` review gets the same ledger. Without
   one, the CHANGELOG section is the whole intent.

   **With `claude_review` true, run `/code-review` next**, at `medium`, on
   `<last-tag>` plus the uncommitted fixes. Give it the CHANGELOG section and
   every finding second-opinion declined, with its reason, so it raises none
   of them again, and triage it the same way. It runs second so a finding the
   cheaper reviewer already fixed costs Claude nothing. Log both reviews'
   findings under round `pre-push`.
3. **Classify cspell findings.** Code identifier or proper noun → `cspell_add`;
   prose misspelling → fix the source; genuinely ambiguous → one batched
   `AskUserQuestion`.
4. **Author `.release/commit-plan.json`** (shape: `schemas/commit-plan.example.json`):
   ordered `groups` of `{globs, prefix, message, trailers}`, file-granularity,
   first match wins. A seeded plan (`plan_seed.seeded`) is last release's -
   edit its messages and the `docs(changelog)` version, not just the globs.
   The CHANGELOG riders (`CHANGELOG.md`, `project-words.txt`, `pyproject.toml`,
   `uv.lock`, `.github/copilot-instructions.md`) go in the final
   `docs(changelog)` group; the last one is there for a review rule added
   mid-coda, which `recut` would otherwise refuse as an orphan. Keep `Co-Authored-By:` /
   `Codified-Learning:` lines in `trailers`.

```bash
echo '{"cspell_add": [], "version_final": "<X.Y.Z>", "plan_written": true}' | .claude/skills/release-auto/scripts/release.py resume --decision -
```

The driver may gate again before touching git: `cspell` (words the new prose
introduced) or `changelog` (a bullet over 40 words, or a bump the release does
not earn - `Added` in a patch that touches `PRODUCT_GLOBS`, or a minor that
touches none of them). For a version suggestion, ask the
user; never switch silently. Then it recuts headless and runs `make lint-diff`
inside the same atomic block. An orphan path or empty group fails before any
git mutation: fix the plan's globs and resume again.

### Step 3 - the push gate

Eyeball `commits` and `pr_body_preview`, then:

```bash
echo '{"approve": true}' | .claude/skills/release-auto/scripts/release.py resume --decision -
```

`review_coda: []` means this push finishes the run (and triggers the
integration tests), so ask any escalations held from second-opinion before
approving; after an answered fix, run `recut` first - the driver refuses to push
an uncommitted edit. If the user wants the Copilot review after all, add
`"review": true` - this gate is the last point it can be turned on.

### Step 4 - Copilot review coda (skipped with --skip-review)

Runs when `address-pr-review` is installed in `~/.claude/skills/`; without it
the push gate's `review_coda` is empty and the push finishes the run.

```bash
.claude/skills/release-auto/scripts/release.py copilot-review   # Bash timeout 540000
```

**A reported issue outranks the running review.** When the user or another
session reports a defect in this release mid-coda, stop and fix every open
report, leaving the fixes uncommitted. Before `copilot-review` has requested
Copilot: run `second-opinion --fixes` on them as below, `recut`, `push` - a push
Copilot never reviewed or was asked to does not spend the round - then run
`copilot-review`. After: the fixes join the round's own and go through its fix
review and its one push.

It requests the review only when needed (a force-push usually does not
re-request it) and waits. Exit 4: re-run it. Exit 10 `review_unavailable`: the
trigger failed - read its message; if Copilot code review is not available for
the repo, say so in one line and go to the finish, otherwise stop and surface
the error. Exit 10 `review_triage`: triage every thread yourself by **Review
triage** below, using `pr_review.py` from `~/.claude/skills/address-pr-review/scripts/`:

- `fix` - edit, then `resolve <id>` **before re-cutting**: the force-push
  makes the thread outdated, and an outdated thread still blocks merge.
- `decline` - `reply <id> --body -` with the one-sentence reason, then
  `resolve <id>` once the reply exits 0. Write the reason to a file with the
  file-writing tool, never a heredoc, and pipe it: `--body - < <file>`.
- `resolve-only` - `resolve <id>`.
- `escalate` - leave the thread open and hold it for the end.

Fold fixes to unshipped code into the existing `Added` bullet.

**There is one Copilot round.** A round with no fix ends the review; when a
decline added a REVIEW.md rule, `recut` + `push` it first. A round
that fixed something gets second-opinion on those fixes instead of a second
Copilot round, which mostly finds defects in the first round's own fixes and
costs far more. Write a notes file - each finding the round fixed, as what that
fix is for, then every finding declined so far with its reason under an
`Already decided` heading - and run:

```bash
.claude/skills/release-auto/scripts/release.py second-opinion --fixes <notes>   # Bash timeout 600000
```

It reviews from the head Copilot reviewed, so only the uncommitted fixes, with
the CHANGELOG section and your notes as intent. It runs once per published head,
so fixes pushed ahead of the round leave the round's own fixes a review. Exit 3/4 is one line in the
report. Triage it, log its rows under round `fixes`, then `recut` + `push`. The
push reports `fix_cycles_left: 0`: do not run `copilot-review` again. If you do,
its payload sets `fix_cycle_cap_reached` and a thread you would fix becomes an
escalation.

**The end of the review.** The held escalations are the rows whose call is
`escalate` in `.release/decision-log.md` - second-opinion's and Copilot's - that
no `end` row answers yet; the log holds them, not your memory. Ask them in one `AskUserQuestion` and append
each answer as its own row: `| end | <finding> | asked: fix / left open /
declined | <author's reason> |`. A "yes" is an edit and a `resolve` of its
thread: `recut`, `push`, then `push --done`, with no further round. The other
way is a `reply` giving the author's reason, then `resolve`. "Leave open" leaves the thread for a
human reviewer; finish with `push --done --force`.

### Review triage

The four calls - `fix`, `decline`, `resolve-only`, `escalate` - the
decline-becomes-a-rule step, and the escalation question format are the
triage-rules block in `~/.claude/skills/address-pr-review/SKILL.md` (identical
in `second-opinion`). Read it before the first triage. A decline that becomes a
rule goes in `.github/copilot-instructions.md` (`REVIEW.md` links to it).

A release adds escalation triggers of its own:

- **A fix that would change the earned bump** - a user-visible capability added
  inside a patch release, say. The release would grow scope from a review.
- **A finding on `.assets/config/bin/wslview`** - a repo-owned shim whose
  overwrite-on-change is deliberate; a human judges any change to it.

CHANGELOG wording counts as stated intent: a bullet that contradicts the code is
`fix`, style is `decline`. "A bug the change did not introduce" means one that
predates `<last-tag>`.

Append one row per finding to `.release/decision-log.md` in the form the gate
payload gives; `push --done` posts it to the PR as one comment.

**`recut` is the lint gate - never validate a coda fix with bare `make lint`.**
During a release `[Unreleased]` is empty, so bare `make lint` false-positives
on `check-changelog`; `recut` commits with `--no-verify` and runs
`make lint-diff` atomically. `push` refuses while a plan-covered fix is
uncommitted. `recut` gates only when the plan cannot execute (an orphan path
or an empty group): fix the globs and re-run it.

### Step 5 - finish and integration tests

```bash
.claude/skills/release-auto/scripts/release.py push --done
```

It refuses while HEAD is not pushed, and gates (`unresolved_threads`) on any
open thread, outdated ones included - triage and resolve them, then re-run.
`--force` finishes regardless (an escalation left open, GitHub unreachable),
with a warning to relay. It posts the decision log (printing it instead if the
post fails), applies the `test:integration` label, then wipes `.release/` and
prints `integration.since`; a failed label leaves the run intact for a retry. The label re-runs the suite on every push,
which is why it is applied only now.

```bash
.claude/skills/release-auto/scripts/release.py integration --since <since>   # Bash timeout 600000
```

Exit 4: still running - re-run the same command. Exit 0: report the release as
merge-ready. Exit 1: report each failed workflow's `failed_jobs` and `url` to
the user and investigate the logs (`gh run view <id> --log-failed`). A fix goes
through `/release-auto <X.Y.Z> --reopen`; never push past a red run.

## Bullet style guidelines

- **One sentence; two if the why is non-obvious.** Split into separate bullets rather than write three.
- **Pattern**: "X now does Y" or "Fixed Z that caused W". Lead with the change.
- **Backticks for code identifiers**: `function_name`, `file.sh`, `--flag`.
- **No prose paragraphs, no quoted CI logs, no commit SHAs / PR numbers** - all searchable via git/GitHub.
- **10-40 words per bullet** (the driver gates on more than 40).
- **No "we"** - imperative or third-person.
- **Section order**: `Added` → `Changed` → `Fixed` → `Removed` → `Security` → `Deprecated`; skip empty ones.
- **Intro paragraph** only for major / minor releases; patch releases go straight to sections.
- **Date**: `YYYY-MM-DD`, today.

## Section reclassification (shipped-version timeline)

The CHANGELOG's audience is a user upgrading from `<last-tag>`, not a
contributor reading commit history. Classify by *"from the perspective of a
user on `<last-tag>`, what kind of change is this?"* Applies to the re-run
merge and to folding review fixes.

| Feature/fix exists in `<last-tag>`? | Bullet describes               | Action                                    |
| ----------------------------------- | ------------------------------ | ----------------------------------------- |
| No (introduced this version)        | iteration/refinement/fix on it | **Fold** into the existing `Added` bullet |
| No (introduced this version)        | a new, additional feature      | new `Added` bullet                        |
| Yes (already in `<last-tag>`)       | behavior change                | new `Changed` bullet                      |
| Yes (already in `<last-tag>`)       | bug fix to existing behavior   | new `Fixed` bullet                        |

A bug introduced *and* fixed within this release cycle never reached users - it
is **not** "Fixed". This is the most common merge-case error.

## Anti-patterns

- **Editing `.release/` by hand** (except `commit-plan.json` and appending to `decision-log.md`). Use `abort` to restart.
- **Asking the user mid-loop.** Escalations wait for the one question at the end.
- **Reasoning about whether to recut.** Just call `recut` after any fix, including a revert (drop the now-empty group).
- **Pushing past a review thread instead of resolving it.** The force-push hides it; it stays open and blocks merge.
- **Copying a reviewer's fix verbatim** or applying findings unchallenged.
- **Running a second Copilot round.** It finds something, mostly in the first round's own fixes, and that something is the over-engineering. The fixes get `second-opinion --fixes` instead.
- **A `Fixed`/`Changed` bullet for something that never shipped.** Fold into `Added`.
- **Tagging the release** - `make release` does that after merge.
- **Skipping a review layer by your own judgment.** Only `--skip-review` (both layers), `reopen` (second-opinion) or an uninstalled review skill (its layer) skips one.

## Recovery

`status`, `abort`, `--reopen`, orphaned state from a shipped cycle, and the
safety backup ref: read `references/recovery.md` when a driver command fails
or the user asks to undo or re-cut a release.
