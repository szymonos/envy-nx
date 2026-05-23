# Bash end-to-end, not Python or Go

macOS no longer ships Python. The tool cannot assume Python exists on a fresh machine - the same bootstrapping paradox that justifies bash 3.2 compatibility. The codebase already has the structural properties of a well-engineered typed codebase: phase library with `_io_*` stubs, 658+ test cases, mechanical constraint enforcement via pre-commit hooks.

**Constraint:** Do not propose rewriting orchestration or CLI logic in Python, Go, or Rust. The bootstrapper and `nx` CLI must remain pure bash with zero runtime dependencies beyond Nix-installed tools. If a specific capability genuinely needs a compiled tool (dependency graph solving, structured API clients), extract it as a single binary called via `_io_run` - the orchestrator stays bash.

**Scope:** `nix/setup.sh`, `.assets/lib/nx*.sh`, `nix/lib/phases/*.sh`
