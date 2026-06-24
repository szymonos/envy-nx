# Playbook-inspired validation skills & hooks

**Date:** 2026-06-24
**Status:** Proposal (not yet implemented)
**Source:** [Founder's Playbook](../.tmp/The%20Founders%20Playbook%20-%20Building%20an%20AI-Native%20Startup.md), [`design/ideas.md`](../ideas.md)

## Why

The Founder's Playbook prescribes validation discipline for AI-native startups: pressure-test before building, write architectural decisions before letting AI generate code, fight scope creep, and pay down agentic technical debt before it compounds. envy-nx is mature (post-launch in playbook terms) but the same disciplines apply per-feature inside a stable repo. Several playbook frames are not yet covered by existing skills:

- `grill-with-docs` builds the case **for** a decision (recommended answers, write ADR when consensus is reached). No skill builds the case **against**.
- `code-review`, `second-opinion`, `review` operate post-build. No skill validates architecture **before** code is written.
- `cleanup_queue.md` is grep-able but no hook surfaces overlap when current work touches deferred CQ-NNN files.
- Scope creep is mentioned in [`AGENTS.md`](../../.claude/CLAUDE.md) as a recipe to follow manually; no automation surfaces when a commit's diff strays from its stated intent.

## What

Two skills + two pre-commit-style hooks. Skills carry the reasoning; hooks carry the mechanical guards.

### 1. `/devils-advocate` - adversarial proposal review (skill)

**Trigger:** explicit invocation.
**Output:** chat-only structured findings; no file written.
**Path:** `.claude/skills/devils-advocate/SKILL.md`

Given a proposal (free-text or a path to a draft), argue against it. Specifically:

- Search [`design/lessons.md`](../lessons.md) for prior failures of similar shape.
- Search [`design/decisions/`](../decisions/) for prior decisions this proposal would conflict with or supersede.
- Search [`design/cleanup_queue.md`](../cleanup_queue.md) for related deferred work the proposal touches or contradicts.
- Search [`design/followups.md`](../followups.md) for queued items that overlap.
- Apply the playbook's "loss of objectivity" frame: list the three strongest arguments AGAINST, not for.
- Surface any cross-shell parity risk (per [`.claude/rules/cross-shell-parity.md`](../../.claude/rules/cross-shell-parity.md)) the proposal implies.

Returns a short structured report: prior-failures, conflicting-decisions, deferred-overlap, parity-risk, top-3-counterarguments. No verdict - the user reads and decides.

**Why standalone:** cheap to invoke as a sanity check on any proposal without spinning up architecture work. Also composes inside `/validate-architecture` (see below).

### 2. `/validate-architecture` - bounded iterative architecture loop (skill)

**Trigger:** explicit invocation with proposal as argument.
**Output:** draft ADR in `design/decisions/NNNN-slug.md` if the loop converges; otherwise a "needs more work" report.
**Path:** `.claude/skills/validate-architecture/SKILL.md`

Implements the loop sketched in [`design/ideas.md`](../ideas.md) lines 11-18.

**Flow:**

1. **Phase 1 - adversarial pass:** invoke `/devils-advocate` on the proposal. If it surfaces blocking conflicts (e.g. proposal contradicts an ADR), present them and ask: continue, refine proposal, or abort.
2. **Phase 2 - draft architecture:** spawn a subagent with the proposal as input and the ARCHITECTURE.md table of contents (lazy-load specific sections by the subagent on demand). Subagent produces a structured architecture sketch: files to add/modify, sourcing chain, scope/phase placement, hook implications, test surface.
3. **Phase 3 - validate against actual architecture:** main agent compares the sketch against ARCHITECTURE.md sections 3-7 (real call tree, runtime layout, zsh-compat rules, constraints), design/decisions/, and design/cleanup_queue.md. Lists conflicts as a structured table.
4. **Phase 4 - branch:** if no conflicts, write draft ADR and exit. If conflicts surfaced, ask the user one question: (a) fix the proposed architecture to remove the conflict, (b) redefine the requirement so the conflict is moot, or (c) accept and document the tradeoff.
5. **Phase 5 - iterate:** rerun phase 2 with the user's choice as new input. **Bounded to 3 iterations.** If still unresolved after 3, write a "blocked" report listing every conflict and exit; do not write an ADR.

**Why bounded:** the playbook warns against agentic feedback loops that re-derive bad decisions. 3 rounds is enough to converge on real fits and short enough to expose genuine impasses.

### 3. `cleanup-queue-overlap` hook - surfaces CQ-NNN debt the diff touches

**Stage:** `pre-commit`
**Path:** `tests/hooks/check_cleanup_queue.py`
**Files:** all source files (regex matches `.assets/`, `nix/`, `wsl/`, etc.)
**Behavior:** non-blocking warn by default; opt-in block via env var.

Reads `design/cleanup_queue.md`, builds a `file → CQ-NNN` mapping from the path globs each entry declares. For each staged file:

- If the file is referenced by an open CQ entry, print: `ⓘ touched file maps to CQ-NNN: <one-line description>. Consider whether this change should address it.`
- Exit 0 unless `ENVY_NX_BLOCK_CQ_OVERLAP=1` is set (matches existing opt-in patterns).

Counters: the user can intentionally touch transitional code without resolving the CQ. The hook informs; it does not gate. Maps to playbook's "agentic technical debt" warning without becoming a chronic blocker.

**Risk:** depends on `cleanup_queue.md` having parseable file globs. Today the file is freeform Markdown. The hook may need a small schema extension (a fenced `cq-files:` block per entry) - proposal phase decides whether that schema burden is acceptable.

### 4. `scope-drift` hook - flags commit-message vs diff mismatch

**Stage:** `commit-msg`
**Path:** `tests/hooks/check_scope_drift.py`
**Behavior:** warn-only; never blocks.

When the commit message lands, compare the staged diff's file list against the subject + body text. Heuristic:

- Extract referenced filenames, function names, scope names from the commit message.
- List the subsystems touched by the diff (group by top-level directory: `nix/`, `.assets/lib/`, `.assets/config/shell_cfg/`, `wsl/`, `tests/`, `docs/`, etc.).
- If the diff touches subsystems not mentioned in the message AND more than 2 subsystems total, print a one-line warning: `⚠ commit touches <N> subsystems but message mentions <M>. Drift check: <list-of-unmentioned>.`

Exit 0 always. The goal is awareness, not friction. Maps to the playbook's "zero-friction scope creep" warning.

**Risk:** heuristics are noisy. A commit message saying "refactor profile helpers" legitimately touches multiple files. The hook needs to be tuned for this codebase's commit style; the first iteration logs to a metrics file (`.cache/scope_drift_log.json`) so we can review noise before tightening.

## Sequence

1. `/devils-advocate` first - no dependencies, lowest risk, immediately useful.
2. `cleanup-queue-overlap` hook second - small, mechanical, exercises whether `cleanup_queue.md` schema needs tightening.
3. `/validate-architecture` third - depends on `/devils-advocate` and benefits from the cleanup hook.
4. `scope-drift` hook last - needs commit-style data from the first three to tune heuristics.

## Out of scope

These playbook frames intentionally do **not** become skills:

- **Customer discovery / outreach automation.** envy-nx has no "customers" in the playbook sense; users find it via GitHub.
- **TAM/SAM/SOM, market sizing, GTM.** Wrong vertical entirely.
- **Premature scaling.** Already managed by the existing scope system and conscious release cadence.
- **Founder bottleneck.** A two-maintainer OSS repo doesn't have this shape.

The playbook is the inspiration, not the prescription. The skills above adapt its *methodology* (pressure-test, document constraints, fight scope drift, audit debt) to the actual shape of this codebase.

## Resolved decisions

1. **`cleanup_queue.md` gains a structured `cq-files:` block per entry.** Each CQ entry adds a fenced code block:

   ````markdown
   ```cq-files
   .assets/lib/nx_profile.sh
   nix/lib/phases/profiles.sh
   ```
   ````

   One-time migration of existing entries; new entries must include the block. Hook parses these blocks deterministically; freeform prose mentioning paths is ignored.

2. **`design/proposals/` becomes the validating layer.** `/validate-architecture` writes `design/proposals/NNNN-slug.md` during the loop. On user acceptance, the file is promoted (manual `mv` + INDEX update) to `design/decisions/NNNN-slug.md`. The existing `design/proposals/playbook-validation-skills.md` (this file) establishes the pattern. `design/decisions/` stays a clean record of load-bearing choices.

3. **`/validate-architecture` spawns its drafting subagent via `Agent(subagent_type=Plan, ...)`.** `Plan` is the repo-available architect agent, described in the agent registry as: "Software architect agent for designing implementation plans. Returns step-by-step plans, identifies critical files, considers architectural trade-offs." Matches the phase-2 remit exactly; no custom prompt-engineering needed to coerce a different agent type.
