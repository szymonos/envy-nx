# Decision Format

Decisions live in `design/decisions/` and use sequential numbering: `0001-slug.md`, `0002-slug.md`, etc.

Create the `design/decisions/` directory lazily - only when the first decision is needed.

## Template

```md
# {Short title of the decision}

{1-3 sentences: what's the context, what did we decide, and why.}

**Constraint:** {What the agent must or must not do. Concrete, actionable.}

**Scope:** {Which files or paths this applies to.}
```

The `**Constraint:**` field is what makes this agent-readable - it gives a direct instruction the agent can follow without reading the full rationale. The `**Scope:**` field enables lazy-loading: agents only read decisions whose scope matches the files they're touching.

## Optional sections

Only include these when they add genuine value. Most decisions won't need them.

- **Considered alternatives** - only when the rejected alternatives are worth remembering
- **Consequences** - only when non-obvious downstream effects need to be called out

## Numbering

Scan `design/decisions/` for the highest existing number and increment by one.

## INDEX.md

After writing or updating decision files, regenerate `design/decisions/INDEX.md`:

```md
# Decision Index

| # | Decision | Scope | File |
|---|----------|-------|------|
| 0001 | Bash 3.2 on nix-path scripts | `nix/**`, `.assets/lib/`, `.assets/config/shell_cfg/` | [0001](0001-bash-32-compat.md) |
| 0002 | Three package tiers | `nix/scopes/`, `.assets/provision/` | [0002](0002-three-package-tiers.md) |
```

Agents read the index to decide which decisions to load for the current task.

## Relationship to docs/decisions.md

`design/decisions/` is the **agent-readable** layer: short, constraint-focused, lazy-loadable. `docs/decisions.md` is the **human-readable** layer: full persuasion narratives with objections, counter-arguments, and enterprise off-ramps. They are related but independent - a decision may exist in one, the other, or both. No sync is required.

## When to write a decision

All three of these must be true:

1. **Hard to reverse** - the cost of changing your mind later is meaningful
2. **Surprising without context** - a future reader will look at the code and wonder "why on earth did they do it this way?"
3. **The result of a real trade-off** - there were genuine alternatives and you picked one for specific reasons

If a decision is easy to reverse, skip it - you'll just reverse it. If it's not surprising, nobody will wonder why. If there was no real alternative, there's nothing to record beyond "we did the obvious thing."

## Alternative capture: Codified-Decision trailer

When a decision crystallises during a PR rather than a grilling session, use a commit trailer:

```text
feat(scopes): add gcloud scope via tarball install

Codified-Decision(gcloud-tarball): gcloud is installed via the official
tarball, not via Nix, because Nix's google-cloud-sdk blocks
`gcloud components install` with a managed-package-manager marker.
```

The post-merge workflow creates the `design/decisions/NNNN-slug.md` file automatically from the trailer content.
