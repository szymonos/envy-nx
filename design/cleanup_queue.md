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

## CQ-001: Marker rename migration code

- **Status:** open
- **Added:** 2026-05-02
- **Trigger:** 60-90 days after v1.5.0 (rename shipped 2026-05-02)
- **Scope:** 9 hunks across 8 files, annotated with `# MIGRATION:`

### Context

The managed-block rename (`nix-env managed` -> `nix:managed`,
`managed env` -> `env:managed`) shipped in v1.5.0. Transitional code paths
silently strip legacy-named blocks, count both markers as equivalent in
`nx doctor`, and remove both names in `nix/uninstall.sh`.

### What to remove

#### 1. `.assets/lib/nx_profile.sh` - `_nx_profile_regenerate`

Remove the legacy marker constants and the strip-before-write block.

Lines ~166-194 (the `# MIGRATION:` block). After cleanup the function
keeps only the new marker constants (`_nix_marker="nix:managed"`,
`_env_marker="env:managed"`) and writes them directly.

#### 2. `.assets/lib/nx_profile.sh` - `_nx_profile_dispatch`

Remove the legacy marker constants and simplify the doctor + uninstall
arms back to single-marker logic.

- Remove `_pb_legacy_marker` / `_pb_legacy_env_marker` declarations
  (~lines 226-227 + comment block above them)
- Replace the `_pb_count_either` helper + `_pb_doctor_one` indirection
  with the simpler `grep -cF "# >>> $marker >>>"` count that the
  pre-rename code used. The whole `_pb_count_either` function and its
  `_pb_doctor_one` wrapper exist only because legacy and new counts
  needed to be summed.
- In the `uninstall` arm, drop the two extra `manage_block ...
  legacy_marker remove` calls (~lines 288-290).

#### 3. `.assets/lib/env_block.sh`

Remove `ENV_BLOCK_LEGACY_MARKER="managed env"` declaration and its
preceding `# MIGRATION:` comment block (~lines 14-18).

#### 4. `.assets/setup/setup_profile_user.zsh`

Remove the strip-before-write block (~lines 104-107):

```zsh
# MIGRATION: strip legacy-named block before writing the new one ...
if grep -qF "# >>> $ENV_BLOCK_LEGACY_MARKER >>>" "$HOME/.zshrc" 2>/dev/null; then
  manage_block "$HOME/.zshrc" "$ENV_BLOCK_LEGACY_MARKER" remove
fi
```

The script then just writes the new block via `manage_block ... upsert`.

#### 5. `.assets/lib/nx_doctor.sh` - `_check_shell_profile`

Replace the dual-count with a single `grep -cF '# >>> nix:managed >>>'`.
Drop the `_legacy_count` line and the comment block explaining the
transition (~lines 243-251). The simpler single-line count is what the
pre-rename code looked like.

#### 6. `nix/uninstall.sh`

- Remove `BLOCK_MARKER_LEGACY="nix-env managed"` constant + comment
  (~lines 126-129).
- In `run_phase1`, simplify the for-loop over markers back to a
  single-marker invocation (`manage_block "$rc" "$BLOCK_MARKER" remove`).
  The `for marker in "$BLOCK_MARKER" "$BLOCK_MARKER_LEGACY"; do` loops
  in both the `manage_block` branch and the `awk` fallback collapse.

Note: prose comments referring to "nix-env managed environment"
elsewhere in `uninstall.sh` are about the **`nix-env` profile**
(the actual nix profile name in `nix profile list`), not the marker.
Leave those alone.

#### 7. `.assets/docker/Dockerfile.test-nix`

Drop the legacy marker assertion line (~line 79):

```dockerfile
&& ! grep -qF '# >>> nix-env managed >>>' "$HOME/.bashrc" \
```

Keep the `! grep -qF '# >>> nix:managed >>>'` assertion.

#### 8. `tests/bats/test_profile_migration.bats`

Remove three migration-specific tests (helper + 3 tests):

- `_write_legacy_marker_bashrc()` helper (~lines 75-95)
- `@test "profile doctor passes for users with legacy marker names ..."` (~lines 110-122)
- `@test "profile regenerate migrates legacy marker names to nix:managed / env:managed"` (~lines 176-200)
- `@test "profile uninstall also removes legacy-named blocks (transitional users)"` (~lines 215-225)

The remaining tests in `test_profile_migration.bats` stay - they test
current behavior, not migration.

#### 9. `.github/workflows/test_linux.yml` + `test_macos.yml`

In both files, find the `Verify uninstaller (env-only)` step and remove
the legacy assertion (~6 lines):

```yaml
if grep -qF '# >>> nix-env managed >>>' ~/.bashrc; then
  echo "ERROR: legacy nix-env managed block still present"
  exit 1
fi
```

Keep the `'# >>> nix:managed >>>'` assertion.

### Verification

```bash
# Legacy marker strings gone
git grep -nE 'nix-env managed|managed env|LEGACY_MARKER|legacy.*marker' \
  .assets/ nix/ wsl/ modules/ .github/

# All MIGRATION: annotations from #11 gone
git grep -n 'MIGRATION:' .assets/ nix/

# Tests pass
make lint && make test-unit
```

### Risk

**Low.** Purely code deletion. Users who skipped 2+ release cycles will
have legacy blocks that the cleanup release no longer migrates. Mitigations:

- CHANGELOG `Action required` note tells them how to recover.
- `nx doctor`'s `shell_profile` check will FAIL cleanly (new marker
  missing) with the existing `Fix: run nx profile regenerate` hint.

### CHANGELOG framing

Under `### Removed`:

> Removed transitional migration code for the `nix:managed` / `env:managed`
> marker rename (shipped in v1.5.0). `nx profile regenerate`, `nx doctor`,
> `setup_profile_user.zsh`, and `nix/uninstall.sh` no longer recognize the
> pre-rename names (`nix-env managed` / `managed env`).

---

## CQ-002: `do-linux` module cleanup

- **Status:** open
- **Added:** 2026-06-13
- **Trigger:** 60-90 days after v1.12.0 (rename ships with this release)
- **Scope:** 1 file

### Context

The vendored PowerShell module `do-linux` was renamed to `do-unix` in
v1.12.0. A transitional guard in `.assets/setup/setup_common.sh` removes
the old `do-linux` module from the user's PSModulePath during post-install:

```bash
# remove legacy do-linux module (renamed to do-unix)
_io_pwsh_nop -c "if (Get-Module do-linux -ListAvailable) { .assets/scripts/module_manage.ps1 do-linux -Delete }" || true
```

After the migration window, the old module will not exist on any active
install and the guard becomes dead code.

### What to remove

#### 1. `.assets/setup/setup_common.sh`

Delete the two-line `do-linux` cleanup block (the comment + the
`_io_pwsh_nop` call). Currently at lines 70-71.

### Verification

```bash
# No do-linux references remain (except CHANGELOG history)
git grep -n 'do-linux' .assets/ nix/ modules/ tests/

# Tests pass
make lint && make test-unit
```

### Risk

**Negligible.** Users who have not run setup since v1.12.0 will simply
retain an unused `do-linux` module in their PSModulePath. It causes no
conflicts - PowerShell loads modules by name, and nothing imports
`do-linux` anymore.

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
