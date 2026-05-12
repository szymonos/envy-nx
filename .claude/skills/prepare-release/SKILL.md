---
name: prepare-release
description: Cut a release end-to-end - commit uncommitted work, consolidate the branch's commits by Conventional Commits prefix via soft-reset, write the CHANGELOG entry, push the branch, then create or update the release PR. Bundled extract.py reads only the CHANGELOG sections needed (avoids the 100+ KB file). Use when the user types `/prepare-release <X.Y.Z>`, asks to cut a release, prepare release notes, ship X.Y.Z, or wrap a branch up. Disabled for auto-invocation.
disable-model-invocation: true
---

# Prepare release

End-to-end release prep for a feature branch. Optimized for the WIP workflow where a branch accumulates many ad-hoc commits during development and gets consolidated at release time. Tagging is **out of scope** - that's handled post-merge by `make release`.

## When to use

- `/prepare-release 1.7.3` - cut 1.7.3 from current branch
- "wrap this branch up as 1.7.4" - same workflow
- "update the release PR with the new fixes" - re-run; merges new content into existing CHANGELOG entry, force-pushes, updates PR body

## Workflow

Five phases. Stop and surface the error if any phase fails - don't paper over.

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
- Passes + files modified by auto-fix hooks → `git commit --amend --no-verify --no-edit -a` to fold formatting fixes into the last commit. Acceptable noise (lint modifications are uniform: whitespace, EOF, dictionary pruning).
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
- **Reading the full CHANGELOG.** Run `extract.py` first; agent context is what we're trying to save.
- **Multi-paragraph bullets, SHAs / finding IDs / PR numbers in the body.** Searchable elsewhere; clutters the changelog.
- **Tagging the release here** - real tags trigger release workflows; `make release` handles tagging post-merge.
- **Drafting GitHub Release notes** - separate concern, not in scope.
- **Listing every file from `DIFF_STAT`** - group related changes; mention specific files only for searchability.

## Example invocations

- `/prepare-release 1.7.3` - full pipeline end-to-end
- "Update the release PR with the new fixes" - re-run; CHANGELOG merges, force-push, PR body updates
- "Add a `Fixed` bullet for the timeout regression" - append to the active version section via `Edit`; if the branch is already pushed, re-run Phase 4+5 to update the PR
