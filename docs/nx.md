# The `nx` CLI

Nix is wonderful and intimidating in equal measure. The flake API is sharp, the language is alien on first contact, and the day-to-day tasks every developer expects from a package manager - *install this, remove that, upgrade everything, undo what just broke* - are buried under terminology like *profiles*, *generations*, and *closures*. The result is a steep cliff between "nix is installed" and "nix is useful".

`nx` is the bridge. It is a single, friendly command that wraps everything this tool ships - Nix profile management, scope composition, shell-profile injection, certificate handling, and the source-repo lifecycle - behind verbs you already know from `apt`, `brew`, and `pip`.

```bash
nx install httpie       # add a package
nx remove httpie        # remove it
nx upgrade              # pull latest of everything
nx rollback             # back out the last change
nx list                 # what's installed and where it came from
nx search ripgrep       # find a package before installing
```

If you stopped reading here and only used those six commands, you would already be more productive with Nix than the official documentation lets on. But `nx` does more - it manages **scopes** (named bundles of related tools), runs **health checks**, exposes **install provenance**, and gives you a single entry point to **re-provision the whole environment** without remembering where you cloned the source repository six months ago. That is what the rest of this page covers.

!!! tip "The one mental model"

    `nx` writes plain text files in `~/.config/nix-env/` and asks Nix to make reality match. Every command is either *editing the desired state* (`install`, `remove`, `scope add`) or *querying / maintaining the actual state* (`list`, `doctor`, `gc`, `rollback`). There is no hidden database, no daemon, and no lock file you cannot read.

## Command surface at a glance

| Verb              | Closest analog         | What it does                                            |
| ----------------- | ---------------------- | ------------------------------------------------------- |
| `nx search`       | `apt search`           | Find a package in nixpkgs before installing             |
| `nx install`      | `apt install` / `brew` | Add packages by name (validates against nixpkgs)        |
| `nx remove`       | `apt remove`           | Drop user-installed packages                            |
| `nx upgrade`      | `apt upgrade`          | Pull latest nixpkgs and rebuild the profile             |
| `nx list`         | `apt list --installed` | Show every package with its scope/origin annotation     |
| `nx rollback`     | (unique)               | Revert to the previous Nix profile generation           |
| `nx scope`        | `apt-get groups`       | Manage named bundles of packages (curated or custom)    |
| `nx overlay`      | (unique)               | Inspect team/org customization layer                    |
| `nx pin`          | (unique)               | Lock nixpkgs to a specific commit for reproducibility   |
| `nx profile`      | (unique)               | Manage shell-rc managed blocks (bash/zsh)               |
| `nx setup`        | (unique)               | Re-run full provisioning (`nix/setup.sh` from anywhere) |
| `nx self`         | (unique)               | Update the source repository this tool lives in         |
| `nx doctor`       | `brew doctor`          | Health checks against the live environment              |
| `nx version`      | `apt-config`           | Show install provenance, scopes, and live config        |
| `nx prune`        | (unique)               | Remove orphaned `nix profile` entries                   |
| `nx gc` / `clean` | `apt clean`            | Garbage-collect old generations to reclaim disk         |

Run `nx help` for the inline cheat sheet, or `nx <command> help` for subcommand help.

## Tab completion (bash, zsh, PowerShell)

You should never have to memorize the verbs in the table above. `nx` ships native tab completion for every shell it supports - installed automatically by `nix/setup.sh` into the managed shell-rc block, no extra wiring required.

| Shell          | Source                                      | Style                                                                                                                            |
| -------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **bash**       | `.assets/config/shell_cfg/completions.bash` | Programmable completion (`compgen -W ...`) - completes verbs, subcommands, scope names from `config.nix`, and every `setup` flag |
| **zsh**        | `.assets/config/shell_cfg/completions.zsh`  | Native `_describe` style - each subcommand suggestion includes a one-line description                                            |
| **PowerShell** | `.assets/config/pwsh_cfg/_aliases_nix.ps1`  | `Register-ArgumentCompleter -Native` - same coverage as bash, integrated with PSReadLine                                         |

What you get out of the box:

```bash
nx <TAB><TAB>          # all top-level commands
nx scope <TAB>         # list  show  tree  add  edit  remove
nx scope edit <TAB>    # dynamic: only the scopes actually present in config.nix
nx setup --<TAB>       # every scope flag + --omp-theme, --starship-theme, --upgrade, --all, ...
nx self update --<TAB> # --force
```

The PowerShell completer fires inside both the native `pwsh` REPL and VS Code's PowerShell terminal. The dynamic scope completion (for `nx scope show|edit|remove`) reads `~/.config/nix-env/config.nix` directly, so it always reflects the current installation - including overlay scopes prefixed with `local_`.

!!! tip "Nothing to install"

    Completions live in the same managed shell-rc blocks that `nix/setup.sh` writes. If `nx <TAB>` doesn't fire, run `nx profile doctor` - a missing or duplicated block is the usual culprit, and `nx profile regenerate` fixes it without re-running setup.

## Package management - the apt/brew layer

This is the part that erases the Nix learning cliff. Four verbs cover 90% of daily use.

### `nx install <pkg>...`

```bash
nx install httpie
nx install ripgrep fd bat        # install several at once
```

Each name is **validated against nixpkgs before being added** to `packages.nix`, so typos and non-existent packages fail fast - not after a 30-second `nix profile upgrade`. If a package is already provided by an enabled scope, `nx` tells you and skips the duplicate.

The package list lives in plain Nix at `~/.config/nix-env/packages.nix`. You can read it, version-control it, or edit it by hand - but you almost never need to.

### `nx remove <pkg>...`

```bash
nx remove httpie
nx uninstall httpie              # alias
```

Removes packages from the user layer. If you ask to remove a package that's owned by a scope, `nx` refuses and points you at the right command (`nx scope remove ...`). This protects you from accidentally amputating a tool that something else depends on.

### `nx upgrade`

```bash
nx upgrade
nx update                        # alias
```

Runs `nix flake update` on the per-user lock, then `nix profile upgrade nix-env`. If `nx pin` is set, the upgrade respects the pinned `nixpkgs` revision instead. If the network is unreachable, the existing lock is kept and the upgrade is reported as a warning rather than a failure - so a flaky VPN doesn't leave you with a half-broken profile.

### `nx list`

```bash
$ nx list
  * bash-completion       (base)
  * git                   (base)
  * httpie                (extra)
  * kubectl               (k8s_base)
  * ripgrep               (shell)
  * uv                    (python)
```

Every installed package, annotated with where it came from: `(base)` for the always-on baseline, `(scope-name)` for scope-owned packages, `(extra)` for `nx install` additions, `(local)` for overlay scopes. No more guessing why a binary is on your PATH.

### `nx search <query>`

```bash
nx search ripgrep
```

Thin wrapper over `nix search nixpkgs --json` with the output reformatted into a readable list (name + version + description). Use it before `nx install` to confirm the upstream package name.

## Scopes - the curated bundles

A **scope** is a named set of packages that belongs together: `python` ships `uv` + `prek` + `python3`; `k8s_dev` ships `helm`, `flux`, `kustomize`, `trivy`, `kyverno`, and friends. Scopes are how teams agree on a tooling baseline without writing a wiki page nobody reads.

See [Customization](customization.md) for the full layering model. The day-to-day commands:

```bash
nx scope list                           # what's enabled
nx scope show k8s_dev                   # what packages does k8s_dev contain
nx scope tree                           # everything, expanded
nx scope add devtools httpie jq bat     # create a custom scope (overlay layer)
nx scope edit devtools                  # open in $EDITOR
nx scope remove devtools                # drop the scope
```

!!! info "Base vs overlay"

    Scopes shipped in this repository are read-only - `nx scope edit shell` will refuse and tell you to create an overlay scope instead. Custom overlay scopes get a `local_` prefix on disk so they cannot collide with base scope names. Adding a scope re-runs `nix profile upgrade` automatically, so the new packages land immediately.

### `nx overlay`

```bash
nx overlay
```

Shows the active overlay directory (defaults to `~/.config/nix-env/local/`, override with `$NIX_ENV_OVERLAY_DIR`) and the sync state of every overlay file: `(synced)`, `(differs)`, `(modified)`, `(source missing)`. Use it to spot drift between the source-of-truth overlay and what's actually installed.

## Lifecycle - the unique entry point

This is where `nx` does things `apt` cannot. Three verbs manage the **tool itself**, not just packages.

### `nx setup [flags...]`

```bash
nx setup                                # re-run with current scopes
nx setup --terraform --gcloud           # add scopes to the existing config
nx setup --upgrade                      # full upgrade pass
```

Re-runs `nix/setup.sh` from anywhere - no need to remember where you cloned the repo. The lookup order is:

1. `install.json:repo_path` if it points to a valid envy-nx checkout (respects forks and non-canonical clones).
2. Otherwise the canonical fallback `$HOME/source/repos/szymonos/envy-nx`. If that location doesn't exist, `nx setup` clones it on demand - no prompt, no surprises.
3. If neither is reachable, `nx setup` fails with a clear error.

When the recorded `repo_path` is stale (the directory was deleted or moved), `nx setup` falls back to the canonical location and prints a one-line notice so you know what happened. The new path is recorded in `install.json` automatically when `nix/setup.sh` exits - no manual cleanup.

### `nx self update [--force]`

```bash
nx self update                          # git pull --ff-only
nx self update --force                  # fetch + reset --hard origin/<branch>
nx self path                            # print the recorded repo path
```

Updates the source repository. Default is **safe** (`--ff-only` refuses to clobber local commits). `--force` resets to `origin/<current-branch>` for environments where the clone is treated as ephemeral. If the install was from a release tarball (no `.git`), `nx self update` offers to convert it to a git clone instead.

After an update, the in-shell `nx_main` function is invalidated so the next `nx` call re-sources the freshly-updated `nx.sh` - no shell restart needed.

### `nx version`

```bash
$ nx version
  envy-nx    v1.2.0 (rfr/envy-setup)
  Repo:      /home/me/source/repos/szymonos/envy-nx
  Installed: 2026-04-29 by me on Linux x86_64
  Scopes:    k8s_base k8s_dev python conda az terraform oh_my_posh shell pwsh rice
  Mode:      install
  Status:    success
  Nix:       Determinate Nix 3.18.1
```

Reads `~/.config/dev-env/install.json` and prints the full provenance: tool version, repo path and branch, install timestamp, active scopes, last-run status. The single command that answers "what is actually deployed here?" - useful for fleet visibility, support tickets, and post-incident audits.

### `nx doctor`

```bash
nx doctor
nx doctor --strict                      # warnings also exit non-zero (CI use)
nx doctor --json                        # machine-readable, no log file written
```

Read-only health checks that don't touch state. Failing or warning checks print a `Fix: <command>` hint indented under the check, so the common remediation (`nx self sync`, `nx profile regenerate`, `nx upgrade`, ...) is one read away. The full plain-text output is also written to `~/.config/dev-env/doctor.log` (overwritten per run); the path is printed only when there are failures or warnings - a clean run is silent about it.

| Check                   | Verifies                                                                                                                             |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `nix_available`         | `nix` resolves on PATH and reports version ≥ 2.18 (older nix produces cryptic flake errors)                                          |
| `flake_lock`            | `flake.lock` exists and the nixpkgs node is valid                                                                                    |
| `env_dir_files`         | `flake.nix`, `nx.sh`, `nx_{pkg,scope,profile,lifecycle,doctor}.sh`, `profile_block.sh`, `config.nix` present in `~/.config/nix-env/` |
| `install_record`        | `install.json` exists and the last run succeeded                                                                                     |
| `scope_binaries`        | Every binary declared by a scope's `# bins:` is found anywhere on `$PATH`                                                            |
| `scope_bins_in_profile` | Tighter: each `# bins:` binary must live under `~/.nix-profile/bin/` (proves nix provided it, not a system shadow)                   |
| `shell_profile`         | Exactly one managed block in the **invoking shell's** rc (bash → `.bashrc`, zsh → `.zshrc`)                                          |
| `managed_block_drift`   | Both managed blocks (`env:managed`, `nix:managed`) in the invoking shell's rc match what `nx profile regenerate` would write today   |
| `shell_config_files`    | Every `~/.config/shell/<file>` referenced by the rc resolves on disk                                                                 |
| `cert_bundle`           | Custom CA bundle present and VS Code env wired up                                                                                    |
| `vscode_server_env`     | `~/.vscode-server/server-env-setup` includes nix PATH                                                                                |
| `nix_profile`           | `nix-env` entry exists in `nix profile list`                                                                                         |
| `nix_profile_link`      | `~/.nix-profile` is a live symlink (not missing or dangling)                                                                         |
| `overlay_dir`           | Overlay directory is readable (when `NIX_ENV_OVERLAY_DIR` is set)                                                                    |
| `version_skew`          | Installed version matches the latest GitHub release (when `gh` is available)                                                         |

The `nx doctor --strict` form is what CI runs after every smoke test. Locally, run it whenever something feels off - it usually points at the broken edge in one line.

## Maintenance - every operation is reversible

Nix's killer feature is **profile generations**. Every change creates a new generation; the previous one stays on disk until you explicitly clean it up. `nx` exposes that as everyday verbs.

### `nx rollback`

```bash
nx rollback
```

Reverts to the previous profile generation. If `nx upgrade` brought in a broken kubectl, one command and a shell restart later, the old kubectl is back.

### `nx pin`

```bash
nx pin set                              # pin to whatever flake.lock currently has
nx pin set 1234abcd...                  # pin to a specific nixpkgs commit
nx pin show
nx pin remove                           # back to nixpkgs-unstable HEAD
```

Coordinates a team or fleet on a single nixpkgs revision without shipping a `flake.lock` in the repo. `nx upgrade` honors the pin transparently. Useful for reproducible builds, cohort rollouts, or freezing during a release window.

### `nx prune`

```bash
nx prune
```

Removes stale entries from `nix profile list` - leftovers from old experiments or aborted upgrades that aren't `nix-env` (the canonical profile this tool manages). Doesn't touch generations on disk; for that, use `gc`.

### `nx gc` (`nx clean`)

```bash
nx gc
```

`nix profile wipe-history` + `nix store gc`. Deletes old profile generations and runs the Nix store garbage collector. Reclaims disk space - safe to run anytime, but rolls back the rollback target.

### `nx profile`

```bash
nx profile doctor                       # check shell-rc managed blocks
nx profile regenerate                   # rewrite the blocks
nx profile uninstall                    # remove the blocks (keeps sourced files)
```

Manages the **managed blocks** that `nix/setup.sh` writes into `~/.bashrc` and `~/.zshrc`. See [Architecture → Managed block pattern](architecture.md) for the full design. The everyday case: if `nx doctor` reports a duplicate block, `nx profile regenerate` fixes it without re-running setup.

## Why `nx` matters for this tool

A traditional take on Nix gives you `nix profile add nixpkgs#httpie`, `nix flake update`, `nix profile rollback`, and a stack of overlay terminology. It works, but it leaks the implementation into every command.

`nx` lets you forget that:

- **No flake URLs to memorize.** `nx install httpie` is what you'd type with `apt`.
- **No "profile" vs "store" distinction at the surface.** `nx upgrade` does what you mean, regardless of which Nix concept is involved underneath.
- **No hunting for the source repo.** `nx setup` finds it, or clones the canonical location on demand.
- **Health, provenance, and rollback are first-class verbs.** `nx doctor`, `nx version`, `nx rollback` - each one is a single word, and each one answers a question you would otherwise google.
- **Imperative UX over declarative state.** You change *one* thing imperatively (`nx install`); `nx` updates the declarative file (`packages.nix`) on your behalf and applies it. Best of both worlds.

The cost of this convenience is roughly 1200 lines of bash, a handful of unit tests, and a hard rule that the tool stays bash 3.2 / BSD-sed compatible so it works on a stock macOS shell. The cost is paid once. The benefit compounds every time a developer runs `nx install` instead of reading the Nix manual.

## Reference

- Inline help: `nx help`, `nx <command> help`
- Source: [`.assets/lib/nx.sh`](https://github.com/szymonos/envy-nx/blob/main/.assets/lib/nx.sh)
- Architecture context: [Architecture](architecture.md), [Customization](customization.md)
- Tests: `tests/bats/test_nx_commands.bats`, `tests/bats/test_nx_doctor.bats`, `tests/bats/test_nx_scope.bats`
