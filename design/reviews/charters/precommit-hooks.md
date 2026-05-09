# Charter - `precommit-hooks` shard (the gate scripts)

Pre-commit hooks gate every commit. False positives erode trust ("the hooks are paranoid, just bypass them with `--no-verify`") and slow daily work. False negatives let regressions through into `main`. Detection logic and exit codes need the same scrutiny as production code - these scripts are the project's first line of defense and the place where defense quality compounds.

## Scope

| File                                  | Role                                                                    |
| ------------------------------------- | ----------------------------------------------------------------------- |
| `tests/hooks/run_bats.py`             | Execute bats tests for changed shell script files                       |
| `tests/hooks/run_pester.py`           | Execute Pester tests for changed PowerShell files                       |
| `tests/hooks/check_bash32.py`         | Verify shell scripts for bash 3.2 / BSD sed compatibility               |
| `tests/hooks/check_zsh_compat.py`     | Verify shell scripts for zsh compatibility                              |
| `tests/hooks/check_changelog.py`      | Validate CHANGELOG.md structure and require updates for runtime changes |
| `tests/hooks/check_no_tty_read.py`    | Forbid `read ... </dev/tty` without `# tty-ok` annotation               |
| `tests/hooks/gen_nx_completions.py`   | Generate nx completions and help text from `nx_surface.json`            |
| `tests/hooks/check_nx_completions.py` | Verify generated completions match committed artifacts                  |
| `tests/hooks/validate_scopes.py`      | Validate scope definition internal consistency                          |
| `tests/hooks/validate_docs_words.py`  | Validate documentation word/language conventions                        |
| `tests/hooks/align_tables.py`         | Auto-align markdown table columns                                       |
| `tests/hooks/nix_closure_to_spdx.py`  | Transform nix closure JSON to SPDX 2.3 SBOM                             |
| `tests/hooks/gremlins.py`             | Scan staged files for unwanted Unicode characters                       |

**Out of scope:** the test bodies the hooks invoke (→ `test-quality` shard); the project-level prek configuration (`.pre-commit-config.yaml` is config, not hook logic).

## What "good" looks like

- **Deterministic exit codes: 0 on success, 1 on violation.** No other codes used as ad-hoc signals (e.g., 2 for "warn but pass" - do that with an explicit `print` and `exit 0`).
- **Output is parseable and points to the file:line.** A user running `make lint` should be able to jump from output to source. Format: `<file>:<line>: <message>` is the convention.
- **Hooks fail fast on the first violation per file** (or aggregate cleanly per file), not on the first across the whole batch - users want to see all the work in one run.
- **Detection patterns are conservative - borderline cases are NOT flagged unless there's a test for that case.** A regex that matches `mapfile` should not also match `_mapfile_internal`. False positives are technical debt; the test suite documents what's intentional.
- **Each hook has tests for true positives AND true negatives.** True positives prove it catches violations; true negatives prove it doesn't false-flag legitimate code that *looks* similar to a violation.
- **Hooks operate on the *staged* content via `git show :<path>`** where applicable, not on the working tree. Working-tree content can include un-staged changes that aren't part of the commit.
- **Generators are deterministic.** Same input always produces byte-identical output. `gen_nx_completions.py` running twice on the same `nx_surface.json` yields the same `.bash` and `.zsh` files.
- **No reliance on global Python state across files.** Each hook is invoked per-file by prek; module-level mutable state will leak if Python keeps the import cached.
- **`ruff` handles Python style; hooks themselves enforce only correctness rules.** A hook that flags style is overlapping with `ruff` - should be removed or scoped tighter.
- **No silent skips.** A hook that decides "this file isn't relevant" should `exit 0` cleanly; if it can't tell, it should fail loud.

## What NOT to flag

- **Use of `prek` (not `pre-commit`) as the runner.** Project convention; see [`.claude/CLAUDE.md`](../../../.claude/CLAUDE.md).
- **Python 3.x usage; `uv` for environment management.** Existing convention.
- **Specific hook implementations being "verbose."** Many of these need to handle multiple distro / shell edge cases - clarity > brevity.
- **The choice to enforce `bash 3.2` and `zsh` compat at all.** Per [`docs/decisions.md`](../../../docs/decisions.md). Findings about "drop bash 3.2 compat" go to the parent decision, not this shard.
- **The `# tty-ok` annotation marker pattern.** It's the documented escape hatch for `check_no_tty_read.py`.
- **Hook-as-Python (not bash) choice.** Hooks need to parse files, walk JSON, etc. - Python is the right tool. Don't suggest rewrites.
- **Anything already in [`design/reviews/accepted.md`](../accepted.md).**

## Severity rubric

| Level    | Definition                                                                                                                              | Examples                                                                                                                               |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| critical | A hook silently passes a real violation (false negative on something the hook is *named* for); a hook destructively mutates user files. | `check_bash32.py` doesn't catch `mapfile` because the regex only matches at column 0; `align_tables.py` corrupts a non-table markdown. |
| high     | Hook false-positives on legitimate code; non-deterministic generator output; non-zero exit on internal error swallowed.                 | `check_zsh_compat.py` flags a comment containing `[[ -v X ]]`; `gen_nx_completions.py` output order depends on dict iteration.         |
| medium   | Output not parseable; missing `:line:`; module-level state that leaks across files; no test for a true-negative case.                   | Hook prints "issue found" with no file/line; only true-positive tests, no protection against future false-positive regression.         |
| low      | Comment rot in the hook; redundant check overlapping with ruff; help text wrong.                                                        | Stale `# TODO` referencing a deleted file; hook flags `unused import` (ruff already does).                                             |

## Categories

| Category        | Use for                                                                                 |
| --------------- | --------------------------------------------------------------------------------------- |
| correctness     | A hook produces the wrong verdict on some input.                                        |
| security        | A hook that could be tricked into following a symlink, exec'ing user input, etc.        |
| maintainability | Hidden coupling between hooks; module-level state; hook does too many unrelated things. |
| testability     | A hook lacks a true-negative test for a case where false positives are likely.          |
| docs            | Hook lacks docstring; runnable-examples block stale; output format undocumented.        |

## References

- [`.claude/CLAUDE.md`](../../../.claude/CLAUDE.md) - `prek` not `pre-commit`; tool conventions
- `Makefile` - see how hooks are invoked (`make lint`, `make hooks`)
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes for this shard

## Charter version

- v1 (2026-05-09) - initial draft. Expect refinement after the first `/review precommit-hooks` cycle.
