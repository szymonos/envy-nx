#!/usr/bin/env bats
# Unit tests for nix/configure/gcloud_remove.sh
# Covers: no-op when SDK dir missing, unattended removal, prompt-skip on
# non-tty, interactive declined, "removed" message, retention message.

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/nix/configure/gcloud_remove.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "no-op when ~/google-cloud-sdk is not installed" {
  [ ! -d "$HOME/google-cloud-sdk" ]
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unattended removes ~/google-cloud-sdk without prompting" {
  mkdir -p "$HOME/google-cloud-sdk/bin"
  : >"$HOME/google-cloud-sdk/bin/gcloud"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/google-cloud-sdk" ]
  [[ "$output" == *"removed"*"google-cloud-sdk"* ]]
}

@test "unattended notes that ~/.config/gcloud is preserved" {
  mkdir -p "$HOME/google-cloud-sdk/bin"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/.config/gcloud/"* ]]
  [[ "$output" == *"not touched"* ]]
}

@test "interactive declined leaves ~/google-cloud-sdk in place" {
  mkdir -p "$HOME/google-cloud-sdk/bin"
  : >"$HOME/google-cloud-sdk/bin/gcloud"

  # `[ ! -t 0 ]` guard short-circuits when stdin is not a terminal; cf.
  # ARCHITECTURE.md §7.9. Same pattern as test_nodejs_remove.bats /
  # test_python_remove.bats.
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  [ -d "$HOME/google-cloud-sdk" ]
  [[ "$output" == *"Skipped"* && "$output" == *"retained"* ]]
}

@test "skips component enumeration when gcloud binary is not executable" {
  # Component enumeration is best-effort: if the binary is missing or
  # broken, the script should still proceed to the prompt/removal path.
  mkdir -p "$HOME/google-cloud-sdk/bin"
  # No bin/gcloud at all - simulates a corrupted install.

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/google-cloud-sdk" ]
  # No "component(s) will be removed" line - enumeration was skipped.
  [[ "$output" != *"component(s) will be removed"* ]]
}
