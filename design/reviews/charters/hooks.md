# Charter - `hooks`

The pre-commit gate scripts under `tests/hooks/` and their tests. False positives teach people to `--no-verify`; false negatives let regressions onto `main`. These are the project's first line of defense, so detection logic and exit codes get production scrutiny.

## What good looks like

- **Exit 0 on pass, 1 on a violation**, nothing else as an ad-hoc signal.
- **Output names `file:line`** and says how to fix it.
- **All violations in one run**, not just the first.
- **Patterns are conservative**: a regex for `mapfile` does not match `_mapfile_internal`, and every borderline case has a test.
- **True positives and true negatives are both tested.**
- **Hooks read staged content** (`git show :<path>`) where it matters.
- **No module-level mutable state** leaking between files.
- **No silent skips** - a hook that cannot tell whether a file is relevant fails loud.

## What NOT to flag

- **`prek` as the runner, Python for hooks** - project conventions.
- **Enforcing bash 3.2 and zsh compatibility at all** - a decision in `docs/decisions.md`, not a hook defect.
- **The `# tty-ok` annotation** - the documented escape hatch for `check_no_tty_read.py`.
- **Verbose detection code** that handles real edge cases.

## References

- `ARCHITECTURE.md` sections 6.7 and 8
- `docs/standards.md` - what each hook exists to catch
