# Charter - `nx-cli` shard (sourced into user shells)

The `nx` CLI is sourced into every interactive bash and zsh on every login. It runs in the user's shell context, so variable leaks, surprising aliases, slow init, and zsh incompat all become daily user pain immediately. It's also the long-lived API users build muscle memory around - verb name churn is expensive. Bash 3.2 + zsh 5+ compat is non-negotiable; both are CI-gated.

## Scope

| File                           | Role                                                                                      |
| ------------------------------ | ----------------------------------------------------------------------------------------- |
| `.assets/lib/nx_pkg.sh`        | nx package-management verbs (search, install, remove, upgrade, list, prune, gc, rollback) |
| `.assets/lib/nx_scope.sh`      | nx scope/overlay/pin verbs; config-shape surface API                                      |
| `.assets/lib/nx_lifecycle.sh`  | nx tool-itself verbs (setup, self, doctor, version, help)                                 |
| `.assets/lib/nx_profile.sh`    | nx profile verb and managed-block rendering                                               |
| `.assets/lib/nx_doctor.sh`     | Health check command                                                                      |
| `.assets/lib/scopes.sh`        | Shared scope definitions, dependency resolution, install ordering                         |
| `.assets/lib/profile_block.sh` | Managed-block helper for shell rc files (bash 3.2 / BSD sed compatible)                   |
| `.assets/lib/helpers.sh`       | Shared helpers for provision, setup, lifecycle scripts                                    |

**Out of scope:** the orchestrator (→ `orchestration` shard), shell config templates that get sourced alongside `nx` (→ `config-templates` shard), the generated bash/zsh completer files (artifact of `nx_surface.json`; manual edits are caught by the `check-nx-generated` hook).

## What "good" looks like

- **All exported names follow the prefix convention.** Public verbs: `nx_*` (no underscore prefix). Private helpers: `_nx_*`. IO wrappers: `_io_*`. Scope helpers: `scope_*`. A function leaking into the user's shell without a prefix is a regression.
- **No leaked unprefixed variables after sourcing.** `set | grep -v '^_\|^nx_\|^scope_\|^[A-Z]'` should not show anything new attributable to nx-cli files. Use `local` aggressively in functions; for module-level state, use the `_nx_*` prefix.
- **Bash 3.2 + zsh 5+ both verified.** Both `check_bash32` and `check_zsh_compat` hooks gate commits. Review still checks that intent matches enforcement (e.g., a new helper added without thinking about zsh's word-splitting differences).
- **Sub-50ms cold-start cost when sourced.** No heavy work at source time - defer expensive work into verb functions. `nx <verb>` should feel instant for read-only verbs (`nx scope list`, `nx version`).
- **`nx_surface.json` is the single source of truth.** Verb list, flag definitions, completers, and help text all derive from it via `gen_nx_completions.py`. Hand-edits to the generated artifacts are caught by `check_nx_completions`.
- **Verb additions are forward-compatible.** Adding a new verb does not change the behavior of an existing one. Removing or renaming a verb is a breaking change and needs CHANGELOG + migration note.
- **Profile-block writes are idempotent.** `manage_block` in `profile_block.sh` produces byte-identical output on the second invocation; tests verify this.
- **No use of `read ... </dev/tty`** without the `# tty-ok` annotation (gated by `check_no_tty_read`).

## What NOT to flag

- **bash 3.2 verbosity.** See [`docs/decisions.md` → "Why bash 3.2 compatibility"](../../../docs/decisions.md#why-bash-32-compatibility). `while IFS= read -r` not `mapfile`; space-delimited strings not `declare -A`; `tr` not `${var,,}`.
- **The nx-as-shell-function (not Python CLI) choice.** See [`docs/decisions.md` → "Why bash end-to-end"](../../../docs/decisions.md#why-bash-end-to-end-not-bootstrap-in-bash-implement-in-python). Suggestions to "rewrite this in Python/Go/Rust for type safety" are out of scope.
- **`profile_block.sh`'s BSD-sed-only patterns.** macOS BSD sed has no `-i ''` requirement glitch; the helper deliberately uses temp-file + rename. Don't suggest GNU sed `-i` extensions.
- **The `_nx_*` private / `nx_*` public prefix convention itself.** Flag *violations* of the convention, not the convention.
- **Help text that's auto-generated from `nx_surface.json`.** Don't suggest hand-editing `.bash`/`.zsh` completer files or the `--help` output - change `nx_surface.json` and regenerate.
- **Anything already in [`design/reviews/accepted.md`](../accepted.md).**

## Severity rubric

| Level    | Definition                                                                                                                             | Examples                                                                                                                          |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| critical | A nx command silently mutates user state in a way that can't be undone via `nx rollback`. A leaked secret in nx output or shell state. | `nx install` writes `packages.nix` then crashes before backup; verbose-mode prints token from `gh_login_user`.                    |
| high     | nx breaks under bash 3.2 or zsh; a verb produces wrong output for a documented input; profile-block write becomes non-idempotent.      | `nx setup --remove <TAB>` completes nothing on zsh; `manage_block` appends instead of replaces on second run.                     |
| medium   | Surprise behavior (helper leaks variable into user shell); naming inconsistency that breaks the prefix convention; missing local.      | `_nx_resolve` accidentally exports `cur_scope` to the user's shell; new public verb named `nxScopeAdd` instead of `nx_scope_add`. |
| low      | Comment rot, help-text typo (in source, not generated), dead code, minor refactor opportunity.                                         | `# TODO: remove after migration to X` (where X happened); orphan helper used only by deleted code.                                |

## Categories

| Category        | Use for                                                                             |
| --------------- | ----------------------------------------------------------------------------------- |
| correctness     | A verb does the wrong thing under some input, flag combination, or shell.           |
| security        | Leaked secret, command injection via unquoted user input, surprising privilege use. |
| maintainability | Prefix-convention violation, missing `local`, hidden coupling between nx files.     |
| testability     | A function cannot be unit-tested in isolation; missing seam for the bats pattern.   |
| docs            | Source-level help text wrong or missing; runnable-examples block stale.             |

## References

- [`docs/decisions.md` → "Why bash 3.2 compatibility"](../../../docs/decisions.md#why-bash-32-compatibility)
- [`docs/decisions.md` → "Why bash end-to-end, not 'bootstrap in bash, implement in Python'"](../../../docs/decisions.md#why-bash-end-to-end-not-bootstrap-in-bash-implement-in-python)
- [`docs/decisions.md` → "Why managed blocks, not append-style profile injection"](../../../docs/decisions.md#why-managed-blocks-not-append-style-profile-injection)
- [`.claude/rules/cross-shell-parity.md`](../../../.claude/rules/cross-shell-parity.md) - `nx_profile.sh` pairs with pwsh's `_aliases_nix.ps1`; the rule documents the map and asymmetry handling
- `ARCHITECTURE.md` - search for `nx CLI` and `surface` sections
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes for this shard

## Charter version

- v1 (2026-05-09) - initial draft. Expect refinement after the first `/review nx-cli` cycle.
