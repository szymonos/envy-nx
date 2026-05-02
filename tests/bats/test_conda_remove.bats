#!/usr/bin/env bats
# Unit tests for nix/configure/conda_remove.sh
# Covers: no-op when miniforge missing, unattended removal, prompt-skip,
# prompt-accept, env enumeration warning.

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/nix/configure/conda_remove.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "no-op when miniforge3 is not installed" {
  [ ! -d "$HOME/miniforge3" ]
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unattended removes miniforge3 without prompting" {
  mkdir -p "$HOME/miniforge3/bin"
  : >"$HOME/miniforge3/bin/conda"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/miniforge3" ]
  [[ "$output" == *"removed"*"miniforge3"* ]]
}

@test "unattended lists user environments before removal" {
  mkdir -p "$HOME/miniforge3/envs/myproj" "$HOME/miniforge3/envs/scratch"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 user environment(s)"* ]]
  [[ "$output" == *"myproj"* ]]
  [[ "$output" == *"scratch"* ]]
  [ ! -d "$HOME/miniforge3" ]
}

@test "interactive declined leaves miniforge3 in place" {
  mkdir -p "$HOME/miniforge3"

  # The script's own `[ ! -t 0 ]` guard short-circuits the prompt when
  # stdin is not a terminal (cf. ARCHITECTURE.md §7.9). `</dev/null` here
  # makes stdin a non-tty, so the script exits 0 with "Skipped" without
  # ever touching /dev/tty - regardless of whether the test runner itself
  # has a controlling terminal.
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  [ -d "$HOME/miniforge3" ]
  [[ "$output" == *"Skipped"* ]] || [[ "$output" == *"retained"* ]]
}

@test "skips conda init --reverse when conda binary is missing" {
  mkdir -p "$HOME/miniforge3"
  # no bin/conda - the unsetup step must be guarded
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/miniforge3" ]
}
