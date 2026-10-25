# Charter - `nx-core`

The `nx` dispatcher (`.assets/lib/nx.sh`), its shared helpers, the revision helper and the manifest `.assets/lib/nx_surface.json` that generates every completer, dispatcher arm and help text in bash, zsh and PowerShell. `nx` is sourced into every interactive shell on every login, so a leaked variable, a slow source or a zsh incompatibility is daily user pain, and verb names are muscle memory.

## What good looks like

- **Prefix discipline.** Public verbs `nx_*`, private helpers `_nx_*`, IO wrappers `_io_*`, scope helpers `scope_*`. Nothing unprefixed leaks into the user's shell; functions use `local`.
- **bash 3.2 and zsh 5+** both work. The hooks catch syntax; review catches semantics - word splitting, 0-based vs 1-based arrays, an unguarded bash-only builtin.
- **Sourcing is cheap.** Expensive work happens inside verbs, not at source time.
- **`nx_surface.json` is the single source of truth**, and `tests/hooks/gen_nx_completions.py` output is deterministic. A verb, flag or help line edited by hand in a generated artifact is a defect.
- **Verbs are forward-compatible.** Adding one never changes another; removing or renaming one is a breaking change with a CHANGELOG note.
- **pwsh is called only through `_io_pwsh_nop`**, and bare `mv`/`cp` never appear in shell-sourced files (they inherit the user's `-i` aliases).
- **bash and PowerShell dispatchers agree** on verbs and flags, since both are generated from one manifest.
- **Tests** run the completers and dispatcher the way a shell does, including under zsh.

## What NOT to flag

- **`nx` as a shell function, not a Python or Go CLI** - see "Why bash end-to-end".
- **bash 3.2 verbosity** - see "Why bash 3.2 compatibility".
- **The prefix convention itself** - flag violations of it.
- **Independent bash and PowerShell `nx profile` dispatchers** - `REVIEW.md` Author decisions.

## References

- `ARCHITECTURE.md` sections 3c, 3d, 5 and 7.3
