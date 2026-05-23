# Unfree packages are opt-in, not default

Setting `allowUnfree = true` silently permits proprietary-licensed packages. For enterprise adoption this creates license compliance exposure, binary cache misses (unfree packages must build from source), and reproducibility gaps (license-restricted source may be withdrawn).

**Constraint:** Never set `allowUnfree = true` by default. The default scope set contains zero unfree packages. Users opt in explicitly via `--allow-unfree` flag (sticky in `config.nix`). Terraform is handled via `tfswitch` (MIT-licensed) to avoid the unfree dependency entirely.

**Scope:** `nix/flake.nix`, `.assets/lib/nx.sh` (nx install), `nix/lib/phases/scopes.sh`
