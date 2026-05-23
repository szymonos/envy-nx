# Managed blocks, not append-style profile injection

The `grep -q 'pattern' || echo 'line' >> ~/.bashrc` pattern is fragile: duplicates on re-run, no in-place update, no clean removal. This tool uses sentinel-delimited managed blocks (`# >>> nix-env managed >>>` / `# <<< nix-env managed <<<`) that are fully regenerated on each run.

**Constraint:** Never append lines to shell profile files directly. Always write inside managed blocks via `_nx_render_nix_block` (bash/zsh) or `Update-ProfileRegion` (PowerShell `#region`/`#endregion`). Two block types: nix-specific (removed on uninstall) and generic (certs, local PATH - preserved after uninstall). `nx doctor` detects duplicate or missing blocks.

**Scope:** `.assets/lib/nx_profile.sh`, `.assets/config/pwsh_cfg/_aliases_nix.ps1`, `nix/lib/phases/profiles.sh`, `nix/uninstall.sh`
