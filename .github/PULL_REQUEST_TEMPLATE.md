# Pull request

<!--
Thanks for the contribution. A few notes:
- Keep the PR title short (< 70 chars); use the description for detail.
- Conventional commits style (feat:, fix:, docs:, chore:, refactor:) is the norm.
- Run `make lint` before pushing. Most local failures map to a specific hook
  ID listed in `make hooks`; debug a single hook with `make lint-all HOOK=<id>`.
-->

## Summary

<!-- 1-3 bullets describing what changed and why. -->

-

## Test plan

<!-- Checklist of how the change was verified. Tick the ones you actually ran. -->

- [ ] `make lint` clean
- [ ] `make test-unit` clean
- [ ] Manual smoke test (describe):

## Codified learnings

<!--
If this PR teaches a generalization future contributors should know - a
constraint, a non-obvious pattern, a class-of-bug to watch for - add a
`Codified-Learning:` trailer to one of the commits in this PR. The post-merge
`codify_learnings.yml` workflow scrapes those trailers and auto-appends
numbered entries to `design/lessons.md` via a separate auto-merging PR.

Example commit body:

    fix(profile): guard prompt() against re-init under OMP

    Codified-Learning: In pwsh profile scripts, never define `function Prompt`
    unconditionally - the last function definition wins, so a fallback prompt
    clobbers oh-my-posh's installed prompt.

If this PR genuinely teaches no generalization (trivial refactor, dep bump,
typo fix) AND it touches a high-leverage path (`.assets/lib/nx_*.sh`,
`nix/lib/phases/*.sh`, `tests/hooks/*.py`), add `# no-learning` anywhere in
the commit body to opt out of the pre-commit nudge.

See `CONTRIBUTING.md` § "Codifying learnings" for the full convention.
-->

- [ ] Trailer added to a commit, OR
- [ ] No generalization to codify (and `# no-learning` token added if hook nudged)

## Linked work

<!-- Cross-links: issue numbers, related PRs, decisions, lessons, charters. -->

- Closes: #
- Related: docs/decisions.md#, design/lessons.md#L-, design/reviews/charters/
