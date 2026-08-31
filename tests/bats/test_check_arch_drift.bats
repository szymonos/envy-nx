#!/usr/bin/env bats
# Unit tests for tests/hooks/check_arch_drift.py - the hook that holds the
# agent-facing design docs to the tree they describe: no dead path references,
# no stale counts, no over-budget files.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

# Resolve the source-repo root so the Python module path resolves.
REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  # Fixture tree mirroring the real layout; CHECK_ARCH_DRIFT_ROOT points the
  # hook at it so the bare (whole-tree) scan is what the tests exercise.
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/.assets/lib" "$FIXTURE/tests/bats" "$FIXTURE/design/reviews/charters"
  printf 'echo hi\n' >"$FIXTURE/.assets/lib/real.sh"
  cd "$REPO_SRC" || return 1
}

teardown() {
  rm -rf "$FIXTURE"
}

# Write ARCHITECTURE.md - the doc every test drives the hook through.
_arch() {
  cat >"$FIXTURE/ARCHITECTURE.md"
}

_run_hook() {
  CHECK_ARCH_DRIFT_ROOT="$FIXTURE" python3 -m tests.hooks.check_arch_drift "$@"
}

# ---- A. dead path references ------------------------------------------------

@test "path check: reference to an existing file => pass" {
  _arch <<'EOF'
See `.assets/lib/real.sh` for the helper.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "path check: reference to a missing file => fail naming the path" {
  _arch <<'EOF'
See `.assets/lib/gone.sh` for the helper.
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"ARCHITECTURE.md:1"* ]]
  [[ "$output" == *".assets/lib/gone.sh"* ]]
}

@test "path check: unrooted path (runtime destination) is ignored" {
  # §13 runtime-layout tables name destinations under ~/.config, not repo paths.
  _arch <<'EOF'
| `omp/theme.omp.json` | `.assets/lib/real.sh` |
| `Scripts/_aliases_nix.ps1` | installed copy |
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "path check: glob reference is ignored" {
  _arch <<'EOF'
Scope files live in `.assets/lib/*.sh`.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "path check: bare filename without a directory is ignored" {
  _arch <<'EOF'
The entry point is `nx.sh` and the manifest is `nx_surface.json`.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "path check: charter with a dead file row => fail" {
  # A charter's file table decides what a review shard looks at; a dead row
  # silently under-reviews.
  cat >"$FIXTURE/design/reviews/charters/certs.md" <<'EOF'
| `.assets/lib/vanished.sh` | Per-tool env exports |
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"charters/certs.md:1"* ]]
}

@test "path check: proposal opt-out exempts forward references" {
  cat >"$FIXTURE/design/proposal.md" <<'EOF'
<!-- arch-drift: proposal -->
We would add `nix/lib/not_yet.sh` to carry the seam.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "path check: proposal opt-out does NOT exempt counts" {
  printf 'x\ny\n' >"$FIXTURE/.assets/lib/two.sh"
  cat >"$FIXTURE/design/proposal.md" <<'EOF'
<!-- arch-drift: proposal -->
Budget note <!-- arch:max-lines .assets/lib/two.sh 1 -->
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"over its stated budget"* ]]
}

# ---- B. line budgets --------------------------------------------------------

@test "max-lines: file within budget => pass" {
  printf 'a\nb\nc\n' >"$FIXTURE/.assets/lib/three.sh"
  _arch <<'EOF'
A slim helper (~3 lines <!-- arch:max-lines .assets/lib/three.sh 10 -->).
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "max-lines: file over budget => fail with actual and budget" {
  printf 'a\nb\nc\nd\ne\n' >"$FIXTURE/.assets/lib/five.sh"
  _arch <<'EOF'
A slim helper (~2 lines <!-- arch:max-lines .assets/lib/five.sh 2 -->).
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"is 5 lines, over its stated budget of 2"* ]]
}

@test "max-lines: missing target => fail rather than silently pass" {
  _arch <<'EOF'
Budget <!-- arch:max-lines .assets/lib/absent.sh 10 -->
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"does not exist"* ]]
}

# ---- C. exact counts --------------------------------------------------------

@test "count: matching count => pass" {
  printf '@test "a" {\n}\n@test "b" {\n}\n' >"$FIXTURE/tests/bats/sample.bats"
  _arch <<'EOF'
2 tests <!-- arch:count tests/bats/sample.bats '^@test' 2 --> cover it.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "count: mismatched count => fail with actual and claimed" {
  printf '@test "a" {\n}\n@test "b" {\n}\n@test "c" {\n}\n' >"$FIXTURE/tests/bats/sample.bats"
  _arch <<'EOF'
2 tests <!-- arch:count tests/bats/sample.bats '^@test' 2 --> cover it.
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"has 3 lines matching"* ]]
  [[ "$output" == *"claims 2"* ]]
}

@test "count: quoted regex containing a space parses" {
  printf '    It "one" {\n    }\n    It "two" {\n    }\n' >"$FIXTURE/tests/bats/sample.bats"
  _arch <<'EOF'
2 tests <!-- arch:count tests/bats/sample.bats '^\s*It ' 2 --> cover it.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "count: glob target sums across files" {
  printf '@test "a" {\n}\n' >"$FIXTURE/tests/bats/one.bats"
  printf '@test "b" {\n}\n' >"$FIXTURE/tests/bats/two.bats"
  _arch <<'EOF'
2 tests <!-- arch:count tests/bats/*.bats '^@test' 2 --> cover it.
EOF
  run _run_hook
  [[ "$status" -eq 0 ]]
}

# ---- marker hygiene ---------------------------------------------------------

@test "malformed marker: too few arguments => fail loudly" {
  _arch <<'EOF'
Broken <!-- arch:count tests/bats/sample.bats -->
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"arch:count takes"* ]]
}

@test "malformed marker: non-numeric budget => fail loudly" {
  _arch <<'EOF'
Broken <!-- arch:max-lines .assets/lib/real.sh many -->
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"must be a number"* ]]
}

@test "malformed marker: invalid regex => fail loudly" {
  _arch <<'EOF'
Broken <!-- arch:count .assets/lib/real.sh '[unclosed' 1 -->
EOF
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"is invalid"* ]]
}

@test "clean tree with no docs at all => pass" {
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "marker inside backticks is documentation, not a claim" {
  # ARCHITECTURE.md §8 documents the marker syntax; it must not self-trigger.
  _arch <<'INNER'
Use `<!-- arch:max-lines -->` and `<!-- arch:count -->` to state a claim.
INNER
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "path check: extensionless repo path is validated, not skipped" {
  # Rooting supplies the precision; requiring a file extension would skip
  # extensionless targets and hyphenated suffixes (second-opinion F-001).
  _arch <<'INNER'
The shim is `.assets/lib/bin/gone` and the image is `.assets/docker/Dockerfile.test-nix`.
INNER
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *".assets/lib/bin/gone"* ]]
}

@test "path check: a ::symbol locator is stripped, the file still validated" {
  # ARCHITECTURE.md cites `tests/hooks/_file_scopes.py::INTERACTIVE_SHELL` twice;
  # requiring the path to end at the backtick skipped both (Copilot PR #76).
  _arch <<'INNER'
The set lives in `.assets/lib/vanished.py::SOME_CONST` and is authoritative.
INNER
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$output" == *".assets/lib/vanished.py"* ]]
}

@test "path check: a :line locator is stripped too" {
  _arch <<'INNER'
See `.assets/lib/real.sh:42` for the guard.
INNER
  run _run_hook
  [[ "$status" -eq 0 ]]
}
