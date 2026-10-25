# Periodic standing reviews

This directory holds the **standing artifacts** for envy-nx's periodic agentic code review. Per-PR review checks the delta; drift, dead code and decisions that aged out are invisible to it. This framework reviews the standing code, one shard at a time, the whole shard every run.

For the design rationale see [`docs/decisions.md` → "Process decisions"](../../docs/decisions.md). The runbook the agent follows is [`.claude/skills/review/SKILL.md`](../../.claude/skills/review/SKILL.md).

## Shards

Every tracked file belongs to exactly one shard, unless `shards.json` excuses it under `skip` (vendored and generated files) or `unowned_ok` (docs and repo metadata). When several shards' globs match a file, the most specific glob - the most literal characters - owns it, so `.assets/fix/fix_*_certs.sh` in `certs` beats `.assets/fix/*` in `system-installers`. Each shard owns its code **and the tests for it**, so a test is judged next to what it tests. The `check-arch-drift` hook fails a commit that adds a file no shard owns, naming the nearest shard.

[`shards.json`](shards.json) is the source of truth; this table is for reading.

| Name                   | Surface                                                     | Blast radius | Charter                                                     |
| ---------------------- | ----------------------------------------------------------- | ------------ | ----------------------------------------------------------- |
| `orchestration`        | `nix/setup.sh`, phase library, uninstall, upgrade walk      | high         | [orchestration.md](charters/orchestration.md)               |
| `scopes`               | `scopes.json`, `nix/scopes`, `nix/configure`, `flake.nix`   | high         | [scopes.md](charters/scopes.md)                             |
| `nx-core`              | nx dispatcher, helpers, `nx_surface.json`, completers       | high         | [nx-core.md](charters/nx-core.md)                           |
| `nx-packages`          | `nx install`/`remove`, `nx scope`, lifecycle verbs, overlay | high         | [nx-packages.md](charters/nx-packages.md)                   |
| `doctor-profile`       | `nx doctor`, managed profile blocks, install record         | high         | [doctor-profile.md](charters/doctor-profile.md)             |
| `certs`                | certificate and proxy path                                  | high         | [certs.md](charters/certs.md)                               |
| `system-installers`    | root installers, `linux_setup.sh`, host scripts             | high         | [system-installers.md](charters/system-installers.md)       |
| `shell-config`         | shell / pwsh / prompt config, `.assets/setup`               | medium       | [shell-config.md](charters/shell-config.md)                 |
| `wsl`                  | Windows-host PowerShell, `modules/utils-*`                  | medium       | [wsl.md](charters/wsl.md)                                   |
| `hooks`                | pre-commit gate scripts                                     | medium       | [hooks.md](charters/hooks.md)                               |
| `test-harness`         | test runners, generators, `Makefile`, lint config           | medium       | [test-harness.md](charters/test-harness.md)                 |
| `ci`                   | GitHub workflows, CI scripts, release build                 | medium       | [ci.md](charters/ci.md)                                     |
| `enterprise-readiness` | posture lens over the enterprise docs and extension points  | medium       | [enterprise-readiness.md](charters/enterprise-readiness.md) |
| `agent-tooling`        | agent skills, subagents, rules                              | low          | [agent-tooling.md](charters/agent-tooling.md)               |

`/review status` prints the live version: owned files and lines per shard, the last review, commits since, open follow-ups, and which shard runs next.

## A run

Type `/review` (the next shard) or `/review <shard>`. The run goes to the end without a question in the middle:

1. **Prepare** - on `main` it cuts `review/<shard>-<date>`; on another branch it stays, so several shards can stack before one release.
2. **Two reviewers at once** - the charter-driven `reviewer` subagent (read-only) and `second-opinion` (a different model family, through Copilot CLI) read every file the shard owns. Both are told what earlier reviews of the shard declined, and what other shards handed to it.
3. **Triage by the agent** - each finding becomes `fix`, `decline`, `resolve-only`, `handoff` or `escalate`. Declining about half is normal.
4. **Fixes** land in place, each runtime change with a CHANGELOG bullet.
5. **One question** - escalations only, in one batch.
6. **Finish** - refuses while a reviewer's report is missing or any finding, carried-in follow-up or escalation lacks a decision; then runs `make test-unit`, records the run in [`history.md`](history.md), runs `make lint` and commits.

Then `/release-auto` takes the branch to a PR as usual: its own second-opinion pass over the fixes, one Copilot review round, the integration tests.

## Cross-shard findings

A defect in a file another shard owns is **fixed now** when the fix is small and confirmed - ownership does not change whether something is a bug. When it needs the owner's charter to judge, spreads beyond one function, or could not be verified, it is **handed off**: a row in `history.md`'s "Open follow-ups", addressed to the owning shard. That shard's next run carries the row in to both reviewers and must decide it - `finish` will not record the run otherwise - and the row leaves the table. Shards with follow-ups waiting rank right after never-reviewed ones in the rotation.

## Layout

| Artifact                     | Lifetime  | Why                                                                        |
| ---------------------------- | --------- | -------------------------------------------------------------------------- |
| `shards.json`                | committed | What each shard owns and reads as context; what is skipped                 |
| `charters/<shard>.md`        | committed | What good looks like for the shard, and what not to flag                   |
| `history.md`                 | committed | Every run, every finding's decision, open hand-offs - visible on any clone |
| `.claude/agents/reviewer.md` | committed | The read-only reviewer                                                     |
| `.claude/skills/review/`     | committed | The `/review` skill and its `review.py` script                             |
| `.review/`                   | scratch   | One run's findings, decision log and intent; gitignored, wiped by `finish` |

Repo-wide "do not report" rules live in `REVIEW.md` (`.github/copilot-instructions.md`), which every reviewer reads, per-PR ones included.

## Charters

A charter has four parts: a summary of the shard and why it matters, **What good looks like**, **What NOT to flag**, and **References**. Files are not listed - `shards.json` owns that, so a charter cannot drift from the tree it describes.

Charters grow through use. When triage declines a finding that will be declined again - a deliberate decision, a convention the reviewer misread - the agent adds it to the charter's "What NOT to flag", or to `REVIEW.md` Author decisions when it holds repo-wide. A charter claim that contradicts `AGENTS.md` or `REVIEW.md` is fixed as a finding. `history.md` records each run's charter hash, so a changed charter lifts the shard in the rotation.

## Adding or splitting a shard

1. Add the entry to `shards.json`: `name`, `title`, `charter`, `blast_radius`, `owns`, `context`.
2. Write `charters/<name>.md` in the shape above.
3. Run `.claude/skills/review/scripts/review.py status` - it lists any file left without an owner or claimed by two shards at the same specificity. Keep a shard within about 6,500 lines including its tests; `status` flags one past that.

## PDCA mapping

| Phase | Per-PR cycle (daily)       | Standing review (periodic)                              |
| ----- | -------------------------- | ------------------------------------------------------- |
| Plan  | PR description, plan mode  | Charter                                                 |
| Do    | The PR diff                | (n/a - the code already exists)                         |
| Check | PR review (sees only diff) | Two reviewers read the whole shard against the charter  |
| Act   | Merge / request changes    | Agent triage, fixes, one question, then `/release-auto` |
