# Charter - `orchestration` shard (nix/setup.sh + phase library)

The orchestrator and its phase library are the spine that touches every install, upgrade, and rollback. A regression here breaks setup itself - and since the project's lint and test gates depend on a working environment, a broken orchestrator can mask its own regressions until much later. Reviewers should weight idempotency, error propagation, and phase-boundary contracts especially heavily.

## Scope

| File                             | Role                                                                              |
| -------------------------------- | --------------------------------------------------------------------------------- |
| `nix/setup.sh`                   | Slim ~110-line orchestrator; sources phase files in fixed order and runs them     |
| `nix/lib/io.sh`                  | Side-effect wrappers (`_io_run`, `_io_nix`, `_io_curl_probe`); test override seam |
| `nix/lib/phases/bootstrap.sh`    | Root guard, path/version resolution, nix/jq detection, ENV_DIR sync, arg parsing  |
| `nix/lib/phases/platform.sh`     | OS detection, overlay directory discovery, hook runner                            |
| `nix/lib/phases/scopes.sh`       | Load scopes, merge CLI flags, resolve dependencies, write `config.nix`            |
| `nix/lib/phases/configure.sh`    | GitHub CLI auth, git config, scope-based post-install                             |
| `nix/lib/phases/nix_profile.sh`  | Flake update, nix profile upgrade, MITM proxy cert detection                      |
| `nix/lib/phases/profiles.sh`     | bash/zsh/PowerShell shell profile setup                                           |
| `nix/lib/phases/post_install.sh` | Common post-install setup, nix garbage collection                                 |
| `nix/lib/phases/summary.sh`      | Mode detection and final status output                                            |

**Out of scope** (other shards): the user-facing `nx_*.sh` CLI surface (→ `nx-cli` shard), MITM cert handling specifics (→ `certs` shard), the per-scope post-install scripts under `nix/configure/` (→ orchestration touches them indirectly via `_io_run`, but their internal correctness belongs to the relevant feature shard).

## What "good" looks like

- **Each phase function obeys its declared `# Reads:` / `# Writes:` header comments.** A phase that mutates state not in its `Writes:` list, or reads state not in its `Reads:` list, has broken the documented contract - the contract is what makes the phase library testable.
- **`_io_*` wrappers are the ONLY place external commands are called from phase code.** No raw `nix`, `curl`, `git`, or `bash` invocations inside `phase_*` functions. The wrappers are the test seam; bypassing them means the test can't intercept the side effect.
- **Idempotency is byte-for-byte.** Running `nix/setup.sh` twice with the same flags produces the same on-disk state - same `config.nix`, same `flake.lock` if pinned, same managed blocks in profiles, same install record. CI verifies this on every PR; review checks for accidental sources of non-determinism (timestamps in output files, ordering-dependent hashes).
- **Errors propagate via `$?` - no `|| true` swallowing real failures.** `_io_run`'s try/catch semantics are the right pattern; bare `command || true` outside `_io_run` is suspect unless explicitly justified by an inline comment.
- **Phase ordering is sequential and forward-only.** bootstrap → platform → scopes → configure → nix_profile → profiles → post_install → summary. No phase reads state a later phase writes; if it does, the dependency direction is wrong.
- **Bash 3.2 compatibility is verified, not assumed.** The `check_bash32` hook gates every commit; review still checks that intent matches enforcement (e.g., a new helper that "feels" portable but uses `${var,,}` slips through if the hook hasn't been updated to scan it).
- **`set -euo pipefail` is on** at the top of every phase file. Scripts that intentionally allow unset vars must document why inline.

## What NOT to flag

- **The phase library architecture itself.** See [`docs/decisions.md` → "Why phase-based orchestration with side-effect stubs"](../../../docs/decisions.md#why-phase-based-orchestration-with-side-effect-stubs). Findings about "this would be cleaner as a single script" or "use a different test framework" are out of scope.
- **The function-redefinition testing pattern.** Tests override `_io_*` wrappers by re-defining functions before sourcing the phase under test. This is intentional and load-bearing.
- **`_io_run` capturing stderr to a temp file.** Necessary to preserve nix's progress bars on stdout while still surfacing errors on failure. Don't suggest "just redirect stderr inline."
- **The 110-line `nix/setup.sh` length.** It's deliberately thin - orchestration only, no logic. Adding logic to it (rather than to a phase) is the smell, not its current size.
- **bash 3.2 verbosity.** See [`docs/decisions.md` → "Why bash 3.2 compatibility"](../../../docs/decisions.md#why-bash-32-compatibility). `while IFS= read -r` instead of `mapfile` is intentional.
- **Anything already in [`design/reviews/accepted.md`](../accepted.md).** Cross-check before flagging.

## Severity rubric

| Level    | Definition                                                                                                                                | Examples                                                                                                                               |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| critical | Setup completes "successfully" but leaves state inconsistent (half-written `config.nix`, leaked process). A swallowed fatal error.        | Phase exits 0 after `nix profile install` failed; `config.nix` is half-written when the script is interrupted between two file writes. |
| high     | Idempotency broken (second run mutates state). Cross-phase data flow that violates declared `Reads:`/`Writes:`. `_io_*` wrapper bypassed. | Second run appends to a managed block instead of replacing; phase reads a variable another phase writes without declaring the dep.     |
| medium   | Error message lacks context to act on. Phase function lacks `Reads:`/`Writes:` headers. Missing `set -euo pipefail`.                      | `err "failed"` with no detail of what failed; new phase added without contract headers.                                                |
| low      | Stale comment, unused variable, naming inconsistency that doesn't affect behavior.                                                        | `# TODO: remove this once X` where X happened a year ago; `_helper_fn` defined but never called.                                       |

## Categories

| Category        | Use for                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------- |
| correctness     | The orchestrator does the wrong thing under some flag combination, platform, or partial state.     |
| security        | Privilege escalation, leaked secrets in logs, command injection via unquoted variables.            |
| maintainability | Hidden coupling between phases; missing or wrong `Reads:`/`Writes:` headers; phase doing too much. |
| testability     | A phase or helper cannot be unit-tested via the `_io_*` override pattern; missing test seam.       |
| docs            | Phase header comment is wrong; runnable-examples block is stale.                                   |

## References

- [`docs/decisions.md` → "Why phase-based orchestration with side-effect stubs"](../../../docs/decisions.md#why-phase-based-orchestration-with-side-effect-stubs)
- [`docs/decisions.md` → "Why bash 3.2 compatibility"](../../../docs/decisions.md#why-bash-32-compatibility)
- [`docs/decisions.md` → "Why bash end-to-end, not 'bootstrap in bash, implement in Python'"](../../../docs/decisions.md#why-bash-end-to-end-not-bootstrap-in-bash-implement-in-python)
- `ARCHITECTURE.md` - phase orchestration details (grep for the relevant section; do NOT read whole file)
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes for this shard

## Charter version

- v1 (2026-05-09) - initial draft, written before first review run. Expect refinement after the first `/review orchestration` cycle surfaces what the charter actually needs to constrain.
