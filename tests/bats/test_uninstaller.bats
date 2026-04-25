#!/usr/bin/env bats
# Unit tests for nix/uninstall.sh --dry-run behavior.
# shellcheck disable=SC2034  # DRY_RUN is read by _rm helper extracted from uninstall.sh
bats_require_minimum_version 1.5.0

setup() {
  TEST_HOME="$(mktemp -d)"

  # extract helpers from uninstall.sh without running arg parsing or main
  eval "$(sed -n '/^# -- Helpers/,/^# -- Parse args/{ /^# -- Parse args/d; p; }' \
    "$BATS_TEST_DIRNAME/../../nix/uninstall.sh")"
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "dry-run: _rm does not delete files" {
  local target="$TEST_HOME/keep_me.txt"
  echo "data" >"$target"
  DRY_RUN="true"
  _rm "$target"
  [[ -f "$target" ]]
}

@test "dry-run: _rm prints would-remove for existing file" {
  local target="$TEST_HOME/existing.txt"
  echo "data" >"$target"
  DRY_RUN="true"
  run _rm "$target"
  [[ "$output" == *"would remove"* ]]
  [[ "$output" == *"$target"* ]]
}

@test "dry-run: _rm prints would-remove for directory" {
  local target="$TEST_HOME/subdir"
  mkdir -p "$target"
  DRY_RUN="true"
  run _rm "$target"
  [[ "$output" == *"would remove"* ]]
}

@test "dry-run: _rm prints would-remove for symlink" {
  local real="$TEST_HOME/real.txt"
  local link="$TEST_HOME/link.txt"
  echo "data" >"$real"
  ln -s "$real" "$link"
  DRY_RUN="true"
  run _rm "$link"
  [[ "$output" == *"would remove"* ]]
  [[ -L "$link" ]]
}

@test "dry-run: _rm is silent for non-existent target" {
  DRY_RUN="true"
  run _rm "$TEST_HOME/does_not_exist"
  [[ -z "$output" ]]
}

@test "real mode: _rm deletes file" {
  local target="$TEST_HOME/delete_me.txt"
  echo "data" >"$target"
  DRY_RUN="false"
  _rm "$target"
  [[ ! -f "$target" ]]
}

@test "real mode: _rm deletes directory" {
  local target="$TEST_HOME/delete_dir"
  mkdir -p "$target"
  DRY_RUN="false"
  _rm "$target"
  [[ ! -d "$target" ]]
}
