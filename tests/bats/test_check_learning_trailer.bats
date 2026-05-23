#!/usr/bin/env bats
# Unit tests for tests/hooks/check_learning_trailer.py - commit-msg-stage hook
# that nudges for a Codified-Learning trailer on high-leverage changes.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

# Resolve the source-repo root so the Python module path resolves.
REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  # Temp git repo serves as the "target" tree the hook scans for staged files.
  TEST_REPO="$(mktemp -d)"
  git -C "$TEST_REPO" init --quiet --initial-branch=main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"

  # Commit-msg file the hook reads as argv[0].
  COMMIT_MSG="$TEST_REPO/.git/COMMIT_EDITMSG"
}

teardown() {
  rm -rf "$TEST_REPO"
}

# Helper: stage a file under TEST_REPO at the given path with arbitrary content.
_stage_file() {
  local path="$1"
  mkdir -p "$TEST_REPO/$(dirname "$path")"
  echo "test content" >"$TEST_REPO/$path"
  git -C "$TEST_REPO" add "$path"
}

# Helper: run the hook with REPO_ROOT pointing at TEST_REPO (so the staged-
# files lookup hits the test fixture, not the actual envy-nx repo).
_run_hook() {
  CHECK_LEARNING_REPO_ROOT="$TEST_REPO" \
    python3 -m tests.hooks.check_learning_trailer "$COMMIT_MSG"
}

@test "high-leverage file staged + no trailer => fail with nudge" {
  _stage_file ".assets/lib/nx_pkg.sh"
  echo "fix(nx): tweak install path" >"$COMMIT_MSG"
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 1 ]]
  [[ "$stderr" == *"Codified-Learning nudge"* ]] || [[ "$output" == *"Codified-Learning nudge"* ]]
  [[ "$stderr" == *".assets/lib/nx_pkg.sh"* ]] || [[ "$output" == *".assets/lib/nx_pkg.sh"* ]]
}

@test "high-leverage file staged + Codified-Learning trailer => pass" {
  _stage_file ".assets/lib/nx_pkg.sh"
  cat >"$COMMIT_MSG" <<'EOF'
fix(nx): tweak install path

Codified-Learning: nix-built pwsh leaks LD_LIBRARY_PATH so always invoke
through _io_pwsh_nop, never bare pwsh.
EOF
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "high-leverage file staged + tagged Codified-Learning(tag) trailer => pass" {
  _stage_file "tests/hooks/check_bash32.py"
  cat >"$COMMIT_MSG" <<'EOF'
fix(hooks): tighten regex for mapfile detection

Codified-Learning(do-not-repeat): tagged trailers must be recognized too.
EOF
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "high-leverage file staged + # no-learning skip token => pass" {
  _stage_file ".assets/lib/nx_scope.sh"
  cat >"$COMMIT_MSG" <<'EOF'
chore(nx): rename a local variable for clarity

# no-learning - no generalization beyond the local rename.
EOF
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "non-high-leverage file staged + no trailer => pass" {
  _stage_file "docs/some_user_doc.md"
  echo "docs: fix typo" >"$COMMIT_MSG"
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "nix/lib/phases path matches high-leverage regex" {
  _stage_file "nix/lib/phases/bootstrap.sh"
  echo "fix(bootstrap): adjust ordering" >"$COMMIT_MSG"
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 1 ]]
}

@test "tests/hooks path matches high-leverage regex" {
  _stage_file "tests/hooks/some_hook.py"
  echo "fix(hook): edge case" >"$COMMIT_MSG"
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 1 ]]
}

@test "no staged files + no trailer => pass (no-op)" {
  echo "chore: refactor on a branch with no staged content yet" >"$COMMIT_MSG"
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 0 ]]
}

@test "missing argv (no commit-msg path) => pass" {
  cd "$REPO_SRC"
  run env CHECK_LEARNING_REPO_ROOT="$TEST_REPO" \
    python3 -m tests.hooks.check_learning_trailer
  [[ "$status" -eq 0 ]]
}

@test "trailer with mixed case key is rejected (must match Codified-Learning exactly)" {
  _stage_file ".assets/lib/nx_pkg.sh"
  cat >"$COMMIT_MSG" <<'EOF'
fix(nx): tweak install path

codified-learning: lower-case key should not match the trailer regex.
EOF
  cd "$REPO_SRC"
  run _run_hook
  [[ "$status" -eq 1 ]]
}

@test "git failure is fail-closed (non-zero exit, not silent pass)" {
  # Regression test: _staged_files() must check git's exit code. Pointing
  # CHECK_LEARNING_REPO_ROOT at a non-git directory makes `git diff --cached`
  # fail; the hook must surface that as a non-zero exit, not silently treat
  # the empty result as "no staged files" and pass.
  NON_GIT_DIR="$(mktemp -d)"
  echo "anything" >"$COMMIT_MSG"
  cd "$REPO_SRC"
  run env CHECK_LEARNING_REPO_ROOT="$NON_GIT_DIR" \
    python3 -m tests.hooks.check_learning_trailer "$COMMIT_MSG"
  [[ "$status" -ne 0 ]]
  [[ "$stderr" == *"git diff failed"* ]] || [[ "$output" == *"git diff failed"* ]]
  rm -rf "$NON_GIT_DIR"
}
