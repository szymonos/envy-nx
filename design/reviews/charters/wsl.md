# Charter - `wsl`

Windows-host PowerShell that creates and provisions WSL distros before any of them exists (`wsl/*.ps1`), and the repo-owned modules behind it (`modules/utils-setup/`, `modules/utils-install/`). There is no CI that boots real WSL2 - only mocked Pester tests - so review stands in for integration testing.

## What good looks like

- **Admin is checked with a principal check**, not assumed.
- **Files crossing into WSL are UTF-8 without BOM** (`-Encoding utf8NoBOM` or `[IO.File]::WriteAllText`).
- **Paths are translated with `wsl wslpath -a`**, not string substitution.
- **Long operations survive idle shutdown** - one `wsl -- bash -c` call, or a restart accepted.
- **`$LASTEXITCODE` is checked after every `wsl.exe` call**; native `--install` / `--update` go through `Invoke-WslExe`.
- **`$Script:rel_*` caches release versions across the distro loop**, consistently.
- **Phase functions in `modules/utils-setup/` stay unit-testable**, with realistic mocked distro state in `tests/pester/WslSetupPhases.Tests.ps1`.
- **Public functions have comment-based help**; OTBS, approved verbs, PascalCase parameters.

## What NOT to flag

- **PowerShell itself** - the only option on a stock Windows host.
- **Mocked Pester tests in place of real WSL boots** - a known limitation (`docs/index.md`).
- **Repeated `wsl --shutdown`** - needed after config changes.
- **PowerShell 5.1 syntax in `wsl/pwsh_setup.ps1`** - it runs on the host's stock PowerShell.
- **The vendored `modules/do-*`, `modules/psm-windows`, `modules/aliases-*`** - fixed upstream, not reviewed here.

## References

- `ARCHITECTURE.md` section 3h
- `.claude/rules/powershell-style.md`
