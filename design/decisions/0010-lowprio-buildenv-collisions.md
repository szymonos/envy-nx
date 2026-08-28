# lib.lowPrio for buildEnv per-file collisions

Some nixpkgs packages ship extra CLIs bundled inside their own derivation
(e.g. `pkgs.minikube` includes `bin/kubectl`). When such a bundler and the
standalone version of the bundled tool are both requested by the enabled
scope set, `buildEnv` sees two derivations at the same `meta.priority`
claiming the same relative path and aborts the profile build with a
conflicting-subpath error. `lib.lowPrio` demotes the bundler's whole
derivation to priority 10, letting the standalone package (default
priority 5) win the per-file collision while every non-colliding file from
the bundler still links. `lib.hiPrio` is the symmetric primitive for the
rare case where a scope must ship a patched variant that must override the
base package.

**Constraint:** Bundler-class packages (those known to ship a CLI already
provided by another package in the base or scopes) are tagged with
`lib.lowPrio` in their scope file. Do not resolve `buildEnv` collisions
via `ignoreCollisions = true` on the flake - collisions are diagnosed at
build time, on purpose. Do not introduce a cross-scope exclusion table;
`meta.priority` handles resolution at the right abstraction level (per
file, not per package name).

**Scope:** `nix/scopes/*.nix`, `nix/flake.nix`

## Scenarios

| # | Situation                                                                      | Without a priority tag                                  | With `lib.lowPrio` on the bundler                                       |
| - | ------------------------------------------------------------------------------ | ------------------------------------------------------- | ----------------------------------------------------------------------- |
| A | Standalone tool only enabled                                                   | Works.                                                  | Unchanged.                                                              |
| B | Bundler only enabled                                                           | Works. Bundled CLI is linked (no rival).                | Unchanged. Bundler is priority-10 but still the only candidate.         |
| C | Standalone + bundler enabled together                                          | **Fails** - two equal-priority claims on the same path. | Standalone wins the colliding file; bundler keeps everything else.      |
| D | Two standalone packages claim the same binary (duplicate across scopes)        | Fails - two default-priority claims collide.            | Unchanged. Not this ADR's remit; fix by dropping the duplicate.         |
| E | Two bundlers within the same scope both ship the same bundled CLI              | Fails - two default-priority claims collide.            | Requires `lib.lowPrio` on each bundler that yields to the standalone.   |
| F | Non-CLI file from a bundler collides with a corresponding file in a standalone | Fails with a collision error on the shared file.        | Standalone version wins; bundler's copy is skipped (usually desirable). |

## First application

`nix/scopes/k8s_ext.nix` tags `pkgs.minikube` with `lib.lowPrio` so its
bundled `bin/kubectl` yields to standalone `pkgs.kubectl` from
`nix/scopes/k8s_base.nix`.
