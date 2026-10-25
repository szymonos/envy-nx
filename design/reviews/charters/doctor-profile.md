# Charter - `doctor-profile`

`nx doctor` (`.assets/lib/nx_doctor.sh`), the renderers of the managed shell-rc blocks (`.assets/lib/nx_profile.sh`, `.assets/lib/profile_block.sh`), and the install record (`.assets/lib/install_record.sh`). Doctor is how a user - or an agent reading `--strict` - learns something is wrong; the managed blocks are what every shell sources at login; the install record is the fleet's audit trail.

## What good looks like

- **Every degraded state is detectable.** A check that cannot fail, or a failure with no `Fix:` hint when a clear fix exists, is a gap.
- **Doctor stays standalone.** It is copied to `~/.config/nix-env/` and must work after the repo clone is gone - no sourcing of repo-only helpers.
- **`--json` output is a stable schema**; a renamed field is a breaking change with a CHANGELOG note.
- **Managed blocks regenerate byte-identically.** PATH and env sections run in every shell; completion and prompt sections are gated on an interactive shell.
- **bash/zsh and PowerShell render the same content.** `_nx_render_nix_block` and `_nx_render_env_block` have counterparts in the `#region nix:*` blocks of `.assets/config/pwsh_cfg/_aliases_nix.ps1`; a deliberate asymmetry carries an inline comment.
- **The install record is written on success and failure** with version, scopes, timestamp and status, atomically.
- **Tests** cover each doctor check's pass, warn and fail paths, and block regeneration from a stale or hand-edited rc file.

## What NOT to flag

- **Managed-block sentinels as the idempotency mechanism** - see "Why managed blocks, not append-style profile injection".
- **pwsh aliases not gated on a TTY** - `REVIEW.md` Author decisions.
- **Doctor shelling out to `nx profile regenerate --dry-run`** rather than sourcing `helpers.sh` - it keeps doctor standalone.

## References

- `ARCHITECTURE.md` sections 3e, 3f and 13.6
- `.claude/rules/cross-shell-parity.md`
