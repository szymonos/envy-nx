# Recovery & inspection

Read when a driver command fails, or the user asks to undo or re-cut a release.
The driver is `.claude/skills/release-auto/scripts/release.py`; every verb
below is one of its subcommands.

- **`status`** - print the current state JSON.
- **`abort`** - soft-rewind this run's recut commits to the pre-recut HEAD
  recorded in the safety backup ref (work stays in the working tree, never
  `--hard`) and wipe `.release/`. The rewind fires only when the backup ref is
  an **ancestor of HEAD**; an orphaned backup from a divergent/shipped cycle,
  or no backup at all, wipes state without touching any commit. At a gate,
  resuming with `{"abort": true}` is equivalent.
- **`start --reopen --version <X.Y.Z>`** - re-cut an already-cut+pushed release
  that has **no new changes**, e.g. to fold coda follow-up commits (or a fix
  for a failed integration run) back into clean per-group commits. The previous
  plan is seeded, so this is an edit, not a re-derivation. Skips the version
  bump and `make upgrade`, lints with `lint-diff`, then runs the normal
  phase-1 → recut → push flow; the push is a force-push. Requires `.release/`
  to be absent.
- **Orphaned state from a shipped cycle** - when leftover state's version is
  already tagged, `start` refuses and names `abort`. Run it: it is
  ancestor-guarded, so it will not rewind the shipped release.
- **HEAD moved** - `resume`, `recut` and `push` refuse if HEAD changed under
  the orchestrator (a manual commit or reset). Inspect `git log`; `abort` and
  `start` fresh if the move was intentional.
- **Safety backup ref** - `refs/release-backup/<version>` records the pre-recut
  HEAD. It survives a failure for inspection (`git log refs/release-backup/<version>`)
  and is deleted on a clean finish.
- **A failed recut** - pre-validation errors (orphan path, empty group) exit
  before touching git. Anything later, including a `lint-diff` failure,
  soft-rewinds to the pre-recut HEAD and re-raises: git is never left
  half-mutated and uncommitted work is never lost.
