# Three package tiers, not everything via Nix

Nix is user-scope after install - it cannot provide packages that require root, setuid, or must exist before Nix is available. Forcing system-scope packages into Nix creates fragile workarounds.

**Constraint:** Every package belongs to exactly one tier: **system-only** (ca-certificates, curl, sudo - installed by `install_base.sh` with root), **system-prefer** (vim, zsh - system on Linux, Nix on macOS), or **always-nix** (git, ripgrep, kubectl, uv - user-scope via flake). Never move a system-only package into the Nix flake. The `phase_scopes_skip_system_prefer()` function handles the conditional logic centrally.

**Scope:** `nix/scopes/*.nix`, `.assets/provision/install_*.sh`, `nix/lib/phases/scopes.sh`
