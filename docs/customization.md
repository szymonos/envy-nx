# Customization

The tool is designed for customization at three levels - from individual developers adding a package to organizations distributing standardized environments - without forking the base repository.

## Package layers

Packages are assembled from four layers, evaluated bottom-up by the Nix flake. All layers merge into a single `buildEnv` - one nix profile entry, one `nix profile upgrade` to apply. No layer can shadow or break another.

```mermaid
graph TD
    subgraph "Nix buildEnv (single profile entry)"
        L4["Layer 4: Extra packages
        packages.nix - nx install/remove"]
        L3["Layer 3: Overlay and personal scopes
        overlays/ subscriptions, local_*.nix - nx overlay add, nx scope add"]
        L2["Layer 2: Repo scopes
        shell.nix, python.nix - nix/setup.sh flags"]
        L1["Layer 1: Base
        base.nix - always installed"]
    end

    L4 --> L3 --> L2 --> L1
```

| Layer              | What                                           | How                                 | Who        |
| ------------------ | ---------------------------------------------- | ----------------------------------- | ---------- |
| **Base**           | Core tools (git, jq, curl, coreutils)          | Always included, cannot be disabled | Base repo  |
| **Repo scopes**    | Curated groups (shell, python, k8s, terraform) | `nix/setup.sh --shell --python`     | Base repo  |
| **Overlay scopes** | Custom groups (team CLIs, org utilities)       | `nx overlay add` or `nx scope add`  | Team / org |
| **Extra packages** | Individual tools                               | `nx install httpie`                 | Individual |

## Adding packages (layer 4)

The simplest way - no scopes, no files to edit:

```bash
nx install httpie jq       # validates against nixpkgs, installs immediately
nx remove httpie           # remove a package
nx list                    # see everything installed, annotated by layer
```

Package names are validated against nixpkgs before being added. Typos and non-existent packages are caught immediately. Changes apply without needing `nx upgrade`.

Use this for one-off tools. If you find yourself adding many related packages, consider creating a scope instead.

## Creating custom scopes (layer 3)

Scopes group related packages with a meaningful name:

```bash
# Create a scope and add packages in one step
nx scope add devtools httpie jq bat

# Add more packages to an existing scope
nx scope add devtools fd

# Open a scope in your editor
nx scope edit devtools

# Apply changes after manual edits
nx upgrade
```

The scope file is standard Nix:

```nix
{ pkgs }: with pkgs; [
  bat
  fd
  httpie
  jq
]
```

Scopes created via `nx scope add` live in your personal scopes folder (`~/.config/nix-env/local/`) and are copied into `~/.config/nix-env/scopes/` with a `local_` prefix - preventing name collisions with base repo scopes.

### Packages that are not in nixpkgs

A scope file is an ordinary Nix function: it takes `pkgs` and returns a list of
derivations. The flat package list is only the shape `nx scope add` writes - it
is not a restriction. You can build a derivation inline and return that, which
is how an overlay ships a tool nixpkgs does not carry without changing this
repo.

This example installs a prebuilt release binary, so it costs a download instead
of a source build:

```nix
{ pkgs }:
let
  version = "0.28.4";
  sofka = pkgs.stdenvNoCC.mkDerivation {
    pname = "sofka";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/nklmilojevic/sofka/releases/download/v${version}"
        + "/sofka-v${version}-x86_64-unknown-linux-musl.tar.gz";
      sha256 = "72b5b56afc3cb021d5233a63b6d252a4b8375c420a887da1e58be803cafdae0b";
    };
    sourceRoot = ".";
    installPhase = ''
      runHook preInstall
      install -Dm755 sofka "$out/bin/sofka"
      runHook postInstall
    '';
  };
in
[ sofka ]
```

Things worth knowing:

- Prefer a statically linked release asset - a `musl` build on Linux. A
  dynamically linked binary also needs `pkgs.autoPatchelfHook` in
  `nativeBuildInputs` and its shared libraries in `buildInputs`.
- `sourceRoot = "."` is for a flat archive that has no top-level directory.
- This example pins one platform. To cover several, look the URL and hash up in
  an attribute set keyed on `pkgs.stdenv.hostPlatform.system`.
- `nx scope add` cannot add such a package, because it checks every name
  against nixpkgs. Create the scope with `nx scope add <name>`, then write the
  derivation with `nx scope edit <name>`.
- After a scope file contains hand-written Nix, `nx scope add <name> <pkg>`
  refuses to touch it. That command rebuilds the file from package names alone
  and would discard everything else. Edit the file directly instead.

## Overlays and personal scopes

Two places add scopes on top of the standard ones:

| Source          | Where it comes from                                    | Owned by                   |
| --------------- | ------------------------------------------------------ | -------------------------- |
| Overlays        | a repository, subscribed by name with `nx overlay add` | a team or org, or an image |
| Personal scopes | `~/.config/nix-env/local/`, written by `nx scope add`  | you                        |

### Overlays

An overlay is a named set of scopes in a repository. Subscribe to one, and every `nx setup` and
`nx upgrade` keeps it current:

```bash
nx overlay browse github:<org>/dev-overlays    # what the repository offers
nx overlay add github:<org>/dev-overlays k8s   # subscribe by name and apply
nx overlay                                     # subscriptions and their scopes
nx overlay remove k8s                          # unsubscribe
```

Its scopes are named `<overlay>/<scope>`. Opt out of one with `nx scope remove k8s/sofka`; it stays out
across updates until `nx scope add k8s/sofka`. Run `nx setup` after an overlay adds a header scope with
install steps, such as the gcloud CLI, which `nx upgrade` skips. Writing an overlay, addresses, shell config,
hooks and images are covered in [Overlays](overlays.md).

### Personal scopes

`nx scope add` keeps your own scope files in `~/.config/nix-env/local/scopes/`. Every setup run copies each
one in as `local_<name>.nix` and enables it; `nx scope remove` deletes it. A file in
`~/.config/nix-env/local/shell_cfg/` is sourced at login and wins over an overlay file of the same name.

A scope file can also name the standard scopes it needs, in a `# scopes:` header:

```nix
# scopes: python nodejs gcloud k8s_base
# bins: btop psql
{ pkgs }: with pkgs; [
  btop
  postgresql
]
```

Setup enables those scopes as if they were passed as flags, with their dependencies and install steps.
An unknown name prints a warning and is skipped. When a name drops out of the header, setup removes that
scope once, with its remove step, and prints it. On an unattended run that step deletes the scope's
home folder too, for example `~/google-cloud-sdk` for `gcloud`. A user who adds the scope back keeps it.

## Hooks

Hook scripts (`*.sh`) run at defined phases during `nix/setup.sh`.

Per-machine hooks live in `~/.config/nix-env/hooks/`. They are sourced into setup, so they can read and
change its variables:

| Phase      | Directory                               | Variables available                              |
| ---------- | --------------------------------------- | ------------------------------------------------ |
| Pre-setup  | `~/.config/nix-env/hooks/pre-setup.d/`  | `NIX_ENV_VERSION`, `NIX_ENV_PLATFORM`, `ENV_DIR` |
| Post-setup | `~/.config/nix-env/hooks/post-setup.d/` | All above + `NIX_ENV_SCOPES`                     |

Overlay hooks in `overlays/<name>/hooks/post-setup.d/` run after the per-machine post-setup hooks, and only for an
overlay subscribed from a local folder - one fetched from git never runs hooks. Each runs as its own `bash` process with `ENV_DIR`, `NIX_ENV_PLATFORM` and `NIX_ENV_SCOPES` set,
and with PATH covering the nix profile, `~/.local/bin`, fnm's default Node and `~/google-cloud-sdk/bin`, so it can call `npm`,
`uv` or `gcloud`, and with the shell's trust-store variables (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, ...) when `~/.config/certs` holds the certificates. A hook that fails prints a warning and setup finishes. Overlays have no pre-setup hooks.

Hooks run on every setup run, so make them safe to repeat:

```bash
# overlays/<name>/hooks/post-setup.d/npm-globals.sh
v=5.6.3
npm ls -g "typescript@$v" >/dev/null 2>&1 || npm install -g "typescript@$v"
```

Deleting a hook stops it running; what it installed stays.

Example use cases:

- **VPN check** - verify VPN is connected before setup downloads packages
- **Fleet telemetry** - POST `install.json` to a monitoring endpoint after setup
- **Team pinning** - write `pinned_rev` to lock package versions across a team
- **Compliance** - verify required scopes are present, block setup if missing

## Pinning package versions

By default, `nx upgrade` moves to the CI-validated `nixpkgs-unstable` revision - a deterministic snapshot of 100k+ packages at specific versions. Each commit is a reproducible state, not a rolling release.

For teams that need coordinated versions:

```bash
nx upgrade           # upgrade and verify everything works
nx pin set           # pin the current (tested) revision
nx pin show          # show current pin
nx pin remove        # go back to the validated revision
```

The pin is stored in `~/.config/nix-env/pinned_rev`. When present, `nx upgrade` locks to that commit instead of the validated revision. Set the pin from a pre-setup hook on each machine (placed there by your device management, for example):

```bash
# ~/.config/nix-env/hooks/pre-setup.d/pin_nixpkgs.sh
echo "abc123..." > "$HOME/.config/nix-env/pinned_rev"
```

When IT validates a new nixpkgs revision, they update the hook - every machine gets the tested baseline on its next setup run.

## Upgrades and rollback

```bash
nx upgrade                    # upgrade all packages to latest (or pinned) versions
nx rollback                   # revert to the previous package set
nix profile diff-closures     # see exactly what changed
nx gc                         # clean up old generations
```

Upgrades are atomic - all packages upgrade together through a single `buildEnv`. Rollback reverts the entire environment to the previous state, not individual packages. This eliminates partial upgrade states.

## Quick reference

| Task                         | Command                              |
| ---------------------------- | ------------------------------------ |
| Add a package                | `nx install <pkg>`                   |
| Remove a package             | `nx remove <pkg>`                    |
| List all packages            | `nx list`                            |
| Search nixpkgs               | `nx search <term>`                   |
| Create a scope with packages | `nx scope add <name> <pkg> [pkg...]` |
| Edit a scope file            | `nx scope edit <name>`               |
| Show scope tree              | `nx scope tree`                      |
| Show overlays and sync state | `nx overlay`                         |
| Upgrade packages             | `nx upgrade`                         |
| Pin current revision         | `nx pin set`                         |
| Show / remove pin            | `nx pin show` / `nx pin remove`      |
| Roll back last upgrade       | `nx rollback`                        |
| See what changed             | `nix profile diff-closures`          |
| Clean up old generations     | `nx gc`                              |
| Run health checks            | `nx doctor`                          |
