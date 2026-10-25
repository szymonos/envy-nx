# Charter - `scopes`

A scope is a four-tuple: its `.assets/lib/scopes.json` entry, its `nix/scopes/<name>.nix` package list, its dependency rules and its `# bins:` declaration - plus an optional `nix/configure/<name>.sh` post-install hook and `*_remove.sh` removal hook. `nix/flake.nix` assembles the profile from them, and `nix/nixpkgs_rev.json` pins the validated nixpkgs revision. A wrong entry here installs the wrong thing on every machine that selects the scope.

## What good looks like

- **The four-tuple agrees.** `validate_scopes.py` catches a missing piece; review checks meaning - a `# bins:` list naming binaries the package does not ship, a dependency rule missing a transitive dep (resolution is single-pass), an `install_order` gap.
- **The `# bins:` tier fits how the binary arrives:** unmarked when nix installs it, `%` when a manager installs it outside the profile, `(external-installer)` for an empty scope.
- **Configure hooks are rerunnable** and do not wrap commands in `_io_*` (they already run under `_io_run`).
- **Removal hooks prompt before deleting user state and honour `--unattended`.**
- **macOS and Linux arms differ only where the platform does** (docker, playwright, zsh system-prefer), each difference visible in the scope file.
- **`flake.nix` keeps one atomic `buildEnv`**, skips a missing scope file silently (overlays rely on it), and applies `patchPwsh` and `demote` to every package.
- **PowerShell scope parsing** (`modules/utils-setup/Functions/scopes.ps1`) resolves the same set as `.assets/lib/scopes.sh` for the same input.
- **Tests** cover dependency resolution, mutual exclusivity of the prompt engines, and each configure and remove hook's prompt and unattended paths.

## What NOT to flag

- **No repo `flake.lock`** - `nix/nixpkgs_rev.json` pins the revision (decision 0011).
- **Empty scopes** (`docker` on Linux, `conda`, `distrobox`) - they exist to trigger their configure hook and to be recorded.
- **Unfree off by default** and terraform via tfswitch - see "Why unfree packages are opt-in, not default".
- **jq bootstrapped through `base_init.nix`** - see `ARCHITECTURE.md` section 5, "Bootstrap dependency".

## References

- `ARCHITECTURE.md` sections 3b, 4, 5 and 6.1
- `docs/decisions.md` - three package tiers, unfree opt-in, nixpkgs-unstable
