# JSON as the shared schema format

Scope metadata (valid names, install order, dependency rules) must be consumed by three runtimes: bash (`jq`), PowerShell (`ConvertFrom-Json`), and Python (`json` stdlib). JSON is the only format all three parse natively without custom parsers.

**Constraint:** Cross-runtime data lives in JSON (e.g., `scopes.json`, `nx_surface.json`, `install.json`). Do not introduce YAML, TOML, or bash-sourceable data for anything consumed by more than one runtime. `jq` is bootstrapped via `base_init.nix` on first run for macOS machines that start without it.

**Scope:** `.assets/lib/scopes.json`, `.assets/lib/nx_surface.json`, `nix/scopes/*.nix`
