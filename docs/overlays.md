# Overlays

An overlay is a named set of scopes - your own packages, shell config and setup scripts - on top of the
standard Envy-NX scopes. A team or an organization uses one to describe its environment in a single
place, for example the tools every Coder workspace or Dev Container should have. Overlays live in a
repository, and users subscribe to them by name. Every setup run updates the subscriptions, so a change
to an overlay reaches every machine on its next run.

This page is for the people who write an overlay, use one, or build an image on one. For your own scopes
and packages, see [Customization](customization.md).

## Quick start

See what a repository offers, then subscribe to an overlay by name:

```bash
nx overlay browse github:my-org/dev-overlays
#   base - Shell, PowerShell and oh-my-posh
#   k8s  - Kubernetes tools
nx overlay add github:my-org/dev-overlays k8s
nx overlay        # your subscriptions: repository, ref, commit and scopes
nx doctor         # confirms the commands in `# bins:` are on PATH
```

`nx overlay add` saves the subscription and runs `nx setup` to apply it. From then on every `nx setup` and
`nx upgrade` fetches it and applies what changed.

## Repository layout

Every overlay is a folder under `overlays/`, and the folder name is the overlay's name. A repository with
one overlay has the same shape with one folder:

```text
dev-overlays/
├── overlays/
│   ├── default/            # installed when no name is given - see below
│   │   ├── README.md       # the first line is the description `nx overlay browse` shows
│   │   └── scopes/
│   │       └── base.nix
│   └── k8s/
│       ├── README.md
│       ├── scopes/         # scope files - installed because they are here
│       │   ├── k8s.nix
│       │   └── sofka.nix -> ../../../lib/sofka.nix
│       ├── shell_cfg/      # shell files sourced at login
│       │   └── aliases_k8s.sh
│       └── hooks/
│           └── post-setup.d/   # run only when the repository is a local folder
│               └── 10-npm-globals.sh
└── lib/                    # shared files, used by symlink or import
    └── sofka.nix
```

Everything but `scopes/` is optional. The repository root is never an overlay, and anything outside
`overlays/` is shared: a scope file can `import ../../../lib/sofka.nix`, or `scopes/` can hold a symlink
to it.

**Name one overlay `default`.** An address with no overlay name installs the repository's only overlay,
or else the one named `default`. A repository that relies on having just one overlay changes what a
no-name address means the day it gets a second one. `default` keeps it stable.

## Addresses

```bash
nx overlay add github:my-org/dev-overlays k8s cloud          # two overlays by name
nx overlay add github:my-org/dev-overlays k8s --ref v2       # pinned to a tag or branch
nx overlay add github:my-org/dev-overlays --all              # every overlay in the repository
nx overlay add github:other-team/overlays k8s --as k8s-other # a second overlay named k8s
nx overlay add ~/src/dev-overlays k8s                        # a local folder, copied as it is
```

The repository is `github:<owner>/<repo>`, any `https://` or ssh git URL, or a local folder. Git fetches
with your own credentials, so a private repository works when `gh auth setup-git` or an SSH key already
gives you access - `github:` fetches over https, so with SSH keys only, use `git@github.com:<owner>/<repo>.git`. Envy-NX handles no secrets.

`nix/setup.sh --overlay` and `wsl/wsl_setup.ps1 -Overlay` take one overlay per address, in Nix
flake-reference style:

| Address                                        | Overlay                             |
| ---------------------------------------------- | ----------------------------------- |
| `'github:my-org/dev-overlays#k8s'`             | `k8s`, from the default branch      |
| `'github:my-org/dev-overlays/v2#k8s'`          | `k8s`, at the tag or branch `v2`    |
| `'https://git.example.com/dev.git?ref=v2#k8s'` | `k8s`, at `v2`, from any git URL    |
| `'/opt/dev-overlays#k8s'`                      | `k8s`, from a local folder (no ref) |

Quote addresses in a shell: zsh treats `?` and `#` as glob characters.

### When you give no name

| The repository has            | `nx overlay add <repo>` / `--overlay <repo>` installs                                   |
| ----------------------------- | --------------------------------------------------------------------------------------- |
| one overlay                   | it                                                                                      |
| an overlay named `default`    | `default`                                                                               |
| several, none named `default` | in a terminal, a picker with the descriptions; unattended, nothing - it lists the names |
| no `overlays/` folder         | nothing: "no overlays/ in this repository"                                              |

`--all` installs every overlay; a missing name never means everything. What you picked is saved by name,
so an overlay added to the repository later never changes an existing subscription, and an unattended
upgrade never asks.

## Commands

| Command                              | What it does                                                       |
| ------------------------------------ | ------------------------------------------------------------------ |
| `nx overlay`                         | subscriptions: name, repository, ref, commit and scopes            |
| `nx overlay browse <repo>`           | the repository's overlays and their descriptions; installs nothing |
| `nx overlay add <repo> [overlay...]` | subscribe and apply; `--ref`, `--as <name>`, `--all`               |
| `nx overlay remove <name...>`        | unsubscribe; their scopes are removed on the same run              |
| `nx overlay update`                  | fetch every subscription and apply (the same as `nx upgrade`)      |
| `nx scope remove <overlay>/<scope>`  | opt out of one scope; it stays out across updates                  |
| `nx scope add <overlay>/<scope>`     | opt back in (runs `nx setup`)                                      |

Adding a subscription you already have changes nothing and keeps your opt-outs, so an image can run the
same `--overlay` at build and at every start.

## Scope files

A scope file in `overlays/<name>/scopes/` is installed because it is there, as `<name>/<scope>`: overlays
`k8s` and `web` can both ship `base.nix`. Delete the file and the next run removes the scope and its
packages.

- **File name.** Letters, digits, `-` and `_` only, for example `k8s.nix` or `data_tools.nix`. Setup skips
  any other name with a warning.
- **Packages.** One nixpkgs attribute name per line between `[` and `]`. Find names with `nx search <term>`
  or on [search.nixos.org](https://search.nixos.org/packages).
- **`# bins:`** lists the commands the packages provide. `nx doctor` checks that each one is on PATH.
  Optional, but it turns a missing package into a visible warning.
- **Tools nixpkgs does not have.** A scope file is a Nix function, so it can build a tool from a release
  binary: return a `stdenvNoCC.mkDerivation` over `fetchurl` of the release asset for
  `pkgs.stdenv.hostPlatform.system`. The build is pure, so every asset needs a fixed hash; keep the
  version current from the repository's own CI, with a scheduled job that reads the release's checksums
  and commits the new version and hashes. See
  [Packages that are not in nixpkgs](customization.md#packages-that-are-not-in-nixpkgs).

Setup copies every `.nix` file of the repository into `~/.config/nix-env/overlays/`, so imports across
folders resolve. A symlinked file is followed only while it stays inside the repository and out of `.git`.
One that points elsewhere - directly or through a symlinked folder - is refused and named, because
whatever is copied ends up in the world-readable Nix store. Symlinked folders are not walked: link the
files, or import them.

### The `# scopes:` header

Some tools are not plain packages. `gcloud`, `nodejs` and `az` run an install step that a scope file
cannot repeat. Name those standard scopes in the header instead of passing setup flags:

```nix
# scopes: python nodejs gcloud k8s_base az
```

- Setup enables the named scopes exactly as if they were passed as flags. Their dependencies come along,
  and their install steps run.
- An unknown name prints a warning and is skipped, so an overlay written for a newer Envy-NX release still
  works on an older one.
- Use the names from the list below, with underscores (`k8s_base`). Only the first `# scopes:` line in a
  file counts. The header is plain text: put platform differences inside the scope file
  (`pkgs.stdenv.isDarwin`) - standard scopes such as `docker` already handle macOS and Linux themselves.

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

Files in `shell_cfg/` are copied to `~/.config/shell/overlay/` on every setup run, and the managed block
in `~/.bashrc` and `~/.zshrc` sources them after the standard aliases, so an overlay alias wins.

- **Pick the shell by extension.** `.sh` loads in bash and zsh, `.bash` in bash only, `.zsh` in zsh only.
  Other files are copied but not loaded. Names may use letters, digits, `.`, `-` and `_`.
- **Write `.sh` files for both shells.** No bash-only syntax such as `[[ =~ ]]` captures or arrays indexed
  from 0, and use `function name() {` rather than `name() {`.
- **A change asks first.** Shell config runs in every shell, so an update that changes it - or adds or
  removes the folder - shows the diff and asks. An unattended run keeps the previous files and warns until
  someone accepts the change in a terminal. A new subscription, a new `--ref`, a local folder, and an
  address given on the command line (`--overlay`, `nx overlay add`) apply without asking: naming it was the review.
- **Your own file with the same name wins** (`~/.config/nix-env/local/shell_cfg/`).
- PowerShell does not read these files.

## Hooks

Scripts in `overlays/<name>/hooks/post-setup.d/*.sh` run near the end of setup - **only when the
repository is a local folder**, which the machine's owner placed there, such as an image's
`/opt/dev-overlays`. An overlay fetched from a git repository never runs hooks: running another team's
scripts on every setup is too wide a reach.

Use hooks for tools that a command installs rather than a package: global npm packages,
`uv tool install`, gcloud components.

- **They run on every setup run.** On a Coder workspace that means every start. Check first, then install,
  so a run with nothing to do is fast:

    ```bash
    # overlays/k8s/hooks/post-setup.d/10-npm-globals.sh
    v=5.6.3
    npm ls -g "typescript@$v" >/dev/null 2>&1 || npm install -g "typescript@$v"
    ```

- **Each runs as its own `bash` process** as the user, with `ENV_DIR`, `NIX_ENV_PLATFORM` and
  `NIX_ENV_SCOPES` set. PATH covers the Nix profile, `~/.local/bin`, fnm's default Node and
  `~/google-cloud-sdk/bin`, so `npm`, `uv` and `gcloud` work. Behind a TLS-inspecting proxy it gets the
  same trust-store variables as your shell (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `PIP_CERT`, ...)
  when `~/.config/certs` holds the certificates.
- **A failing hook prints a warning** and setup still finishes.
- **Deleting a hook stops it running, but does not undo it.** To remove what a hook installed, ship a hook
  that uninstalls it.

## What changes when

| When the overlay …                  | every subscribed machine, on its next setup run …                                            |
| ----------------------------------- | -------------------------------------------------------------------------------------------- |
| adds a package to a scope file      | installs it                                                                                  |
| removes a package from a scope file | uninstalls it                                                                                |
| adds a scope file                   | installs its packages                                                                        |
| deletes a scope file                | uninstalls its packages                                                                      |
| adds a name to `# scopes:`          | installs that scope, with its install step                                                   |
| removes a name from `# scopes:`     | removes that scope **once**, with its remove step, and prints it (see below)                 |
| changes `shell_cfg/`                | shows the diff and asks; unattended, keeps the old files (an `--overlay` address applies it) |
| cannot be fetched                   | keeps the previous copy - nothing is removed (an `--overlay` address stops setup)            |

Updates are fast-forward only: setup prints the incoming commits and changed files, and a repository whose
history was rewritten, or a tag moved backwards, keeps its previous copy with a warning.

Removing a name from the header deserves care:

- **The remove step deletes the scope's home folder** on an unattended run, without asking. Dropping
  `gcloud` deletes `~/google-cloud-sdk` with its components (the login in `~/.config/gcloud` stays).
  Dropping `nodejs` deletes fnm's Node, including every global npm package users installed. Dropping
  `python` deletes uv's Pythons and tools.
- **A scope another scope needs stays.** Dropping `python` while `az` is still named keeps `python`,
  because `az` depends on it.
- **It happens once.** A user who adds the scope back afterwards with `nx setup --gcloud` keeps it.

## What users can do

- **Add anything on top.** `nx install <pkg>`, `nx setup --<scope>`, or their own scopes with
  `nx scope add`. All of it survives image upgrades.
- **Opt out of a subscribed scope.** `nx scope remove k8s/sofka` keeps it out across updates;
  `nx scope add k8s/sofka` brings it back. A standard scope a header names works the same way:
  `nx scope remove gcloud` runs its remove step once and keeps it out; `nx scope add gcloud` brings it back.
- **Prefer their own prompt.** A prompt engine an overlay's header names replaces the user's other engine,
  but a personal scope naming the other engine wins.

## Building an image on an overlay

A container image (a Coder workspace template, a Dev Container) copies the overlay repository in and runs
the same setup command at build time and at every start. The overlay is then the one description of the
environment, and the image passes no scope flags.

```dockerfile
# Nix itself is installed earlier in the image, single-user (--no-daemon), owned by the workspace user.

# Envy-NX: the latest release, no git history needed
RUN curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 30 --max-time 600 -o /tmp/envy-nx.tar.gz \
      https://github.com/szymonos/envy-nx/releases/latest/download/envy-nx.tar.gz \
 && mkdir -p /opt/envy-nx && tar xzf /tmp/envy-nx.tar.gz -C /opt/envy-nx --strip-components=1 \
 && rm /tmp/envy-nx.tar.gz

# The overlay repository lives next to the Dockerfile in your template repository
COPY dev-overlays/ /opt/dev-overlays/

USER coder
RUN /opt/envy-nx/nix/setup.sh --unattended --overlay '/opt/dev-overlays#k8s'
```

And at every workspace start, from the entrypoint:

```bash
/opt/envy-nx/nix/setup.sh --skip-repo-update --unattended --overlay '/opt/dev-overlays#k8s'
```

Things to know:

- **Name the overlay.** An unattended run cannot ask, so an address without a name works only for a
  repository with one overlay or a `default`.
- **Run setup at start, not only at build.** The workspace home is a volume that hides whatever the build
  wrote to `$HOME`: `~/.nix-profile`, the shell profiles, and the tools installed into the home folder
  (Node through fnm, the gcloud tarball, uv tools). The build still pays off: the packages it downloaded
  stay in `/nix/store`, so the start only links them.
- **The start applies image upgrades.** A new image with a changed overlay or a newer Envy-NX reaches an
  existing home on its next start. Scopes the user added, and scopes they opted out of, stay that way.
- **A local folder runs its hooks.** The image copied it in, so its `hooks/post-setup.d` scripts run.
- **A missing folder stops the start.** An address given with `--overlay` must resolve: if the folder is
  not there, for example a mount that has not arrived yet, setup stops before it changes any scope, rather
  than start the workspace without its tools. A saved subscription refreshed by `nx upgrade` keeps its
  previous copy instead.
- **Shell config follows the image.** The `--overlay` address counts as reviewed, so a new image's
  `shell_cfg/` applies at the next start without asking.
- **Pick the Envy-NX version on purpose.** `releases/latest` takes every release, each of which passed
  Envy-NX CI on Linux and macOS. To hold a version, download `releases/download/v<X.Y.Z>/envy-nx.tar.gz`
  instead and bump it with your template releases.
- **No root in the overlay.** An overlay installs nothing that needs root. Daemons, system packages and
  anything run through `sudo` stay in the image.

## Testing an overlay before you ship it

Subscribe to your working copy - a local folder applies without asking and runs its hooks:

```bash
nx overlay add ~/src/dev-overlays k8s   # your working copy
nx setup                                # after each edit
nx overlay                              # what was picked up
nx doctor                               # every `# bins:` command on PATH
```

Use `nx setup`, not `nx upgrade`. `nx upgrade` skips install steps, so a scope you just added to the header
would get its packages but not its installer.

Before you ship, check that:

- setup prints no `unknown scope`, `ignored` or `refused` warning for your files,
- every hook runs twice in a row without error, and the second run is quick,
- `nx doctor` reports no missing commands.

## Reference

- [Customization](customization.md) - your own scopes and packages, pinning.
- [Decision 0015](https://github.com/szymonos/envy-nx/blob/main/design/decisions/0015-overlay-subscriptions.md) - how subscriptions fetch, copy and namespace overlays, and the options that were rejected.
- [Decision 0013](https://github.com/szymonos/envy-nx/blob/main/design/decisions/0013-overlays-org-extension-point.md) - why an overlay's scopes and `# scopes:` header are installed on every run.
