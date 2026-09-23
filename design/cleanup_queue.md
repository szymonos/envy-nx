# Cleanup queue

Deferred removals of transitional code, migration shims, and compatibility
paths. Each item is safe to keep indefinitely but adds cognitive surface area.
Remove when the trigger condition is met.

## How to add an entry

1. Pick the next `CQ-NNN` ID.
2. Fill in the template: status, added date, trigger, scope, what to remove,
   verification steps.
3. Annotate the transitional code with `# CLEANUP: CQ-NNN` so it is
   grep-able and self-documenting.

## When to execute

Pick ONE signal per item (all are reasonable for a single-maintainer project):

- **Time-based (default):** 60-90 days after the change ships (>= 2 upgrade
  cadences for active users).
- **Version-based:** bake into the next major release.

---

## CQ-003: Migrate check_zsh_compat + check_bash32 to `_file_scopes.py`

- **Status:** open
- **Added:** 2026-06-14
- **Trigger:** when the next shell file is added/removed from the
  interactive-shell set (forcing a touch of all three regexes anyway),
  OR opportunistically alongside any zsh-compat fix
- **Scope:** 2 hook scripts + 1 module + ~2 pre-commit regex blocks

### Context

`tests/hooks/_file_scopes.py` was introduced alongside the new
`check_no_aliased_builtins` hook (v1.13.x) to centralize the
"interactively-sourced shell files" list. Today only the new hook imports
from it; the existing `check_zsh_compat` and `check_bash32` hooks still
maintain their own file lists via hand-written regexes in
`.pre-commit-config.yaml`.

The `check_zsh_compat` regex is silently UNDER-COVERING - it misses
`nx_doctor.sh`, `helpers.sh`, `certs.sh`, and `env_block.sh`, all of
which are sourced into the interactive shell (verified by tracing the
source chain from `~/.bashrc` -> `functions.sh` -> `certs.sh`, etc.).
Running `python3 -m tests.hooks.check_zsh_compat` against those four
files surfaces ~50 real violations (mostly bare `name() {` definitions)
that the rule would catch if the regex covered them.

### What to do

1. Widen `check_zsh_compat`'s file scope to import `INTERACTIVE_SHELL`
   from `tests/hooks/_file_scopes.py` (mirror the change already done in
   `check_no_aliased_builtins.py`).
2. Run `python3 -m tests.hooks.check_zsh_compat` against the widened set
   and fix each surfaced violation (mostly mechanical: `foo() {` -> `function foo() {`).
3. Update the `check-zsh-compat` regex in `.pre-commit-config.yaml` to
   match the new file list.
4. Optional follow-up: refactor `check_bash32` to use the same pattern.
   Its file list is larger (includes nix/setup-path subprocess scripts)
   and would need a second category in `_file_scopes.py` -
   `NIX_SETUP_PATH_PREFIXES` -- design sketch in the original
   `_file_scopes.py` draft (git history).
5. Optional follow-up: add a `gen_pre_commit_scopes.py` codegen script
   that rewrites the regexes in `.pre-commit-config.yaml` from the
   module, with a `check-pre-commit-scopes` drift hook (same pattern as
   `check-nx-generated`). This is only worth it if a third category is
   added.

### Verification

```bash
# Hook should report zero violations after the surfaced ones are fixed.
python3 -m tests.hooks.check_zsh_compat

# Pre-commit regex matches the same file set as the Python import.
make lint-all HOOK=check-zsh-compat

# Suite still green.
make lint && make test-unit
```

### Risk

**Low.** Pure additive coverage + mechanical fixes. The widened rule
catches latent zsh violations on files that today happen to work under
zsh by luck; making the rule fire catches the next regression.
