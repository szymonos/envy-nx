# Marker rename cleanup plan (#11 follow-up)

_Created: 2026-05-02 (post-rename ship)_
_Trigger: when the install base has had time to migrate (see "When to execute")_
_Owner: maintainer decision - this is a one-shot cleanup_

## Context

Item #11 ("Rename managed blocks: `nix:managed` + `env:managed`") shipped in
`0413ac6` on 2026-05-02. The new marker convention matches the PowerShell
`#region nix:*` convention and eliminates the old word-order confusion
(`nix-env managed` vs `managed env`).

To avoid stranding existing users with duplicate or unrecognized blocks,
the rename was shipped with **transitional code paths** that:

- silently strip legacy-named blocks before writing the new ones
  (`_nx_profile_regenerate`, `setup_profile_user.zsh`)
- count both old and new markers as equivalent so `nx doctor` doesn't
  flag valid installs that haven't migrated yet as broken
- remove both names in `nix/uninstall.sh` so users who upgraded but
  never regenerated still get cleaned up

Each leftover is annotated with `# MIGRATION:` so they're easy to grep
for and self-documenting. They're safe to keep indefinitely (they cost nothing
at runtime besides one extra `grep -cF` per check) but they add
cognitive surface area: every reader of `nx_profile.sh` has to mentally
filter out the legacy paths.

This plan describes how to remove them when they're no longer needed.

## When to execute

Pick ONE of these signals; all are reasonable for a single-maintainer
project. The maintainer-trust assumption (per `docs/decisions.md` -
"setup runs are tested released versions") means a fast cadence is OK.

### Option A: Time-based (recommended, simplest)

**Wait 60-90 days after the rename release ships.** That's >= 2 typical
upgrade cadences for active users. By then anyone who runs `nx upgrade`
or `nx setup` periodically has been auto-migrated. Document the cleanup
release as "if you haven't run `nx setup` since YYYY-MM-DD, do that
first" in the CHANGELOG.

### Option B: Version-based

**Bake into the next major release** (e.g., 2.0.0). Signals "we may
break old configs". Coupled with other intentional break-compat
changes if any are queued up.

### Option C: Telemetry-based (not viable today)

If `install.json` provenance ever reaches a central collector, gate
the cleanup on "<5% of running installs are pre-rename version". Not
worth building infrastructure for one cleanup.

**My pick: Option A**, dated either at the time of writing or whenever
the next minor release lands - whichever comes second.

## What to remove

9 hunks across 8 files. All annotated with `# MIGRATION:` for grep-ability
(except the integration workflows in §9, which carry an inline comment).

### 1. `.assets/lib/nx_profile.sh` - `_nx_profile_regenerate`

Remove the legacy marker constants and the strip-before-write block.

Lines ~166-194 (the `# MIGRATION:` block). After cleanup the function
keeps only the new marker constants (`_nix_marker="nix:managed"`,
`_env_marker="env:managed"`) and writes them directly.

### 2. `.assets/lib/nx_profile.sh` - `_nx_profile_dispatch`

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

### 3. `.assets/lib/env_block.sh`

Remove `ENV_BLOCK_LEGACY_MARKER="managed env"` declaration and its
preceding `# MIGRATION:` comment block (~lines 14-18).

### 4. `.assets/setup/setup_profile_user.zsh`

Remove the strip-before-write block (~lines 104-107):

```zsh
# MIGRATION: strip legacy-named block before writing the new one ...
if grep -qF "# >>> $ENV_BLOCK_LEGACY_MARKER >>>" "$HOME/.zshrc" 2>/dev/null; then
  manage_block "$HOME/.zshrc" "$ENV_BLOCK_LEGACY_MARKER" remove
fi
```

The script then just writes the new block via `manage_block ... upsert`.

### 5. `.assets/lib/nx_doctor.sh` - `_check_shell_profile`

Replace the dual-count with a single `grep -cF '# >>> nix:managed >>>'`.
Drop the `_legacy_count` line and the comment block explaining the
transition (~lines 243-251). The simpler single-line count is what the
pre-rename code looked like.

### 6. `nix/uninstall.sh`

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

### 7. `.assets/docker/Dockerfile.test-nix`

Drop the legacy marker assertion line (~line 79):

```dockerfile
&& ! grep -qF '# >>> nix-env managed >>>' "$HOME/.bashrc" \
```

Keep the `! grep -qF '# >>> nix:managed >>>'` assertion - that's the
real check.

### 8. `tests/bats/test_profile_migration.bats`

Remove three migration-specific tests (helper + 3 tests):

- `_write_legacy_marker_bashrc()` helper (~lines 75-95)
- `@test "profile doctor passes for users with legacy marker names ..."` (~lines 110-122)
- `@test "profile regenerate migrates legacy marker names to nix:managed / env:managed"` (~lines 176-200)
- `@test "profile uninstall also removes legacy-named blocks (transitional users)"` (~lines 215-225)

These exist to prove the migration path works; once the migration code
is gone, the tests are dead weight.

The remaining tests in `test_profile_migration.bats` (regenerate
preserves user content, doctor passes / fails, uninstall removes
managed blocks) stay - they test current behavior, not migration.

### 9. `.github/workflows/test_linux.yml` + `test_macos.yml`

The integration-test uninstaller verification step contains a defensive
assertion that `nix/uninstall.sh` removed both the new `nix:managed`
block AND the legacy `nix-env managed` block. Added in `1224bb8` to
catch regressions while the dual-marker uninstall logic was live.

In both files, find the `Verify uninstaller (env-only)` step and remove
the legacy assertion (~6 lines):

```yaml
if grep -qF '# >>> nix-env managed >>>' ~/.bashrc; then
  echo "ERROR: legacy nix-env managed block still present"
  exit 1
fi
```

Keep the `'# >>> nix:managed >>>'` assertion - that's the real check.
Once `nix/uninstall.sh` no longer touches the legacy marker (per §6),
the legacy assertion is dead weight: there is no codepath that could
ever leave the legacy block in `~/.bashrc` since CI starts from a fresh
runner image where the legacy block was never written.

## Verification

After the cleanup, every one of these greps should return zero hits in
the source tree:

```bash
# Should return nothing - legacy marker strings gone
git grep -nE 'nix-env managed|managed env|LEGACY_MARKER|legacy.*marker' \
  .assets/ nix/ wsl/ modules/ .github/

# All MIGRATION: annotations from #11 should be gone (other MIGRATION:
# tags from future cleanups may exist; sanity-check the diff catches
# only the rename-related ones).
git grep -n 'MIGRATION:' .assets/ nix/

# Smoke: the test suite still passes
bats tests/bats/

# Smoke: the uninstaller still removes a current-format installation
make test-nix
```

## CHANGELOG framing

Add under `## [Unreleased]` `### Removed`:

> - Removed transitional migration code for the `nix:managed` /
>   `env:managed` marker rename (`#11`, shipped in vX.Y.Z on YYYY-MM-DD).
>   `nx profile regenerate`, `nx doctor`, `setup_profile_user.zsh`, and
>   `nix/uninstall.sh` no longer recognize the pre-rename names
>   (`nix-env managed` / `managed env`).
>
>   **Action required if you have not run `nx setup` / `nx upgrade` /
>   `nx profile regenerate` since vX.Y.Z**: your shell rc still has the
>   old block names. Either upgrade through the rename release first
>   (run `nx setup` while still on vN-1), or manually delete the old
>   `# >>> nix-env managed >>>` and `# >>> managed env >>>` blocks
>   from `~/.bashrc` / `~/.zshrc` and run `nx profile regenerate`.

## What stays

- The new marker names (`nix:managed`, `env:managed`) - permanent.
- ARCHITECTURE.md §3e - already describes only the new names; the
  legacy-name footnote in the alias-routing list can be dropped at
  cleanup time but it's a one-line edit.
- §7.9 (`read </dev/tty` recipe) and the `check-no-tty-read` hook -
  unrelated to this cleanup.

## Risk assessment

**Low.** The change is purely code deletion. The ONLY user-visible
risk is users who skipped 2+ release cycles - they'll have legacy
blocks that the cleanup release no longer migrates. Mitigations:

- The CHANGELOG `Action required` note tells them how to recover.
- `nx doctor`'s `shell_profile` check, after cleanup, will FAIL
  cleanly (the new marker is missing) with the existing
  `Fix: run nx profile regenerate` hint - the hint correctly points
  at the right command. The user runs regenerate, the OLD blocks
  stay (no migration), but the NEW blocks are added alongside them.
  Their shell rc temporarily has both old and new blocks until they
  manually clean up the old. Annoying but not broken.

The one foot-gun: `nx profile uninstall` after cleanup won't remove
old-named blocks anymore. Document in the cleanup CHANGELOG: "if you
ran `nx profile uninstall` after a long time without regenerate, you
may need to manually delete pre-rename blocks from your rc files."
