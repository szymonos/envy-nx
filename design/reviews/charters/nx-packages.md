# Charter - `nx-packages`

The `nx` verbs that change what is installed: `nx install` / `nx remove` (`.assets/lib/nx_pkg.sh`), `nx scope` and overlays (`.assets/lib/nx_scope.sh`), and the lifecycle verbs - setup, upgrade, pin, rollback, self update (`.assets/lib/nx_lifecycle.sh`). Each one writes durable state under `~/.config/nix-env/` that the next `nix/setup.sh` run reads back.

## What good looks like

- **State files are written atomically** (temp file, then `command mv -f`) and never left half-written when a verb fails.
- **A verb that edits `packages.nix`, `config.nix` or the overlay set leaves them valid nix** that the flake can evaluate, and reports what changed.
- **Upgrade and pin respect the validated revision** in `nix/nixpkgs_rev.json` unless the user opts out (`--latest`), and restore the previous `flake.lock` when the profile never receives the new one.
- **Overlays stay optional.** Nothing costs a user who has no overlay; a missing or broken overlay is reported, not fatal to unrelated verbs.
- **Rollback names the generation it returns to** and leaves the profile usable.
- **Same prefix, bash 3.2 and zsh rules as `nx-core`** - these files are sourced into the user's shell too.
- **Tests** cover each verb's write path, its failure path, and a second identical invocation.

## What NOT to flag

- **One atomic `buildEnv` for every layer** - see `ARCHITECTURE.md` section 4.
- **No repo `flake.lock`** (decision 0011) and the single upgrade path (decision 0012).
- **Overlay subscriptions running no hooks** - decision 0013.

## References

- `ARCHITECTURE.md` sections 3c, 4, 5 and 13.3
