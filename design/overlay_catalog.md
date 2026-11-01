# Overlay subscriptions and catalogs

Status: **phase 1 implemented, in a different shape** - overlays are `overlays/<name>/` folders picked by name, and the organization overlay folder is folded into subscriptions. [Decision 0015](decisions/0015-overlay-subscriptions.md) is authoritative where this proposal differs; phase 2 is open.

Makes overlays something a user subscribes to with one command, from a whole
repository or from one directory of a curated catalog repository, instead of a
directory they clone and wire up by hand. Supersedes the distribution half of
[`enterprise_design.md`](enterprise_design.md) §1; the policy half (signing,
version gates, an org baseline users cannot bypass) stays there, unchanged and deferred.

---

## 1. Where the overlay system is today

As verified against the code on 2026-09-24, before decision 0013. Items 1-3 meant the
team pattern that `docs/customization.md` described did not work end to end for a consumer.

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

Decision [0013](decisions/0013-overlays-org-extension-point.md) (overlays as the org
extension point) resolves findings 1, 2 and 5 for the legacy directory: its scopes
are enabled automatically, its `post-setup.d` hooks run, and `NIX_ENV_OVERLAY_DIR`
adds to `$ENV_DIR/local`. Subscriptions still need their own answer to each, given
below. Findings 4 and 6 are resolved only here.

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

## 3. Decisions, user surface and acceptance (as built)

The reviewed proposal here addressed folders by path (`?dir=`), kept the organization overlay folder
beside subscriptions, and treated the repository root as an overlay. The built phase 1 replaced all
three, and these sections were retired rather than kept in two versions:

- **Decisions:** [decision 0015](decisions/0015-overlay-subscriptions.md) - overlays are
  `overlays/<name>/` folders picked by name, addresses are `<repo>#<overlay>` with `/<ref>` or
  `?ref=`, a no-name address is resolved once (the only overlay, else `default`), the organization
  overlay folder is folded into subscriptions, and only a local folder runs hooks.
- **User surface:** `nx overlay`, `nx overlay add|remove|update|browse`, `nix/setup.sh --overlay`,
  `wsl_setup.ps1 -Overlay` - see [`docs/overlays.md`](../docs/overlays.md).
- **Acceptance:** the eight fixture scenarios in `tests/bats/test_overlay_subscribe.bats`
  ("acceptance N"), run against a local copy of the `github:szymonos/nix-overlay` layout.

## 4. Phases

**Phase 1 - subscriptions (1.33.0, done).** Overlays by name, `nx overlay
add|remove|update|browse`, `--overlay`, update on every setup and upgrade, and the
organization overlay folder folded in - which also delivered what phase 3 was for.

**Phase 2 - catalogs.** `overlay.yaml` metadata beyond the README line for the IDP, a
CI example for catalog repositories (`nix eval` every scope before merge), the
template repository.

## 5. Fixed in the docs, independent of this proposal

Decision 0013 later made overlay scopes enable themselves and overlay
`post-setup.d` hooks run. `docs/customization.md` and `docs/overlays.md` describe
that; the remaining consumer steps for a team overlay (clone, set the variable,
`nx setup`) are the gap phase 1 removes (finding 3).

## 6. Review questions

1. Is "subscribing enables every scope in the directory" (3.5) right for a large
   catalog directory, or should `overlay.yaml` name a default subset?
2. Should `ref` pinning be encouraged for catalogs (stable), or is following the
   default branch the intended model (fresh)?
