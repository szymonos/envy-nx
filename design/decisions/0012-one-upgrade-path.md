# One upgrade path through setup.sh

Updating an install took four commands that each refreshed a different part:
`nx setup` pulled the repo and the validated revision but kept packages where
they were, `nx setup --upgrade` also upgraded them, `nx upgrade` upgraded to
whatever revision was already on disk and never fetched a newer one, and
`nx self update` pulled and then re-ran the full setup. Users, and the author,
expected `nx setup` or `nx upgrade` alone to "really" upgrade. A user who only
ever ran `nx upgrade` stayed on one nixpkgs revision forever.

The split predates the validated revision (decision
[0011](0011-validated-nixpkgs-rev.md)). It existed so that re-running setup could
not pull an untested nixpkgs. Once every default upgrade lands on a revision CI
has built and installed on Linux and macOS, holding packages back protects
nothing.

**Decision:**

| Command                 | Does                                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------------------------------ |
| `nx upgrade [--latest]` | Runs `nix/setup.sh` from the recorded repo: pull, move to the validated revision, upgrade, refresh configs   |
| `nx setup [flags]`      | The same pipeline, plus scope and theme changes. `--upgrade` is accepted with a warning and does nothing     |
| `nx self update`        | Pulls the repo and runs `setup.sh --sync-only`: nx files and the revision file are synced, nothing installed |
| `nx pin set`            | The way to hold packages on one revision                                                                     |

Without the source repo on disk, `nx upgrade` falls back to an in-place upgrade
to the revision synced last, so the repo clone stays disposable.

**Both paths restore `flake.lock` when the profile never gets the new revision.**
`setup.sh` backs the lock up in `phase_nix_profile_update_flake`, discards the
backup once `phase_nix_profile_apply` succeeds, and restores it from the EXIT
trap otherwise - which covers a failed build and Ctrl-C alike. The in-place
`nx upgrade` runs the lock and the upgrade in a subshell whose INT/TERM trap
restores the lock and exits, because a `return` from a trap does not reliably
leave a bash function.

**Rejected:**

- **`nx upgrade` = nixpkgs HEAD, dropping `--latest`.** `upgrade` is the verb
  people type without reading the docs and repeat to each other. The lock
  restore only catches revisions that fail to build; a tool that builds and then
  misbehaves at runtime is exactly what the validated revision's test suite
  exists to catch. The unvalidated path stays behind a flag you have to type.
- **`--no-nix-upgrade` on setup.** `nx pin set` already holds packages, and it is
  durable instead of something to repeat on every run. Add the flag when someone
  asks for it.
- **`nx upgrade` = self update + package upgrade only.** It would leave
  `install.json` on the old version (so `nx doctor` keeps warning), and profile
  blocks and tool configs behind the packages.

**Consequences:**

- Every setup run touches the network to lock the revision. When the lock and
  config are unchanged, the narHash check skips `nix profile upgrade`, so a
  re-run stays fast.
- `nx self update` no longer re-renders profiles or runs migrations in later
  phases; they run on the next `nx upgrade`. The install record is not rewritten,
  so `nx version` and `nx doctor` report the last full setup until then.
- The setup summary mode `reconfigure` is gone; a run with no scope changes is
  `upgrade`.

**Scope:** `.assets/lib/nx_pkg.sh`, `.assets/lib/nx_lifecycle.sh`,
`.assets/lib/nx_rev.sh`, `nix/setup.sh`, `nix/lib/phases/nix_profile.sh`,
`nix/lib/phases/bootstrap.sh`
