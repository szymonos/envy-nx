# Overlays

An overlay is a folder that adds your own packages, shell config and setup scripts on top of the standard
Envy-NX scopes. A team or an organization uses one to describe its environment in a single place,
for example the tools every Coder workspace or Dev Container should have. Envy-NX reads the folder on
every setup run, so a change to the overlay reaches every machine on its next run.

This page is for the people who write an overlay or build an image on one. For the user-side view, see
[Customization](customization.md).

## Two overlays, one machine

| Overlay      | Where it lives                                  | Who owns it                              |
| ------------ | ----------------------------------------------- | ---------------------------------------- |
| Organization | any folder, chosen with `nx overlay set <path>` | a team, an org, or an image              |
| Personal     | `~/.config/nix-env/local/`                      | the user, usually through `nx scope add` |

Setup takes the organization overlay from `nix/setup.sh --overlay-dir <path>`, else the
`NIX_ENV_OVERLAY_DIR` variable, else the path it saved last time, and saves the one it used. Setup
applies both overlays: the organization overlay first, then the personal one. The organization overlay
decides what it provides. Users add their own tools on top, but cannot remove or replace what the
organization overlay installs.

## Quick start

1. Create a folder with one scope file:

    ```text
    team-overlay/
    └── scopes/
        └── team.nix
    ```

    ```nix
    # Team tools on top of the standard scopes
    # scopes: shell python nodejs
    # bins: btop psql
    { pkgs }: with pkgs; [
      btop
      postgresql
    ]
    ```

2. Point Envy-NX at it and run setup:

    ```bash
    nx overlay set ~/src/team-overlay
    nx setup
    ```

    Envy-NX remembers the path in `~/.config/nix-env/overlay_dir`, so later runs use it from any
    shell. `nx overlay unset` forgets it.

3. Check the result:

    ```bash
    nx overlay      # the overlay's scopes, header scopes, shell config and hooks
    nx doctor       # confirms the commands in `# bins:` are on PATH
    ```

That is the whole loop. Edit the folder, run `nx setup` again, and the machine follows.

## Folder layout

```text
team-overlay/
├── scopes/                 # scope files - installed because they are here
│   └── team.nix
├── shell_cfg/              # shell files sourced at login
│   └── aliases_team.sh
└── hooks/
    └── post-setup.d/       # scripts run after setup, in name order
        └── 10-npm-globals.sh
```

Every part is optional. Other files in the folder are ignored.

## Scope files

A scope file in `scopes/` is installed because it is there. Setup copies it into
`~/.config/nix-env/scopes/` as `local_<name>.nix` and enables it on every run. Delete the file and the
next run removes the scope and its packages.

- **File name.** Letters, digits, `-` and `_` only, not starting with `local_`, for example `team.nix`
  or `data_tools.nix`. Setup
  skips any other name with a warning. Prefer `_`: `nx` commands turn `-` into `_` in scope names.
- **Packages.** One nixpkgs attribute name per line between `[` and `]`. Find names with
  `nx search <term>` or on [search.nixos.org](https://search.nixos.org/packages).
- **`# bins:`** lists the commands the packages provide. `nx doctor` checks that each one is on PATH.
  Optional, but it turns a missing package into a visible warning.
- **Tools nixpkgs does not have.** A scope file is a Nix function, so it can build a tool from a
  release binary. See [Packages that are not in nixpkgs](customization.md#packages-that-are-not-in-nixpkgs).

### The `# scopes:` header

Some tools are not plain packages. `gcloud`, `nodejs` and `az` run an install step that a scope file
cannot repeat. Name those standard scopes in the header instead of passing setup flags:

```nix
# scopes: python nodejs gcloud k8s_base az
```

- Setup enables the named scopes exactly as if they were passed as flags. Their dependencies come
  along, and their install steps run.
- An unknown name prints a warning and is skipped, so an overlay written for a newer Envy-NX release
  still works on an older one.
- Use the names from the list below, with underscores (`k8s_base`). Only the first `# scopes:` line
  in a file counts.

### Standard scopes

Every scope can go in the header. These are the ones whose install steps matter for an overlay:

| Scope        | Install step                                                                      | Brings in  |
| ------------ | --------------------------------------------------------------------------------- | ---------- |
| `nodejs`     | fnm from Nix, then the Node.js LTS into `~/.local/share/fnm`, so `npm i -g` works |            |
| `python`     | uv and prek from Nix; Python versions are managed by uv                           |            |
| `az`         | azure-cli installed with uv, set up to trust the corporate CA bundle              | `python`   |
| `gcloud`     | Google's tarball into `~/google-cloud-sdk`, so `gcloud components install` works  |            |
| `k8s_base`   | kubectl, kubelogin, helm, k9s; with `gcloud`, also the GKE auth plugin            |            |
| `k8s_dev`    | flux, kustomize, trivy and other cluster tools                                    | `k8s_base` |
| `terraform`  | tfswitch, which puts `terraform` into `~/.local/bin`                              |            |
| `conda`      | Miniforge into `~/miniforge3`                                                     |            |
| `playwright` | the playwright CLI as a uv tool                                                   | `python`   |
| `pwsh`       | PowerShell, plus the `pwsh` profile                                               | `shell`    |
| `zsh`        | zsh plugins only; the zsh binary must come from the system                        | `shell`    |

The full list with every package is in the [scope table](index.md).

## Shell config

Files in `shell_cfg/` are copied to `~/.config/shell/overlay/` on every setup run, and the managed
block in `~/.bashrc` and `~/.zshrc` sources them after the standard aliases, so an overlay alias wins.

- **Pick the shell by extension.** `.sh` loads in bash and zsh, `.bash` in bash only, `.zsh` in zsh
  only. Other files are copied but not loaded. Names may use letters, digits, `.`, `-` and `_`.
- **Write `.sh` files for both shells.** No bash-only syntax such as `[[ =~ ]]` captures or arrays
  indexed from 0, and use `function name() {` rather than `name() {`.
- **A personal file with the same name replaces the organization's one.** The organization decides
  the tools, the user decides their shell.
- **Deleting a file removes it** from `~/.config/shell/overlay/` on the next setup run.
- PowerShell does not read these files.

## Hooks

Scripts in `hooks/post-setup.d/*.sh` run near the end of setup, after the packages, the scopes' install
steps and the shell profiles are done. Only the GitHub Copilot CLI, zsh plugins and PowerShell modules
install later. Use them for tools that a command installs rather than a package: global npm
packages, `uv tool install`, gcloud components.

- **They run on every setup run.** On a Coder workspace that means every start. Check first, then
  install, so a run with nothing to do is fast:

    ```bash
    # hooks/post-setup.d/10-npm-globals.sh
    v=5.6.3
    npm ls -g "typescript@$v" >/dev/null 2>&1 || npm install -g "typescript@$v"
    ```

- **Each runs as its own `bash` process** as the user, with `ENV_DIR`, `NIX_ENV_PLATFORM` and
  `NIX_ENV_SCOPES` set. PATH covers the Nix profile, `~/.local/bin`, fnm's default Node and
  `~/google-cloud-sdk/bin`, so `npm`, `uv` and `gcloud` work.
- **A failing hook prints a warning** and setup still finishes. Read the setup output when you change
  a hook.
- **Deleting a hook stops it running, but does not undo it.** To remove what a hook installed, ship a
  hook that uninstalls it.
- Organization overlay hooks run first, then personal ones. There are no pre-setup hooks in an overlay.

## What changes when

Setup applies the overlay on every run. An edit to the organization overlay reaches existing machines
on their next run, not only new ones:

| When you …                         | every machine, on its next setup run …                                       |
| ---------------------------------- | ---------------------------------------------------------------------------- |
| add a package to a scope file      | installs it                                                                  |
| remove a package from a scope file | uninstalls it                                                                |
| add a scope file                   | installs its packages                                                        |
| delete a scope file                | uninstalls its packages                                                      |
| add a name to `# scopes:`          | installs that scope, with its install step                                   |
| remove a name from `# scopes:`     | removes that scope **once**, with its remove step, and prints it (see below) |
| add or change a hook               | runs it, then keeps running it on every run                                  |
| delete a hook                      | stops running it; what it installed stays                                    |

Removing a name from the header deserves care:

- **The remove step deletes the scope's home folder** on an unattended run, without asking.
  Dropping `gcloud` deletes `~/google-cloud-sdk` with its components (the login in `~/.config/gcloud`
  stays). Dropping `nodejs` deletes fnm's Node, including every global npm package users installed.
  Dropping `python` deletes uv's Pythons and tools.
- **A scope another scope needs stays.** Dropping `python` while `az` is still named keeps `python`,
  because `az` depends on it.
- **It happens once.** A user who adds the scope back afterwards with `nx setup --gcloud` keeps it.

## What users can and can't do

- **Add anything on top.** `nx install <pkg>`, `nx setup --<scope>` for a scope the overlay does not
  name, or their own scopes with `nx scope add`. All of it survives image upgrades.
- **Not remove what the organization overlay provides.** `nx scope remove`, `nx scope edit` and
  `nix/setup.sh --remove` refuse its scopes and the scopes its headers name, and print which file
  provides them. Removing something for everyone is a change to the overlay.
- **Not replace it.** Adding a scope the overlay already provides does nothing and says so, and a
  `--omp-theme` or `--starship-theme` flag cannot swap out a prompt engine the overlay names. A prompt
  engine the overlay names also replaces the other engine if the user had it, including one a
  personal overlay names. A personal
  scope file with the same name as an organization one is ignored with a warning.

This is a default the organization controls, not a lock. A user can install a removed tool again
themselves, or stop using the organization overlay with `nx overlay unset` (and by dropping
`NIX_ENV_OVERLAY_DIR` if it is set).

## Building an image on an overlay

A container image (a Coder workspace template, a Dev Container) bakes the overlay in and runs the same
setup command at build time and at every start. The overlay is then the one description of the
environment, and the image passes no scope flags.

```dockerfile
# Nix itself is installed earlier in the image, single-user (--no-daemon), owned by the workspace user.

# Envy-NX: the latest release, no git history needed
RUN curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 30 --max-time 600 -o /tmp/envy-nx.tar.gz \
      https://github.com/szymonos/envy-nx/releases/latest/download/envy-nx.tar.gz \
 && mkdir -p /opt/envy-nx && tar xzf /tmp/envy-nx.tar.gz -C /opt/envy-nx --strip-components=1 \
 && rm /tmp/envy-nx.tar.gz

# The overlay lives next to the Dockerfile in your template repository
COPY nix-overlay/ /opt/nix-overlay/
ENV NIX_ENV_OVERLAY_DIR=/opt/nix-overlay

USER coder
RUN /opt/envy-nx/nix/setup.sh --unattended
```

The image sets the path with `ENV`, which takes precedence over the saved path, so every shell and
every setup run in the workspace agrees on it. `nix/setup.sh --overlay-dir /opt/nix-overlay` works
too, and saves the path for later runs.

And at every workspace start, from the entrypoint:

```bash
/opt/envy-nx/nix/setup.sh --skip-repo-update --unattended
```

Things to know:

- **Run setup at start, not only at build.** The workspace home is a volume that hides whatever the
  build wrote to `$HOME`: `~/.nix-profile`, the shell profiles, and the tools installed into the home
  folder (Node through fnm, the gcloud tarball, uv tools). The build still pays off: the packages it
  downloaded stay in `/nix/store`, so the start only links them.
- **The first start of a new workspace is slower.** It downloads the tools that install into `$HOME`.
  Later starts find them on the volume and finish quickly.
- **The start applies image upgrades.** A new image with a changed overlay or a newer Envy-NX reaches
  an existing home on its next start, and scopes the user added stay.
- **Pick the Envy-NX version on purpose.** `releases/latest` takes every release, each of which passed
  Envy-NX CI on Linux and macOS. To hold a version, download `releases/download/v<X.Y.Z>/envy-nx.tar.gz`
  instead and bump it with your template releases.
- **A missing overlay folder stops setup.** If the organization overlay is not there or not readable,
  for example a mount that has not arrived yet, setup exits with an error before it changes any scope. Fix the
  path, or run `nx overlay unset` (and drop the variable) to stop using it.
- **No root in the overlay.** An overlay installs nothing that needs root. Daemons, system packages
  and anything run through `sudo` stay in the image.

## Testing an overlay before you ship it

Try every change on one machine before it goes into an image:

```bash
nx overlay set ~/src/team-overlay   # your working copy
nx setup                 # applies scopes, header scopes, shell config and hooks
nx overlay               # what was picked up, and anything ignored
nx doctor                # every `# bins:` command on PATH
```

Use `nx setup`, not `nx upgrade`. `nx upgrade` skips install steps, so a scope you just added to the
header would get its packages but not its installer.

Before you ship, check that:

- setup prints no `unknown scope` or `ignored` warning for your files,
- every hook runs twice in a row without error, and the second run is quick,
- `nx doctor` reports no missing commands.

## Reference

- [Customization](customization.md) - the user side: personal scopes, packages, pinning.
- [Decision 0013](https://github.com/szymonos/envy-nx/blob/main/design/decisions/0013-overlays-org-extension-point.md) - why overlays work this way, and the options that were rejected.
- [`design/overlay_catalog.md`](https://github.com/szymonos/envy-nx/blob/main/design/overlay_catalog.md) - the planned `nx overlay add`, for subscribing to an overlay from a git repository.
