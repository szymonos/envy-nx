# Charter - `orchestration`

`nix/setup.sh` and its phase library touch every install, upgrade and rollback; `nix/uninstall.sh` undoes them, and the upgrade walk proves an old install still upgrades to HEAD. A regression here breaks setup itself - and since the lint and test gates need a working environment, a broken orchestrator can hide its own regressions. Weight idempotency, error propagation and phase-boundary contracts heavily.

## What good looks like

- **Each phase obeys its `# Reads:` / `# Writes:` header.** A phase touching state its header does not declare has broken the contract that makes the library testable.
- **Phase code calls external commands only through `_io_*` wrappers** (`nix/lib/io.sh`) - the test seam. Configure scripts run under `_io_run` and must not wrap again.
- **Idempotency is byte-for-byte.** A second run with the same flags leaves the same `config.nix`, managed blocks and install record. Look for non-determinism: timestamps in output files, ordering-dependent output.
- **Errors propagate.** No `|| true` swallowing a real failure outside `_io_run` without an inline reason; no phase exiting 0 after a failed `nix profile` step.
- **Phases run forward only:** bootstrap -> platform -> scopes -> configure -> nix_profile -> profiles -> post_install -> summary. No phase reads what a later one writes.
- **`set -eo pipefail` without `-u`** in nix-path files (bash 3.2 treats an empty array as unset under `-u`).
- **`nix/uninstall.sh --env-only` removes only nix-managed state** (`nix:managed` blocks, `nix:`-prefixed pwsh regions) and `--dry-run` previews all of it.
- **The upgrade walk exercises the real user path** - install at the old tag, `nx setup` at HEAD, verify - and fails fast at the first broken version.
- **Tests** stub only the `_io_*` side effects, never the logic under test, and cover partial-state and failure paths, not only the happy path.

## What NOT to flag

- **The phase library architecture and function-redefinition stubs** - see `docs/decisions.md` "Why phase-based orchestration with side-effect stubs".
- **`_io_run` capturing stderr to a temp file.** It keeps nix's progress bars on stdout while still surfacing errors.
- **`nix/setup.sh` being thin.** Logic added to it, not its size, is the smell.
- **bash 3.2 verbosity** (`while IFS= read -r` instead of `mapfile`) - see "Why bash 3.2 compatibility".

## References

- `ARCHITECTURE.md` sections 3a, 5 and 7 (grep the section; do not read the whole file)
- `docs/decisions.md` - phase orchestration, bash 3.2, bash end-to-end
