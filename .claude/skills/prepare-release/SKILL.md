---
name: prepare-release
description: Cut a release end-to-end - commit uncommitted work, consolidate the branch's commits by Conventional Commits prefix via soft-reset, write the CHANGELOG entry, push the branch, then create or update the release PR. Bundled extract.py reads only the CHANGELOG sections needed (avoids the 100+ KB file); cspell_words.py reconciles new vocabulary with project-words.txt before committing; test_stats.py audits stat-callout drift in docs when `tests/` changed since the last tag. Use when the user types `/prepare-release <X.Y.Z>`, asks to cut a release, prepare release notes, ship X.Y.Z, or wrap a branch up. Disabled for auto-invocation.
disable-model-invocation: true
---

# Prepare release

End-to-end release prep for a feature branch. Optimized for the WIP workflow where a branch accumulates many ad-hoc commits during development and gets consolidated at release time. Tagging is **out of scope** - that's handled post-merge by `make release`.

## When to use

- `/prepare-release 1.7.3` - cut 1.7.3 from current branch
- "wrap this branch up as 1.7.4" - same workflow
- "update the release PR with the new fixes" - re-run; merges new content into existing CHANGELOG entry, force-pushes, updates PR body

## Workflow

Five numbered phases plus two interstitials (Phase 1.5 cspell sweep, Phase 1.6 test-stats drift sweep). Stop and surface the error if any phase fails - don't paper over.

### Phase 1: Compose CHANGELOG entry

1. Run `make lint` first - ensures clean files before composing the entry.
   - **WATCHOUT:** `make lint` stages every file modified by the hooks (formatters, end-of-file-fixer, project-words.txt rewrite, etc.). We'll undo this in Phase 4 - until then, **do not run `git commit` casually**.
2. Run the bundled extractor to get small chunks instead of the full CHANGELOG:

   ```bash
   .claude/skills/prepare-release/scripts/extract.py --version <X.Y.Z>
   ```

   Returns `LAST_TAG`, `UNRELEASED`, `EXISTING_<X.Y.Z>`, `COMMITS` (since last tag), `DIFF_STAT` (since last tag).

3. Compose bullets per the **Bullet style guidelines** below. Three cases:
   - `[Unreleased]` empty + target version doesn't exist → compose fresh from `COMMITS` + `DIFF_STAT`.
   - `[Unreleased]` has notes + target version doesn't exist → shape and promote those notes; cross-check against COMMITS/DIFF_STAT to fill gaps.
   - Target version already exists (re-run / merge case) → combine `EXISTING_<X.Y.Z>` + new `[Unreleased]`; deduplicate; preserve any intro paragraph.

4. `Edit` `CHANGELOG.md` to splice in the new entry. Targeted `Read` of the first ~15 lines is enough to get the anchor; never `Read` the full file.

   - **New version** anchor: `## [Unreleased]\n\n<UNRELEASED-content-from-extract>\n\n## [<last-tag>]`
   - **Merge** case: two `Edit`s - one to replace the existing `## [<X.Y.Z>] - <date>` block with merged content, one to clear `[Unreleased]`.

### Phase 1.5: Cspell sweep (run only if release docs touched)

Reconcile new vocabulary in the release docs with `project-words.txt` *before* committing - otherwise `make lint-diff` in Phase 4 fails on `Unknown word (...)` and you pay an amend cycle. Adding to the dictionary intentionally needs human-or-agent judgment (a typo and a new library name look identical to cspell), so it's a skill helper rather than a pre-commit hook.

1. Scan changed `*.md` since `<last-tag>` (plus uncommitted/staged):

   ```bash
   .claude/skills/prepare-release/scripts/cspell_words.py scan
   ```

   Returns JSON: `[{"word", "file", "line", "context"}, ...]`. Empty list → skip the rest of this phase.

2. **Classify each finding by surrounding context** (the `context` field in the JSON):
   - In backticks, adjacent to a code identifier, an obvious proper-noun (`prek`, `idna`, `setup-uv`) → **name** to add.
   - Embedded in plain prose with no code markers, looks like a misspelling of a real word (`recieve`, `deendency`) → **typo**. Fix the source file via `Edit`; do **not** add to the dictionary.
   - Genuinely ambiguous → **unsure** bucket.

3. **Resolve the unsure bucket in one round-trip.** Single `AskUserQuestion` with one yes/no per ambiguous word ("Add to dictionary? `<word>` (in `<file>`: ...<context>...)"), batched. The user's answers split it into add-vs-fix.

4. Add all approved words in one call:

   ```bash
   .claude/skills/prepare-release/scripts/cspell_words.py add <word1> <word2> ...
   ```

   Idempotent: dedupes against existing entries, sorts, writes back. The updated `project-words.txt` rides along with the CHANGELOG in Phase 4's `docs(changelog)` commit (content-coupling).

### Phase 1.6: Test-stats drift sweep (run only when `tests/` changed)

Several docs hard-code counters that drift the moment a `.bats` file or an `It` block is added: `docs/standards.md`'s test-suite dashboard, `docs/index.md`'s quick-facts table, `ARCHITECTURE.md`'s test-infra section, and free-prose paragraphs in `docs/decisions.md` / `docs/architecture.md`. Stale numbers ship in releases and quietly degrade the docs' authority. This phase catches that *before* Phase 4 cuts the commits.

**Trigger:** `git diff --name-only <last-tag>..HEAD -- tests/` returns any file. If empty, skip the rest of this phase. (`extract.py`'s `DIFF_STAT` block also makes the touched paths visible at a glance - if no `tests/...` lines appear there, this phase is a no-op.)

1. Audit current callouts against live counts:

   ```bash
   .claude/skills/prepare-release/scripts/test_stats.py audit
   ```

   Prints `{counts, drift}` JSON. `drift` is a list of `{file, line, snippet, expected, actual, kind}` for each callout whose recorded number disagrees with the live count. Exit 1 = drift; exit 0 = clean.

2. **Edit each drift entry.** Use `Edit` to replace the stale number (`actual`) with the live one (`expected`). Keep the surrounding sentence intact; do not paraphrase the prose unless the change made the surrounding claim wrong (e.g. a sentence that says "12 zsh runtime tests verify ..." stays unchanged if only the bats *total* drifted, but if the zsh suite itself grew by 3, edit that prose too).

3. **Don't trust the audit alone.** The auditor only catches numbers in the curated `STAT_LOCATIONS` table inside `test_stats.py`. Manually skim the **Canonical statistics callouts** table below for callouts the regex doesn't cover - especially free-form prose like *"412 test cases across 22 test files"* in `docs/decisions.md`, which uses different phrasings the regex would have to enumerate. When you find an uncovered callout, fix it AND extend `STAT_LOCATIONS` (one `(file, regex, kind)` tuple, regex with exactly one `(\d+)` capture) so the next release catches it automatically.

4. **Reflect the doc edits in the CHANGELOG bullets you wrote in Phase 1.** Add a `### Changed` bullet (or extend an existing one) along the lines of "Refreshed test/hook counters in `docs/standards.md`, `docs/index.md`, and `ARCHITECTURE.md` to match the current X bats / Y Pester totals after the new tests in this release." Don't list the old → new numbers in the bullet body - the searchable record is the diff.

5. **Re-run `make lint`** after the doc edits - markdown table-alignment and trailing-whitespace hooks may auto-fix the touched files. (Same WATCHOUT as Phase 1: lint stages the modifications; Phase 4 will redo the staging.)

#### Canonical statistics callouts

The auditor knows about the entries below; the others are listed for the manual skim in step 3. When a doc adds a new stat callout, add a row here AND a tuple in `STAT_LOCATIONS`.

| File                   | Type    | Counter                                                                                           | Audited        |
| ---------------------- | ------- | ------------------------------------------------------------------------------------------------- | -------------- |
| `docs/standards.md`    | table   | total / bats / Pester file counts                                                                 | yes            |
| `docs/standards.md`    | table   | total / bats / Pester case counts                                                                 | yes            |
| `docs/standards.md`    | prose   | "N bats files cover ..."                                                                          | yes            |
| `docs/standards.md`    | prose   | "N Pester files mirror ..."                                                                       | yes            |
| `docs/standards.md`    | prose   | "N hooks split across two categories"                                                             | no - free-form |
| `docs/standards.md`    | prose   | per-suite case counts inside paragraph (`WslSetupPhases.Tests.ps1` - 49 unit tests)               | no - free-form |
| `docs/index.md`        | table   | "across N test files"                                                                             | yes            |
| `docs/index.md`        | prose   | "N mocked Pester tests"                                                                           | no - free-form |
| `ARCHITECTURE.md`      | section | "N Pester files; full suite ..."                                                                  | yes            |
| `ARCHITECTURE.md`      | prose   | per-file case counts in §9 (e.g. "12 tests verify nx.sh", "9 integration tests", "49 unit tests") | no - free-form |
| `docs/decisions.md`    | prose   | "N test cases across M test files"                                                                | no - free-form |
| `docs/architecture.md` | prose   | "N+ test cases across M test files"                                                               | no - free-form |
| `docs/enterprise.md`   | table   | "N Pester tests cover orchestration logic"                                                        | no - free-form |

The same drift principle applies to other counters that change with file additions (review charters in `design/reviews/charters/`, hook IDs in `.pre-commit-config.yaml`, scope `.nix` files in `nix/scopes/`, valid scopes in `.assets/lib/scopes.json`). The current helper only covers tests; expand `test_stats.py` (or split into a dedicated helper) when the same drift bites those counters.

### Phase 2: Categorize the diff

For Phase 4's per-prefix consolidation, classify every changed file (since `<last-tag>`) into a Conventional Commits prefix.

1. List the changes:

   ```bash
   git diff --name-status <last-tag>..HEAD
   git diff --name-status                     # uncommitted
   git diff --cached --name-status            # staged (lint side-effects)
   ```

2. For each file, classify into one prefix:
   - `feat` - new feature, new code
   - `fix` - bug fix
   - `chore` - lint / build config, dependencies, internal tooling, hook tweaks
   - `docs` - README, CHANGELOG, design docs
   - `test` - new tests only (no production change in the same file)
   - `refactor` - behavior-preserving cleanup

3. Use the CHANGELOG bullets you wrote in Phase 1 as the primary classification signal: `Added` → `feat`, `Fixed` → `fix`, `Changed`/`Removed`/`Deprecated`/`Security` → `chore` (or `refactor` when behavior preserved), CHANGELOG itself → `docs(changelog)`.

4. **Watch for content-coupled files.** `project-words.txt` (cspell dictionary) is content-coupled to the docs/code that uses its words - roll it into the commit that introduces those words (usually `docs(changelog)`), not into a generic `chore` commit. Conceptual coupling (the word exists *because* of the bullet) makes the commit history easier to read; with `--no-verify` in Phase 4 there's no auto-fix-loop hazard, so this is good practice rather than load-bearing.

5. Produce a categorization plan: which files go in which commit, with the commit message. **Don't execute yet** - Phase 3 verifies the release first, then Phase 4 has guardrails.

### Phase 3: Release verification

Two non-blocking checks. Surface findings, ask the user to confirm before proceeding to soft-reset.

1. **Version vs content match.**
   - `Added` section non-empty (or any `feat:` in the Phase 2 plan) + user picked patch → suggest minor (next-minor).
   - Any `feat!:` / `fix!:` / `BREAKING CHANGE:` in commits → suggest major.
   - Only `fix:` / `chore:` / `docs:` / `refactor:` + user picked minor or major → suggest patch (overshoot warning).
   - Match → silent pass.

2. **Bullet completeness.**
   - Every section header in the new entry has ≥1 bullet (no orphan `### Added`).
   - Date is today (not stale from a prior session).
   - No `TODO` / `TBD` / `XXX` placeholders in the bullets.

**Output shape on findings:**

```text
Release verification:
  ✓ Bullets present (Added: 4, Changed: 2, Fixed: 1)
  ✓ Date current (<today>)
  ✓ No placeholders
  ⚠ Version: picked X.Y.Z (patch); diff has N feat: commits → SemVer suggests X.(Y+1).0 (minor)

Continue with X.Y.Z, change to X.(Y+1).0, or abort?
```

**Prompt the user via `AskUserQuestion`** with three options: continue with picked version, change to suggested version, or abort. Don't proceed silently or assume - the user picks. If they pick the change, re-`Edit` the CHANGELOG header (one Edit, swaps `## [old] - <date>` → `## [new] - <date>`) before proceeding to Phase 4. If they abort, exit cleanly with no changes pushed.

**Both checks are non-blocking** because sometimes you genuinely want a patch with one `feat:` (security backport, hotfix that incidentally adds a small flag) - the skill surfaces, the user decides.

### Phase 4: Soft-reset and recommit by prefix

Three guardrails *before* destroying history:

1. **Refuse to force-push to a shared branch.** If the current branch is `main`, `master`, `develop`, or matches `release/*`, **stop**. Tell the user to do it manually.
2. **Capture the current HEAD SHA** for emergency restore (`git rev-parse HEAD`); print it to your output so the user can `git reset --hard <SHA>` if anything goes wrong.
3. **Clear the lint-staged state** so Phase 4 starts from a clean index:

   ```bash
   git restore --staged .
   ```

**Pick the soft-reset target:**

- **First cut for this version** (target `## [<X.Y.Z>]` block did not exist in CHANGELOG before Phase 1) → `git reset --soft <last-tag>`. All commits since the last release tag get folded into the new sequence.
- **Re-run / merge case** (target version block already existed before Phase 1) → identify the **oldest commit since `<last-tag>` whose files this run is touching**, and `git reset --soft <oldest-commit>^`. Untouched earlier commits stay intact. Common merge case (only CHANGELOG bullets added) collapses to a single `docs(changelog)` redo instead of N.

  To find the oldest commit being touched: for each modified file, run `git log --oneline <last-tag>..HEAD -- <file>` and pick the oldest hit across all files.

Then the consolidation:

```bash
# Move HEAD back to the chosen target; all changes since then become staged.
git reset --soft <target>

# Wipe the unified index so we can stage by category.
git restore --staged .

# For each Conventional Commits group, in this order.
# --no-verify skips per-commit hooks - we run them once after, via `make lint-diff`.
git add <files-for-this-group>
git commit --no-verify -m "<prefix>(scope): <one-line summary>"
# repeat for each prefix...

# Final commit is always the CHANGELOG itself (and project-words.txt rides along):
git add CHANGELOG.md project-words.txt
git commit --no-verify -m "docs(changelog): cut <X.Y.Z> release notes"
```

**Commit message style** - terse, single-line, Conventional Commits. Examples:

- `feat(skills): add grill-with-docs, slide-deck-builder, prepare-release`
- `fix(hooks): handle hidden directories in cspell ignorePaths`
- `chore: extend check_changelog SECTION_ORDER; exclude .claude/skills from lint`
- `docs(changelog): cut 1.7.3 release notes`

**Never** `git add .` or `git add -A` in this phase - the active scope is what you want, not whatever happens to be in working tree. Always explicit file lists.

**End of Phase 4: run `make lint-diff` once.** Hooks were skipped per-commit via `--no-verify`; this validates the full sequence at once. (`make lint` won't work here - post-commit there are no uncommitted changes for it to operate on; `make lint-diff` runs hooks against `main..HEAD` which is what we actually want to validate.)

- Passes + working tree clean → done, proceed to Phase 5.
- Passes + files modified by auto-fix hooks → `git commit --amend --no-verify --no-edit -a` to fold formatting fixes into the last commit. Acceptable noise (lint modifications are uniform: whitespace, EOF, dictionary pruning by `validate_docs_words`).
- Fails on `cspell` `Unknown word (...)` → Phase 1.5 was skipped or missed entries. Re-run `cspell_words.py scan`/`add`, then `git commit --amend --no-verify --no-edit -a`.
- Fails non-recoverably → **stop**. Surface the error. Don't push. User fixes manually, then re-runs Phase 5.

### Phase 5: Push and PR

1. **Push.** If the branch has no upstream yet:

   ```bash
   git push -u origin <branch>
   ```

   Otherwise (history was rewritten):

   ```bash
   git push --force-with-lease
   ```

   `--force-with-lease` (not `--force`) refuses to clobber remote commits you haven't seen - safety net for the "someone else pushed in the last 5 minutes" case.

2. **Create or update PR.** Probe first:

   ```bash
   gh pr view --json number,title,body 2>/dev/null
   ```

   - **No PR** → create:

     ```bash
     gh pr create --base main \
       --title "chore(release): <X.Y.Z>" \
       --body "$(<changelog-section>)"
     ```

   - **PR exists** → update title + body only:

     ```bash
     gh pr edit --title "chore(release): <X.Y.Z>" --body "$(<changelog-section>)"
     ```

     Never close/reopen, never re-request review, never touch the milestone.

   The PR body is the CHANGELOG entry verbatim (DRY - the bullets ARE the release notes). Do **not** append the Claude Code attribution trailer to release PRs - the CHANGELOG is the authoritative release record and shouldn't carry tooling attribution.

## Bullet style guidelines

For the CHANGELOG entry composed in Phase 1.

- **One sentence; two if the why is non-obvious.** Hard ceiling - split into separate bullets if a change needs three sentences.
- **Pattern**: "X now does Y" or "Fixed Z that caused W". Lead with the change, follow with the why only when not obvious from the change itself.
- **Backticks for code identifiers**: `function_name`, `file.sh`, `--flag`.
- **No prose paragraphs, no quoted CI logs, no commit SHAs / finding IDs / PR numbers in the body.** All searchable via git or GitHub anyway.
- **10-40 words per bullet.** Hard cap at 40.
- **No "we" - imperative or third-person.**

## Section order in the CHANGELOG

`### Added` → `### Changed` → `### Fixed` → `### Removed` → `### Security` → `### Deprecated`. Skip any section with no bullets. The `check_changelog.py` pre-commit hook enforces this order.

## Release intro paragraph

- **Major (X.0.0) or minor (X.Y.0) releases** - open with a single ~30-50 word paragraph framing the release.
- **Patch (X.Y.Z) releases** - skip the intro, go straight to sections.

## Date format

`YYYY-MM-DD` (matches existing entries). Use today's date.

## Anti-patterns

- **`git push --force`** without `--with-lease` - clobbers remote commits you haven't seen.
- **Force-pushing to `main` / `master` / `develop` / `release/*`** - Phase 4 guardrail must refuse.
- **`git add .` or `git add -A`** in Phase 4 - the active scope is what you want, not whatever happens to be in working tree.
- **Splitting `project-words.txt`** from its content-source commit. Conceptual coupling - the word exists *because* of the bullet - keeps the commit history honest.
- **Skipping `make lint-diff` after Phase 4.** Per-commit hooks were bypassed via `--no-verify`; `make lint-diff` is the validation gate. Skipping it means pushing unvalidated state.
- **Skipping Phase 3 (release verification).** A patch release that's actually feature-shaped is the most common quiet bug - verify before destroying history, when fixing is one Edit.
- **Skipping Phase 1.5 (cspell sweep).** Forces an amend cycle in Phase 4 when `lint-diff` flags `Unknown word (...)`. Run `cspell_words.py scan` once before committing - it's cheap and saves a reset.
- **Auto-adding everything cspell flags without classification.** A typo silently becomes a "valid" word and persists in the dictionary forever. Phase 1.5's classification step is the safeguard.
- **Shipping a release with stale test/hook/scope counts in the docs.** The numbers in `docs/standards.md`, `docs/index.md`, `ARCHITECTURE.md`'s §9 paragraphs, and the `docs/decisions.md` / `docs/architecture.md` test-cases-across-files prose decay every time a test or hook is added; they were correct at some point and read as authoritative until proven wrong. Phase 1.6 is the safeguard - the trigger (`git diff --name-only <last-tag>..HEAD -- tests/`) is one bash line and the audit is one script invocation.
- **Trusting the test_stats.py auditor as exhaustive.** It only catches the regexes in `STAT_LOCATIONS` - free-form prose like "412 test cases across 22 test files" in `docs/decisions.md` slips past. Manually skim the **Canonical statistics callouts** table during Phase 1.6.
- **Reading the full CHANGELOG.** Run `extract.py` first; agent context is what we're trying to save.
- **Multi-paragraph bullets, SHAs / finding IDs / PR numbers in the body.** Searchable elsewhere; clutters the changelog.
- **Tagging the release here** - real tags trigger release workflows; `make release` handles tagging post-merge.
- **Drafting GitHub Release notes** - separate concern, not in scope.
- **Listing every file from `DIFF_STAT`** - group related changes; mention specific files only for searchability.

## Example invocations

- `/prepare-release 1.7.3` - full pipeline end-to-end
- "Update the release PR with the new fixes" - re-run; CHANGELOG merges, force-push, PR body updates
- "Add a `Fixed` bullet for the timeout regression" - append to the active version section via `Edit`; if the branch is already pushed, re-run Phase 4+5 to update the PR
- "Refresh the test counts in the docs without cutting a release" - call `test_stats.py audit` directly outside the skill; fix the drift; commit as `docs(stats): refresh test counters` (this is the manual escape hatch when you notice drift between releases)
