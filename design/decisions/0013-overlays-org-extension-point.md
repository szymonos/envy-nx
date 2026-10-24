# Overlays as the org extension point

An org that bakes Envy-NX into a container image (a Coder workspace template, a
Codespaces or Dev Container image) needs its own packages on top of the standard
scopes, and wants that list to live with the image. The overlay directory
(`NIX_ENV_OVERLAY_DIR` or `$ENV_DIR/local`, ARCHITECTURE.md §13.3) was built for
this, but `design/overlay_catalog.md` §1 lists three gaps that
make it unusable for an image owner:

1. **Overlay scopes are never enabled.** `phase_platform_discover_overlay` copies
   `scopes/*.nix` to `$ENV_DIR/scopes/local_<name>.nix`, but nothing adds
   `local_<name>` to `config.nix`. The image would have to edit `config.nix`.
2. **Overlay hooks never run.** Tools installed by a command rather than a Nix
   package (global npm packages, `uv tool install`, gcloud components) have no home.
3. **One overlay at a time.** Setting `NIX_ENV_OVERLAY_DIR` hides every user's
   personal `~/.config/nix-env/local/`.

An overlay also cannot say which standard scopes it builds on. Scopes like
`gcloud`, `nodejs` and `python` trigger configure steps keyed by scope name
(`nix/configure/*.sh`), so the image has to pass scope flags at build and at every
start, and the package set is split between two places.

The rule behind every decision below: **the org overlay is the target state for
what it provides.** The org adds and removes; the user adds on top of it.

**Decision:**

**D1. A scope file in an overlay is installed.** Every `local_<name>` that
discovery syncs is added to `config.nix` on every setup run, attended or not.

- Removing the file from the overlay removes the scope from `config.nix` on the
  next run, and the next build drops its packages.
- `nx scope remove <name>` refuses for a scope the org overlay provides and names
  the overlay. For a scope from `$ENV_DIR/local` it deletes the file, as today.

**D2. A `# scopes:` header names the standard scopes an overlay needs.** It is
parsed like the `# bins:` header:

```nix
# scopes: shell python nodejs gcloud k8s_base
{ pkgs }: with pkgs; [ btop nano ]
```

- The named scopes are merged into the requested scopes before
  `phase_scopes_resolve_and_sort`, so dependencies, prompt exclusivity and
  `skip_system_prefer` apply exactly as for `setup.sh` flags.
- Names are checked against `scopes.json`. An unknown name warns, so an image
  built against an older release still starts.
- The scopes a header scope depends on count as named by the header: `az`
  brings `python`, which is then protected and removed the same way.
- **Dropping a name from the header removes the scope once.** Setup saves the
  merged header scopes to `$ENV_DIR/overlay_scopes`. A scope in the saved list but
  in no current header is removed, with its remove step, and setup prints it. A
  user who adds it back afterwards keeps it.
- **A header scope cannot be removed or added around the header.**
  `setup.sh --remove <scope>` and `nx scope remove <scope>` skip a scope that a
  header names and say where it comes from: "controlled by the organization
  overlay" for `NIX_ENV_OVERLAY_DIR`, "remove it from `<file>`" for
  `$ENV_DIR/local`. `setup.sh --<scope>` and `nx scope add <scope>` for a scope the
  org overlay already provides print that it is provided and change nothing, and a
  theme flag cannot swap out an overlay's prompt engine, which also replaces the
  user's other engine. The
  rest of the run goes on.

**D3. Overlay `post-setup.d` hooks run after the per-machine hooks.**
`$OVERLAY_DIR/hooks/post-setup.d/*.sh` runs after `$ENV_DIR/hooks/post-setup.d`,
once profiles and configure steps are done, so a hook sees the final PATH, fnm
Node and uv.

- Each hook runs as `bash "$hook"`, not sourced, with `ENV_DIR`,
  `NIX_ENV_PLATFORM` and the final scope list exported. Per-machine hooks are
  sourced so they can change phase variables; overlay hooks get no such access.
- A non-zero exit warns and setup continues.
- No `pre-setup.d` from overlays: discovery would have to move ahead of the
  pre-setup hooks, and nobody needs it.
- `nx overlay` lists overlay hooks as active.

**D4. The org overlay and the personal overlay apply together.** Discovery reads
the org overlay, then `$ENV_DIR/local` (if present), as a list of directories that
later sources (overlay subscriptions) can extend.

- **The org overlay path is stored, not only exported.** It comes from
  `setup.sh --overlay-dir <path>`, else `NIX_ENV_OVERLAY_DIR`, else the path
  saved in `$ENV_DIR/overlay_dir`. Setup saves whichever it used. `nx overlay set
  <path>` and `nx overlay unset` change the saved path; the variable still wins,
  so an image keeps using `ENV`.
- **A missing or unreadable org overlay stops setup** before it changes any scope.
  Read as empty, it would remove every org scope and run their remove steps.

- Both sync into the `local_<name>` namespace. **On a name clash the org file
  wins** and setup warns, naming both files. `nx scope add <name>` refuses when the
  org overlay provides `<name>`.
- Orphan cleanup keeps `local_<name>.nix` while either directory provides it.
- `shell_cfg/` is copied from the org overlay first and the personal one second,
  so a personal file replaces an org file of the same name. The org controls the
  tools; the user controls their shell.
- Hooks run from the org overlay first, then the personal one.

**Rejected:**

- **Per-user opt-out of org scopes.** In an image, the next workspace start
  would re-enable the scope anyway, and the org decides what its workspaces carry.
- **An additive `# scopes:` header**, where a dropped name stays installed.
  `config.nix` cannot tell the header's scopes from the user's, so the org would
  have no way to take a standard scope back, for security or otherwise. Renaming
  the overlay file does not help: header scopes are not tied to the file.
- **Tracking who asked for each scope**, so a dropped header scope survives when
  the user also asked for it. The bookkeeping is easy to get wrong, and a wrong
  answer runs a remove step on a tool the user set up. Removing once and letting
  the user re-add is simpler.
- **Personal overlay wins on a scope clash.** An empty personal `team.nix` would
  remove the org's packages, the removal D1 refuses.
- **Removals reach only new workspaces; org hooks handle security removals.** A
  hook runs on every start and after the build, so it would remove a user's
  re-added scope each time and need a second build. Add a `# remove:` header if
  "new workspaces only" becomes a real need.
- **The org overlay chosen by the environment variable alone.** It exists only in
  shells that export it. A setup run from a shell without it (a script, a terminal
  that skipped the rc file) would see no org overlay and remove every org scope,
  remove steps included. Leaving the org overlay has to be a deliberate
  `nx overlay unset`.
- **Overlay hooks rejected outright** (`design/overlay_catalog.md` §3.7). That argument is about subscribing to another team's repository. A legacy
  overlay directory is put on disk by the machine's owner (the image build or the
  user), so it is trusted like `$ENV_DIR/hooks/`. §3.7 stands for subscriptions.

**Consequences:**

- An image runs `nix/setup.sh --unattended` with no scope flags, at build and at
  every start. The overlay is the one description of the environment.
- An org change reaches every existing workspace on its next start, removals
  included. Removals happen once and are printed; users can re-add what the org
  dropped.
- Workspace starts run unattended, so a header removal runs the scope's remove
  step without a prompt and deletes its home folder: `~/google-cloud-sdk` for
  `gcloud`, fnm's Node with the user's global npm packages for `nodejs`, uv's
  Pythons and tools for `python`. That is the intended clean-up; project files
  are where those packages are declared, so they reinstall easily.
- `OVERLAY_DIR` becomes a list; every consumer reads it as one.
- PowerShell needs no change: overlays feed Nix scopes and `~/.config/shell/`,
  which the pwsh profile does not read.

**Acceptance:**

- An overlay with `scopes/team.nix` produces `local_team` in `config.nix` and its
  packages after a flagless `nix/setup.sh --unattended`.
- `# scopes: gcloud k8s_base` installs both scopes, their dependencies and the
  gcloud configure step, as `--gcloud --k8s_base` would. An unknown name warns.
- Dropping `gcloud` from the header removes it once; `nx setup --gcloud`
  afterwards keeps it.
- Deleting `team.nix` from the overlay removes `local_team` on the next run.
- `setup.sh --remove gcloud` and `nx scope remove gcloud` skip a header-named
  scope with the message; adding an org-provided scope is a no-op with a message.
- `hooks/post-setup.d/a.sh` runs after profiles are built and sees `npm`; a
  failing hook warns and setup finishes.
- With the variable unset, a later run still uses the org overlay setup saved;
  after `nx overlay unset` it does not. A saved path that went missing stops setup.
- With both directories populated, scopes from both install, a clash resolves to
  the org file with a warning, and `shell_cfg/` from both is installed.
- `nx scope remove team` refuses for an org scope and works as today for a
  personal one.

**Scope:** `nix/lib/phases/platform.sh`, `nix/lib/phases/scopes.sh`, `nix/lib/phases/bootstrap.sh`,
`nix/setup.sh`, `nix/configure/profiles.sh`, `nix/configure/profiles.zsh`,
`.assets/lib/nx_scope.sh`, `.assets/lib/nx_doctor.sh`
