#!/usr/bin/env bats
# Unit tests for .assets/provision/install_copilot.sh - footer quota setting.
bats_require_minimum_version 1.5.0

setup() {
  command -v jq >/dev/null || skip "jq not installed"
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.assets/provision/install_copilot.sh"
  SETTINGS="$HOME/.copilot/settings.json"

  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME/.local/bin/copilot"
  chmod +x "$HOME/.local/bin/copilot"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "missing file is created with showQuota true" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$SETTINGS")" = '{"footer":{"showQuota":true}}' ]
}

@test "unset key is added and other settings are kept" {
  mkdir -p "$HOME/.copilot"
  printf '{"theme":"dark","footer":{"cwd":true}}\n' >"$SETTINGS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$SETTINGS")" = '{"theme":"dark","footer":{"cwd":true,"showQuota":true}}' ]
}

@test "explicit false is kept" {
  mkdir -p "$HOME/.copilot"
  printf '{"footer":{"showQuota":false}}\n' >"$SETTINGS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$SETTINGS")" = '{"footer":{"showQuota":false}}' ]
}

@test "empty, whitespace and multi-document files are left untouched" {
  mkdir -p "$HOME/.copilot"
  for content in '' '  ' '{} {}'; do
    printf '%s' "$content" >"$SETTINGS"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a single JSON object"* ]]
    [ "$(cat "$SETTINGS")" = "$content" ]
  done
}

@test "invalid JSON is left untouched with a warning" {
  mkdir -p "$HOME/.copilot"
  printf '{broken' >"$SETTINGS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a single JSON object"* ]]
  [ "$(cat "$SETTINGS")" = '{broken' ]
  [ "$(find "$HOME/.copilot" -type f | wc -l)" -eq 1 ]
}
