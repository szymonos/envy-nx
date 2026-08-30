---
name: release-auto
description: Orchestrator-driven release prep. A stateful Python driver (release.py) runs the deterministic release spine headless - make lint, extract, make upgrade, pyproject bump, commit-plan recut, lint-diff, force-push, PR upsert - and stops at ~3 batched gates where the agent supplies judgment (CHANGELOG prose, cspell classification, commit topology, version verdict, review triage). Re-cutting after a fix is a scripted verb (zero agent turns). Inverts /prepare-release's turn-by-turn runbook to cut token cost. Use when the user types `/release-auto` with a target version, asks to cut a release the automated way, or wants the orchestrator-driven release. Disabled for auto-invocation.
disable-model-invocation: true
---

# Release-auto

Orchestrator-driven release prep for a feature/release branch. A central Python
driver, `scripts/release.py`, owns the **deterministic spine**; the agent is a
**decision oracle** called only at batched gates. Tagging is **out of scope** -
`make release` handles it post-merge.

This skill uses inverted control: instead of the agent interpreting a turn-by-turn
runbook, it runs `release.py`, reads a `DECISION_NEEDED` payload, decides, and
re-invokes. Mechanical steps never reach the agent's context. It replaced - and
absorbed the shared leaf scripts of - the now-retired `/prepare-release` skill
(see **History**).

## When to use

- `/release-auto 1.16.0` - cut 1.16.0 from the current branch, orchestrator-driven
- `/release-auto 1.16.0 --skip-review` - skip *both* coda review layers, second-opinion (4a) and Copilot PR review (4b) (urgent hotfix, Copilot offline, already reviewed)
- `/release-auto 1.16.0 --reopen` - re-cut/consolidate an already-cut+pushed release with no new changes (e.g. fold coda follow-up commits back into clean per-group commits). Freezes content: skips the version bump + `make upgrade`. See **Recovery & inspection**.
- "cut the release the automated way" / "run the orchestrated release" - same

## Prerequisites

- On a feature or `release/*` branch - **never** `main`/`master`/`develop` (the driver refuses).
- `gh` CLI authenticated; `make lint`, `make upgrade`, `make lint-diff` available.
- A git tag exists to scope the release against (`git describe --tags` resolves).

## Mental model

```text
release.py start   ──► [headless: lint, upgrade, bump] ──► GATE phase1  (exit 10)
   agent: compose CHANGELOG, classify cspell, author commit-plan.json
release.py resume  ──► [headless: recut, lint-diff]     ──► GATE push   (exit 10)
   agent: eyeball commits + PR body
release.py resume  ──► [headless: force-push, PR upsert] ──► SPINE_COMPLETE (exit 0)
   ── review coda (unless --skip-review) ──
   4a agent: /second-opinion (gpt-5.3-codex) → fold fixes → recut + push
   4b agent: trigger Copilot PR review, triage vs review-policy.json, apply fixes
release.py recut   ──► [reconcile + recut + lint-diff]   (silent unless the plan can't execute)
release.py push --done ──► wipes .release/, release ready to merge
```

**Exit codes:** `0` = done / step complete, `10` = `DECISION_NEEDED` gate, `1` =
error (surface it, don't paper over), `2` = usage.

**Invoke the driver bare - never pipe its output.** The `DECISION_NEEDED` payload
is already compact by design; there is nothing to `| tail` or `| head`, and doing
so *masks the sentinel exit code* (`$?` becomes the pipe tail's status, not
`release.py`'s 10). If a step is genuinely verbose and you must pipe, read
`${PIPESTATUS[0]}`, not `$?`. Run each verb on its own so exit 10 vs 0 vs 1 is
unambiguous.

**The core primitive at every gate:** the script *proposes as a bundle*, the agent
*confirms or overrides inline* in one turn. Deterministic work runs silently
between gates.

## Workflow

### Step 1 - start the spine

```bash
.claude/skills/release-auto/scripts/release.py start --version <X.Y.Z> [--skip-review]
```

This runs headless to the first gate: refuses shared branches, `make lint`,
bumps `pyproject.toml`, `make upgrade`, then writes `.release/state.json` and
prints `DECISION_NEEDED` with a `phase1` payload (extract chunks, cspell findings,
`git diff --name-status`). Exit 10.

If it exits 1, read the error and stop - a failed `make lint`/`make upgrade` must
be fixed before the release proceeds. If a release is already in progress it tells
you to `status`/`resume`/`abort` first; if the leftover state is from an
already-shipped (tagged) version it says so explicitly and points at `abort` (see
**Recovery & inspection**) - just run `release.py abort` and re-`start`.

### Step 2 - the phase-1 gate (agent judgment)

From the `phase1` payload, do three things, then resume:

1. **Compose the CHANGELOG entry.** `Edit CHANGELOG.md` to splice in the new
   `## [<X.Y.Z>] - <today>` block. Use the `extract` chunk (`UNRELEASED`,
   `COMMITS`, `DIFF_STAT`, `UNCOMMITTED`, `EXISTING_<X.Y.Z>`) - never Read the full
   CHANGELOG. Follow **Bullet style** and **Section reclassification** below. On a
   re-run (`is_rerun: true`) combine the existing block with `[Unreleased]` and
   **reclassify, don't just merge**.
2. **Classify cspell findings.** For each `{word, file, line, context}`: a
   code identifier / proper-noun → collect for `cspell_add`; a plain-prose
   misspelling → `Edit` the source file to fix it (do **not** add to the
   dictionary); genuinely ambiguous → ask the user in one batched `AskUserQuestion`.
3. **Author `.release/commit-plan.json`.** `Write` it following
   `schemas/commit-plan.example.json`: ordered `groups`, each `{globs, prefix,
   message, trailers}`, **file-granularity**, first-match-wins. When
   `context.plan_seed.seeded` is true the *previous release's* plan is already
   there - read it against `diff_name_status` and **edit** it rather than
   starting over. Only glob coverage is machine-checked (`recut` pre-validation
   rejects an orphan path or an empty group), so a stale glob fails loudly; the
   commit messages and the `docs(changelog)` group's version still describe the
   last release until you change them. Put the CHANGELOG
   riders (`CHANGELOG.md`, `project-words.txt`, `pyproject.toml`, `uv.lock`) in
   the final `docs(changelog)` group. Store `Codified-Learning:`/`Co-Authored-By:`
   lines as `trailers` entries - never re-typed later.

   **Verify version vs content** before resuming (the check `/prepare-release`
   Phase 3 did): `Added`/`feat:` present but user picked patch → suggest the next
   minor; a `feat!`/`BREAKING CHANGE` → suggest major; only `fix`/`chore`/`docs` +
   user picked minor/major → suggest patch. Non-blocking - surface, let the user
   decide via `AskUserQuestion`, and pass the chosen version as `version_final`.

Then resume with a decision (write it to `.release/decision.json` or pipe via `-`):

```bash
.claude/skills/release-auto/scripts/release.py resume --decision .release/decision.json
```

Decision shape:

```json
{ "cspell_add": ["msal", "wslview"], "version_final": "1.16.0", "plan_written": true }
```

`resume` adds the approved words, resolves the reset target (last tag for a first
cut; oldest-touched-commit^ for a re-run), records the confirmed covered set, then
**recuts headless** (pre-validate → safety backup ref → soft-reset → per-group
commits) and runs `make lint-diff`. It stops at the `push` gate (exit 10) with the
commit subjects and a PR-body preview.

If `recut` fails pre-validation (an orphan path or an empty group), it exits 1
**before touching git** - fix the plan's globs and re-run `resume`. If it fails
*after* mutation (including a `lint-diff` failure, which runs inside the same
atomic block), it soft-rewinds the commits back to the pre-recut HEAD - leaving
all release work in the working tree - and re-raises; git is never left
half-mutated and uncommitted work is never lost.

### Step 3 - the push gate (agent judgment)

Eyeball the `commits` list and `pr_body_preview`. If good, resume to push:

```bash
echo '{"approve": true}' | .claude/skills/release-auto/scripts/release.py resume --decision -
```

Headless: `git push --force-with-lease` (sets upstream on first push), then
create-or-update the release PR (`chore(release): <X.Y.Z>`, body = the CHANGELOG
section verbatim - no attribution trailer). If `--skip-review` was set, this wipes
`.release/` and the release is merge-ready (exit 0). Otherwise it prints
`SPINE_COMPLETE` and hands off to the review coda.

**This gate is the last chance to turn the review coda on.** `review_coda` in the
payload reports which of the two endings is coming; when it is `false` this push
wipes the run. If `--skip-review` was passed but the user wants the review after
all, add the key rather than letting the run wipe and starting a second spine:

```bash
echo '{"approve": true, "review": true}' | .claude/skills/release-auto/scripts/release.py resume --decision -
```

It only ever turns the coda **on**. Omitting it on a run started without
`--skip-review` leaves the coda enabled - forgetting to repeat a flag must not be
able to destroy the state the coda runs on.

To abort at either gate: resume with `{"abort": true}`, or run `release.py abort`
(soft-rewinds any release commits back to the tag - work preserved in the tree -
and wipes `.release/`).

### Step 4 - review coda (skipped with --skip-review)

Mostly judgment, so it runs as an agent-driven coda *outside* the spine; only the
Copilot wait is detached so a non-responsive reviewer never blocks. The coda has
**two review layers**, run in order - `--skip-review` skips **both**:

- **4a - heterogeneous-model review** (`/second-opinion`): a different model
  family (GitHub Copilot CLI, `gpt-5.3-codex`) reviews the diff at author time,
  before merge. Catches what a same-model PR review structurally cannot.
- **4b - Copilot PR review** (`/address-pr-review`): the GitHub Copilot reviewer
  on the PR itself.

Run 4a first: its fixes fold into the release commits via `recut` (zero-gate if
they stay within covered paths), so the PR the Copilot reviewer sees in 4b is
already second-opinion-clean.

#### Step 4a - heterogeneous-model review (`/second-opinion`)

Unlike `/prepare-release` (which runs this *before* its soft-reset and needs a
`preflight-wip` commit), the spine has **already committed and pushed** every
release change, so second-opinion's "committed state only" contract is satisfied -
no WIP commit needed. Review scope is always `<last-tag>..HEAD` (what this release
introduces over the last tag).

1. **Skip-check + availability.** If `--skip-review` was passed, announce and go
   to Step 4c. Otherwise run `command -v copilot >/dev/null`; if it fails, log a
   warning and proceed to Step 4b (never block a release on Copilot-CLI absence).
   Do not assume it is missing without checking - in VS Code Server it lives at
   `~/.vscode-server/data/User/globalStorage/github.copilot-chat/copilotCli/copilot`.

2. **Invoke with author intent.** Run the Copilot CLI against the release diff and
   point it at the freshly-composed CHANGELOG section so it judges against stated
   intent (per `.claude/skills/second-opinion/SKILL.md`):

   ```bash
   copilot -p "Read .claude/skills/second-opinion/REVIEW-BRIEF.md AND the '## [<X.Y.Z>]' section of CHANGELOG.md (the author's stated intent), then review the branch's changes since <last-tag>. Run: git diff <last-tag>..HEAD. Dismiss findings that contradict the documented intent unless the code genuinely fails to deliver it (then flag the bullet-vs-code gap). Output findings using the brief's format and severities." \
     -s --model gpt-5.3-codex --no-custom-instructions --allow-all-tools
   ```

3. **Challenge every finding.** The reviewer has no project context beyond the
   brief - it will flag intentional patterns and misread intent. For each: read
   the flagged code; dismiss with a reason if clearly wrong, fix if clearly right,
   and surface via `AskUserQuestion` when uncertain - never auto-fix on doubt.
   Present a summary with a verdict per finding (`fixed` / `dismissed (reason)` /
   `needs-user-judgment`).

4. **Fold fixes + re-cut.** Apply fixes with `Edit`, fold user-facing changes into
   the existing CHANGELOG bullet (never a `Fixed` bullet for a bug that never
   shipped - see **Section reclassification**), then `release.py recut` +
   `release.py push` (same zero-gate rules as 4b step 3 below). Optionally rerun
   `/second-opinion` scoped to only the fixed files (cap 1 rerun). On "No
   findings.", announce and go to Step 4b.

#### Step 4b - Copilot PR review (`/address-pr-review`)

1. **State → trigger-if-needed → wait** via the shared review script (do **not**
   use raw `gh pr edit --add-reviewer`). Always run `state` first and **only
   trigger when it reports state A** (`copilotRequested: false`). Do **not** assume
   a push auto-requested Copilot - the initial `git push -u` usually does, but a
   `--force-with-lease` re-push (every coda re-cut) frequently does **not**, so
   `wait` would poll a never-requested review to timeout. `wait` polls but never
   triggers; the trigger is your responsibility:

   ```bash
   python3 .claude/skills/address-pr-review/scripts/pr_review.py state    # A=trigger, B=just wait, C=process, D=triage-clean
   python3 .claude/skills/address-pr-review/scripts/pr_review.py trigger  # ONLY if state A
   python3 .claude/skills/address-pr-review/scripts/pr_review.py wait --timeout 480
   ```

2. **Triage as one bundle against policy.** Read `review-policy.json` (this
   skill's committed default). For every fresh unresolved thread, propose a
   disposition - `fix` / `resolve-only` / `skip` - matching `known_false_positives`
   (e.g. `ubuntu-slim`), `path_ownership` (e.g. `modules/aliases-git/** →
   resolve-only: upstream-managed`), and `accepted_intentional`. Present the whole
   bundle to the user in one `AskUserQuestion` to confirm or override inline.
   **Nothing is auto-dismissed without being shown** - that is what keeps a stale
   policy from silently over-suppressing. Resolve `fix`/`resolve-only` threads via
   `pr_review.py resolve <thread-id>`; write actual fixes with `Edit` (never
   copy the reviewer's suggestion verbatim). Fold review-driven fixes to unshipped
   code into the existing `Added` bullet - do **not** add a `Fixed` bullet for a
   bug that never shipped (see **Section reclassification**).

3. **Re-cut + re-push** only if fixes were applied:

   ```bash
   .claude/skills/release-auto/scripts/release.py recut
   .claude/skills/release-auto/scripts/release.py push
   ```

   **Resolve every `fix`/`resolve-only` thread before you re-cut.** The re-push
   is a force-push, which flips every thread anchored to the old diff to
   `isOutdated` - and `state` does not report those. A thread you push past
   instead of resolving does not come back: it stays open on the PR, unread,
   and still blocks merge under conversation-resolution rules.

   **Let `recut` be the lint gate; never validate a coda fix with bare `make
   lint`.** The spine commits only through `recut`, which uses `git commit
   --no-verify` (so `check-changelog` never fires on a release commit) and runs
   `make lint-diff` *inside* its atomic block - a green `recut` means the full
   hook suite passed. A bare working-tree `make lint` instead *false-positives*
   on `check-changelog`: during a release the CHANGELOG entry sits under `##
   [X.Y.Z]`, so `[Unreleased]` is empty, and a still-uncommitted runtime fix
   trips "runtime files changed but no `[Unreleased]` entry". `make lint-diff`
   (`--from-ref main`) runs the same hooks diff-scoped and passes because
   CHANGELOG.md is in the diff - run it yourself only to double-check before `push
   --done`. `make test-unit` is a subset (bats/Pester/pytest only) - use it for
   quick logic checks on the fix, never as the lint gate. If you edit a fix and
   forget to `recut`, `release.py push` refuses (dirty plan-covered paths would be
   left unpushed) - run `recut` first.

   `recut` reconciles the working tree against the plan and gates **only when the
   plan cannot execute** - an `orphan` path no group's globs claim, or an
   `empty_groups` entry whose globs now match nothing (e.g. a fix reverted the
   only file a group covered). Fix the plan's globs (add a glob for an orphan;
   remove or repoint an empty group) and re-run `recut`. Everything else recuts
   **silently, zero agent turns** - pure content re-edits of already-approved
   files (a WAM tweak, a shim fix), a new file the plan's globs *already* claim,
   or a reverted file whose group you dropped. The `reconcile` payload also
   reports `new_covered`/`dropped` for context, but those are advisory and never
   gate on their own (a matched plan always proceeds). Cap at 2 fix cycles; after
   that, tell the user to run `/address-pr-review` manually.

   After the coda `push`, **go back to step 1** - re-run `state`, and trigger
   again if it reports A (the force-push usually will not have re-requested
   Copilot). A push does not reliably auto-trigger a fresh review; only an
   explicit `trigger` on state A does.

#### Step 4c - finish

First confirm nothing is still open. `pr_review.py state` reports only *fresh*
threads, and every coda re-push moves the head SHA - which flips existing
threads to `isOutdated` and drops them from that list. A review comment nobody
actioned therefore goes invisible precisely when you are deciding the coda is
clean (this hid two unresolved threads on the 1.20.0 PR, one a live bug):

```bash
python3 .claude/skills/address-pr-review/scripts/pr_review.py unresolved
```

It exits 1 while any thread is unresolved, outdated or not. Triage each the
same way as step 4b - outdated means the diff moved under the comment, not that
the point is moot - then `resolve` it. Only once that exits 0, and **both**
review layers are clean:

```bash
.claude/skills/release-auto/scripts/release.py push --done
```

Deletes the safety backup ref, wipes `.release/` (the commit plan survives as
`commit-plan.prev.json`). The release is merge-ready. Safe to run
unconditionally - `--done` on an already-finished run is a no-op, not an error.

`--done` re-runs the thread check itself and prints a `WARNING` to stderr for
anything still unresolved - or for a lookup it could not complete, which is not
the same as clean. That is a backstop for a skipped step, not a substitute for
running `unresolved` above: this is the terminal command, so a warning it prints
is the last chance anyone has to see the thread. Report any such warning to the
user rather than letting the run end on it.

## Recovery & inspection

- `release.py status` - print the current state JSON.
- `release.py start --reopen --version <X.Y.Z>` - re-cut an already-cut+pushed
  release that has **no new changes**. The previous release's commit plan is
  seeded into place automatically (see `plan_seed` at the phase-1 gate), so a
  consolidation re-cut is an edit rather than a re-derivation of every group. Skips the "nothing to do" guard and the
  version bump + `make upgrade` (content frozen), then runs the normal
  phase-1 → recut → push flow. Use to fold coda follow-up commits (made outside the
  spine, or after `.release/` was wiped) back into clean per-group commits. The
  recut rewrites the pushed branch, so the push is a force-push. Requires `.release/`
  to be absent (wipe a stale run with `abort` first).
- `release.py abort` - soft-rewind any release commits back to the reset target
  (work preserved in the working tree, never `--hard`) and wipe `.release/`. The
  rewind only fires when the safety backup ref is an **ancestor of HEAD** (this
  run's un-finished recut); an orphaned backup from a divergent/shipped cycle, or
  no backup at all, wipes state without touching any commits.
- **Orphaned state from an already-shipped cycle:** if the coda never ran `push
  --done` (or a run was interrupted after the tag shipped), `.release/` is left
  behind. `start` detects this - when the leftover state's version is already a
  git tag it refuses with `state is from v<X> which is already tagged (shipped);
  run release.py abort to clear it` (not the generic "in progress" message). Run
  `release.py abort`; it is ancestor-guarded, so it safely wipes the stale state
  without rewinding the shipped release or any of your current work.
- `resume` refuses if HEAD moved underneath the orchestrator (a manual commit/reset
  between steps) or the state version mismatches - inspect `git log`, `abort` and
  `start` fresh if the move was intentional.
- The safety backup ref (`refs/release-backup/<version>`) records the pre-recut
  HEAD as a breadcrumb; it is preserved on failure for inspection (`git log
  refs/release-backup/<version>`) and only deleted on a clean finish.

## Scripts

The spine (`release.py` + the three JSON contracts) plus the leaf scripts absorbed
from the retired `/prepare-release` skill, all under `scripts/`:

- `scripts/extract.py` - CHANGELOG + git-context chunks.
- `scripts/cspell_words.py` - `scan` / `add`.
- `scripts/test_stats.py`, `scripts/extract_signals.py` - interstitial checks
  (test-stat drift, learning extraction) when a release warrants them.

It also drives two sibling skills, used verbatim:

- `.claude/skills/second-opinion/SKILL.md` + `REVIEW-BRIEF.md` - heterogeneous-model
  review (Step 4a); the `copilot` CLI invocation and the project review brief.
- `.claude/skills/address-pr-review/scripts/pr_review.py` - `state`/`trigger`/`wait`/`resolve`.

## Bullet style guidelines

For the CHANGELOG entry composed at the phase-1 gate.

- **One sentence; two if the why is non-obvious.** Split into separate bullets rather than write three.
- **Pattern**: "X now does Y" or "Fixed Z that caused W". Lead with the change.
- **Backticks for code identifiers**: `function_name`, `file.sh`, `--flag`.
- **No prose paragraphs, no quoted CI logs, no commit SHAs / PR numbers in the body** - all searchable via git/GitHub.
- **10-40 words per bullet.** Hard cap at 40.
- **No "we"** - imperative or third-person.
- **Section order**: `### Added` → `### Changed` → `### Fixed` → `### Removed` → `### Security` → `### Deprecated`. Skip empty sections (`check_changelog.py` enforces this).
- **Intro paragraph** only for major (X.0.0) / minor (X.Y.0); patch releases go straight to sections.
- **Date**: `YYYY-MM-DD`, today.

## Section reclassification (shipped-version timeline)

The CHANGELOG's audience is a user upgrading from `<last-tag>`, not a contributor
reading commit history. Classify by *"from the perspective of a user on
`<last-tag>`, what kind of change is this?"* - not by what activity happened during
the PR. Applies in two spots: the re-run/merge case, and folding review fixes.

| Feature/fix exists in `<last-tag>`? | Bullet describes               | Action                                    |
| ----------------------------------- | ------------------------------ | ----------------------------------------- |
| No (introduced this version)        | iteration/refinement/fix on it | **Fold** into the existing `Added` bullet |
| No (introduced this version)        | a new, additional feature      | new `Added` bullet                        |
| Yes (already in `<last-tag>`)       | behavior change                | new `Changed` bullet                      |
| Yes (already in `<last-tag>`)       | bug fix to existing behavior   | new `Fixed` bullet                        |

A bug introduced *and* fixed within this release cycle never reached users - it is
**not** "Fixed"; the corrected behavior is part of the feature's `Added`
description. This is the most common merge-case error.

## Anti-patterns

- **Editing `.release/` files by hand mid-run** (except `commit-plan.json`, which the agent authors). State is the driver's; corrupting it breaks `resume`. Use `abort` to restart.
- **Reasoning about whether to recut.** `recut` reconciles and decides. It's a silent no-op unless the plan can't execute against the tree (orphan path or empty group); just call it after a fix - including after *reverting* one, as long as you also drop the now-unused plan group.
- **Calling `gh pr edit --add-reviewer` directly.** Use `pr_review.py trigger` - the raw call drifts on reviewer login/idempotency.
- **Finishing on state D.** D means "nothing left to triage", not "nothing left open" - it cannot see threads a force-push made outdated. Run `pr_review.py unresolved` before `push --done` (step 4c).
- **Pushing past a thread instead of resolving it.** The force-push hides it rather than settling it: it drops out of `state` and stays open on the PR.
- **Copying a reviewer's suggested fix verbatim,** or auto-applying findings without challenge. The reviewer is a different model with limited context; validate against author intent, surface uncertainty to the user.
- **Adding a `Fixed`/`Changed` bullet for something that never shipped.** Fold into `Added` (see reclassification).
- **Force-pushing to `main`/`master`/`develop`** - the driver refuses; don't work around it.
- **Reading the full CHANGELOG.** The `phase1` payload already carries `extract.py`'s chunks.
- **Tagging the release** - `make release` tags post-merge. Out of scope.
- **Skipping either review layer by your own judgment.** The only skip is `--skip-review`, and it skips *both* second-opinion (4a) and the Copilot PR review (4b) together - you cannot drop just one. New features are the *most* important case to review.

## History

`/release-auto` replaced `/prepare-release` (a ~10K-token turn-by-turn runbook) with
inverted control to cut release token cost. `/prepare-release` has been **retired
and removed**; its shared leaf scripts (`extract.py`, `cspell_words.py`,
`test_stats.py`, `extract_signals.py`) now live under `scripts/` here and are
invoked via the `SHARED` constant in `release.py`.

## Example invocations

- `/release-auto 1.16.0` - full orchestrated pipeline with review coda
- `/release-auto 1.16.0 --skip-review` - spine only, merge-ready at push
- "run the orchestrated release for 1.16.0" - same as `/release-auto 1.16.0`
- "the release PR has new Copilot comments" - run Step 4 (coda) again: `pr_review.py` triage → `release.py recut` → `release.py push`
