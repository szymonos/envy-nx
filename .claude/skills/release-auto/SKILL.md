---
name: release-auto
description: Orchestrator-driven release prep. A stateful Python driver runs the deterministic release spine headless - lint, extract, version bump, upgrade, commit-plan recut, lint-diff, force-push, PR upsert, both review layers, and the final integration-test run - and stops at a few batched gates where the agent supplies judgment (CHANGELOG prose, cspell classification, commit topology, version verdict, review triage). Use when the user types `/release-auto` with a target version, asks to cut a release the automated way, or wants the orchestrator-driven release. Disabled for auto-invocation.
disable-model-invocation: true
---

# Release-auto

Orchestrator-driven release prep for a feature/release branch. The driver,
`.claude/skills/release-auto/scripts/release.py`, owns every mechanical step;
the agent is a **decision oracle** called only at batched gates. Tagging is
**out of scope** - `make release` handles it post-merge.

## When to use

- `/release-auto 1.16.0` - cut 1.16.0 from the current branch
- `/release-auto 1.16.0 --skip-review` - skip *both* review layers (urgent hotfix, Copilot offline, already reviewed)
- `/release-auto 1.16.0 --reopen` - re-cut an already-pushed release with no new changes (fold coda follow-ups into clean per-group commits); see `references/recovery.md`
- "minor ver" / "patch" - compute the version from `git describe --tags --abbrev=0`

## Prerequisites

- A feature or `release/*` branch - never `main`/`master`/`develop` (the driver refuses). On `main`, create a branch first.
- `gh` authenticated; a git tag to scope against.

## Mental model

```text
start        ──► lint, bump, upgrade             ──► GATE phase1   (exit 10)
resume       ──► cspell/changelog checks, recut  ──► GATE push     (exit 10)
resume       ──► force-push, PR upsert           ──► SPINE_COMPLETE (exit 0)
second-opinion / copilot-review ──► fixes ──► recut + push ──► (repeat review)
push --done  ──► thread check, wipe, label PR    ──► integration --since <ts>
```

**Exit codes:** `0` done, `1` error (surface it, don't paper over), `2` usage,
`4` still waiting (re-run the same command), `10` `DECISION_NEEDED` gate.

**Invoke the driver bare - never pipe it.** A pipe reports the tail's status,
not the driver's 10 or 4. Run each verb on its own.

Every gate payload carries an `instructions` string - follow it; this file
covers only the judgment behind it.

## Workflow

### Step 1 - start

```bash
.claude/skills/release-auto/scripts/release.py start --version <X.Y.Z> [--skip-review]
```

Exit 1 means stop: a failed `make lint`/`make upgrade` must be fixed first.
Leftover state from an earlier run is reported with the command that clears it.

### Step 2 - the phase-1 gate

1. **Compose the CHANGELOG entry.** Splice `## [<X.Y.Z>] - <today>` into
   `CHANGELOG.md` from the payload's `extract` chunks - never Read the whole
   file. Follow **Bullet style** and **Section reclassification**. On a re-run
   (`is_rerun: true`) combine the existing block with `[Unreleased]` and
   **reclassify, don't just merge**.
2. **Classify cspell findings.** Code identifier or proper noun → `cspell_add`;
   prose misspelling → fix the source; genuinely ambiguous → one batched
   `AskUserQuestion`.
3. **Author `.release/commit-plan.json`** (shape: `schemas/commit-plan.example.json`):
   ordered `groups` of `{globs, prefix, message, trailers}`, file-granularity,
   first match wins. A seeded plan (`plan_seed.seeded`) is last release's -
   edit its messages and the `docs(changelog)` version, not just the globs.
   The CHANGELOG riders (`CHANGELOG.md`, `project-words.txt`, `pyproject.toml`,
   `uv.lock`) go in the final `docs(changelog)` group. Keep `Co-Authored-By:` /
   `Codified-Learning:` lines in `trailers`.

```bash
echo '{"cspell_add": [], "version_final": "<X.Y.Z>", "plan_written": true}' | .claude/skills/release-auto/scripts/release.py resume --decision -
```

The driver may gate again before touching git: `cspell` (words the new prose
introduced) or `changelog` (a bullet over 40 words, or sections that do not
match the bump - e.g. `Added` in a patch). For a version suggestion, ask the
user; never switch silently. Then it recuts headless and runs `make lint-diff`
inside the same atomic block. An orphan path or empty group fails before any
git mutation: fix the plan's globs and resume again.

### Step 3 - the push gate

Eyeball `commits` and `pr_body_preview`, then:

```bash
echo '{"approve": true}' | .claude/skills/release-auto/scripts/release.py resume --decision -
```

`review_coda: false` means this push finishes the run (and triggers the
integration tests). If the user wants the review after all, add
`"review": true` - this gate is the last point it can be turned on.

### Step 4 - review coda (skipped with --skip-review)

Two layers, in order; `--skip-review` is the only way to skip either. New
features are the *most* important case to review.

**4a - heterogeneous model.** A different model family reviews
`<last-tag>..HEAD` against the CHANGELOG section as stated intent:

```bash
.claude/skills/release-auto/scripts/release.py second-opinion   # Bash timeout 600000
```

It picks the model itself (and says why), and skips the layer when the
Copilot CLI is absent. **Challenge every finding** - the reviewer has no
context beyond the brief. Read the flagged code; dismiss with a reason, fix
when clearly right, `AskUserQuestion` when uncertain - never auto-fix on doubt.
Report a verdict per finding (`fixed` / `dismissed (reason)` /
`needs-user-judgment`). After fixes: `recut` + `push`, optionally one scoped
rerun with `--files <fixed files>`; the driver refuses a third run.

**4b - Copilot PR review:**

```bash
.claude/skills/release-auto/scripts/release.py copilot-review   # Bash timeout 540000
```

It requests the review only when needed (a force-push usually does not
re-request it) and waits. Exit 4: re-run it. Exit 10 (`review_triage`): every
thread carries a `proposal` from `review-policy.json` (`null` = no rule
matched). Present the whole bundle in one `AskUserQuestion` - nothing is
dismissed without being shown. Write fixes yourself, never copying a
suggestion verbatim; fold fixes to unshipped code into the existing `Added`
bullet. **Resolve every `fix`/`resolve-only` thread before re-cutting** -
the force-push makes them outdated, and an outdated thread still blocks merge:

```bash
python3 .claude/skills/address-pr-review/scripts/pr_review.py resolve <thread-id>
.claude/skills/release-auto/scripts/release.py recut
.claude/skills/release-auto/scripts/release.py push
```

Then run `copilot-review` again. Past two fix cycles the payload sets
`fix_cycle_cap_reached`: hand what remains to the user.

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
`--force` finishes regardless (e.g. GitHub unreachable), with a warning to
relay. It applies the `test:integration` label, then wipes `.release/` and
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

- **Editing `.release/` by hand** (except `commit-plan.json`). Use `abort` to restart.
- **Reasoning about whether to recut.** Just call `recut` after any fix, including a revert (drop the now-empty group).
- **Pushing past a review thread instead of resolving it.** The force-push hides it; it stays open and blocks merge.
- **Copying a reviewer's fix verbatim** or applying findings unchallenged.
- **A `Fixed`/`Changed` bullet for something that never shipped.** Fold into `Added`.
- **Tagging the release** - `make release` does that after merge.
- **Skipping a review layer by your own judgment.** Only `--skip-review` skips, and it skips both.

## Recovery

`status`, `abort`, `--reopen`, orphaned state from a shipped cycle, and the
safety backup ref: read `references/recovery.md` when a driver command fails
or the user asks to undo or re-cut a release.
