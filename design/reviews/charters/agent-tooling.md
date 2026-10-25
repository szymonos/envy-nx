# Charter - `agent-tooling`

The agent skills (`.claude/skills/`), subagents (`.claude/agents/`), the rules that load when files are touched (`.claude/rules/`) and their tests. They decide how agents release, review and edit this repo, so a wrong instruction is followed confidently on every run.

## What good looks like

- **Every documented procedure works as written.** A command a SKILL.md tells the agent to run exists, takes those flags and exits as described.
- **Limits are enforced by scripts, not prose** - a cap, a gate or a required decision the agent could skip by ignoring a sentence is a gap.
- **Scripts are runnable standalone** - `uv run --script` shebang, PEP 723 block, `main(argv)`, timeouts on every subprocess - and write state atomically.
- **Agents' tool restrictions match their role** (the reviewer cannot edit).
- **Rules and skills agree with `AGENTS.md`, `ARCHITECTURE.md` and `REVIEW.md`**; a contradiction is a defect in whichever is wrong.
- **Tests** cover the scripts' pure logic and their git-touching paths in a scratch repo.

## What NOT to flag

- **Review skills installed per user** (`~/.claude/skills/second-opinion`, `address-pr-review`) rather than vendored - each skill skips that layer in one line when it is missing.
- **`release-auto` state and inputs being the agent's own** - `REVIEW.md` Author decisions.
- **Long SKILL.md judgment sections** - judgment is what earns its tokens; flag procedure left in prose.

## References

- `docs/standards.md` - backpressure
- `design/reviews/README.md`
