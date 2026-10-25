# Charter - `test-harness`

What runs the checks: the smart test runners (`tests/hooks/run_bats.py`, `tests/hooks/run_pester.py`), the generators, `Makefile`, `.pre-commit-config.yaml`, lint configs and the Docker smoke images. If the harness reports green wrongly, every other shard's tests stop meaning anything.

## What good looks like

- **The runners map changed files to every test that sources them**, and a test that cannot be mapped runs rather than being skipped.
- **A failing test fails the run** - no swallowed exit code, no hang without a timeout.
- **`make` is the one entry point** and every target has a `##` help comment.
- **The same hook set runs locally and in CI.**
- **Generators are deterministic** - same input, same bytes.
- **Docker smoke images exercise the real install path**, not a shortcut.

## What NOT to flag

- **The `make` contract and `prek`** - see `docs/standards.md`, "Make: the unified entry point".
- **`mkdocs build --strict` living in CI, not pre-commit** - it needs the full docs dependency set.
- **Tests per subject living in other shards** - this shard owns the harness, not the suites.

## References

- `ARCHITECTURE.md` sections 8 and 9
- `docs/standards.md`
