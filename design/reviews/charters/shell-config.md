# Charter - `shell-config`

The config rendered into users' shells - bash/zsh aliases and functions (`.assets/config/shell_cfg/`), the PowerShell profile and aliases (`.assets/config/pwsh_cfg/`), the oh-my-posh and starship themes - plus the user-level setup scripts under `.assets/setup/`. Users move between bash, zsh and PowerShell in the same week, so parity is the main lens.

## What good looks like

- **Cross-shell parity.** An alias or function defined on both sides does the same thing; the pairs are listed in `.claude/rules/cross-shell-parity.md`. A deliberate asymmetry carries an inline comment saying why.
- **Shell files source cleanly in bash and zsh**, and never use bare `mv`/`cp` (the user's `-i` aliases make them prompt).
- **No platform-hard-coded paths** in templates; resolve through env vars or detection.
- **Themes are valid** and `base` themes avoid Nerd Font glyphs.
- **`_aliases_*.ps1` files are dot-sourceable in any order**, OTBS, approved verbs.
- **Setup scripts are rerunnable** and check `$LASTEXITCODE` after native calls.
- **Tests** exercise aliases and functions in the shell that sources them.

## What NOT to flag

- **oh-my-posh and starship over oh-my-zsh** - see "Why oh-my-posh and starship, not oh-my-zsh".
- **The four omp themes, long alias lists and specific alias names** - user-visible; flag a broken alias, not a name.
- **The generated `completions.bash` / `completions.zsh`** - regenerate from `nx_surface.json`; they are not reviewed here.
- **`Write-Host` and OTBS in PowerShell** - project conventions.

## References

- `.claude/rules/cross-shell-parity.md`
- `ARCHITECTURE.md` sections 7.3, 7.7 and 13.4-13.5
