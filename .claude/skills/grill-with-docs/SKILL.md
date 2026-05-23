---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and writes agent-readable decisions to design/decisions/ as they crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
disable-model-invocation: true
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

Agent-readable decisions live in `design/decisions/`:

```text
/
├── AGENTS.md                      <- agent entry point (auto-loaded)
├── ARCHITECTURE.md                <- how things connect (lazy-loaded)
├── design/
│   ├── decisions/                 <- agent-readable decisions (this skill writes here)
│   │   ├── INDEX.md               <- auto-generated scope index
│   │   ├── 0001-slug.md
│   │   └── 0002-slug.md
│   └── lessons.md                 <- operational learnings (auto-populated via trailers)
└── docs/
    └── decisions.md               <- human-readable decision narratives (manual, separate)
```

The `design/decisions/` directory contains short, agent-optimised decision records. The human-readable `docs/decisions.md` is a separate document maintained by the author when a decision is worth the full persuasion narrative. They are related but independent - no sync required.

### Two capture paths for decisions

1. **This skill** writes `design/decisions/NNNN-slug.md` directly during the grilling session (primary path for architectural decisions).
2. **`Codified-Decision:` commit trailer** on a PR triggers a post-merge workflow that creates the file automatically (same pattern as `Codified-Learning:` trailers for `design/lessons.md`).

Both paths produce the same file format in the same directory. Use the trailer when a decision crystallises during a PR rather than a grilling session.

## During the session

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' - do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible - which is right?"

### Write decisions to design/decisions/

When a decision crystallises during the session, write it to `design/decisions/NNNN-slug.md` immediately. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).

After writing or updating decision files, regenerate `design/decisions/INDEX.md` - a scope-indexed table that agents read to decide which decisions to lazy-load.

### Offer decisions sparingly

Only offer to create a decision record when all three are true:

1. **Hard to reverse** - the cost of changing your mind later is meaningful
2. **Surprising without context** - a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** - there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the decision. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).
