#!/usr/bin/env bats
# Unit tests for nix/configure/nodejs_remove.sh
# Covers: no-op when fnm dir missing, unattended removal, prompt-skip,
# version enumeration warning, missing node-versions subdirectory.

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/nix/configure/nodejs_remove.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "no-op when ~/.local/share/fnm is not installed" {
  [ ! -d "$HOME/.local/share/fnm" ]
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unattended removes ~/.local/share/fnm without prompting" {
  mkdir -p "$HOME/.local/share/fnm/node-versions/v20.10.0/installation/bin"
  : >"$HOME/.local/share/fnm/node-versions/v20.10.0/installation/bin/node"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.local/share/fnm" ]
  [[ "$output" == *"removed"*"fnm"* ]]
}

@test "unattended lists installed Node versions before removal" {
  mkdir -p "$HOME/.local/share/fnm/node-versions/v18.20.0" \
    "$HOME/.local/share/fnm/node-versions/v20.10.0" \
    "$HOME/.local/share/fnm/node-versions/v22.5.1"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 Node.js version(s)"* ]]
  [[ "$output" == *"v18.20.0"* ]]
  [[ "$output" == *"v20.10.0"* ]]
  [[ "$output" == *"v22.5.1"* ]]
  [ ! -d "$HOME/.local/share/fnm" ]
}

@test "interactive declined leaves ~/.local/share/fnm in place" {
  mkdir -p "$HOME/.local/share/fnm/node-versions/v20.10.0"

  # The script's own `[ ! -t 0 ]` guard short-circuits the prompt when
  # stdin is not a terminal (cf. ARCHITECTURE.md §7.9). `</dev/null` here
  # makes stdin a non-tty, so the script exits 0 with "Skipped" without
  # ever touching /dev/tty - regardless of whether the test runner itself
  # has a controlling terminal.
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  [ -d "$HOME/.local/share/fnm" ]
  [[ "$output" == *"Skipped"* ]] || [[ "$output" == *"retained"* ]]
}

@test "handles fnm dir without node-versions subdirectory" {
  # fnm creates ~/.local/share/fnm before any `fnm install` runs, so the
  # node-versions subdirectory may legitimately be absent. The version
  # enumeration loop must not error in that case.
  mkdir -p "$HOME/.local/share/fnm/aliases"
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.local/share/fnm" ]
  # No "N Node.js version(s)" warning when the directory is empty
  [[ "$output" != *"version(s)"* ]]
}
