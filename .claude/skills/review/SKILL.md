---
name: review
argument-hint: "[SHARD|next|status]"
description: Periodic standing-code review of one envy-nx shard. Two reviewers - the charter-driven reviewer subagent and second-opinion - review every file the shard owns; the agent decides each finding itself (fix, decline, hand off to another shard, escalate), fixes in place, and asks the user only the escalations, once, at the end. The run ends with one commit on a branch for /release-auto to take to a PR. Use when the user types `/review`, `/review SHARD` or `/review status`.
disable-model-invocation: true
---

# Standing review

Per-PR review sees a diff; this sees what is already there - drift, dead code, workarounds that outlived their reason, two halves of one feature that disagree. One shard per run, the whole shard every time. Shards, charters and history live in `design/reviews/` (`README.md` there explains the framework).

`scripts/review.py` owns everything with a right answer: which shard is next, which files it owns, what was decided before, and whether a run is complete. You own the judgment.

| Typed             | Runs                                      |
| ----------------- | ----------------------------------------- |
| `/review`         | `scripts/review.py prepare next`          |
| `/review <shard>` | `scripts/review.py prepare <shard>`       |
| `/review status`  | `scripts/review.py status`, printed as is |

Anything else the user types is an ordinary request. Exit codes: `0` done, `1` error (surface it), `2` usage, `10` decisions missing (`finish`).

## The run

1. **Prepare.** `scripts/review.py prepare [SHARD|next]` needs a clean tree. On `main` or a `release/*` branch it cuts `review/<shard>-<date>`; on any other branch it stays, so several runs can stack before one release.
2. **Review, both at once.** Start `scripts/review.py second-opinion` as a background Bash call (timeout 600000) and spawn the `reviewer` subagent with the payload's `reviewer_prompt`. Findings land in `.review/findings/`; `finish` needs both reports. When second-opinion is not installed the command records the skip, and a lens that times out is recorded as failed; carry on with what came back and name the gap in the report.
3. **Triage** every finding by the rules below into `.review/decision-log.md`. Findings from the two reviewers that share a root cause get one decision each, with the same `Why` word for word - `finish` counts root causes from it.
4. **Fix** each `fix` in the codebase's own idiom. Add an `[Unreleased]` CHANGELOG bullet for each runtime change - the `check-changelog` hook refuses the commit without one.
5. **Escalations**, if any: asked together at the end - one `AskUserQuestion` holds four, so more than four take consecutive calls - then an `answered` row for each. Apply every answer that says fix before finishing - `finish` counts it as a fix and tests it.
6. **Finish.** `scripts/review.py finish` refuses (exit 10) while a finding, a carried-in follow-up or an escalation has no decision, and lists what is missing. Then it runs `make test-unit` when something was fixed, records the run in `design/reviews/history.md`, runs `make lint` and commits everything. A failed test or lint: fix what it names and run `finish` again - it re-records from the committed history, so changed decisions are kept. Pass any commit attribution your harness asks for as `--trailer`.
7. **Report** the counts - `distinct` in the `finish` output counts root causes, not rows - and the branch, and stop. `/release-auto` takes the branch to a PR, with its own second-opinion pass over the fixes and one Copilot round. Never push or open the PR from here.

## Triage

| Call           | When                                                                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fix`          | A defect you can point to at a `file:line`: wrong behaviour, a security hole, a charter or `REVIEW.md` rule broken. Old defects are the target here, not out of scope.                      |
| `decline`      | Everything else: style, "consider X", hardening against a case that cannot happen, a new abstraction, what a hook already enforces, an "Already decided" item.                              |
| `resolve-only` | Already fixed or no longer applies - mostly a carried-in follow-up. Unlike a decline, it does not tell later reviews to stay quiet.                                                         |
| `handoff`      | A real defect in a file another shard owns that needs that shard's charter to judge, spreads past one function, or you could not verify. `Owner` is that shard.                             |
| `escalate`     | Acting either way would change what users see in shipped behaviour, remove a flag or feature, shift architecture, touch security, settle a cross-shell asymmetry, or you are not confident. |

- **Decline what does not hold up, however many that is.** A reviewer asked for gaps always finds some, and chasing them all is how code gets over-engineered. A diff review declines about half; old defects are the target here, so a standing review can decline far fewer.
- **Test a claim you can test before deciding it.** "X fails when Y" is often one command from confirmed or refuted - either way, a guess decides it wrong.
- **Another shard's file, small and confirmed: fix it now.** Ownership does not change whether something is a defect, and a hand-off leaves it broken until the rotation reaches the owner. `scripts/review.py owner <path>` names the owner; put it in the row.
- **A charter claim that contradicts `AGENTS.md` or `REVIEW.md` is a `fix` to the charter.**
- **A fix that would not fit one commit's worth of review** - a refactor across files, a new mechanism - is an escalation, not a fix.
- **`enterprise-readiness` findings** have three destinations - the code or a wrong doc, `docs/enterprise.md` as the integrator's job, or `design/enterprise_design.md` as a seam to build later - routed by its charter. Adding code that every user pays for is an escalation.

**A decline that will hold next time becomes a rule.** The reviewer flagged a deliberate decision or a convention: add a bullet to the charter's "What NOT to flag" when it is about this shard, or to `### Author decisions` in `.github/copilot-instructions.md` (the file `REVIEW.md` links to - never write through the link) when it holds repo-wide. A one-off "not worth it here" stays out of both.

## Decision log

`prepare` writes the header. One row per finding, no `|` inside a cell:

```markdown
| ID     | Where                     | Finding                    | Call     | Owner | Why                                  |
| ------ | ------------------------- | -------------------------- | -------- | ----- | ------------------------------------ |
| F-003  | .assets/lib/certs.sh:120  | bundle path not quoted     | fix      | certs | breaks on a home dir with a space    |
| R-002  | .assets/lib/certs.sh:88   | add a retry around openssl | decline  | certs | local file read, cannot be transient |
| FU-001 | .assets/setup/x.ps1:317   | static cert blocks         | escalate | certs | drops a block users may rely on      |
| FU-001 | -                         | -                          | answered | -     | fix: the user wants them dropped     |
```

`ID` is the finding's id, or the `FU-NNN` of a carried-in follow-up (the reviewer tags those findings with `carried`). An `answered` row repeats the escalation's id; its `Why` starts with the outcome - `fix:`, `decline:` or `leave:` - then the user's reason. `finish` refuses any other start, counts `fix:` as a fix, and carries the other two into later reviews as already decided.

**The escalation question** is one plain sentence - "The review suggests <change>. Should we?" - and its description says, without code: what it is for, who hits it (which platforms and setups), what the user would notice, whether it shifts architecture or touches security, whether it is worth the effort, and your recommendation. Options: "<your call> (Recommended)", the other way, and "Leave as is".

## Anti-patterns

- **Asking mid-run.** Escalations wait for the one question at the end.
- **Copying a reviewer's suggestion verbatim**, or fixing a finding because it was argued well.
- **Editing `design/reviews/history.md` by hand** - `finish` writes it; a follow-up that no longer applies is closed `resolve-only` in its shard's run.
- **Reviewing only what changed.** That is a PR review; a standing review reads the whole shard.
