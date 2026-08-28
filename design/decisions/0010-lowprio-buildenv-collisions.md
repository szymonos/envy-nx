# lib.lowPrio for buildEnv per-file collisions

Some nixpkgs packages ship extra CLIs bundled inside their own derivation (e.g.
`pkgs.minikube` includes `bin/kubectl`). When such a bundler and the standalone
version of the bundled tool both land in the env, `buildEnv` sees two derivations
at the same `meta.priority` claiming the same relative path and aborts the profile
build with a conflicting-subpath error. `lib.lowPrio` demotes the bundler's whole
derivation to priority 10, so the standalone package (default 5) wins the colliding
file while every non-colliding file from the bundler still links. `lib.hiPrio`
(-10) is the symmetric primitive for the rare case where a scope must ship a
patched variant that has to override the base package.

**Decision:** Known bundler-class packages are named in `collisionLowPrio` in
`nix/flake.nix`, and the `demote` helper applies `lib.lowPrio` to them across every
source of packages - base, init, scopes, and the ad-hoc `packages.nix` written by
`nx install`. The tag is *not* written into the scope file as
`(lib.lowPrio minikube)`, for two reasons:

- The repo parses scope files for package names with a line-anchored `sed`
  (`_nx_scope_pkgs` in `.assets/lib/nx.sh`). A wrapped entry is invisible to it, so
  the package disappears from `nx scope tree` / `nx list` and, worse, from
  `_nx_all_scope_pkgs` - the "already installed in scope X" guard - so
  `nx install minikube` would silently add a second copy to `packages.nix`.
- A scope-file tag cannot cover `packages.nix`. A user on `k8s_base` who runs
  `nx install minikube` hits the identical build failure with no path out short of
  editing the flake.

Do **not** resolve collisions with `ignoreCollisions = true` on the flake:
collisions are diagnosed at build time on purpose, and silently picking an
arbitrary winner is how a wrong `kubectl` reaches a user's PATH.

**Consequence:** The demotion is per *derivation*, not per file - a demoted package
loses every path it shares with another package and keeps everything unique to it.
That is desirable for the bundler case and is why `collisionLowPrio` holds only
packages whose duplicated files are genuinely the other package's job. Because the
list is keyed on `lib.getName`, it also demotes the package when it arrives via
`packages.nix`. New collisions surface through `make test-scope-env`, which builds
every scope at once; the same check pins `kubectl` to the `kubectl` derivation so a
future demotion cannot flip the winner unnoticed.

**Scope:** `nix/flake.nix`, `nix/scopes/*.nix`

## Scenarios

| # | Situation                                                               | Without a priority tag                                  | With `lib.lowPrio` on the bundler                                        |
| - | ----------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------ |
| A | Standalone tool only                                                    | Works.                                                  | Unchanged.                                                               |
| B | Bundler only                                                            | Works. Bundled CLI is linked (no rival).                | Unchanged. Bundler is priority-10 but still the only candidate.          |
| C | Standalone + bundler together                                           | **Fails** - two equal-priority claims on the same path. | Standalone wins the colliding file; bundler keeps everything else.       |
| D | Two standalone packages claim the same binary (duplicate across scopes) | Fails - two default-priority claims collide.            | Not this record's remit; fix by dropping the duplicate.                  |
| E | Two bundlers both ship the same bundled CLI                             | Fails - two default-priority claims collide.            | Requires each bundler that must yield to be named in `collisionLowPrio`. |
| F | Non-CLI file from a bundler collides with the same file in a standalone | Fails with a collision error on the shared file.        | Standalone version wins; bundler's copy is skipped (usually desirable).  |

## First application

`pkgs.minikube` ships `bin/kubectl` as a symlink to itself, colliding with
`pkgs.kubectl` from `nix/scopes/k8s_base.nix` - a dependency of the `k8s_ext` scope
that pulls minikube in, so every `k8s_ext` install hit it (v1.19.4).
