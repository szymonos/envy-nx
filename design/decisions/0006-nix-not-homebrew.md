# Nix, not Homebrew

Homebrew is a macOS package manager. Nix is a cross-platform environment provisioning tool. The differences that matter: atomic rollback (`nix profile rollback`), reproducible pins (`flake.lock` / `nx pin`), cross-platform parity (macOS, Linux, WSL, containers - identical), and user-scope operation after initial install.

**Constraint:** Never suggest `brew install` as an alternative or fallback. The entire architecture depends on Nix's store-based isolation, atomic profile management, and `buildEnv` scope composition. Homebrew cannot provide these properties. Enterprise off-ramp: Determinate Systems provides commercially supported Nix with MDM integration.

**Scope:** `nix/**`, `.assets/lib/scopes.*`, `ARCHITECTURE.md`
