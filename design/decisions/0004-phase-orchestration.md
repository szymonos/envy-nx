# Phase-based orchestration with side-effect stubs

A 600-line bash script written top-to-bottom is untestable. This tool uses a phase library architecture: `nix/setup.sh` is a slim ~110-line orchestrator that sources independent phase files from `nix/lib/phases/`. Side effects are routed through thin `_io_*` wrappers in `nix/lib/io.sh` that tests override by function redefinition.

**Constraint:** Never call `nix`, `curl`, or external scripts directly from phase functions. Route through `_io_nix`, `_io_curl_probe`, or `_io_run`. Each phase file must have `# Reads:` / `# Writes:` header comments documenting cross-phase data flow. Tests override wrappers before sourcing the phase under test - no mocking frameworks needed.

**Scope:** `nix/lib/phases/*.sh`, `nix/lib/io.sh`, `nix/setup.sh`, `tests/bats/test_*.bats`
