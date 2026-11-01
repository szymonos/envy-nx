# Overlay subscriptions

Decision 0013 made a local overlay folder a working org extension point, but
using one from a git repository still meant a manual clone and a `git pull`
before every setup. It also allowed only one org overlay at a time, broke any
scope file that imported a file next to it (only `scopes/*.nix` was copied), and
offered two kinds of overlay - an organization folder and subscriptions - that a
user had to tell apart. The aim of this decision is the least confusing model to
document: one noun, one layout, picked by name.

**Decision:**

**D1. One noun, one layout.** An overlay is a named set of scopes; a repository
is where overlays live. Every overlay is `overlays/<name>/` holding `scopes/*.nix`,
an optional `shell_cfg/`, `hooks/post-setup.d/` and `README.md` whose first line
describes it. A one-overlay repository has the same shape. The repository root is
never an overlay; anything outside `overlays/` is shared, used by symlink or
`import`. Folder paths never appear in the interface.

**D2. Addressed by name, in flake-reference style.** `nx overlay add <repo>
[name...] [--ref R] [--as N] [--all]`. The one-string form, used by
`nix/setup.sh --overlay` and `wsl_setup.ps1 -Overlay`, is `<repo>#<overlay>`:
`github:o/r#k8s`, `github:o/r/v2#k8s`, `https://host/o/r.git?ref=v2#k8s`. A
repository is a `github:` address, any https/ssh git URL, or a local folder,
which is copied as it is - git or not - and takes no ref.

**D3. No name is resolved once.** An address without a name installs the only
overlay, else the one named `default`, else asks with a picker in a terminal and
refuses unattended, listing the names. `--all` installs every overlay; a missing
name never means everything. What was picked is saved by name in
`overlays.list` (`<name> <overlay> <ref|-> <repo>`) and never resolved again, so
a repository that grows overlays never changes a subscription and an unattended
upgrade never asks. The author docs recommend a `default` overlay, which keeps a
no-name address stable as a repository grows.

**D4. Fetch per repository, copy `*.nix`.** A remote repository is cloned once
per ref into `~/.cache/nix-env/overlays/<repo key>/` with plain `git` - the
user's own credentials - and updated fast-forward only, a pinned tag included.
Every `*.nix` file of the repository, plus `shell_cfg/` of the subscribed
overlays, is copied into `$ENV_DIR/overlays/<repo key>/`, so imports across
folders resolve under pure evaluation. A symlink is followed only when its
physical target stays inside the source and out of `.git`. A source that
cannot be read keeps its previous copy and is never read as empty.

**D5. Namespaced ids, resolved through an index file.** A subscribed scope is
`<name>/<scope>` in `config.nix`. Setup writes `overlays/index.nix`, mapping each
id to its copied file, and `flake.nix` looks every scope up there before falling
back to `scopes/<id>.nix`. The ids enter `overlay_entries` with origin `sub`, so
enabling them, dropping them, and the `# scopes:` header reuse decision 0013's
machinery, its once-only removal of a dropped header name included.

**D6. No lock.** `nx scope remove <name>/<scope>` opts out of any subscribed scope
(`overlays.exclude`), and it stays out across updates until `nx scope add`.
Re-adding a subscription changes nothing and keeps the opt-outs, so an image can
run `setup.sh --overlay /opt/overlays#k8s` at build and at every start.

**D7. Hooks only from a local folder.** An overlay read from a local folder runs
its `hooks/post-setup.d/*.sh` as child processes; the machine owner placed the
folder there, the argument decision 0013 made. An overlay fetched from git never
runs hooks: running another team's scripts on every setup is the widest blast
radius in the design.

**D8. A `shell_cfg/` change needs a yes.** It is sourced into every shell, so for
a remote subscription the last run applied, a change - files, or the folder
appearing or going - shows its diff and asks; an unattended run keeps the old
files and warns. A new subscription, a new ref and a local folder skip the
question, because choosing them was the review.

**D9. The organization overlay folder is folded in.** `NIX_ENV_OVERLAY_DIR`,
`--overlay-dir`, `$ENV_DIR/overlay_dir`, `nx overlay set/unset` and the org-lock
refusals are gone; an image subscribes to its local folder instead.
`~/.config/nix-env/local/` stays as personal scopes, written by `nx scope add`.
A leftover `NIX_ENV_OVERLAY_DIR` or saved `overlay_dir` warns, naming the
replacement, and never fails: generated devcontainer projects export the
variable at a folder that usually does not exist (CQ-007).

**D10. An address given on the command line is an explicit request.** For the
subscriptions named by `setup.sh --overlay`, `wsl_setup.ps1 -Overlay` or
`nx overlay add` in that run, naming them was the review: their `shell_cfg/`
changes apply without asking, unattended too, and they must resolve - a source
that cannot be read, or a name the repository lacks, stops setup before any
scope changes. A Coder entrypoint passes `--overlay` at every start: without the
first rule a new image's shell config never applies, without the second a broken
path starts the workspace silently without its tools. Saved subscriptions
refreshed by `nx upgrade` keep D4 and D8: warn, keep the previous copy, ask.

**D11. Opting out covers the scopes a header names.** `nx scope remove <scope>`
(or `setup.sh --remove <scope>`) for a standard scope a subscribed overlay's
`# scopes:` header names adds it to `overlays.exclude`, like an overlay scope.
Its remove step runs once; later runs leave it out instead of merging it back
from the header, which would reinstall on every start what the remove step just
deleted. `nx scope add <scope>` takes the exclusion back. A personal scope's
header is the user's own, so removing a scope it names still means editing it.

**Rejected:**

- **Paths instead of names (`--dir`, `?dir=`).** A path is a layout detail; a
  name is what a user picks and an IDP lists.
- **Re-resolving a no-name address on update.** A repository that gains a second
  overlay would silently change what a machine installs, or make an unattended
  upgrade ask.
- **A second list in `config.nix`.** `nx scope` rewrites `config.nix` with the
  scope list only (`_nx_write_config`), so the list would be lost on the first
  `nx scope remove`. The index file lives with the copies, and setup owns it alone.
- **Keeping the organization overlay folder beside subscriptions.** Two kinds of
  overlay, with a lock only one of them had, were the hardest thing to document.
- **Copying the whole repository.** READMEs and images would enter the store on
  every evaluation. **Copying only the subscribed overlay** breaks shared imports.
- **Walking symlinked folders.** A link to `/` would make setup crawl the disk.
- **An OS-aware `# scopes:` header.** The header is static text; platform
  differences belong in scope files and in standard scopes such as `docker`.

**Consequence:** a tool built from a GitHub release asset needs a fixed hash, so
"latest" is the overlay repository's job: a scheduled CI job bumps the version
and hashes. Phase 2 of `design/overlay_catalog.md` (IDP metadata beyond the
README line) is still open.

**Scope:** `nix/lib/phases/overlays.sh`, `nix/lib/phases/platform.sh`,
`nix/lib/phases/scopes.sh`, `.assets/lib/nx_overlay.sh`, `.assets/lib/nx_scope.sh`,
`nix/flake.nix`, `wsl/wsl_setup.ps1`.
