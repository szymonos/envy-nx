# Charter - `test-quality` shard (bats + Pester)

Reviewing the tests themselves. Are they testing the right thing? Are mocks too lenient - mock-prod divergence is a known incident shape elsewhere in the industry and worth preempting? Do test names accurately describe what they assert, or do they lie? Low blast radius (it's test code) but compounds: a bad test misleads every future reader, and a permissive mock can hide a regression for months while CI happily reports green.

## Scope

| Surface           | Files                      | Role                                                             |
| ----------------- | -------------------------- | ---------------------------------------------------------------- |
| Bats unit tests   | `tests/bats/*.bats`        | Bash unit tests using the function-redef stubbing pattern        |
| Pester unit tests | `tests/pester/*.Tests.ps1` | PowerShell tests for `do-common`, `psm-windows`, WSL phase logic |

**Out of scope:** the production code under test (each lives in its own shard); the test-runner hooks (`run_bats.py`, `run_pester.py` - that's the `precommit-hooks` shard).

## What "good" looks like

- **Each test name describes what it asserts in the present tense.** "merge_local_certs deduplicates by serial" beats "test that merge_local_certs works". A reader scanning test names should be able to predict the assertion without reading the body.
- **Function-redef stubbing overrides only side effects, not the logic under test.** If `_io_run` is the seam, stub `_io_run` - don't stub the function that calls it (because then you're testing your stub instead of the function).
- **Pester mocks via `Mock` or `InModuleScope`,** never via global function shadowing that leaks across tests. Each test starts and ends in a clean state.
- **Setup / teardown leaves no temp files, env vars, or test artifacts behind.** `BATS_TEST_TMPDIR` for FS operations (auto-cleaned by bats); explicit `unset` for any env vars set during a test.
- **Edge-case coverage is explicit.** Empty input, malformed JSON, missing files, permission denied, partial state - these are usually the bugs in production. A test file that only covers the happy path is incomplete, even if the happy-path coverage is thorough.
- **No skipped tests without a `skip "<reason>"` (bats) or `-Pending "<reason>"` (Pester) marker** explaining the gate. A silent `return` early in a test is dead code masquerading as a test.
- **One test = one assertion-cluster.** A test that checks 8 unrelated things across 80 lines is a coverage report, not a test - when it fails, you don't know which assertion broke.
- **Tests assert on behavior, not implementation.** `assert_output --partial "F-001"` is robust; `assert_output "exactly this 80-char string"` is fragile and reformats break it.
- **Helper functions in tests are named distinctly from production functions** to avoid confusion when reading a stack trace. `_test_setup_fixture_dir` not `setup_dir`.

## What NOT to flag

- **The choice of `bats-core` and `Pester`.** Project convention; not under review here.
- **The function-redef stubbing pattern.** See [`docs/decisions.md` → "Why phase-based orchestration with side-effect stubs"](../../../docs/decisions.md#why-phase-based-orchestration-with-side-effect-stubs). It's the load-bearing testing approach.
- **The decision to NOT use a heavyweight mocking framework.** Intentional - keeps test files self-contained and readable.
- **Test files mirroring source-file names.** `test_<file>.bats` for `<file>.sh` is the convention; don't suggest reorganizing.
- **Length of test files.** Some are long because the surface they test is wide. Flag bad tests, not test count.
- **Use of `BATS_TEST_TMPDIR` over `mktemp`.** The former is auto-cleaned and CI-friendly.
- **Anything already in [`design/reviews/accepted.md`](../accepted.md).**

## Severity rubric

| Level    | Definition                                                                                                                                   | Examples                                                                                                                                                                     |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| critical | A test asserts the wrong thing - green CI does not reflect green code. A mock that diverges from prod in a behavior-changing way.            | Test asserts `output == "ok"` when prod prints `"OK"` (test passes via case-insensitive match it doesn't realize); mock returns `0` for an error case prod would return `1`. |
| high     | A test silently skips most of its assertions due to a setup failure; mock leaks across test files; no edge-case coverage on a critical path. | `setup()` fails silently; the body's `assert` calls never run. `Mock` not torn down - next test gets stale state. `merge_local_certs` only tested with valid input.          |
| medium   | Test name lies about what it asserts; one test does 5 unrelated things; helper named identically to production fn; setup leaks env var.      | Test named "rejects empty input" but only checks the success case; `function setup_dir` shadows production `setup_dir` in stack traces.                                      |
| low      | Comment rot, fragile string-exact assertion, missing skip-reason, unused helper, test file with no `@test` blocks (just helpers).            | `# Tests for X` where X was renamed; assert on a 200-char output that breaks on whitespace tweaks; orphan helper.                                                            |

## Categories

| Category        | Use for                                                                                   |
| --------------- | ----------------------------------------------------------------------------------------- |
| correctness     | A test asserts the wrong thing or fails to assert what it claims.                         |
| security        | A test that exec's untrusted input; a mock that suppresses a real security check.         |
| maintainability | Bad test name; one test = many assertions; helper naming collision; setup/teardown drift. |
| testability     | A code path that's hard to reach via the existing pattern; missing seam noted in test.    |
| docs            | Test file lacks a top-of-file comment explaining what surface it covers.                  |

## References

- [`docs/decisions.md` → "Why phase-based orchestration with side-effect stubs"](../../../docs/decisions.md#why-phase-based-orchestration-with-side-effect-stubs)
- `tests/bats/test_nix_setup.bats` - canonical example of phase-function unit tests via function redef
- `tests/pester/WslSetupPhases.Tests.ps1` - canonical example of Pester phase-function tests with synthetic state hashtables
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes for this shard

## Charter version

- v1 (2026-05-09) - initial draft. Expect refinement after the first `/review test-quality` cycle, especially around what "edge-case coverage" actually means for each test surface.
