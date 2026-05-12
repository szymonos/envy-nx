# Follow-ups

Tracked design ideas that are noted but not scheduled. New items append to the
top with a date stamp; remove an item when it lands or is rejected (capture
the rationale in `docs/decisions.md` if rejected).

## `nx upgrade --all` - refresh non-Nix tools alongside Nix profile

**Date noted:** 2026-05-12

`nx upgrade` today swaps the nix-env generation. Tools installed outside Nix -
currently `az` (via uv) and `gcloud` (via the official tarball, planned) - are
not refreshed by that path. Each has its own update mechanism:

- `az` -> `uv tool upgrade azure-cli`
- `gcloud` -> `gcloud components update --quiet`

Proposal: an `nx upgrade --all` flag that, after the standard nix-profile
upgrade, iterates through the active scopes and runs each tool's native
upgrade verb. Surface a one-line warning before the run that this can take
several minutes (gcloud component refresh is the slow leg) and require the
flag explicitly so the default `nx upgrade` stays fast and offline-friendly.

Open questions for when this gets picked up:

- Do we model this as a generic "post-upgrade hook per scope" (extensible to
  any future non-Nix tool) or hand-wire the az and gcloud cases?
- Should `--all` also trigger `gh extension upgrade --all` or similar?
- What's the failure mode when a single tool's upgrade fails - abort, warn
  and continue, or aggregate and report at the end?

Defer until at least one user asks for it; the manual `gcloud components
update` and `uv tool upgrade azure-cli` paths are well-understood.
