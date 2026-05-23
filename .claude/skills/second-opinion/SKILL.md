---
name: second-opinion
description: Heterogeneous-model code review of the current branch's changes. Invokes GitHub Copilot CLI with gpt-5.3-codex to review git diff since merge-base with main (or user-specified commit). Reads .claude/skills/second-opinion/REVIEW-BRIEF.md for focused project context. Returns structured findings that Claude reads, summarizes, and acts on. Use when the user types `/second-opinion`, asks for a second opinion on a branch, wants GPT to review the work, or wants an independent review before pushing. Also called from /prepare-release Phase 3.5. Disabled for auto-invocation.
disable-model-invocation: true
---

# Second opinion

Heterogeneous-model author-time review of the current branch. Runs **GitHub Copilot CLI** (`copilot`) with a GPT-family model (default `gpt-5.3-codex`) against the diff since `git merge-base main HEAD`. The reviewer returns structured findings; Claude reads them and acts.

The bias-control mechanism is **the process boundary itself**. Copilot runs as a separate binary, with a separate model family, returning only text. Claude (the implementer) cannot influence Copilot's review; Copilot cannot edit code. Tool restriction inside Copilot is unnecessary - the architecture enforces the separation.

## When to use

- `/second-opinion` - review current branch vs. `git merge-base main HEAD`
- `/second-opinion <commit>` - review since an arbitrary commit hash
- `/second-opinion --model <id>` - use a different Copilot model
- "Get a second opinion before I push" / "have GPT review this" - same as `/second-opinion`
- Called automatically from **`/prepare-release` Phase 3.5** (with adjusted output handling - see below)

## Prerequisites

`copilot` CLI installed and authenticated. Verify with `command -v copilot >/dev/null && copilot --version`. If missing, surface to the user: install via the repo's canonical installer `.assets/provision/install_copilot.sh` (uses `https://gh.io/copilot-install` upstream) and run `copilot login`. Updates via `copilot update`.

## Workflow

### Phase 1 - resolve the diff base

```bash
# Default: merge-base with main
base="$(git merge-base main HEAD)"

# Or, user-specified commit from skill args
base="<user-arg>"
```

If `base == HEAD`, exit early: "Nothing to review - branch is at parity with the base." Don't invoke Copilot.

### Phase 2 - invoke Copilot

Single Bash call. The prompt tells Copilot to read the brief, run `git diff` itself, and produce findings in the brief's specified format:

```bash
copilot -p "Read .claude/skills/second-opinion/REVIEW-BRIEF.md, then review the current branch's changes since <base>. Run: git diff <base>..HEAD to see all changes. Read referenced files for context as needed. Output findings using the format and severities specified in the brief." \
  -s \
  --model gpt-5.3-codex \
  --no-custom-instructions \
  --allow-all-tools
```

Flag rationale:

- **`-s`** (silent) - strips UI chrome, leaves only the agent's response on stdout. Critical for parsing.
- **`--no-custom-instructions`** - skips `AGENTS.md` and `.claude/skills/` auto-loading. The curated `REVIEW-BRIEF.md` is the only context Copilot needs. Loading everything would burn attention budget on irrelevant context (the `/prepare-release` skill is ~300 lines on its own).
- **`--allow-all-tools`** - required for non-interactive `-p` mode. Safe here: Copilot's output is text-only back to Claude; any edits Copilot might attempt happen in its process, not Claude's. Even if Copilot wrote a file, Claude would not act on it - Claude only acts on the findings text.
- **`--model gpt-5.3-codex`** - default. Override via skill arg (see model override below).

If Copilot exits non-zero, capture the error and surface to the user. Don't retry automatically.

### Phase 3 - parse and act on findings

Copilot returns markdown matching the format in `REVIEW-BRIEF.md`:

```text
## Findings

### F-001 - bug - .assets/lib/nx.sh:142
<description>

**Suggestion:** <fix direction>
```

Parse the response into a structured list: `[{id, severity, file, line, description, suggestion}, ...]`. If the response is `No findings.`, announce that and exit.

The output-handling rule **depends on how the skill was invoked**:

#### Standalone (`/second-opinion` typed by the user)

1. Present a summary table to the user:

   ```text
   ## Copilot review (gpt-5.3-codex) - 3 findings

   | ID | Severity | Location | Summary |
   |----|----------|----------|---------|
   | F-001 | bug | .assets/lib/nx.sh:142 | <one-line> |
   | F-002 | warning | nix/lib/phases/profiles.sh:88 | <one-line> |
   | F-003 | nit | docs/standards.md:23 | <one-line> |
   ```

2. Ask via `AskUserQuestion` which to act on. For ≤4 findings, use one question with multiSelect options (`F-001`, `F-002`, ...). For more, present in chunks of 4 or ask "fix all bugs, triage warnings/nits?" first.
3. For each finding the user wants fixed: Claude reads the relevant file, formulates a fix from Copilot's `Suggestion`, applies it via `Edit`. **Do not copy Copilot's patch verbatim** - Copilot suggests direction; Claude writes the actual edit using its own knowledge of the codebase.
4. After edits, run `make lint` to validate.

#### From `/prepare-release` Phase 3.5

1. Auto-fix findings with `severity: bug` AND a concrete `Suggestion` that maps cleanly to one or two lines of code. No user prompt needed for these - they're obvious corrections.
2. Surface to the user via `AskUserQuestion`:
   - Any `bug` finding where the fix is non-obvious or spans multiple files.
   - All `warning` findings (by definition, judgment is needed).
   - `nit` findings only if the user explicitly opted in (default: skip nits during release prep - they're not blockers).
3. After resolution, **re-run `make lint`** - same WATCHOUT as Phase 1 of `/prepare-release` (lint stages modifications; Phase 4 will redo staging).
4. Return control to `/prepare-release` for Phase 4 (soft-reset). Review-driven fixes are absorbed into the WIP commit history and get re-classified into the right Conventional Commits prefix during Phase 4's per-prefix consolidation. Free cleanup.

## Model override

Pass `--model <id>` in the skill args. Claude extracts it and substitutes for `gpt-5.3-codex` in the Copilot invocation.

Currently available Copilot models (May 2026 - list with `copilot -p "list available models"`):

| Model ID          | Tier       | Notes                                                                                                                              |
| ----------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `gpt-5.3-codex`   | standard   | **Default** - code-focused, balanced cost                                                                                          |
| `gpt-5.2-codex`   | standard   | Older codex; use only if 5.3 unavailable                                                                                           |
| `gpt-5.5`         | premium    | Heavier; use for complex / security-sensitive diffs                                                                                |
| `gpt-5.4`         | standard   | General-purpose; less code-specialized than codex variants                                                                         |
| `gpt-5-mini`      | fast/cheap | Quick triage; expect more noise / missed nuance                                                                                    |
| `claude-opus-4-7` | premium    | **NOT heterogeneous** - same family as Claude (the implementer); only useful if you specifically want a same-family second context |

## Anti-patterns

- **Running `/second-opinion` repeatedly on the same diff.** Wastes Copilot API tokens. If the first run missed something, evolve `REVIEW-BRIEF.md` (add a focus area), don't re-run.
- **Dropping `--no-custom-instructions`.** Copilot would auto-load `AGENTS.md` and every file under `.claude/skills/`. That's ~500+ lines of context unrelated to the actual diff review.
- **Piping the full diff into the `-p` argument.** Copilot's shell access lets it run `git diff` itself - piping risks shell-escape issues and prompt-size limits. Let Copilot run the command.
- **Copying Copilot's patch verbatim.** Copilot's `Suggestion` is a direction; Claude writes the actual edit. Verbatim copies skip Claude's knowledge of cross-shell parity, accepted decisions, and the codebase's idiomatic patterns.
- **Adding `Co-Authored-By: Copilot` to fix commits.** Fixes derived from Copilot's review are Claude's edits informed by Copilot's review - same as a human reviewer's comment. No tooling attribution needed.
- **Running `/second-opinion` after `/prepare-release` Phase 4 (soft-reset).** Phase 4 is the point of no return for commit topology; review-driven fixes after that require another soft-reset cycle. Phase 3.5 fires *before* Phase 4 by design.

## Example invocations

- `/second-opinion` - review against `git merge-base main HEAD`
- `/second-opinion abc1234` - review against an arbitrary commit
- `/second-opinion --model gpt-5.5` - use a heavier model for a security-sensitive branch
- "Get a second opinion before I push" - same as `/second-opinion`
- From inside `/prepare-release`: invoked automatically at Phase 3.5 unless user passed `--skip-review`

## Compounding loop

`REVIEW-BRIEF.md` is **git-tracked** so it compounds across runs. Two triggers update it:

1. **Copilot keeps flagging an intentional pattern** → add it to the "do NOT flag" section.
2. **Copilot misses a class of bug repeatedly** → add the relevant focus area or paired-file mapping.

This is the same L4 codify loop as the `/review` skill's charters (`design/reviews/charters/<shard>.md`) and `accepted.md`, scaled down to a single brief for the whole-diff reviewer.
