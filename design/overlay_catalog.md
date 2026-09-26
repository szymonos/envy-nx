# Overlay subscriptions and catalogs

Status: **proposal** - for review before any implementation.

Makes overlays something a user subscribes to with one command, from a whole
repository or from one directory of a curated catalog repository, instead of a
directory they clone and wire up by hand. Supersedes the distribution half of
[`enterprise_design.md`](enterprise_design.md) §1; the policy half (signing,
version gates, an org baseline users cannot bypass) stays there, unchanged and deferred.

---

## 1. Where the overlay system is today

Verified against the code on 2026-09-24. Items 1-3 mean the team pattern that
`docs/customization.md` describes does not work end to end for a consumer.

1. **A cloned overlay's scopes are never enabled.** `phase_platform_discover_overlay`
   copies each scope file to `local_<name>.nix`, but a scope is built only when
   `config.nix` lists it. Only `nx scope add` writes that entry, and only when it
   *creates* the file - for a file that already exists (the clone case) it prints
   "already exists" and registers nothing. No `nix/setup.sh` flag accepts an
   overlay scope either. The consumer's only way in is editing `config.nix` by hand.
2. **Overlay hooks never run.** `phase_platform_run_hooks` is called only with
   `$ENV_DIR/hooks/pre-setup.d` and `$ENV_DIR/hooks/post-setup.d`; nothing reads
   the overlay's `hooks/`. `pre-setup` also runs before overlay discovery, so it
   could not see the overlay even if it looked. `nx overlay` lists hook files it
   will never execute.
3. **Without the source repo, `nx upgrade` does not sync the overlay.** The copy
   step runs only in `nix/setup.sh`. Since decision
   [0012](decisions/0012-one-upgrade-path.md) `nx upgrade` runs it too, so this
   gap remains only for the in-place fallback, which rebuilds from the copies
   made by the last setup.
4. **A scope cannot import a sibling file.** Only `scopes/*.nix` is copied, and the
   flake is installed as `path:$ENV_DIR`, so a pure evaluation cannot read the
   overlay directory. `import ../pkgs/tool.nix` resolves against the copy and
   fails. This blocks sharing a derivation between scopes.
5. **One overlay at a time.** `NIX_ENV_OVERLAY_DIR` replaces `$ENV_DIR/local`
   instead of adding to it (documented in `docs/customization.md`).
6. **`nx overlay list` and `nx overlay status` are the same command.** Both are
   declared in `.assets/lib/nx_surface.json`; `_nx_overlay_dispatch` ignores its
   argument apart from `help`.

What does work: `shell_cfg/` files are installed by `nix/configure/profiles.sh`,
and a scope file may build its own derivation (documented, with the
`nx scope add` rewrite guard).

## 2. Goals and non-goals

Goals:

- A consumer joins an overlay with **one command** and never edits a shell rc or
  `config.nix`.
- An overlay is addressed as a **repository, or a directory inside one**, so an
  org can run a curated catalog repo and an IDP entry is a single string.
- **Several overlays at once** - a personal one next to a team one.
- Scopes in one overlay repo can **share Nix files** (package a tool once).
- Updates are visible: the user sees what changed before code that runs in their
  shell changes.

Non-goals (stay in `enterprise_design.md` §1):

- Signature verification, `min_core_version` gates, org-over-user precedence.
- A package registry or index service. The catalog is a git repo, nothing more.

## 3. Decisions

### 3.1 Address format

```text
github:<owner>/<repo>[?dir=<path>][&ref=<branch-or-tag>]
<any git URL>[?dir=<path>][&ref=<branch-or-tag>]
<local path>
```

- `?dir=` and `&ref=` follow Nix flake-reference syntax, so users who know Nix
  read it without learning anything. `github:owner/repo/<segment>` is **not**
  used for directories: in flake syntax the third segment is a ref.
- No `dir` means the repository root is the overlay.
- No `ref` means the default branch; subscribers follow it.
- A local path is a subscription too - this is how an author tests before pushing.
- Private repos need nothing from nx: it runs `git`, which uses the user's SSH key
  or `gh` credential helper.

### 3.2 Fetch per repository, subscribe per directory

The repository is the unit of **fetch**; the directory is the unit of
**subscription**. Five subscriptions to one catalog are one clone and one pull.

- Clone into a cache outside the flake: `~/.cache/nix-env/overlays/<repo-key>/`.
- Copy the working tree, **without `.git`**, into `$ENV_DIR/overlays/<repo-key>/`.

The copy is required, not a convenience. `path:` flakes copy the whole directory
into the store on evaluation, so a clone inside `$ENV_DIR` would drag `.git` into
the store on every build, and files outside `$ENV_DIR` are invisible to the pure
evaluation. Copying the **whole repo tree**, not only the subscribed directory,
is what makes shared files work (finding 4): a scope can
`import ../../_pkgs/sofka.nix` from anywhere in the same repo. The unsubscribed
directories cost a few kilobytes of text.

### 3.3 Subscription list

`$ENV_DIR/overlays.list`, one subscription per line:

```text
<name> <address>
```

Plain text so it parses under bash 3.2 without `jq`. `config.nix` is not used: it
is regenerated by `_nx_write_config` and read back with `sed`, and a second field
there makes both more fragile.

`<name>` defaults to the last path segment of `dir`, or the repo name when `dir`
is empty. A clash with an existing name is refused; `--as <name>` resolves it.

### 3.4 Scope names are namespaced

A subscribed scope is identified as `<overlay>/<scope>` - for example
`data-science/python_ml`. A catalog makes collisions certain (every directory
will want a `base.nix`), so rejecting them is not enough. The slash mirrors the
directory layout and reads like a GitHub path.

The flake gains one small, overlay-agnostic change: a second list in
`config.nix`, imported as `./overlays/<repo-key>/<dir>/scopes/<scope>.nix`. The
flake still knows nothing about git, catalogs, or where overlays came from.

### 3.5 Subscribing enables the overlay's scopes

The directory is the unit: `nx overlay add` enables every scope in it, and a
scope added upstream is enabled on the next update. A curated directory *is* a
use case, so this matches what the subscriber asked for. `nx scope remove
<overlay>/<scope>` opts out of one scope and the opt-out survives updates.

This removes finding 1 by construction: nobody enables overlay scopes by hand.

### 3.6 Updates and trust

`nx upgrade` updates every subscription (fast-forward only) before it rebuilds,
and prints the incoming commit range and changed files per overlay.

Anything that runs in the user's shell needs a confirmation:

| Changed in the update      | Behaviour                                      |
| -------------------------- | ---------------------------------------------- |
| `scopes/` and other `.nix` | applied; summary printed                       |
| `shell_cfg/`               | diff shown, confirmation required              |
| `hooks/` (see 3.7)         | ignored - overlays do not ship hooks           |
| unattended run             | shell-affecting updates skipped with a warning |

Scope files are code too - a derivation's build script runs on the machine, and
the Nix build sandbox is off by default on macOS. "Scopes are relaxed" means
*not prompted*, not *trusted*: the change summary is always printed, and a
catalog repo needs `CODEOWNERS` and branch protection (stated in the author
docs, not enforced by nx).

`nx overlay update [name]` does the same on demand.

### 3.7 Overlay hooks

**Decided: overlays do not ship hooks.** Hooks stay per-machine, read only from
`$ENV_DIR/hooks/`, and a `hooks/` folder in an overlay is ignored. They have
never run from an overlay (finding 2), so nothing depends on them, and they are
the part of an overlay with the widest blast radius: subscribing would mean
running another team's scripts inside every setup. The user docs state this.
Revisit only when a team brings a concrete hook it needs.

### 3.8 Legacy overlay directory

`NIX_ENV_OVERLAY_DIR` and `$ENV_DIR/local` keep working exactly as today, with
the `local_` prefix, alongside subscriptions. This is the escape hatch for orgs
that distribute through MDM or a mounted share. Converging it into a subscription
named `local` is phase 3, tracked with a `CLEANUP:` entry in
[`cleanup_queue.md`](cleanup_queue.md).

## 4. User-facing surface

Consumer:

```bash
nx overlay add github:org/team-overlay
nx overlay add 'github:org/overlays?dir=data-science'
nx overlay                        # subscriptions, source, ref, last update
nx overlay update [name]
nx overlay remove <name>
nix/setup.sh --shell --overlay 'github:org/overlays?dir=data-science'   # onboarding one-liner
```

Author:

- Start from a GitHub template repository (an overlay skeleton with one example
  scope and a README). Maintained outside this repo; no nx code.
- Test locally: `nx overlay add ~/src/team-overlay`.

Catalog layout (a convention, not enforced):

```text
overlays/                 # one repo
├── _pkgs/                # shared derivations, e.g. sofka.nix
├── data-science/
│   ├── overlay.yaml      # phase 2: name, description, owner - read by the IDP
│   ├── scopes/
│   └── shell_cfg/
└── k8s-platform/
    ├── overlay.yaml
    └── scopes/
```

`nx overlay list` and `nx overlay status` are dropped from `nx_surface.json` in
favour of the verbs above (finding 6).

## 5. Phases

**Phase 1 - subscriptions.** Address parsing, cache clone, tree copy,
`overlays.list`, namespaced scopes, the flake change, `nx overlay
add|remove|update`, the bare `nx overlay` view, the `--overlay` setup flag, and
update-on-upgrade with the confirmation rules in 3.6. Regenerate the completers
(bash, zsh and pwsh all come from `nx_surface.json`).

**Phase 2 - catalogs.** `overlay.yaml` metadata, `nx overlay available <repo>` to
list a catalog's directories, a CI example for catalog repos (`nix eval` every
scope before merge), the template repository.

**Phase 3 - convergence.** Fold the legacy directory into a subscription named
`local`, rewrite `local_<name>` scope ids to `local/<name>`, remove the shim.

## 6. Acceptance criteria (phase 1)

- `nx overlay add 'github:<owner>/<repo>?dir=<d>'` on a clean machine results in
  the directory's scopes being built, with no manual edit anywhere.
- Two subscriptions from the same repo produce one clone in the cache.
- A scope that imports `../../_pkgs/<file>.nix` from the same repo builds.
- Two overlays that both ship `base.nix` coexist as `<a>/base` and `<b>/base`.
- `nx upgrade` pulls subscriptions; a `shell_cfg/` change prompts; an unattended
  run skips it with a warning.
- `nx scope remove <overlay>/<scope>` survives the next update.
- A subscription to an unreachable repo fails that subscription only; the rest of
  the upgrade proceeds.
- `NIX_ENV_OVERLAY_DIR` behaviour is unchanged.
- bats coverage for address parsing, list parsing, namespacing, the copy, and the
  trust rules, using a local bare repo as the remote.

## 7. Fixed in the docs, independent of this proposal

The user docs no longer claim overlays ship hooks (finding 2), and
`docs/customization.md` now spells out the real consumer steps for a team overlay
(clone, set the variable, `nx setup`, enable each scope in `config.nix`,
`nx upgrade`) and marks them as the gap phase 1 removes (findings 1 and 3).

## 8. Review questions

1. Is "subscribing enables every scope in the directory" (3.5) right for a large
   catalog directory, or should `overlay.yaml` name a default subset?
2. Should `ref` pinning be encouraged for catalogs (stable), or is following the
   default branch the intended model (fresh)?
